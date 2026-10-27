-- A compact audio control surface for the real voice path: physical capture
-- source -> RNNoise -> meeting_source. The meeting mix is intentionally not
-- presented as an input device because it also carries soundboard audio.

local state = noctalia.state.get("mic_state") or { known = false, muted = false, volume = 100, sources = {}, activeSource = "" }
local previewVolume = nil
local commandSerial = 0

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
          name = state.muted and "microphone-mute" or "microphone",
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
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Refresh audio devices",
        onClick = function() command("refresh") end,
      }),
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
  local volume = math.clamp(math.floor(tonumber(previewVolume or state.volume) or 0), 0, 150)
  local label = state.muted and "Muted" or "Live input"
  return ui.column({ fill = "surface_container", radius = 14, padding = 12, gap = 10 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ align = "center", gap = 7 }, {
        ui.glyph({ name = "equalizer", size = 16, color = state.muted and "error" or "primary" }),
        ui.label({ text = "Voice input", fontSize = 13, fontWeight = "semibold" }),
      }),
      ui.label({ text = label, fontSize = 11, color = state.muted and "error" or "on_surface_variant" }),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "volume-up", size = 15, color = "on_surface_variant" }),
      ui.slider({
        min = 0,
        max = 150,
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
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = sourceName(state.activeSource), fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
      ui.button({
        glyph = state.muted and "microphone" or "microphone-mute",
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
        ui.label({ text = selected and "Feeding RNNoise" or "Hardware input", fontSize = 10, color = "on_surface_variant" }),
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
      ui.row({ align = "center", gap = 6 }, {
        ui.label({ text = tostring(#(state.sources or {})) .. " available", fontSize = 10, color = "on_surface_variant" }),
        ui.button({
          text = "Auto",
          variant = "ghost",
          controlSize = "sm",
          tooltip = "Use the configured physical-input match",
          onClick = function() command("reset_capture_source") end,
        }),
      }),
    }),
    ui.column({ gap = 6 }, rows),
  })
end

function render()
  panel.render(ui.column({ padding = 14, gap = 12, flexGrow = 1 }, {
    header(),
    voiceCard(),
    deviceCard(),
    ui.label({ text = "Filtered through RNNoise before reaching meeting apps", fontSize = 10, color = "on_surface_variant" }),
  }))
end

noctalia.state.watch("mic_state", function(value)
  if type(value) == "table" then
    state = value
    render()
  end
end)

function onOpen()
  command("refresh")
  render()
end

function onConfigChanged()
  render()
end

render()
