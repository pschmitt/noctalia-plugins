--!nonstrict

local SNAPSHOT = "fan.snapshot"
local COMMAND = "fan.command"
local PANEL_ID = "pschmitt/fan-control:panel"

local snap = noctalia.state.get(SNAPSHOT) or {
  backend = "none",
  available = false,
  temp = 0,
  mode = "auto",
  percent = 0,
  rpm = 0,
  fanCount = 0,
  fans = {},
}
local isVertical = false
local reqId = 0

-- Each mode's color is user-overridable (auto_color/manual_color/full_color
-- settings); empty (the default) falls back to a sensible theme token — an
-- error/warning tint for "full" (uncapped, no software limit), the accent
-- for a manual level, and neutral for auto.
local function configuredColor(key, fallback)
  local custom = noctalia.getConfig(key)
  if type(custom) == "string" and custom ~= "" then
    return custom
  end
  return fallback
end

local function accent()
  if noctalia.getConfig("colorize_by_status") == false then
    return configuredColor("auto_color", "on_surface")
  end
  if snap.mode == "full" then
    return configuredColor("full_color", "error")
  elseif snap.mode == "manual" then
    return configuredColor("manual_color", "primary")
  end
  return configuredColor("auto_color", "on_surface")
end

local function displayText()
  local mode = noctalia.getConfig("bar_display")
  if mode == "temp" then
    return (snap.temp or 0) .. "°C"
  elseif mode == "none" then
    return nil
  end
  return (snap.rpm or 0) .. " RPM"
end

local function modeText()
  if snap.mode == "full" then
    return noctalia.tr("mode.full")
  elseif snap.mode == "manual" then
    return (snap.percent or 0) .. "%"
  end
  return noctalia.tr("mode.auto")
end

local function tooltipRows()
  local rows = {
    { key = noctalia.tr("tooltip.speed"), value = (snap.rpm or 0) .. " RPM" },
    { key = noctalia.tr("tooltip.mode"), value = modeText() },
    { key = noctalia.tr("tooltip.temperature"), value = (snap.temp or 0) .. " °C" },
  }
  if (snap.fanCount or 0) > 1 then
    table.insert(rows, { key = noctalia.tr("tooltip.fans"), value = tostring(snap.fanCount) })
  end
  return rows
end

local function render()
  local color = accent()
  local children = { ui.glyph({ name = "car-fan", color = color }) }

  local text = (not isVertical) and displayText() or nil
  if text then
    table.insert(children, ui.label({ text = text, fontWeight = "bold", color = color }))
  end

  local container = isVertical and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(tooltipRows())
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

function update()
  isVertical = barWidget.isVertical()
  render()
end

function onConfigChanged()
  render()
end

-- ── Configurable bar actions ─────────────────────────────────────────────────

local function dispatch(payload)
  reqId += 1
  payload.requestId = tostring(os.time()) .. "-" .. tostring(reqId)
  noctalia.state.set(COMMAND, payload)
end

-- Reusing snap.percent (already meaningful in every mode — 0 for auto, 100
-- for full, the real duty for manual — see service.luau) means cycling or
-- nudging never causes a surprise jump: "full" -> "manual" via cycle_mode
-- lands on the same 100% it was already spinning at.
local function cycleMode()
  if snap.mode == "auto" then
    dispatch({ action = "set_mode", mode = "full" })
  elseif snap.mode == "full" then
    dispatch({ action = "set_percent", value = snap.percent or 100 })
  else
    dispatch({ action = "set_mode", mode = "auto" })
  end
end

local function adjustPercent(direction)
  local step = tonumber(noctalia.getConfig("percent_step")) or 10
  local target = math.clamp((snap.percent or 0) + direction * step, 0, 100)
  dispatch({ action = "set_percent", value = target })
end

local ACTIONS = {
  panel = function()
    noctalia.togglePanel(PANEL_ID)
  end,
  cycle_mode = cycleMode,
  increase = function() adjustPercent(1) end,
  decrease = function() adjustPercent(-1) end,
}

local function runAction(settingKey)
  if not snap.available then
    return
  end
  local action = ACTIONS[noctalia.getConfig(settingKey)]
  if action then
    action()
  end
end

function onClick()
  runAction("action_left_click")
end

function onRightClick()
  runAction("action_right_click")
end

function onMiddleClick()
  runAction("action_middle_click")
end

function onScroll(_axis, steps, _startsGesture)
  -- Positive steps is a scroll *down* (matches noctalia's own convention,
  -- e.g. niri-active-workspace's onScroll), not up.
  runAction(steps > 0 and "action_scroll_down" or "action_scroll_up")
end

noctalia.setUpdateInterval(30000)
render()
