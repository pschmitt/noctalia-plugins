--!nonstrict

local SNAPSHOT = "obs.snapshot"
local COMMAND = "obs.command"

local snap = noctalia.state.get(SNAPSHOT) or {
  connected = false,
  currentScene = "",
  scenes = {},
  recording = false,
  streaming = false,
  virtualcam = false,
  micMuted = nil,
  error = "",
  customButtons = {},
}

local reqId = 0
local render

local function dispatch(payload)
  reqId += 1
  payload.requestId = tostring(os.time()) .. "-" .. tostring(reqId)
  noctalia.state.set(COMMAND, payload)
end

local function header()
  local statusText = snap.connected
    and noctalia.tr("panel.connected")
    or (snap.error ~= "" and snap.error or noctalia.tr("tooltip.disconnected"))

  return ui.column({ gap = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "video", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = function() dispatch({ action = "refresh" }) end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.settings"),
        onClick = function() noctalia.openSettings() end,
      }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.row({
        width = 8,
        height = 8,
        radius = 4,
        fill = snap.connected and "primary" or "on_error",
      }, {}),
      ui.label({ text = statusText, fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
    }),
  })
end

local function sceneRow(scene)
  local isCurrent = scene.name == snap.currentScene
  return ui.button({
    text = scene.name,
    glyph = isCurrent and "check" or "movie",
    variant = isCurrent and "primary" or "ghost",
    flexGrow = 1,
    onClick = function() dispatch({ action = "switch_scene", scene = scene.name }) end,
  })
end

local function sceneList()
  if #snap.scenes == 0 then
    return ui.label({
      text = noctalia.tr("panel.no_scenes"),
      fontSize = 12,
      color = "on_surface_variant",
    })
  end
  local rows = {}
  for _, scene in snap.scenes do
    table.insert(rows, sceneRow(scene))
  end
  return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

local function quickActionButton(spec)
  return ui.button({
    glyph = spec.glyph,
    variant = spec.active and "primary" or "ghost",
    tooltip = spec.tooltip,
    controlSize = "sm",
    onClick = spec.onClick,
  })
end

local function quickActions()
  local buttons = {
    quickActionButton({
      glyph = "player-record",
      active = snap.recording,
      tooltip = noctalia.tr("panel.record"),
      onClick = function() dispatch({ action = "toggle_record" }) end,
    }),
    quickActionButton({
      glyph = "broadcast",
      active = snap.streaming,
      tooltip = noctalia.tr("panel.stream"),
      onClick = function() dispatch({ action = "toggle_stream" }) end,
    }),
    quickActionButton({
      glyph = "camera",
      active = snap.virtualcam,
      tooltip = noctalia.tr("panel.virtualcam"),
      onClick = function() dispatch({ action = "toggle_virtualcam" }) end,
    }),
    quickActionButton({
      glyph = snap.micMuted and "microphone-off" or "microphone",
      active = snap.micMuted == true,
      tooltip = noctalia.tr("panel.mic"),
      onClick = function() dispatch({ action = "toggle_mute" }) end,
    }),
  }
  return ui.row({ gap = 8, align = "center" }, buttons)
end

local function customButtonAction(button)
  if button.obs_control then
    return function() dispatch({ action = "run_obs_control", args = { button.obs_control } }) end
  end
  if button.obs_cli then
    return function() dispatch({ action = "run_obs_cli", args = button.obs_cli }) end
  end
  if button.command then
    return function() dispatch({ action = "run_command", args = button.command }) end
  end
  return function() end
end

local function customButtons()
  if #snap.customButtons == 0 then return nil end
  local columns = math.max(1, math.min(4, tonumber(noctalia.getConfig("custom_buttons_columns")) or 2))
  local rows = {}
  local currentRow = {}
  for _, button in snap.customButtons do
    table.insert(currentRow, ui.button({
      text = button.label,
      glyph = button.icon,
      variant = "ghost",
      flexGrow = 1,
      onClick = customButtonAction(button),
    }))
    if #currentRow >= columns then
      table.insert(rows, ui.row({ gap = 8 }, currentRow))
      currentRow = {}
    end
  end
  if #currentRow > 0 then
    table.insert(rows, ui.row({ gap = 8 }, currentRow))
  end
  return ui.column({ gap = 8 }, rows)
end

local function render_()
  local children = { header(), ui.separator({}) }

  if noctalia.getConfig("panel_show_quick_actions") ~= false then
    table.insert(children, quickActions())
    table.insert(children, ui.separator({}))
  end

  if noctalia.getConfig("panel_show_scene_list") ~= false then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.scenes"),
      fontSize = 12,
      fontWeight = "bold",
      color = "on_surface_variant",
    }))
    table.insert(children, sceneList())
  end

  if noctalia.getConfig("panel_show_custom_buttons") ~= false then
    local buttons = customButtons()
    if buttons then
      table.insert(children, ui.separator({}))
      table.insert(children, ui.label({
        text = noctalia.tr("panel.custom_buttons"),
        fontSize = 12,
        fontWeight = "bold",
        color = "on_surface_variant",
      }))
      table.insert(children, buttons)
    end
  end

  panel.render(ui.column({ gap = 10, padding = 10, align = "stretch" }, children))
end
render = render_

function onOpen(_context)
  snap = noctalia.state.get(SNAPSHOT) or snap
  dispatch({ action = "refresh" })
  render()
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)
