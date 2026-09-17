--!nonstrict
-- Lan Mouse poller — the headless [[service]] entry.
--
-- Two independent sources, both cheap enough to read on every tick:
-- - away_sentinel: a plain file nixos-config's lan-mouse.nix `enter_hook`
--   writes (holding the peer's name) when control leaves this host, and
--   removes when control arrives back. lan-mouse has no IPC/CLI query for
--   this, so the sentinel is the only source of truth for "who has it now".
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

local function publish(away, peerName, peers)
  local parts = {}
  for _, peer in ipairs(peers) do
    table.insert(parts, peer.hostname .. ":" .. tostring(peer.active))
  end
  local key = tostring(away) .. "|" .. (peerName or "") .. "|" .. table.concat(parts, ",")
  if key == lastKey then
    return
  end
  lastKey = key
  noctalia.state.set("lan_mouse_status", {
    away = away,
    peerName = peerName,
    peers = peers,
  })
end

local function poll()
  local path = sentinelPath()
  local away = noctalia.fileExists(path)
  local peerName = away and noctalia.string.trim(noctalia.readFile(path) or "") or nil
  if peerName == "" then
    peerName = nil
  end

  noctalia.runAsync({ "lan-mouse", "cli", "list" }, function(result)
    local peers = result.exitCode == 0 and parsePeers(result.stdout or "") or {}
    publish(away, peerName, peers)
  end, POLL_TIMEOUT_MS)
end

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
