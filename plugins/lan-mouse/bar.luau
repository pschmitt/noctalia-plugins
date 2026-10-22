--!nonstrict
-- Lan Mouse bar widget — the [[widget]] entry.
--
-- Always visible: a Noctalia glyph that reflects where input is going.
-- Clicking opens the peer/status panel defined in plugin.toml.

local state = noctalia.state.get("lan_mouse_status") or { serviceActive = false, away = false, peerName = nil, peers = {} }

local IDLE_TICK_MS = 5000

local function render()
  barWidget.setVisible(true)
  local active = state.serviceActive == true
  local away = state.away == true
  local showLabel = noctalia.getConfig("show_label") ~= false
  local iconColor = "on_surface_variant"
  if active then
    iconColor = away and (noctalia.getConfig("icon_color") or "primary") or "on_surface"
  end

  local children = {}
  children[#children + 1] = ui.glyph({
    name = active and not state.controlKnown and "question-mark" or (away and "mouse-off" or "mouse"),
    size = 18,
    color = iconColor,
  })
  if showLabel and away then
    local controlKnown = state.controlKnown == true
    children[#children + 1] = ui.label({
      text = (state.peerName or "away") .. (controlKnown and "" or "?"),
      fontWeight = "bold",
      color = controlKnown and "primary" or "error",
    })
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  local tooltip = active and "Lan Mouse is running" or "Lan Mouse is stopped"
  if active and not state.controlKnown then
    tooltip = tooltip .. (state.pendingPeer and ("; waiting for " .. state.pendingPeer .. " to acknowledge") or "; input state unknown")
  elseif active and away then
    tooltip = tooltip .. "; sending input to " .. (state.peerName or "a peer")
  elseif active and state.incoming then
    tooltip = tooltip .. "; receiving input from " .. (state.incomingFrom or "a peer")
  elseif active then
    tooltip = tooltip .. "; input is local"
  end
  barWidget.setTooltip(tooltip)
end
noctalia.state.watch("lan_mouse_status", function(val)
  if type(val) == "table" then
    state = val
    render()
  end
end)

render()

function update()
  noctalia.setUpdateInterval(IDLE_TICK_MS)
  render()
end
