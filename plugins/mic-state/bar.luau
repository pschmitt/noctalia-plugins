--!nonstrict
-- Mirrors Noctalia's built-in input-volume widget, but follows the RNNoise
-- voice source rather than the unmuted meeting_source mix.

local state = noctalia.state.get("mic_state") or { known = false, muted = false }
local commandSerial = 0

local function changeVolume(direction)
  commandSerial += 1
  noctalia.state.set("mic_state.command", {
    action = "change_volume",
    direction = direction,
    requestId = tostring(noctalia.nowMs()) .. "-" .. tostring(commandSerial),
  })
end

local function render()
  local name = state.muted and "microphone-mute" or "microphone"
  local color
  if not state.known then
    color = "on_surface_variant"
  else
    color = state.muted and "error" or "on_surface"
  end

  barWidget.render(ui.glyph({ name = name, size = 16, color = color }))

  local status = not state.known and "State unavailable" or (state.muted and "Muted" or "On")
  local tooltip = { { key = "Microphone", value = status } }
  if state.known then
    tooltip[#tooltip + 1] = { key = "Level", value = tostring(math.floor(tonumber(state.volume) or 0)) .. "%" }
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

function onScroll(_axis, steps, _startsGesture)
  changeVolume(steps > 0 and "down" or "up")
end
