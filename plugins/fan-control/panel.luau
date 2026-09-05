--!nonstrict

local colors = require("./lib/colors.luau")

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

local function loadColor(value, cpuCount)
  if cpuCount > 0 and value > cpuCount then
    local custom = noctalia.getConfig("load_high_color")
    if type(custom) == "string" and custom ~= "" then
      return custom
    end
    return "on_error"
  end
  return "on_surface_variant"
end

local function metricCard(label, value, color)
  return ui.column({ gap = 2, flexGrow = 1, fill = "surface_variant/0.5", radius = 8, padding = 8 }, {
    ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 15, fontWeight = "bold", color = color }),
  })
end

local function loadMetric(label, value, color)
  return ui.column({ gap = 1, flexGrow = 1, align = "center" }, {
    ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    ui.label({ text = string.format("%.2f", value), fontSize = 14, fontWeight = "bold", color = color }),
  })
end

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

-- ui.graph wants values in [0, 1]. maxValue fixes the scale (e.g. 100 for a
-- °C reading); omit it to auto-scale against the series' own peak (RPM
-- ranges wildly by hardware, from a GPD Pocket's tiny fan to a ThinkPad's).
-- A small floor keeps a flat/near-zero series visible as a line instead of
-- collapsing to nothing.
local function graphSeries(history, key, maxValue)
  local peak = maxValue or 1
  if not maxValue then
    for _, sample in history do
      local v = sample[key] or 0
      if v > peak then
        peak = v
      end
    end
  end
  local series = {}
  for _, sample in history do
    table.insert(series, math.max(0.02, math.min(1, (sample[key] or 0) / peak)))
  end
  return series
end

-- ui.graph has no built-in axis, so the min/max over the visible window is
-- spelled out as text alongside it instead — the only "axis" a sparkline
-- this small has room for.
local function historyRange(history, key)
  local lo, hi = nil, nil
  for _, sample in history do
    local v = sample[key] or 0
    if not lo or v < lo then
      lo = v
    end
    if not hi or v > hi then
      hi = v
    end
  end
  return lo or 0, hi or 0
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
  local loadAvg = snap.loadAvg or {}
  local loadOne = loadAvg.one or 0
  local loadFive = loadAvg.five or 0
  local loadFifteen = loadAvg.fifteen or 0
  local cpuCount = snap.cpuCount or 0
  local children = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "car-fan", color = colors.icon(snap) }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold" }),
    }),
    ui.row({ gap = 6 }, {
      metricCard(noctalia.tr("panel.fan_speed"), (snap.rpm or 0) .. " RPM", "on_surface"),
      metricCard(noctalia.tr("tooltip.temperature"), (snap.temp or 0) .. " °C", "on_surface"),
    }),
    ui.button({ variant = "default", flexGrow = 1, contentAlign = "center" }, {
      ui.label({ text = noctalia.tr("panel.load_average"), fontSize = 10, color = "on_surface_variant" }),
      ui.row({ gap = 4, align = "center", justify = "space_between" }, {
        loadMetric("1m", loadOne, loadColor(loadOne, cpuCount)),
        loadMetric("5m", loadFive, loadColor(loadFive, cpuCount)),
        loadMetric("15m", loadFifteen, loadColor(loadFifteen, cpuCount)),
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
    panel.render(ui.column({ gap = 6, padding = 10 }, children))
    return
  end

  table.insert(children, ui.spacer({ height = 4 }))
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
  table.insert(children, ui.separator({}))

  if #(snap.history or {}) > 1 then
    local tempLo, tempHi = historyRange(snap.history, "temp")
    local rpmLo, rpmHi = historyRange(snap.history, "rpm")
    local loadLo, loadHi = historyRange(snap.history, "load")
    table.insert(children, ui.column({ gap = 4 }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = noctalia.tr("panel.temp_graph"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({
          text = tostring(tempLo) .. "–" .. tostring(tempHi) .. " °C",
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.graph({
        values = graphSeries(snap.history, "temp", 100),
        color = "error",
        lineWidth = 2,
        fillOpacity = 0.2,
        height = 30,
      }),
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = noctalia.tr("panel.rpm_graph"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({
          text = tostring(rpmLo) .. "–" .. tostring(rpmHi) .. " RPM",
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.graph({
        values = graphSeries(snap.history, "rpm"),
        color = "primary",
        lineWidth = 2,
        fillOpacity = 0.2,
        height = 30,
      }),
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = noctalia.tr("panel.load_graph"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({
          text = string.format("%.2f–%.2f", loadLo, loadHi),
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.graph({
        values = graphSeries(snap.history, "load"),
        color = "secondary",
        lineWidth = 2,
        fillOpacity = 0.2,
        height = 30,
      }),
    }))
  end

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

  panel.render(ui.column({ gap = 6, padding = 10 }, children))
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
