local busy = false
local lastEnabled, lastError = nil, nil
-- The status (is squeekboard running) only changes through this plugin or an
-- external kill, and every read spawns bash plus pgrep: a slow safety net is
-- enough, user actions refresh immediately through onIpc.
local POLL_MS = 5000
local function run(action)
  if busy then return end
  busy = true
  noctalia.runAsync({ "touch-keyboard", action }, function(result)
    busy = false
    local enabled = (result.stdout or ""):match("enabled") ~= nil
    local failed = result.exitCode ~= 0
    if enabled == lastEnabled and failed == lastError then
      return
    end
    lastEnabled, lastError = enabled, failed
    noctalia.state.set("touch_keyboard", { enabled = enabled, error = failed })
  end, 3000)
end

function onIpc(action)
  if action == "toggle" or action == "show" or action == "hide" then run(action) end
end

function update() run("status") end
noctalia.setUpdateInterval(POLL_MS)
run("status")
