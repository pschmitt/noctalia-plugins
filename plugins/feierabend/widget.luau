--!nonstrict
-- Feierabend countdown display — lockscreen label (or bar pill, if a
-- `[[widget]] entry = "widget.luau"` is ever added to plugin.toml) showing
-- "🍻 {N}s before Feierabend" while zhj feierabend's shutdown countdown is
-- armed. Renders nothing while it isn't: the desktop-widget box is placed
-- with box_width/box_height = 0 (auto-fit to content, see
-- profiles/laptop/noctalia.nix) so no content means no visible card.

local state = noctalia.state.get("feierabend_countdown") or { active = false, seconds = 0 }

local function text()
  local template = noctalia.getConfig("text_template")
  if template == nil or template == "" then
    template = "🍻 {seconds}s before Feierabend"
  end
  return (template:gsub("{seconds}", tostring(math.floor(state.seconds or 0))))
end

local function render()
  local renderer = barWidget or desktopWidget
  if renderer == nil then
    return
  end

  if not state.active then
    if barWidget then
      barWidget.setVisible(false)
    end
    -- No desktopWidget.setVisible() exists, so this still has to render
    -- *something* to clear a previous "Ns before Feierabend" once the
    -- countdown stops. A single-space, zero-opacity label keeps a valid
    -- non-empty surface committed at all times -- committing a truly empty
    -- ui.row({}, {}) here crashed Noctalia outright the first time this ran
    -- with nothing to show (a 0x0 buffer commit -> "invalid object" Wayland
    -- protocol error -> fatal display_error=22 -> noctalia.service exits ->
    -- Hyprland's ext-session-lock protocol has no client left to grab the
    -- lock and falls back to its own crashed-lockscreen placeholder;
    -- confirmed live on gk4, 2026-09-11).
    renderer.render(ui.label({ text = " ", color = "on_surface/0", fontSize = 1 }))
    return
  end

  if barWidget then
    barWidget.setVisible(true)
  end
  renderer.render(ui.label({
    text = text(),
    color = noctalia.getConfig("text_color") or "error",
    fontSize = tonumber(noctalia.getConfig("font_size")) or 24,
    fontWeight = "bold",
  }))
end

noctalia.state.watch("feierabend_countdown", function(val)
  if type(val) == "table" then
    state = val
    render()
  end
end)

render()

function update()
  render()
end
