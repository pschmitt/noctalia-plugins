--!nonstrict
-- Lan Mouse bar widget — the [[widget]] entry.
--
-- Hidden while control is on this host (the common case), or while the local
-- lan-mouse.service is stopped; shows a mouse glyph + the peer's name
-- whenever service.luau's away_sentinel poll finds control has moved away.
-- Clicking opens the peer/status panel defined in plugin.toml.

local state = noctalia.state.get("lan_mouse_status") or { serviceActive = false, away = false, peerName = nil, peers = {} }

local IDLE_TICK_MS = 5000

local function render()
  local visible = state.serviceActive == true and state.away == true
  barWidget.setVisible(visible)
  if not visible then
    return
  end

  local color = noctalia.getConfig("icon_color") or "error"
  local showLabel = noctalia.getConfig("show_label") ~= false

  local children = {
    ui.glyph({ name = "mouse", size = 14, color = color }),
  }
  if showLabel then
    children[#children + 1] = ui.label({
      text = state.peerName or "away",
      fontWeight = "bold",
      color = color,
    })
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip("Mouse/keyboard control is on " .. (state.peerName or "a peer"))
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
