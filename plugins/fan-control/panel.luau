--!nonstrict

local SNAPSHOT = "fan.snapshot"
local COMMAND = "fan.command"

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
local reqId = 0
local render

-- Live-preview value while the slider is being dragged, so onChange can
-- update the on-screen percentage without spamming the service; the actual
-- write only fires once, from onDragEnd.
local sliderPreview = nil
-- The last percent committed via onDragEnd, held onscreen optimistically
-- until the service's own snapshot catches up to it — otherwise the display
-- snaps back to the old percent for the round-trip (a hwmon write + a
-- confirming read) before jumping to the new one, which reads as lag.
-- Cleared once snap.percent matches, so an external change (another client)
-- still shows up rather than getting stuck on a stale target forever.
local optimisticTarget = nil

local function shownPercent()
  if sliderPreview then
    return sliderPreview
  end
  if optimisticTarget and optimisticTarget ~= snap.percent then
    return optimisticTarget
  end
  optimisticTarget = nil
  return snap.percent or 0
end

local function dispatch(payload)
  reqId += 1
  payload.requestId = tostring(os.time()) .. "-" .. tostring(reqId)
  noctalia.state.set(COMMAND, payload)
end

local function modeButton(mode, label)
  local active = snap.mode == mode
  return ui.button({ text = label, variant = active and "primary" or "ghost", flexGrow = 1, onClick = function()
    sliderPreview = nil
    optimisticTarget = nil
    dispatch({ action = "set_mode", mode = mode })
  end })
end

render = function()
  local shown = shownPercent()
  local children = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "car-fan", color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.label({
        text = (snap.rpm or 0) .. " RPM · " .. (snap.temp or 0) .. " °C",
        fontSize = 12,
        color = "on_surface_variant",
      }),
    }),
  }

  if not snap.available then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.unavailable"),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 3,
    }))
    panel.render(ui.column({ gap = 8, padding = 10 }, children))
    return
  end

  table.insert(children, ui.row({ gap = 6 }, {
    modeButton("auto", noctalia.tr("panel.auto")),
    modeButton("full", noctalia.tr("panel.full")),
  }))

  table.insert(children, ui.column({ gap = 6 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("panel.manual"), fontWeight = "medium" }),
      ui.label({ text = tostring(shown) .. "%", fontWeight = "bold", color = "primary" }),
    }),
    ui.slider({
      min = 0,
      max = 100,
      step = tonumber(noctalia.getConfig("percent_step")) or 10,
      value = shown,
      onChange = function(value)
        sliderPreview = tonumber(value) or shown
        render()
      end,
      onDragEnd = function(value)
        local target = sliderPreview or tonumber(value) or shown
        sliderPreview = nil
        optimisticTarget = target
        dispatch({ action = "set_percent", value = target })
      end,
    }),
  }))

  if (snap.fanCount or 0) > 1 then
    local rows = {}
    for i, fan in snap.fans do
      table.insert(rows, ui.label({
        text = noctalia.tr("panel.fan_rpm", { index = tostring(i), rpm = tostring(fan.rpm or 0) }),
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end
    table.insert(children, ui.column({ gap = 2 }, rows))
  end

  panel.render(ui.column({ gap = 8, padding = 10 }, children))
end

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  sliderPreview = nil
  render()
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)
