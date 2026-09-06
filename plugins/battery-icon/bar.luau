--!nonstrict
-- Battery icon bar widget — displays the pre-rendered PNG from the
-- service (percentage baked directly into the icon body). Left-click opens
-- this plugin's compact power panel under the bar widget.

local state = noctalia.state.get("battery_icon")
local details = noctalia.state.get("battery_icon.details") or {}
local PANEL_ID = "pschmitt/battery-icon:power"

local function tooltipRows()
  local status = state.charging and noctalia.tr("tooltip.charging")
    or (details.plugged and noctalia.tr("tooltip.plugged") or "")
  local rows = {
    {
      key = noctalia.tr("tooltip.battery"),
      value = tostring(state.percent or 0) .. "%",
    },
  }
  if status ~= "" then
    table.insert(rows, { key = noctalia.tr("tooltip.state"), value = status })
  end
  if details.health ~= nil then
    table.insert(rows, { key = noctalia.tr("tooltip.health"), value = tostring(details.health) .. "%" })
  end
  if details.thresholdStart ~= nil or details.thresholdEnd ~= nil then
    local threshold = details.thresholdStart and details.thresholdEnd
        and tostring(details.thresholdStart) .. "–" .. tostring(details.thresholdEnd)
      or tostring(details.thresholdEnd or details.thresholdStart)
    table.insert(rows, { key = noctalia.tr("tooltip.charge_limit"), value = threshold .. "%" })
  end

  local devices = details.devices or {}
  if #devices > 0 then
    table.insert(rows, { key = noctalia.tr("tooltip.other_devices"), value = tostring(#devices) })
    for _, device in devices do
      table.insert(rows, {
        key = tostring(device.label or noctalia.tr("panel.not_available")),
        value = tostring(device.percent or 0) .. "%",
      })
    end
  end
  return rows
end

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
  barWidget.setTooltip(tooltipRows())
end

noctalia.state.watch("battery_icon", function(val)
  state = val
  render()
end)

noctalia.state.watch("battery_icon.details", function(value)
  if type(value) == "table" then
    details = value
    render()
  end
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
