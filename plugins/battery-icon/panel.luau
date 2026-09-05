--!nonstrict

-- Compact power-control surface for the battery widget. Battery details and
-- power-profile and fan data/commands live in this plugin so its panel can
-- operate independently of the dedicated Fan Control widget.

local DETAILS = "battery_icon.details"
local BATTERY_COMMAND = "battery_icon.command"
local FAN_STATE = "battery_icon.fan"

local details = noctalia.state.get(DETAILS) or {
  percent = 0,
  charging = false,
  plugged = false,
  powerProfile = "",
  chargeLimit = 100,
  devices = {},
}
local batteryIcon = noctalia.state.get("battery_icon") or {}
local fan = noctalia.state.get(FAN_STATE) or {
  available = false,
  mode = "auto",
  percent = 0,
  temp = 0,
  loadAvg = { one = 0, five = 0, fifteen = 0 },
}
local render

local function batteryCommand(payload)
  noctalia.state.set(BATTERY_COMMAND, payload)
end

local function fanCommand(payload)
  noctalia.state.set(BATTERY_COMMAND, payload)
end

local PROFILES = {
  { profile = "power-saver", glyph = "leaf", label = "panel.power_saver" },
  { profile = "balanced", glyph = "scale", label = "panel.balanced" },
  { profile = "performance", glyph = "rocket", label = "panel.performance" },
}

local function profileButton(spec)
  return ui.button({
    glyph = spec.glyph,
    variant = details.powerProfile == spec.profile and "primary" or "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr(spec.label),
    onClick = function()
      batteryCommand({ action = "set_power_profile", profile = spec.profile })
    end,
  })
end

local function metricRow(glyph, label, value, unit, isError)
  local color = isError and "error" or "on_surface_variant"
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = glyph, size = 14, color = color }),
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = value, fontSize = 14, fontWeight = "bold", color = isError and "error" or nil }),
    unit and ui.label({ text = unit, fontSize = 10, color = "on_surface_variant" }) or ui.box({ width = 0 }),
  })
end

local function header()
  local subtitle = tostring(details.percent or 0) .. "%"
  if details.charging then
    subtitle = subtitle .. " · " .. noctalia.tr("panel.charging")
  elseif details.plugged then
    subtitle = subtitle .. " · " .. noctalia.tr("panel.plugged")
  end
  local children = {
    batteryIcon.path
        and ui.image({ path = batteryIcon.path, width = 44, height = 24, fit = "contain" })
      or ui.glyph({ name = "battery-2", size = 28, color = "on_surface" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = subtitle, fontSize = 12, color = "on_surface_variant" }),
    }),
  }
  for _, spec in PROFILES do
    table.insert(children, profileButton(spec))
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function batteryRows()
  local rows = {
    metricRow(
      "heart-pulse",
      noctalia.tr("panel.battery_health"),
      details.health and tostring(details.health) or noctalia.tr("panel.not_available"),
      details.health and "%" or nil
    ),
  }
  if details.rateWatts ~= nil then
    local prefix = details.charging and "+" or (details.status == "Discharging" and "−" or "")
    table.insert(rows, metricRow("bolt", noctalia.tr("panel.charge_rate"), prefix .. string.format("%.1f", details.rateWatts), "W"))
  end
  local eta = details.charging and details.timeToFull
    or (details.status == "Discharging" and details.timeToEmpty or nil)
  if eta and eta > 0 then
    local hours = math.floor(eta / 3600)
    local minutes = math.floor((eta % 3600) / 60)
    local etaText = hours > 0 and string.format("%dh %02dm", hours, minutes) or string.format("%dm", minutes)
    local etaLabel = details.charging and noctalia.tr("panel.time_to_full") or noctalia.tr("panel.time_remaining")
    table.insert(rows, metricRow("clock", etaLabel, etaText, nil))
  end
  if details.thresholdStart or details.thresholdEnd or (details.chargeLimit or 100) < 100 then
    local threshold
    if details.thresholdStart and details.thresholdEnd then
      threshold = tostring(details.thresholdStart) .. "–" .. tostring(details.thresholdEnd)
    else
      threshold = tostring(details.thresholdEnd or details.chargeLimit) .. ""
    end
    if details.thresholdGuessed then
      table.insert(rows, metricRow("battery-charging", noctalia.tr("panel.charging_threshold") .. "*", threshold, "%"))
    else
      table.insert(rows, metricRow("battery-charging", noctalia.tr("panel.charging_threshold"), threshold, "%"))
    end
  end
  return rows
end

local function otherDevices()
  local devices = details.devices or {}
  if #devices == 0 then
    return nil
  end
  local function deviceGlyph(device)
    local kind = tostring(device.kind or ""):lower()
    if kind == "mouse" or kind == "touchpad" then
      return "mouse"
    elseif kind == "keyboard" then
      return "keyboard"
    elseif kind == "headset" or kind == "headphones" then
      return "headphones"
    elseif kind == "phone" then
      return "device-mobile"
    elseif kind == "tablet" then
      return "tablet"
    end
    return "battery-2"
  end
  local rows = { ui.label({ text = noctalia.tr("panel.other_devices"), fontSize = 11, color = "on_surface_variant" }) }
  for _, device in devices do
    table.insert(rows, metricRow(deviceGlyph(device), device.label, tostring(device.percent or 0), "%"))
  end
  return ui.column({ gap = 6 }, rows)
end

local function systemRows()
  if not fan.available then
    return nil
  end
  local load = fan.loadAvg or {}
  local temperature = fan.temp or 0
  local temperatureThreshold = tonumber(noctalia.getConfig("temperature_threshold")) or 85
  local loadThreshold = tonumber(noctalia.getConfig("load_average_threshold")) or 8
  local one, five, fifteen = load.one or 0, load.five or 0, load.fifteen or 0
  local function loadValue(value)
    return ui.label({
      text = string.format("%.2f", value),
      fontSize = 14,
      fontWeight = "bold",
      color = value >= loadThreshold and "error" or nil,
    })
  end
  local loadRow = ui.row({ gap = 6, align = "center" }, {
    ui.glyph({
      name = "activity",
      size = 14,
      color = (one >= loadThreshold or five >= loadThreshold or fifteen >= loadThreshold) and "error" or "on_surface_variant",
    }),
    ui.label({ text = noctalia.tr("panel.load_average"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    loadValue(one),
    ui.label({ text = "·", fontSize = 14, color = "on_surface_variant" }),
    loadValue(five),
    ui.label({ text = "·", fontSize = 14, color = "on_surface_variant" }),
    loadValue(fifteen),
  })
  return ui.column({ gap = 6 }, {
    metricRow("temperature", noctalia.tr("panel.temperature"), tostring(temperature), "°C", temperature >= temperatureThreshold),
    loadRow,
  })
end

local function caffeineControl()
  local enabled = details.caffeineEnabled == true
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "coffee", size = 14, color = enabled and "primary" or "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.caffeine"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({
      text = noctalia.tr(enabled and "panel.caffeine_enabled" or "panel.caffeine_disabled"),
      fontSize = 12,
      color = enabled and "primary" or "on_surface_variant",
    }),
    ui.button({
      glyph = "coffee",
      variant = enabled and "primary" or "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr(enabled and "panel.disable_caffeine" or "panel.enable_caffeine"),
      onClick = function()
        batteryCommand({ action = "set_caffeine", enabled = not enabled })
      end,
    }),
  })
end

local function fanModeButton(mode, glyph, label)
  if mode == "full" then
    return ui.row({
      width = 32,
      height = 32,
      fill = fan.mode == "full" and "error" or "#00000000",
      radius = 8,
      align = "center",
      justify = "center",
      onClick = function()
        fanCommand({ action = "set_fan_mode", mode = "full" })
      end,
    }, {
      ui.glyph({ name = glyph, size = 18, color = fan.mode == "full" and "on_error" or "on_surface" }),
    })
  end
  return ui.button({
    glyph = glyph,
    variant = fan.mode == mode and "primary" or "ghost",
    controlSize = "sm",
    tooltip = label,
    onClick = function()
      fanCommand({ action = "set_fan_mode", mode = mode })
    end,
  })
end

local function fanControls()
  if noctalia.getConfig("show_fan_controls") == false or not fan.available then
    return nil
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "car-fan", size = 14, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.fan"), fontSize = 11, color = "on_surface_variant" }),
      ui.label({
        text = tostring(fan.rpm or 0) .. " " .. noctalia.tr("panel.rpm"),
        fontSize = 12,
        color = "on_surface_variant",
        flexGrow = 1,
      }),
      fanModeButton("auto", "settings-automation", noctalia.tr("panel.auto")),
      fanModeButton("full", "car-fan", noctalia.tr("panel.full_blast")),
      fanModeButton("manual", "adjustments", noctalia.tr("panel.manual")),
    }),
  }
  if fan.mode == "manual" then
    table.insert(children, ui.slider({
      min = 0,
      max = 100,
      step = 10,
      value = fan.percent or 50,
      controlSize = "sm",
      width = 230,
      onDragEnd = function(value)
        fanCommand({ action = "set_fan_percent", value = tonumber(value) or 50 })
      end,
    }))
  end
  return ui.column({ gap = 6 }, children)
end

render = function()
  local children = { header(), ui.column({ gap = 6 }, batteryRows()) }
  local others = otherDevices()
  if others then
    table.insert(children, ui.separator({}))
    table.insert(children, others)
  end
  local system = systemRows()
  if system then
    table.insert(children, ui.separator({}))
    table.insert(children, system)
  end
  table.insert(children, ui.separator({}))
  table.insert(children, caffeineControl())
  local controls = fanControls()
  if controls then
    table.insert(children, ui.separator({}))
    table.insert(children, controls)
  end
  panel.render(ui.column({ gap = 10, padding = 10, align = "stretch" }, children))
end

function onOpen(_context)
  details = noctalia.state.get(DETAILS) or details
  fan = noctalia.state.get(FAN_STATE) or fan
  batteryIcon = noctalia.state.get("battery_icon") or batteryIcon
  render()
end

noctalia.state.watch(DETAILS, function(value)
  if type(value) == "table" then
    details = value
    render()
  end
end)

noctalia.state.watch("battery_icon", function(value)
  if type(value) == "table" then
    batteryIcon = value
    render()
  end
end)

noctalia.state.watch(FAN_STATE, function(value)
  if type(value) == "table" then
    fan = value
    render()
  end
end)
