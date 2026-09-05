--!nonstrict

local colors = require("./lib/colors.luau")

local SNAPSHOT = "fan.snapshot"
local COMMAND = "fan.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  backend = "none",
  available = false,
  temp = 0,
  mode = "auto",
  level = "auto",
  percent = 0,
  rpm = 0,
  fanCount = 0,
  fans = {},
  loadAvg = { one = 0, five = 0, fifteen = 0 },
  cpuCount = 0,
}
local reqId = 0
local render

local sliderPreview = nil
local fanSliderPreviews = {}
local optimisticTarget = nil
local fanOptimisticTargets = {}

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

local function dispatch(payload)
  reqId += 1
  payload.requestId = tostring(os.time()) .. "-" .. tostring(reqId)
  noctalia.state.set(COMMAND, payload)
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

local function fanPercent(fan)
  return math.floor((fan.pwm or 0) * 100 / 255 + 0.5)
end

local function shownFanPercent(index, fan)
  if fanSliderPreviews[index] ~= nil then
    return fanSliderPreviews[index]
  end
  local current = fanPercent(fan)
  local target = fanOptimisticTargets[index]
  if target ~= nil and target ~= current then
    return target
  end
  fanOptimisticTargets[index] = nil
  return current
end

local function clearSliderState()
  sliderPreview = nil
  fanSliderPreviews = {}
  optimisticTarget = nil
  fanOptimisticTargets = {}
end

local function selectMode(mode)
  clearSliderState()
  dispatch({ action = "set_mode", mode = mode })
end

local function modeButton(mode, glyph, label)
  if mode == "full" then
    return ui.row({
      width = 32,
      height = 32,
      fill = snap.mode == mode and "primary" or nil,
      radius = 8,
      align = "center",
      justify = "center",
      onClick = function()
        selectMode(mode)
      end,
    }, {
      ui.glyph({ name = glyph, size = 18, color = colors.fullColor() }),
    })
  end

  return ui.button({
    glyph = glyph,
    variant = snap.mode == mode and "primary" or "ghost",
    controlSize = "sm",
    tooltip = label,
    onClick = function()
      selectMode(mode)
    end,
  })
end

local function fanRow(index, fan, multiFan, shown)
  local rpm = ui.label({
    text = tostring(fan.rpm or 0) .. " RPM",
    fontSize = 11,
    fontWeight = "bold",
  })
  local fanLabel = ui.label({ text = string.format("Fan %d", index), fontSize = 10, width = 42 })

  if snap.mode ~= "manual" then
    if snap.mode == "auto" then
      return ui.row({ gap = 6, align = "center" }, { fanLabel, ui.box({ flexGrow = 1 }), rpm })
    end
    return ui.row({ gap = 6, align = "center" }, {
      fanLabel,
      ui.label({
        text = noctalia.tr("panel.full"),
        fontSize = 10,
        color = colors.fullColor(),
        flexGrow = 1,
        maxLines = 1,
      }),
      rpm,
    })
  end

  local value = multiFan and shownFanPercent(index, fan) or shown
  local slider = ui.slider({
    min = 0,
    max = 100,
    step = tonumber(noctalia.getConfig("percent_step")) or 10,
    value = value,
    flexGrow = 1,
    onChange = function(nextValue)
      if multiFan then
        fanSliderPreviews[index] = tonumber(nextValue) or value
      else
        sliderPreview = tonumber(nextValue) or value
      end
      render()
    end,
    onDragEnd = function(nextValue)
      local target
      if multiFan then
        target = fanSliderPreviews[index] or tonumber(nextValue) or value
        fanSliderPreviews[index] = nil
        fanOptimisticTargets[index] = target
        dispatch({ action = "set_percent", index = index, value = target })
      else
        target = sliderPreview or tonumber(nextValue) or value
        sliderPreview = nil
        optimisticTarget = target
        dispatch({ action = "set_percent", value = target })
      end
    end,
  })

  local controls = {
    ui.row({
      fill = "primary/0.7",
      radius = 4,
      padding = 4,
      align = "center",
      justify = "center",
    }, {
      ui.label({ text = tostring(value) .. "%", fontSize = 10, color = "on_primary" }),
    }),
    slider,
  }
  if snap.backend == "thinkpad" then
    table.insert(controls, ui.label({
      text = "lvl " .. tostring(snap.level or "?") .. "/7",
      fontSize = 10,
      color = "on_surface_variant",
    }))
  end

  return ui.row({ gap = 6, align = "center" }, {
    fanLabel,
    ui.row({ gap = 4, align = "center", flexGrow = 1 }, controls),
    rpm,
  })
end

local function temperatureRow()
  local color = colors.icon(snap)
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "temperature", size = 14, color = color }),
    ui.label({ text = noctalia.tr("tooltip.temperature"), fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = tostring(snap.temp or 0), fontSize = 16, fontWeight = "bold", color = color }),
    ui.label({ text = "°C", fontSize = 10, color = "on_surface_variant" }),
  })
end

local function loadValue(value, color)
  return ui.label({ text = string.format("%.2f", value), fontSize = 12, fontWeight = "bold", color = color })
end

local function loadRow()
  local loadAvg = snap.loadAvg or {}
  local cpuCount = snap.cpuCount or 0
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "activity", size = 14, color = "on_surface_variant" }),
    ui.label({ text = "Load avg", fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
    loadValue(loadAvg.one or 0, loadColor(loadAvg.one or 0, cpuCount)),
    ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" }),
    loadValue(loadAvg.five or 0, loadColor(loadAvg.five or 0, cpuCount)),
    ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" }),
    loadValue(loadAvg.fifteen or 0, loadColor(loadAvg.fifteen or 0, cpuCount)),
  })
end

render = function()
  local shown = shownPercent()
  local multiFan = (snap.fanCount or 0) > 1
  local children = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "car-fan", color = colors.icon(snap) }),
      ui.label({ text = noctalia.tr("panel.title"), fontWeight = "bold" }),
      ui.box({ flexGrow = 1 }),
      modeButton("auto", "settings-automation", noctalia.tr("panel.auto")),
      modeButton("full", "car-fan", noctalia.tr("panel.full")),
      modeButton("manual", "adjustments", noctalia.tr("panel.manual")),
    }),
  }

  if not snap.available then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.unavailable"),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 3,
    }))
  else
    local fans = {}
    for i, fan in snap.fans do
      table.insert(fans, fanRow(i, fan, multiFan, shown))
    end
    table.insert(children, ui.column({ gap = 8 }, fans))
    table.insert(children, ui.separator({}))
    table.insert(children, temperatureRow())
    table.insert(children, loadRow())
  end

  panel.render(ui.column({ gap = 10, fill = "surface_variant/0.5", radius = 12, padding = 10 }, children))
end

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  clearSliderState()
  render()
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    if value.mode ~= snap.mode or value.percent ~= snap.percent then
      clearSliderState()
    else
      for i, fan in value.fans or {} do
        local previous = snap.fans[i]
        if previous and fan.pwm ~= previous.pwm then
          fanOptimisticTargets[i] = nil
        end
      end
    end
    snap = value
    render()
  end
end)
