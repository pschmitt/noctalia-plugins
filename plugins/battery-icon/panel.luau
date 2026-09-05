--!nonstrict

-- Compact power-control surface for the battery widget. Battery details and
-- power-profile writes live in this plugin; fan data/commands are reused from
-- pschmitt/fan-control so there is one source of truth for the controller.

local DETAILS = "battery_icon.details"
local BATTERY_COMMAND = "battery_icon.command"
local FAN_SNAPSHOT = "fan.snapshot"
local FAN_COMMAND = "fan.command"

local details = noctalia.state.get(DETAILS) or {
  percent = 0,
  charging = false,
  powerProfile = "",
  chargeLimit = 100,
  devices = {},
}
local fan = noctalia.state.get(FAN_SNAPSHOT) or {
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
  noctalia.state.set(FAN_COMMAND, payload)
end

local PROFILES = {
  { profile = "power-saver", glyph = "battery-2", label = "panel.power_saver" },
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

local function metricRow(glyph, label, value, unit)
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = value, fontSize = 14, fontWeight = "bold" }),
    unit and ui.label({ text = unit, fontSize = 10, color = "on_surface_variant" }) or ui.box({ width = 0 }),
  })
end

local function header()
  local subtitle = tostring(details.percent or 0) .. "%"
  if details.charging then
    subtitle = subtitle .. " · " .. noctalia.tr("panel.charging")
  end
  local children = {
    ui.glyph({ name = "battery-2", size = 28, color = "on_surface" }),
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
    metricRow("battery-2", noctalia.tr("panel.battery"), tostring(details.percent or 0), "%"),
    metricRow(
      "battery-2",
      noctalia.tr("panel.battery_health"),
      details.health and tostring(details.health) or noctalia.tr("panel.not_available"),
      details.health and "%" or nil
    ),
  }
  if details.thresholdStart or details.thresholdEnd or (details.chargeLimit or 100) < 100 then
    local threshold
    if details.thresholdStart and details.thresholdEnd then
      threshold = tostring(details.thresholdStart) .. "–" .. tostring(details.thresholdEnd)
    else
      threshold = tostring(details.thresholdEnd or details.chargeLimit) .. ""
    end
    table.insert(rows, metricRow("battery-2", noctalia.tr("panel.charging_threshold"), threshold, "%"))
  end
  return rows
end

local function otherDevices()
  local devices = details.devices or {}
  if #devices == 0 then
    return nil
  end
  local rows = { ui.label({ text = noctalia.tr("panel.other_devices"), fontSize = 11, color = "on_surface_variant" }) }
  for _, device in devices do
    table.insert(rows, metricRow("battery-2", device.label, tostring(device.percent or 0), "%"))
  end
  return ui.column({ gap = 6 }, rows)
end

local function systemRows()
  if not fan.available then
    return nil
  end
  local load = fan.loadAvg or {}
  return ui.column({ gap = 6 }, {
    metricRow("temperature", noctalia.tr("panel.temperature"), tostring(fan.temp or 0), "°C"),
    metricRow("activity", noctalia.tr("panel.load_average"), string.format("%.2f", load.one or 0), nil),
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
        fanCommand({ action = "set_mode", mode = "full" })
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
      fanCommand({ action = "set_mode", mode = mode })
    end,
  })
end

local function fanControls()
  if noctalia.getConfig("show_fan_controls") == false or not fan.available or fan.controlMode == "power-profile" then
    return nil
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.power"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
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
        fanCommand({ action = "set_percent", value = tonumber(value) or 50 })
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
  local controls = fanControls()
  if controls then
    table.insert(children, ui.separator({}))
    table.insert(children, controls)
  end
  panel.render(ui.column({ gap = 10, padding = 10, align = "stretch" }, children))
end

function onOpen(_context)
  details = noctalia.state.get(DETAILS) or details
  fan = noctalia.state.get(FAN_SNAPSHOT) or fan
  render()
end

noctalia.state.watch(DETAILS, function(value)
  if type(value) == "table" then
    details = value
    render()
  end
end)

noctalia.state.watch(FAN_SNAPSHOT, function(value)
  if type(value) == "table" then
    fan = value
    render()
  end
end)
