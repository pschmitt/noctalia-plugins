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
    name = away and "mouse-off" or "mouse",
    size = 18,
    color = iconColor,
  })
  if showLabel and away then
    children[#children + 1] = ui.label({
      text = state.peerName or "away",
      fontWeight = "bold",
      color = "primary",
    })
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  local tooltip = active and "Lan Mouse is running" or "Lan Mouse is stopped"
  if active and away then
    tooltip = tooltip .. "; control is on " .. (state.peerName or "a peer")
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
