local function render(state)
  state = state or {}
  barWidget.render(ui.glyph({
    name = "keyboard",
    size = 16,
    color = state.error and "error" or (state.enabled and "primary" or "on_surface_variant"),
  }))
  barWidget.setTooltip({
    { key = "Touch keyboard", value = state.error and "Unavailable" or (state.enabled and "Enabled" or "Off") },
    { key = "Click", value = "Toggle keyboard" },
    { key = "Right click", value = "Dismiss keyboard" },
  })
end
noctalia.state.watch("touch_keyboard", render)
render(noctalia.state.get("touch_keyboard"))
