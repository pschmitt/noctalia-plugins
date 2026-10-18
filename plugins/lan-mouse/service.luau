--!nonstrict
-- Lan Mouse poller — the headless [[service]] entry.
--
-- Three independent sources, all cheap enough to read on every tick:
-- - away_sentinel: a plain file nixos-config's lan-mouse.nix `enter_hook`
--   writes (holding the peer's name) when control leaves this host, and
--   removes when control arrives back. lan-mouse has no IPC/CLI query for
--   this, so the sentinel is the only source of truth for "who has it now".
-- - incoming_sentinel: away_sentinel's counterpart on the *receiving* side --
--   present (holding the source host's name) while a peer's input is
--   flowing into this host. Drives lockscreen.luau's visibility: that
--   button is only relevant while this is true.
-- - `lan-mouse cli list`: per-client connection state (hostname, position,
--   active), independent of who currently owns the cursor.

local POLL_TIMEOUT_MS = 3000

local function pollMs()
  return math.clamp(math.floor(tonumber(noctalia.getConfig("poll_interval")) or 2), 1, 30) * 1000
end

-- Settings carry the literal "$XDG_RUNTIME_DIR"/"$HOME" text (matching
-- lan-mouse.nix's own script) rather than a pre-expanded path, since the
-- runtime dir is only known at runtime, not at config-authoring time.
local function expandEnvVars(path)
  return (path:gsub("%$(%u[%u_]*)", function(name)
    return noctalia.getenv(name) or ""
  end))
end

local function sentinelPath()
  local configured = noctalia.string.trim(noctalia.getConfig("away_sentinel") or "")
  if configured == "" then
    configured = "$XDG_RUNTIME_DIR/lan-mouse-away"
  end
  return noctalia.expandPath(expandEnvVars(configured))
end

local function incomingSentinelPath()
  local configured = noctalia.string.trim(noctalia.getConfig("incoming_sentinel") or "")
  if configured == "" then
    configured = "$XDG_RUNTIME_DIR/lan-mouse-incoming"
  end
  return noctalia.expandPath(expandEnvVars(configured))
end

-- `lan-mouse cli list` prints one line per configured client, e.g.:
--   id 0: gk4:4242 (right) active: true, ips: {...}
local function parsePeers(raw)
  local peers = {}
  for line in raw:gmatch("[^\r\n]+") do
    local id, hostname, position, active = line:match("^id (%d+): ([^:]+):%d+ %(([%a]+)%) active: (%a+)")
    if id then
      table.insert(peers, {
        id = tonumber(id),
        hostname = hostname,
        position = position,
        active = active == "true",
      })
    end
  end
  return peers
end

local lastKey = ""
local serviceActive = false
local away = false
local peerName = nil
local incoming = false
local incomingFrom = nil
local remoteServiceStates = {}
local remotePolling = {}
local lastRemotePollAt = 0

local function publish(peers)
  local parts = {}
  for _, peer in ipairs(peers) do
    table.insert(parts, peer.hostname .. ":" .. tostring(peer.active) .. ":" .. (peer.remoteServiceState or "checking"))
  end
  local key = tostring(serviceActive)
    .. "|"
    .. tostring(away)
    .. "|"
    .. (peerName or "")
    .. "|"
    .. tostring(incoming)
    .. "|"
    .. (incomingFrom or "")
    .. "|"
    .. table.concat(parts, ",")
  if key == lastKey then
    return
  end
  lastKey = key
  noctalia.state.set("lan_mouse_status", {
    serviceActive = serviceActive,
    away = away,
    peerName = peerName,
    incoming = incoming,
    incomingFrom = incomingFrom,
    peers = peers,
  })
end

local lastPeers = {}
local servicePolling = false
local peerPolling = false

local function pollRemoteServices(peers)
  local now = os.time()
  if lastRemotePollAt > 0 and now - lastRemotePollAt < 10 then
    return
  end
  lastRemotePollAt = now

  for _, peer in ipairs(peers) do
    local hostname = peer.hostname
    if not remotePolling[hostname] then
      remotePolling[hostname] = true
      local sshCommand = noctalia.string.trim(noctalia.getConfig("ssh_command") or "")
      if sshCommand == "" then
        sshCommand = "ssh"
      end
      noctalia.runAsync({
        sshCommand,
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=2",
        hostname,
        "systemctl",
        "--user",
        "is-active",
        "lan-mouse.service",
      }, function(result)
        remotePolling[hostname] = nil
        local serviceState = noctalia.string.trim(result.stdout or "")
        if serviceState == "active" then
          remoteServiceStates[hostname] = "running"
        elseif serviceState == "inactive" then
          remoteServiceStates[hostname] = "stopped"
        elseif serviceState == "failed" then
          remoteServiceStates[hostname] = "failed"
        elseif serviceState == "activating" then
          remoteServiceStates[hostname] = "starting"
        elseif serviceState == "deactivating" then
          remoteServiceStates[hostname] = "stopping"
        elseif serviceState == "unknown" then
          remoteServiceStates[hostname] = "missing"
        else
          remoteServiceStates[hostname] = "unreachable"
        end

        for _, currentPeer in ipairs(lastPeers) do
          if currentPeer.hostname == hostname then
            currentPeer.remoteServiceState = remoteServiceStates[hostname]
            break
          end
        end
        publish(lastPeers)
      end, 3500)
    end
  end
end

local function readSentinels()
  local path = sentinelPath()
  away = noctalia.fileExists(path)
  peerName = away and noctalia.string.trim(noctalia.readFile(path) or "") or nil
  if peerName == "" then
    peerName = nil
  end

  local incomingPath = incomingSentinelPath()
  incoming = noctalia.fileExists(incomingPath)
  incomingFrom = incoming and noctalia.string.trim(noctalia.readFile(incomingPath) or "") or nil
  if incomingFrom == "" then
    incomingFrom = nil
  end
end

local function pollPeers()
  if peerPolling or not serviceActive then
    return
  end
  peerPolling = true
  noctalia.runAsync({ "lan-mouse", "cli", "list" }, function(result)
    peerPolling = false
    if result.exitCode == 0 then
      lastPeers = parsePeers(result.stdout or "")
      for _, peer in ipairs(lastPeers) do
        peer.remoteServiceState = remoteServiceStates[peer.hostname] or "checking"
      end
      pollRemoteServices(lastPeers)
    end
    publish(lastPeers)
  end, POLL_TIMEOUT_MS)
end

local function poll()
  readSentinels()

  -- Publish the sentinel-derived state immediately -- these are cheap
  -- synchronous file reads, unlike the service and CLI checks below.
  -- The service check is separate so a stale sentinel cannot keep either
  -- widget visible after lan-mouse.service has stopped.
  publish(lastPeers)

  if not servicePolling then
    servicePolling = true
    noctalia.runAsync({ "@systemctl@", "--user", "is-active", "--quiet", "lan-mouse.service" }, function(result)
      servicePolling = false
      serviceActive = result.exitCode == 0
      publish(lastPeers)
      pollPeers()
    end, POLL_TIMEOUT_MS)
  end

  pollPeers()
end

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
