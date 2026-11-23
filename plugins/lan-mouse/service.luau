--!nonstrict
-- Local daemon snapshots only. No cross-host SSH and no replay of edge hooks:
-- a fresh widget immediately recovers current state.
--
-- Snapshots are streamed (`lan-mouse cli input-state --watch` prints one JSON
-- line per routing change), so an idle shell spawns nothing per second. While
-- lan-mouse.service is inactive the stream script only re-checks the unit
-- every STREAM_RETRY_S seconds. poll_interval is a slow safety net that
-- re-reads a snapshot when the unit is known to be running.
local polling = false
local generation = 0
local serviceActive = false
local STREAM_RETRY_S = 10
local lastSentinel = nil

local function pollMs()
  return math.clamp(math.floor(tonumber(noctalia.getConfig("poll_interval")) or 30), 1, 300) * 1000
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

local function validSnapshot(snapshot)
  return type(snapshot) == "table" and type(snapshot.incoming) == "table" and type(snapshot.peers) == "table"
end

-- Stdout lines: a JSON snapshot, "inactive" (unit stopped) or "down" (unit
-- running but the watch ended / IPC unavailable). Sentinels repeat while the
-- condition lasts, so only publish when one changes.
local function onStreamLine(line)
  if line == "inactive" or line == "down" then
    if lastSentinel == line then
      return
    end
    lastSentinel = line
    generation += 1
    polling = false
    publish(nil, line == "down")
    return
  end
  local ok, snapshot = pcall(noctalia.json.decode, line)
  if ok and validSnapshot(snapshot) then
    lastSentinel = nil
    generation += 1
    polling = false
    publish(snapshot, true)
  end
end

local STREAM_SCRIPT = "while :; do "
  .. "if @systemctl@ --user is-active --quiet lan-mouse.service; then "
  .. "lan-mouse cli input-state --watch 2>/dev/null; "
  .. "if @systemctl@ --user is-active --quiet lan-mouse.service; then echo down; else echo inactive; fi; "
  .. "else echo inactive; fi; "
  .. "sleep " .. tostring(STREAM_RETRY_S) .. "; done"

publish(nil, false)
noctalia.runStream("sh -c '" .. STREAM_SCRIPT .. "'", onStreamLine)

function update()
  noctalia.setUpdateInterval(pollMs())
  -- The stream reports the unit stopping within STREAM_RETRY_S; skip the
  -- safety-net read while it is known to be inactive.
  if lastSentinel == "inactive" then
    return
  end
  poll()
end
