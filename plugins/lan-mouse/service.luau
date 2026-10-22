--!nonstrict
-- Read a complete local daemon snapshot each tick. No cross-host SSH and
-- no replay of edge hooks: a fresh widget immediately recovers current state.
local polling = false
local generation = 0
local serviceActive = false

local function pollMs()
  return math.clamp(math.floor(tonumber(noctalia.getConfig("poll_interval")) or 1), 1, 30) * 1000
end

local function publish(snapshot, active)
  serviceActive = active
  local known = type(snapshot) == "table"
  local incoming = known and snapshot.incoming or {}
  noctalia.state.set("lan_mouse_status", {
    serviceActive = active,
    controlKnown = known and snapshot.pending == nil,
    pendingPeer = known and snapshot.pending or nil,
    away = known and snapshot.outgoing ~= nil,
    peerName = known and snapshot.outgoing or nil,
    incoming = #incoming > 0,
    incomingFrom = table.concat(incoming, ", "),
    captureEnabled = known and snapshot.capture_enabled == true,
    emulationEnabled = known and snapshot.emulation_enabled == true,
    peers = known and snapshot.peers or {},
  })
end

local function poll()
  if polling then
    return
  end
  polling = true
  generation += 1
  local request = generation
  noctalia.runAsync({ "lan-mouse", "cli", "input-state" }, function(result)
    if request ~= generation then
      return
    end
    local snapshot = result.exitCode == 0 and noctalia.json.decode(result.stdout or "") or nil
    if type(snapshot) == "table" and type(snapshot.incoming) == "table" and type(snapshot.peers) == "table" then
      polling = false
      publish(snapshot, true)
      return
    end
    -- Drop all previous routing data immediately on IPC failure. Check the
    -- unit only to distinguish stopped from running-but-state-unavailable.
    publish(nil, serviceActive)
    noctalia.runAsync({ "@systemctl@", "--user", "is-active", "--quiet", "lan-mouse.service" }, function(status)
      if request == generation then
        polling = false
        publish(nil, status.exitCode == 0)
      end
    end, 1000)
  end, 1500)
end

publish(nil, false)
poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
