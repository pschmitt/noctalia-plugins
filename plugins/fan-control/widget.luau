--!nonstrict

local SNAPSHOT = "fan.snapshot"
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

-- "full" (fans running uncapped, no software limit) and a low manual percent
-- both deserve a warning color; a comfortable manual level is just the accent.
local function accent()
  if noctalia.getConfig("colorize_by_status") == false then
    return "on_surface"
  end
  if snap.mode == "full" then
    return "error"
  elseif snap.mode == "manual" then
    return "primary"
  end
  return "on_surface"
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

  if not isVertical then
    table.insert(children, ui.label({
      text = (snap.rpm or 0) .. " RPM",
      fontWeight = "bold",
      color = color,
    }))
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

function onClick()
  if noctalia.getConfig("allow_popup") ~= false then
    noctalia.togglePanel(PANEL_ID)
  end
end

noctalia.setUpdateInterval(30000)
render()
