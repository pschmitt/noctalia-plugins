--!nonstrict
-- Timewarrior bar widget entry.
--
-- Declarative render (barWidget.render, not the imperative setGlyph/setText
-- API) so the Timewarrior project logo can sit next to the tracked duration.
-- While nothing is tracked the widget hides by default or, depending on the
-- `visibility` setting, keeps its place showing a pause icon — see
-- visibility() below.

local duration = require("./lib/duration.luau")

local state = noctalia.state.get("tw_status") or { active = false, duration = "" }

local LOGO_TRACKING = "assets/timewarrior-logo.svg"
local LOGO_STOPPED = "assets/pause.svg"

local function isOvertime()
  if not state.active then
    return false
  end
  local hours = tonumber(string.match(state.duration or "", "^(%d+):"))
  local threshold = tonumber(noctalia.getConfig("overtime_hours")) or 7
  return hours ~= nil and hours > threshold
end

local function icon(active)
  local size = tonumber(noctalia.getConfig("icon_size")) or 16
  return ui.image({
    path = active and LOGO_TRACKING or LOGO_STOPPED,
    width = size,
    height = size,
    fit = "contain",
  })
end

-- Whether the slot survives an idle timer: "tracking" (vanish, the
-- long-standing default), "always", or "workdays" (Mon-Fri only — a time
-- tracker means nothing on a Sunday). getConfig returns nil for a setting the
-- user has never touched, so anything unrecognised falls back to "tracking".
local function visibility()
  local value = noctalia.getConfig("visibility")
  if value == "always" or value == "workdays" then
    return value
  end
  return "tracking"
end

-- %u is the ISO weekday, 1 (Monday) to 7 (Sunday), formatted in the user's
-- local timezone — so this flips at local midnight rather than UTC's. An
-- unparsable weekday counts as a workday: showing the widget on a Saturday is
-- a much smaller failure than hiding the start button on a Monday.
local function isWorkday()
  local weekday = tonumber(noctalia.formatTime("%u", math.floor(noctalia.nowMs() / 1000)))
  if weekday == nil then
    noctalia.log("timewarrior: could not read the local weekday, assuming a workday")
    return true
  end
  return weekday <= 5
end

local function keepSlotWhileIdle()
  local mode = visibility()
  return mode == "always" or (mode == "workdays" and isWorkday())
end

local function render()
  local active = state.active == true
  local container = barWidget.isVertical() and ui.column or ui.row
  local labelColor = noctalia.getConfig("label_color") or "on_surface"

  if not active then
    if not keepSlotWhileIdle() then
      barWidget.setVisible(false)
      return
    end
    -- The service publishes duration = "" when the timer is off, so there is
    -- no figure to put beside the icon.
    barWidget.setVisible(true)
    barWidget.render(container({ gap = 5, align = "center" }, { icon(false) }))
    barWidget.setTooltip("Timewarrior: not tracking")
    return
  end

  local overtime = isOvertime()
  local color = overtime and (noctalia.getConfig("label_overtime_color") or "error") or labelColor
  local fmt = noctalia.getConfig("bar_time_format")
  if fmt == nil or fmt == "" then
    fmt = "{hours}:{minutes}"
  end

  barWidget.setVisible(true)
  barWidget.render(container({ gap = 5, align = "center" }, {
    icon(true),
    ui.label({ text = duration.format(state.duration, fmt), color = color }),
  }))
  barWidget.setTooltip("Timewarrior: tracking")
end

noctalia.state.watch("tw_status", function(val)
  if type(val) == "table" then
    state = val
    render()
  end
end)

render()

function update()
  render()
end
