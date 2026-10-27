--!nonstrict
-- Mirrors Noctalia's built-in input-volume widget, but follows the RNNoise
-- voice source rather than the unmuted meeting_source mix.

local state = noctalia.state.get("mic_state") or { known = false, muted = false }
local commandSerial = 0

local function render()
  local name = state.muted and "microphone-off" or "microphone"
  local volume = tonumber(state.volume) or 0
  local color
  if not state.known then
    color = "on_surface_variant"
  else
    color = state.muted and "error" or (volume > 100 and "tertiary" or "on_surface")
  end

  barWidget.render(ui.glyph({ name = name, size = 16, color = color }))

  local status = not state.known and "State unavailable" or (state.muted and "Muted" or "On")
  local tooltip = { { key = "Microphone", value = status } }
  local inputName = "No active input"
  for _, source in ipairs(state.sources or {}) do
    if source.name == state.activeSource then
      inputName = source.description or source.name
      break
    end
  end
  tooltip[#tooltip + 1] = { key = "Input", value = inputName }
  if state.known then
    local level = tostring(math.floor(volume)) .. "%"
    tooltip[#tooltip + 1] = { key = "Level", value = level .. (volume > 100 and " · Boost active" or "") }
  end
  tooltip[#tooltip + 1] = { key = "Scroll", value = "Adjust microphone volume" }
  barWidget.setTooltip(tooltip)
end

noctalia.state.watch("mic_state", function(value)
  if type(value) == "table" then
    state = value
    render()
  end
end)

render()

function onScroll(axis, steps, _startsGesture)
  if axis ~= "vertical" then return end
  commandSerial += 1
  noctalia.state.set("mic_state.command", {
    action = "change_volume",
    delta = -steps,
    requestId = tostring(noctalia.nowMs()) .. "-" .. tostring(commandSerial),
  })
end
