local busy = false
local function run(action)
  if busy then return end
  busy = true
  noctalia.runAsync({ "touch-keyboard", action }, function(result)
    busy = false
    noctalia.state.set("touch_keyboard", {
      enabled = (result.stdout or ""):match("enabled") ~= nil,
      error = result.exitCode ~= 0,
    })
  end, 3000)
end

function onIpc(action)
  if action == "toggle" or action == "show" or action == "hide" then run(action) end
end

function update() run("status") end
noctalia.setUpdateInterval(1000)
run("status")
