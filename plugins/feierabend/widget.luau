--!nonstrict
-- Feierabend countdown display — lockscreen label (or bar pill, if a
-- `[[widget]] entry = "widget.luau"` is ever added to plugin.toml) showing
-- "🍻 {N}s before Feierabend" while zhj feierabend's shutdown countdown is
-- armed. Renders nothing while it isn't: the desktop-widget box is placed
-- with box_width/box_height = 0 (auto-fit to content, see
-- profiles/laptop/noctalia.nix) so an empty row collapses to nothing rather
-- than leaving a visible empty card.

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
    renderer.render(ui.row({}, {}))
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
