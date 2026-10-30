--!nonstrict

-- Compact power-control surface for the battery widget. Battery details and
-- power-profile and fan data/commands live in this plugin so its panel can
-- operate independently of the dedicated Fan Control widget.

local DETAILS = "battery_icon.details"
local BATTERY_COMMAND = "battery_icon.command"
local FAN_STATE = "battery_icon.fan"
local TDP_STATE = "battery_icon.tdp"
local PANEL_PADDING = 10

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
  cpuCount = 1,
  temp = 0,
  loadAvg = { one = 0, five = 0, fifteen = 0 },
}
local tdp = noctalia.state.get(TDP_STATE) or {
  available = false,
  watts = 28,
  minWatts = 5,
  maxWatts = 28,
}
local render
local fanSliderPreview = nil
local tdpSliderPreview = nil

-- Clicked controls answer at once: the target shows as selected with an
-- hourglass glyph cycling until the service's state confirms it (or
-- PENDING_TIMEOUT_MS passes, which also covers a command that failed).
-- Glyphs cannot be rotated, so the motion is a glyph swap on the panel's
-- frame tick, which only runs while something is pending.
-- Generous on purpose: `powerprofilesctl set` plus the follow-up poll was seen
-- taking over 4s, and a shorter timeout let the old value flash back first.
local PENDING_TIMEOUT_MS = 8000
local BUSY_GLYPHS = { "hourglass-empty", "hourglass-low", "hourglass-high", "hourglass" }
local BUSY_INTERVAL_MS = 200
local pendingProfile = nil -- { value, since }
local pendingFanMode = nil -- { value, since }
local pendingCaffeine = nil -- { value, since }
local busyFrame = 1
local busyElapsedMs = 0

local function anyPending()
  return pendingProfile ~= nil or pendingFanMode ~= nil or pendingCaffeine ~= nil
end

local function busyGlyph()
  if noctalia.getConfig("animations_enabled") == false then
    return nil
  end
  return BUSY_GLYPHS[busyFrame]
end

-- Panel state updates keep arriving from the service while the popup is
-- closed; building a whole UI tree for a panel nobody can see is wasted work,
-- so render() only runs between onOpen and onClose.
local panelIsOpen = false

local commandSerial = 0

-- The nonce keeps two identical commands (the periodic refresh) distinct
-- state values, so a watcher always sees the second one.
local function batteryCommand(payload)
  commandSerial += 1
  payload.n = tostring(noctalia.nowMs()) .. "-" .. tostring(commandSerial)
  noctalia.state.set(BATTERY_COMMAND, payload)
end

local function fanCommand(payload)
  batteryCommand(payload)
end

local PROFILES = {
  { profile = "power-saver", glyph = "leaf", label = "panel.power_saver" },
  { profile = "balanced", glyph = "scale", label = "panel.balanced" },
  { profile = "performance", glyph = "rocket", label = "panel.performance" },
}

local function profileButton(spec)
  local waiting = pendingProfile ~= nil and pendingProfile.value == spec.profile
  local selected = waiting or (pendingProfile == nil and details.powerProfile == spec.profile)
  return ui.button({
    glyph = waiting and busyGlyph() or spec.glyph,
    variant = selected and "primary" or "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr(spec.label),
    onClick = function()
      pendingProfile = { value = spec.profile, since = noctalia.nowMs() }
      render()
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
  local status = ""
  if details.charging then
    status = noctalia.tr("panel.charging")
  elseif details.plugged then
    status = noctalia.tr("panel.plugged")
  elseif details.status == "Discharging" or (details.percent and not details.plugged) then
    status = noctalia.tr("panel.discharging")
  end

  local rate = details.rateWatts and string.format("%.1f", details.rateWatts) or nil
  if rate == "0.0" then
    rate = nil
  end

  local titleChildren = {}
  if status ~= "" then
    table.insert(titleChildren, ui.label({ text = status, fontSize = 16, fontWeight = "bold" }))
  end
  if rate then
    local prefix = details.charging and "+" or (details.status == "Discharging" and "−" or "")
    table.insert(
      titleChildren,
      ui.label({ text = prefix .. rate .. " W", fontSize = 10, color = "on_surface_variant" })
    )
  end
  local children = {
    batteryIcon.path
        and ui.image({ path = batteryIcon.path, width = 44, height = 24, fit = "contain" })
      or ui.glyph({ name = "battery-2", size = 28, color = "on_surface" }),
    ui.column({ gap = 2, flexGrow = 1 }, titleChildren),
  }
  for _, spec in PROFILES do
    table.insert(children, profileButton(spec))
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function batteryRows()
  local rows = {
    metricRow(
      "heartbeat",
      noctalia.tr("panel.battery_health"),
      details.health and tostring(details.health) or noctalia.tr("panel.not_available"),
      details.health and "%" or nil
    ),
  }
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

  local function chargeGlyph(device)
    local state = tostring(device.state or ""):lower()
    if state == "charging" then
      return "battery-charging"
    elseif state == "fully-charged" or state == "pending-charge" then
      return "battery-plugged"
    end

    local percent = tonumber(device.percent) or 0
    if percent >= 85 then
      return "battery-4"
    elseif percent >= 55 then
      return "battery-3"
    elseif percent >= 30 then
      return "battery-2"
    elseif percent >= 10 then
      return "battery-1"
    end
    return "battery-0"
  end

  local function deviceGlyph(device)
    if noctalia.getConfig("other_device_icon_mode") == "level" then
      return chargeGlyph(device)
    end

    local kind = tostring(device.kind or ""):lower()
    if kind == "mouse" then
      return "mouse-2"
    elseif kind == "touchpad" or kind == "tablet" then
      return "device-tablet"
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
  local rows = {}
  local lowThreshold = tonumber(noctalia.getConfig("low_threshold")) or 20
  for _, device in devices do
    local isLow = (device.percent or 0) <= lowThreshold
    table.insert(rows, metricRow(deviceGlyph(device), device.label, tostring(device.percent or 0), "%", isLow))
  end
  return ui.column({ gap = 6 }, rows)
end

-- Footer: caffeine on the left, plugin settings on the right. Caffeine is the
-- one control here that gets toggled rather than read, so it belongs in the
-- row that stays put while the body scrolls, not buried between the metric
-- rows. Primary variant marks it active, the same way the power-profile and
-- fan-mode buttons above mark their selection, and the tooltip names the
-- action rather than the state.
local function footer()
  local caffeine = details.caffeineEnabled == true
  if pendingCaffeine ~= nil then
    caffeine = pendingCaffeine.value
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.button({
      glyph = pendingCaffeine ~= nil and busyGlyph() or "coffee",
      text = `{noctalia.tr("panel.caffeine")} · {noctalia.tr(caffeine and "panel.caffeine_enabled" or "panel.caffeine_disabled")}`,
      fontSize = 11,
      glyphSize = 13,
      variant = caffeine and "primary" or "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr(caffeine and "panel.disable_caffeine" or "panel.enable_caffeine"),
      onClick = function()
        local target = not caffeine
        pendingCaffeine = { value = target, since = noctalia.nowMs() }
        render()
        batteryCommand({ action = "set_caffeine", enabled = target })
      end,
    }),
    ui.row({ flexGrow = 1 }, {}),
    ui.button({
      glyph = "settings",
      glyphSize = 13,
      width = 24,
      height = 24,
      color = "on_surface_variant",
      variant = "ghost",
      tooltip = noctalia.tr("panel.open_settings"),
      onClick = "onSettings",
    }),
  })
end

local function systemRows()
  if not fan.available then
    return nil
  end
  local load = fan.loadAvg or {}
  local temperature = fan.temp or 0
  local temperatureThreshold = tonumber(noctalia.getConfig("temperature_threshold")) or 85
  local loadThreshold = tonumber(noctalia.getConfig("load_average_threshold")) or 0
  if loadThreshold <= 0 then
    loadThreshold = fan.cpuCount or 1
  end
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
  local waiting = pendingFanMode ~= nil and pendingFanMode.value == mode
  local selected = waiting or (pendingFanMode == nil and fan.mode == mode)
  return ui.button({
    glyph = waiting and busyGlyph() or glyph,
    variant = selected and "primary" or "ghost",
    controlSize = "sm",
    tooltip = label,
    onClick = function()
      pendingFanMode = { value = mode, since = noctalia.nowMs() }
      render()
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
      value = fanSliderPreview or fan.percent or 50,
      controlSize = "sm",
      width = 230,
      onChange = function(nextValue)
        fanSliderPreview = tonumber(nextValue) or fanSliderPreview
        render()
      end,
      onDragEnd = function(value)
        local target = fanSliderPreview or tonumber(value) or fan.percent or 50
        fanSliderPreview = nil
        fanCommand({ action = "set_fan_percent", value = target })
      end,
    }))
  end
  return ui.column({ gap = 6 }, children)
end

local function tdpControls()
  if noctalia.getConfig("show_tdp_controls") ~= true then
    return nil
  end
  if not tdp.available then
    return ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "bolt", size = 14, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.tdp_unavailable"), fontSize = 11, color = "on_surface_variant" }),
    })
  end

  local minimum = tonumber(tdp.minWatts) or 5
  local maximum = tonumber(tdp.maxWatts) or 28
  local watts = math.clamp(math.floor(tonumber(tdpSliderPreview or tdp.watts) or minimum), minimum, maximum)
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "bolt", size = 14, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.tdp"), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = tostring(watts) .. " W", fontSize = 14, fontWeight = "bold" }),
    }),
    ui.slider({
      min = minimum,
      max = maximum,
      step = 1,
      value = watts,
      controlSize = "sm",
      width = 230,
      onChange = function(nextValue)
        tdpSliderPreview = tonumber(nextValue) or watts
        render()
      end,
      onDragEnd = function(value)
        local target = tdpSliderPreview or tonumber(value) or watts
        tdpSliderPreview = nil
        batteryCommand({ action = "set_tdp", value = target })
      end,
    }),
  })
end

render = function()
  if not panelIsOpen then return end
  local scrollChildren = { ui.column({ gap = 6 }, batteryRows()) }
  local others = otherDevices()
  if others then
    table.insert(scrollChildren, ui.separator({}))
    table.insert(scrollChildren, others)
  end
  local system = systemRows()
  if system then
    table.insert(scrollChildren, ui.separator({}))
    table.insert(scrollChildren, system)
  end
  local controls = fanControls()
  if controls then
    table.insert(scrollChildren, ui.separator({}))
    table.insert(scrollChildren, controls)
  end
  local tdp = tdpControls()
  if tdp then
    table.insert(scrollChildren, ui.separator({}))
    table.insert(scrollChildren, tdp)
  end

  -- The surface is content-fitted (plugin.toml height = "content"), so the
  -- body must not flexGrow: a growing scroll measures as "fill" and pins the
  -- panel at max_height. ui.scroll has no maxHeight prop (the host ignores it
  -- with a warning), so plugin.toml's max_height is the only bound.
  panel.setNeedsFrameTick(anyPending())
  panel.render(ui.column({
    gap = 8,
    padding = PANEL_PADDING,
    align = "stretch",
    flexGrow = 1,
  }, {
    header(),
    ui.scroll({ gap = 8 }, scrollChildren),
    footer(),
  }))
end

function onOpen(_context)
  panelIsOpen = true
  details = noctalia.state.get(DETAILS) or details
  fan = noctalia.state.get(FAN_STATE) or fan
  tdp = noctalia.state.get(TDP_STATE) or tdp
  batteryIcon = noctalia.state.get("battery_icon") or batteryIcon
  batteryCommand({ action = "refresh" })
  render()
end

function onSettings()
  noctalia.openSettings()
end

function onClose()
  panelIsOpen = false
  pendingProfile = nil
  pendingFanMode = nil
  pendingCaffeine = nil
  panel.setNeedsFrameTick(false)
end

function onFrameTick(deltaMs)
  local now = noctalia.nowMs()
  local changed = false
  if pendingProfile ~= nil and now - pendingProfile.since >= PENDING_TIMEOUT_MS then
    pendingProfile = nil
    changed = true
  end
  if pendingFanMode ~= nil and now - pendingFanMode.since >= PENDING_TIMEOUT_MS then
    pendingFanMode = nil
    changed = true
  end
  if pendingCaffeine ~= nil and now - pendingCaffeine.since >= PENDING_TIMEOUT_MS then
    pendingCaffeine = nil
    changed = true
  end
  busyElapsedMs += tonumber(deltaMs) or BUSY_INTERVAL_MS
  if busyElapsedMs >= BUSY_INTERVAL_MS then
    busyElapsedMs = busyElapsedMs % BUSY_INTERVAL_MS
    busyFrame = busyFrame % #BUSY_GLYPHS + 1
    changed = true
  end
  -- The glyph only changes every BUSY_INTERVAL_MS; skip the frames between.
  if changed then render() end
end

noctalia.state.watch(DETAILS, function(value)
  if type(value) == "table" then
    details = value
    if pendingProfile ~= nil and value.powerProfile == pendingProfile.value then
      pendingProfile = nil
    end
    if pendingCaffeine ~= nil and (value.caffeineEnabled == true) == pendingCaffeine.value then
      pendingCaffeine = nil
    end
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
    if value.mode ~= fan.mode or value.percent ~= fan.percent then
      fanSliderPreview = nil
    end
    fan = value
    if pendingFanMode ~= nil and value.mode == pendingFanMode.value then
      pendingFanMode = nil
    end
    render()
  end
end)

noctalia.state.watch(TDP_STATE, function(value)
  if type(value) == "table" then
    if value.watts ~= tdp.watts or value.minWatts ~= tdp.minWatts or value.maxWatts ~= tdp.maxWatts then
      tdpSliderPreview = nil
    end
    tdp = value
    render()
  end
end)

-- The service normally polls at a relaxed interval. While this panel is open,
-- refresh telemetry frequently enough for RPM and temperature to feel live.
panel.setWantsSecondTicks(true)
local refreshTick = 0
function update()
  refreshTick += 1
  if refreshTick % 2 == 0 then
    batteryCommand({ action = "refresh" })
  end
end
