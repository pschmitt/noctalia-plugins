-- A compact audio control surface for the real voice path: physical capture
-- source -> RNNoise -> meeting_source. The meeting mix is intentionally not
-- presented as an input device because it also carries soundboard audio.

local state = noctalia.state.get("mic_state") or { known = false, muted = false, volume = 100, sources = {}, activeSource = "" }
local previewVolume = nil
local lastObservedVolume = tonumber(state.volume)
local meterLevels = {}
local metersStarted = {}
local meterDataDir = nil
local panelOpen = false
local commandSerial = 0
local volumeRowHovered = false
local previousPopupScrollOffset = nil
local popupScrollRemainder = 0

local function maxVolume()
  return noctalia.getConfig("allow_volume_boost") == true and 150 or 100
end

local function command(action, extra)
  commandSerial += 1
  local payload = extra or {}
  payload.action = action
  payload.requestId = tostring(noctalia.nowMs()) .. "-" .. tostring(commandSerial)
  noctalia.state.set("mic_state.command", payload)
end

local function sourceName(name)
  for _, source in ipairs(state.sources or {}) do
    if source.name == name then return source.description end
  end
  return "No active hardware input"
end

local function meterConfigPath(sourceName)
  if not meterDataDir then
    meterDataDir = noctalia.pluginDataDir()
  end
  if not meterDataDir then return nil end
  local safeName = sourceName:gsub("[^%w%-_]", "_")
  return meterDataDir .. "/voice-meter-" .. safeName .. ".conf"
end

local function meterPidPath(sourceName)
  local configPath = meterConfigPath(sourceName)
  return configPath and configPath:gsub("%.conf$", ".pid") or nil
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function writeMeterConfig(sourceName)
  local configPath = meterConfigPath(sourceName)
  if not configPath then return nil end
  local config = [[
[general]
live-config = 1
bars = 1
framerate = 15
autosens = 2

[input]
method = pulse
source = ]] .. sourceName .. [[

[output]
method = raw
raw_target = /dev/stdout
data_format = ascii
ascii_max_range = 1000
bar_delimiter = 59
frame_delimiter = 10
channels = mono

[smoothing]
noise_reduction = 0
]]
  if noctalia.writeFile(configPath, config) then
    return configPath
  end
  return nil
end

local function startMeters()
  if not panelOpen then return end
  for _, source in ipairs(state.sources or {}) do
    local sourceName = source.name
    if sourceName ~= "" and not metersStarted[sourceName] then
      local configPath = writeMeterConfig(sourceName)
      local pidPath = meterPidPath(sourceName)
      if configPath and pidPath then
        local commandPath = table.concat({
          "pid_file=", shellQuote(pidPath), "; ",
          "config=", shellQuote(configPath), "; ",
          "child=; cleanup() { if [ -n \"$child\" ]; then kill \"$child\" 2>/dev/null || true; fi; rm -f \"$pid_file\"; }; ",
          "trap cleanup EXIT; trap 'exit 0' TERM INT; ",
          "printf '%s\\n' \"$$\" > \"$pid_file\"; ",
          "cava -p \"$config\" & child=$!; wait \"$child\"",
        })
        metersStarted[sourceName] = noctalia.runStream(commandPath, function(line)
          local value = tonumber(line:match("%d+"))
          if value then
            meterLevels[sourceName] = math.clamp(value / 1000, 0, 1)
            render()
          end
        end)
      end
    end
  end
end

local function stopMeters()
  for sourceName in pairs(metersStarted) do
    local pidPath = meterPidPath(sourceName)
    local rawPid = pidPath and noctalia.readFile(pidPath)
    local pid = rawPid and tonumber(rawPid:match("%d+"))
    if pid then
      noctalia.runAsync({ "sh", "-c", "kill -TERM " .. tostring(math.floor(pid)) })
    end
    if pidPath then noctalia.removeFile(pidPath) end
  end
  metersStarted = {}
  meterLevels = {}
end

local function header()
  local status = state.known and (state.muted and "Muted" or "Microphone on") or "Microphone unavailable"
  local color = not state.known and "on_surface_variant" or (state.muted and "error" or "primary")
  return ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.column({
        width = 38,
        height = 38,
        radius = 12,
        fill = state.muted and "error/0.14" or "primary/0.14",
        align = "center",
        justify = "center",
      }, {
        ui.glyph({
          name = state.muted and "microphone-off" or "microphone",
          size = 20,
          color = color,
        }),
      }),
      ui.column({ gap = 2 }, {
        ui.label({ text = "Microphone", fontSize = 16, fontWeight = "bold" }),
        ui.row({ align = "center", gap = 5 }, {
          ui.box({ width = 7, height = 7, radius = 4, fill = color }),
          ui.label({ text = status, fontSize = 11, color = color }),
        }),
      }),
    }),
    ui.row({ align = "center", gap = 2 }, {
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Microphone settings",
        onClick = function() noctalia.openSettings() end,
      }),
    }),
  })
end

local function voiceCard()
  local maximum = maxVolume()
  local volume = math.clamp(math.floor(tonumber(previewVolume or state.volume) or 0), 0, maximum)
  local label = state.muted and "Muted" or "Live input"
  return ui.column({ fill = "surface_container", radius = 14, padding = 12, gap = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ align = "center", gap = 7 }, {
        ui.glyph({ name = "activity", size = 16, color = state.muted and "error" or "primary" }),
        ui.label({ text = "Voice input", fontSize = 13, fontWeight = "semibold" }),
      }),
      ui.label({ text = label, fontSize = 11, color = state.muted and "error" or "on_surface_variant" }),
    }),
    ui.row({ align = "center", gap = 8, onHover = function(hovered)
      volumeRowHovered = hovered == "true"
      previousPopupScrollOffset = nil
      popupScrollRemainder = 0
    end }, {
      ui.glyph({ name = "volume-2", size = 15, color = "on_surface_variant" }),
      ui.slider({
        min = 0,
        max = maximum,
        step = 1,
        value = volume,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(value)
          previewVolume = tonumber(value) or volume
          render()
        end,
        onDragEnd = function(value)
          local target = previewVolume or tonumber(value) or volume
          previewVolume = nil
          command("set_volume", { value = target })
        end,
      }),
      ui.label({ text = tostring(volume) .. "%", fontSize = 11, color = "on_surface_variant", minWidth = 34 }),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Voice level", fontSize = 10, color = "on_surface_variant", minWidth = 62 }),
      ui.progress({
        progress = meterLevels[state.activeSource] or 0,
        height = 5,
        fill = state.muted and "error" or "primary",
        track = "on_surface/0.14",
        radius = 5,
        flexGrow = 1,
      }),
    }),
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = sourceName(state.activeSource), fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
      ui.button({
        glyph = state.muted and "microphone" or "microphone-off",
        text = state.muted and "Unmute" or "Mute",
        variant = state.muted and "primary" or "outline",
        controlSize = "sm",
        enabled = state.known,
        onClick = function() command("toggle_mute") end,
      }),
    }),
  })
end

local function deviceCard()
  local rows = {}
  for _, source in ipairs(state.sources or {}) do
    local selected = source.name == state.activeSource
    rows[#rows + 1] = ui.row({ align = "center", gap = 9, padding = 9, fill = selected and "primary/0.10" or "surface_container", radius = 10 }, {
      ui.glyph({ name = "microphone", size = 16, color = selected and "primary" or "on_surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = source.description, fontSize = 12, fontWeight = selected and "semibold" or "normal", maxLines = 1 }),
        ui.row({ align = "center", gap = 6 }, {
          ui.label({ text = selected and "Feeding RNNoise" or "Hardware input", fontSize = 10, color = "on_surface_variant" }),
          ui.progress({
            progress = meterLevels[source.name] or 0,
            height = 3,
            fill = source.muted and "error" or "primary",
            track = "on_surface/0.14",
            radius = 3,
            flexGrow = 1,
          }),
        }),
      }),
      selected and ui.glyph({ name = "check", size = 16, color = "primary" }) or ui.button({
        text = "Use",
        variant = "outline",
        controlSize = "sm",
        onClick = function() command("set_capture_source", { name = source.name }) end,
      }),
    })
  end

  if #rows == 0 then
    rows[1] = ui.row({ align = "center", gap = 8, padding = 12, fill = "surface_container", radius = 10 }, {
      ui.glyph({ name = "microphone", size = 16, color = "on_surface_variant" }),
      ui.label({ text = "No physical capture devices found", fontSize = 12, color = "on_surface_variant" }),
    })
  end

  return ui.column({ gap = 7 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Input device", fontSize = 13, fontWeight = "bold" }),
      ui.label({ text = tostring(#(state.sources or {})) .. " available", fontSize = 10, color = "on_surface_variant" }),
    }),
    ui.column({ gap = 6 }, rows),
  })
end

function render()
  panel.render(ui.scroll({ padding = 14, gap = 12, onScroll = function(offset)
    local currentOffset = tonumber(offset)
    if currentOffset and previousPopupScrollOffset and volumeRowHovered then
      popupScrollRemainder += previousPopupScrollOffset - currentOffset
      local detents = math.floor(math.abs(popupScrollRemainder) / 30)
      if detents > 0 then
        detents *= popupScrollRemainder > 0 and 1 or -1
        command("change_volume", { delta = detents })
        popupScrollRemainder -= detents * 30
      end
    end
    previousPopupScrollOffset = currentOffset
  end }, {
    header(),
    voiceCard(),
    deviceCard(),
  }))
end

noctalia.state.watch("mic_state", function(value)
  if type(value) == "table" then
    local observedVolume = tonumber(value.volume)
    if observedVolume ~= lastObservedVolume then
      previewVolume = nil
      lastObservedVolume = observedVolume
    end
    state = value
    startMeters()
    render()
  end
end)

function onOpen()
  panelOpen = true
  command("refresh")
  startMeters()
  render()
end

function onClose()
  panelOpen = false
  stopMeters()
  render()
end

function onConfigChanged()
  render()
end

render()
