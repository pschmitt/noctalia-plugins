--!nonstrict
-- Battery icon bar widget — displays the pre-rendered PNG from the
-- service (percentage baked directly into the icon body). Left-click opens
-- this plugin's compact power panel under the bar widget.

local state = noctalia.state.get("battery_icon")
local PANEL_ID = "pschmitt/battery-icon:power"

local function render()
  if state == nil or state.path == nil then
    barWidget.setVisible(false)
    return
  end

  local width = tonumber(noctalia.getConfig("icon_width")) or 36
  local height = tonumber(noctalia.getConfig("icon_height")) or 18

  barWidget.setVisible(true)
  barWidget.render(ui.row({}, {
    -- fit="contain": the rendered PNG is 128x64 (2:1, wider than the
    -- battery body itself to leave room for either the terminal or charging
    -- bolt) — without contain, a mismatched display box stretches it.
    ui.image({ path = state.path, width = width, height = height, fit = "contain" }),
  }))
  local suffix = state.charging and " (charging)" or (state.powerSaver and " (Battery Saver)" or "")
  barWidget.setTooltip(tostring(state.percent) .. "%" .. suffix)
end

noctalia.state.watch("battery_icon", function(val)
  state = val
  render()
end)

render()

function update()
  render()
end

function onClick()
  runAction("action_left_click")
end

-- Configurable bar actions follow the same scroll convention as Noctalia's
-- built-in widgets: positive steps are scroll-down.
local function toggleCaffeine()
  local details = noctalia.state.get("battery_icon.details") or {}
  noctalia.state.set("battery_icon.command", {
    action = "set_caffeine",
    enabled = details.caffeineEnabled ~= true,
  })
end

local ACTIONS = {
  panel = function()
    noctalia.togglePanel(PANEL_ID)
  end,
  cycle_power_profile = function()
    noctalia.runAsync("noctalia msg power-cycle", function(_result) end, 5000)
  end,
  toggle_caffeine = toggleCaffeine,
}

function runAction(settingKey)
  local action = ACTIONS[noctalia.getConfig(settingKey)]
  if action then
    action()
  end
end

function onRightClick()
  runAction("action_right_click")
end

function onMiddleClick()
  runAction("action_middle_click")
end

function onScroll(_axis, steps, _startsGesture)
  runAction(steps > 0 and "action_scroll_down" or "action_scroll_up")
end
