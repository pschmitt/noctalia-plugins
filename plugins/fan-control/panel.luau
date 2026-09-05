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

local function monitorOnly()
  return noctalia.getConfig("alt_mode") == true
end

local function selectMode(mode)
  clearSliderState()
  dispatch({ action = "set_mode", mode = mode })
end

local function selectPowerProfile(profile)
  dispatch({ action = "set_power_profile", profile = profile })
end

local POWER_PROFILE_BUTTONS = {
  { profile = "power-saver", glyph = "battery-2", label = "panel.power_saver" },
  { profile = "balanced", glyph = "scale", label = "panel.balanced" },
  { profile = "performance", glyph = "rocket", label = "panel.performance" },
}

local function powerProfileButton(spec)
  return ui.button({
    glyph = spec.glyph,
    variant = snap.powerProfile == spec.profile and "primary" or "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr(spec.label),
    onClick = function()
      selectPowerProfile(spec.profile)
    end,
  })
end

local function modeButton(mode, glyph, label)
  if mode == "full" then
    return ui.row({
      width = 32,
      height = 32,
      -- The declarative runtime retains an omitted fill from the previous
      -- render, so clear the Full-blast background explicitly on mode changes.
      fill = snap.mode == mode and colors.fullColor() or "#00000000",
      radius = 8,
      align = "center",
      justify = "center",
      onClick = function()
        selectMode(mode)
      end,
    }, {
      ui.glyph({
        name = glyph,
        size = 18,
        color = snap.mode == mode and "on_error" or "on_surface",
      }),
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
  local fanLabel = ui.label({ text = string.format("Fan %d", index), fontSize = 10, width = 42 })

  if snap.mode ~= "manual" then
    if snap.mode == "auto" then
      return ui.row({ gap = 6, align = "center", minWidth = 320 }, {
        fanLabel,
        ui.box({ flexGrow = 1 }),
      })
    end
    return ui.row({ gap = 6, align = "center", minWidth = 320 }, {
      fanLabel,
      ui.label({
        text = noctalia.tr("panel.full"),
        fontSize = 10,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
    })
  end

  local value = multiFan and shownFanPercent(index, fan) or shown
  local slider = ui.slider({
    min = 0,
    max = 100,
    step = tonumber(noctalia.getConfig("percent_step")) or 10,
    value = value,
    width = 180,
    controlSize = "sm",
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

  local controls = { slider }
  if snap.backend == "thinkpad" then
    table.insert(controls, ui.label({
      text = "lvl " .. tostring(snap.level or "?") .. "/7",
      fontSize = 10,
      color = "on_surface_variant",
    }))
  end
  table.insert(controls, ui.box({ flexGrow = 1 }))

  return ui.row({ gap = 6, align = "center", minWidth = 320 }, {
    fanLabel,
    ui.row({ gap = 4, align = "center", flexGrow = 1 }, controls),
  })
end

local function temperatureRow()
  local color = colors.temperatureColor(snap)
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

local function header()
  local subtitle = tostring(snap.rpm or 0) .. " RPM"
  if monitorOnly() then
    local profile = snap.powerProfile ~= "" and noctalia.tr("panel." .. snap.powerProfile:gsub("-", "_"))
      or noctalia.tr("panel.power_profile")
    subtitle = subtitle .. " · " .. profile
  end
  local children = {
    ui.glyph({ name = "car-fan", size = 28, color = "on_surface" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({
        text = subtitle,
        fontSize = 12,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
  }
  if monitorOnly() then
    for _, spec in POWER_PROFILE_BUTTONS do
      table.insert(children, powerProfileButton(spec))
    end
  else
    table.insert(children, modeButton("auto", "settings-automation", noctalia.tr("panel.auto")))
    table.insert(children, modeButton("full", "car-fan", noctalia.tr("panel.full")))
    table.insert(children, modeButton("manual", "adjustments", noctalia.tr("panel.manual")))
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

render = function()
  local shown = shownPercent()
  local multiFan = (snap.fanCount or 0) > 1
  local children = { header() }

  if not snap.available then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.unavailable"),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 3,
    }))
  else
    if not monitorOnly() and snap.mode ~= "auto" then
      local fans = {}
      for i, fan in snap.fans do
        table.insert(fans, fanRow(i, fan, multiFan, shown))
      end
      table.insert(children, ui.column({ gap = 8 }, fans))
    end
    table.insert(children, ui.separator({}))
    table.insert(children, temperatureRow())
    table.insert(children, loadRow())
  end

  panel.render(ui.column({ gap = 10, padding = 10, align = "stretch" }, children))
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
