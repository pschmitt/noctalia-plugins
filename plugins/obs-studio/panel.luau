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
  previewPath = "",
}

local reqId = 0
local render

local function dispatch(payload)
  reqId += 1
  payload.requestId = tostring(os.time()) .. "-" .. tostring(reqId)
  noctalia.state.set(COMMAND, payload)
end

-- Same header shape as pschmitt/ha's list view and pschmitt/syncthing's
-- top-level view: a bare branded logo (it already carries its own color/
-- shape, so no boxed-glyph treatment), title + a small connection-status
-- line stacked beside it, and ghost icon buttons at the trailing edge.
local function header()
  local statusText = snap.connected
    and noctalia.tr("panel.connected")
    or (snap.error ~= "" and snap.error or noctalia.tr("tooltip.disconnected"))
  -- Unlike pschmitt/ha's always-neutral status line, red text (not just a
  -- red dot) is deliberate here: "not connected" isn't a passive status,
  -- it means none of the panel's controls will do anything until OBS starts.
  local statusColor = snap.connected and "primary" or "error"

  local left = ui.row({ align = "center", gap = 8 }, {
    ui.image({ path = "assets/obs-studio-icon.png", width = 32, height = 32, fit = "contain" }),
    ui.column({ gap = 1 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
      ui.row({ align = "center", gap = 5 }, {
        ui.box({ width = 8, height = 8, radius = 4, fill = statusColor }),
        ui.label({ text = statusText, fontSize = 11, color = statusColor, maxLines = 1 }),
      }),
    }),
  })

  local right = ui.row({ align = "center", gap = 2 }, {
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
  })

  return ui.row({ align = "center", justify = "space_between" }, { left, right })
end

local function sceneNames()
  local names = {}
  for _, scene in snap.scenes do
    table.insert(names, scene.name)
  end
  return names
end

local function currentSceneIndex()
  for i, scene in snap.scenes do
    if scene.name == snap.currentScene then return i - 1 end
  end
  return 0
end

-- A dropdown rather than one button per scene: OBS setups with a dozen-plus
-- scenes turned the old button list into more scrolling than switching.
local function sceneSelect()
  if #snap.scenes == 0 then
    return ui.label({
      text = noctalia.tr("panel.no_scenes"),
      fontSize = 12,
      color = "on_surface_variant",
    })
  end
  local scenes = snap.scenes
  return ui.select({
    key = "obs_scene",
    options = sceneNames(),
    selectedIndex = currentSceneIndex(),
    flexGrow = 1,
    onChange = function(index)
      local scene = scenes[(tonumber(index) or 0) + 1]
      if scene then dispatch({ action = "switch_scene", scene = scene.name }) end
    end,
  })
end

local function quickActionButton(spec)
  return ui.button({
    key = spec.key,
    glyph = spec.glyph,
    variant = spec.active and "primary" or "ghost",
    tooltip = spec.tooltip,
    controlSize = "sm",
    onClick = spec.onClick,
  })
end

-- The scene dropdown and the record/stream/virtualcam/mute toggles share one
-- row: each toggle is individually hideable (panel_show_*_button), and the
-- dropdown takes whatever space they leave (flexGrow) rather than owning a
-- row -- and a "Scenes" label -- of its own.
local function actionsRow()
  local children = {}

  if noctalia.getConfig("panel_show_scene_list") ~= false then
    table.insert(children, sceneSelect())
  end

  if noctalia.getConfig("panel_show_record_button") ~= false then
    table.insert(children, quickActionButton({
      key = "obs-action-record",
      glyph = "player-record",
      active = snap.recording,
      tooltip = noctalia.tr("panel.record"),
      onClick = function() dispatch({ action = "toggle_record" }) end,
    }))
  end

  if noctalia.getConfig("panel_show_stream_button") ~= false then
    table.insert(children, quickActionButton({
      key = "obs-action-stream",
      glyph = "broadcast",
      active = snap.streaming,
      tooltip = noctalia.tr("panel.stream"),
      onClick = function() dispatch({ action = "toggle_stream" }) end,
    }))
  end

  if noctalia.getConfig("panel_show_virtualcam_button") ~= false then
    table.insert(children, quickActionButton({
      key = "obs-action-virtualcam",
      glyph = "camera",
      active = snap.virtualcam,
      tooltip = noctalia.tr("panel.virtualcam"),
      onClick = function() dispatch({ action = "toggle_virtualcam" }) end,
    }))
  end

  if noctalia.getConfig("panel_show_mute_button") ~= false then
    table.insert(children, quickActionButton({
      key = "obs-action-mute",
      glyph = snap.micMuted and "microphone-off" or "microphone",
      active = snap.micMuted == true,
      tooltip = noctalia.tr("panel.mic"),
      onClick = function() dispatch({ action = "toggle_mute" }) end,
    }))
  end

  if #children == 0 then return nil end
  return ui.row({ key = "obs-actions-row", gap = 8, align = "center" }, children)
end

local function customButtonAction(button)
  if button.filter_source and button.filter_name then
    return function()
      dispatch({
        action = "run_filter",
        source = button.filter_source,
        name = button.filter_name,
        filter_action = button.filter_action,
      })
    end
  end
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


-- Plain ui.button only takes a theme variant (primary/ghost/outline/...),
-- not an arbitrary background, so a button with a configured `bg`/`fg`
-- renders as a colored row (fill, radius, size) with a real ghost-variant
-- ui.button *inside* it doing the actual click handling and glyph/text
-- tint (color = fg is a supported ui.button prop, confirmed via
-- pschmitt/syncthing's own row icon buttons). The click handler deliberately
-- lives on the button, not the row: an onClick on a plain ui.row was
-- observed to also dismiss the panel itself on click, unlike a real button.
-- Buttons backed by a filter (see pollButtonStates in service.luau) show
-- whether it's currently enabled: `selected` on the plain-button branch is a
-- real ui.button prop (same on/off look the quick-action toggles use via
-- variant swaps); the colored branch instead gets a bright ring, since
-- `selected`'s own look is a variant swap that would fight a custom bg.
local function customButtonWidget(button, index)
  local key = "obs-custom-button-" .. tostring(index)
  local label = button.label
  local active = button.active == true
  if not button.bg and not button.fg then
    return ui.button({
      key = key,
      text = label,
      glyph = button.icon,
      variant = active and "outline" or "ghost",
      flexGrow = 1,
      onClick = customButtonAction(button),
    })
  end
  return ui.row({
    key = key,
    flexGrow = 1,
    height = 36,
    radius = 8,
    align = "center",
    justify = "center",
    fill = button.bg or "surface_variant",
    border = active and "primary" or nil,
    borderWidth = active and 2 or nil,
  }, {
    ui.button({
      text = label,
      glyph = button.icon,
      variant = "ghost",
      color = button.fg or "on_surface",
      flexGrow = 1,
      height = 36,
      onClick = customButtonAction(button),
    }),
    active and ui.box({ width = 6, height = 6, radius = 3, fill = "primary" }) or nil,
  })
end

-- Explicit keys throughout (button, row, and the grid's own outer column)
-- because this grid only exists in the tree once OBS is connected -- it's
-- not just re-rendered but newly inserted whenever the not-running prompt
-- swaps out for it. Without stable keys, that live swap (as opposed to a
-- fresh onOpen() mount) was observed to leave the grid's layout garbled
-- until the panel was closed and reopened.
-- Each button has flexGrow = 1, allowing Noctalia's Flex layout to divide
-- the row's available space equally among columns regardless of ui_scale.
local function customButtons()
  if #snap.customButtons == 0 then return nil end
  local columns = math.max(1, math.min(4, tonumber(noctalia.getConfig("custom_buttons_columns")) or 2))
  local rows = {}
  local currentRow = {}
  local index = 0
  for _, button in snap.customButtons do
    index += 1
    table.insert(currentRow, customButtonWidget(button, index))
    if #currentRow >= columns then
      table.insert(rows, ui.row({ key = "obs-custom-row-" .. tostring(#rows), gap = 8 }, currentRow))
      currentRow = {}
    end
  end
  if #currentRow > 0 then
    table.insert(rows, ui.row({ key = "obs-custom-row-" .. tostring(#rows), gap = 8 }, currentRow))
  end
  return ui.column({ key = "obs-custom-buttons-grid", gap = 8 }, rows)
end

-- Shown instead of the quick-action row while OBS itself isn't reachable --
-- toggling recording/streaming/etc. or picking a scene can't do anything
-- without a running obs-websocket to talk to, so those buttons would just
-- fail. Offers to start it with the configured launch_command instead.
-- No repeat of the "isn't running" text here -- the header's status line
-- (red dot + text) already says that.
local function notRunningPrompt()
  return ui.column({ key = "obs-not-running", gap = 8, align = "center", padding = 16 }, {
    ui.glyph({ name = "video-off", size = 28, color = "on_surface_variant" }),
    ui.button({
      key = "obs-start-button",
      text = noctalia.tr("panel.start_obs"),
      glyph = "player-play",
      variant = "primary",
      onClick = function() dispatch({ action = "obs_cmd" }) end,
    }),
  })
end

local function screenshotPreview()
  if noctalia.getConfig("panel_show_screenshot") == false then return nil end
  local path = snap.previewPath
  if not path or path == "" then return nil end
  return ui.row({
    key = "obs-screenshot-container",
    align = "center",
    justify = "center",
  }, {
    ui.image({
      key = "obs-screenshot-img",
      path = path,
      width = 320,
      height = 180,
      radius = 8,
      fit = "contain",
      tooltip = noctalia.tr("panel.screenshot_tooltip"),
      onClick = function() dispatch({ action = "screenshot" }) end,
    }),
  })
end

local function render_()
  local body = {}

  if snap.connected then
    local actions = actionsRow()
    if actions then
      table.insert(body, actions)
    end
    local preview = screenshotPreview()
    if preview then
      table.insert(body, ui.separator({}))
      table.insert(body, preview)
    end
  else
    table.insert(body, notRunningPrompt())
  end

  if snap.connected and noctalia.getConfig("panel_show_custom_buttons") ~= false then
    local buttons = customButtons()
    if buttons then
      table.insert(body, ui.separator({}))
      table.insert(body, ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "bolt", size = 14, color = "on_surface_variant" }),
        ui.label({
          text = noctalia.tr("panel.custom_buttons"),
          fontSize = 12,
          fontWeight = "bold",
          color = "on_surface_variant",
        }),
      }))
      table.insert(body, buttons)
    end
  end

  -- The custom-buttons grid has no fixed size (as many rows as the config
  -- file declares), so the body scrolls rather than the panel growing or
  -- clipping past its configured height. The header stays put above it.
  local children = {
    header(),
    ui.separator({}),
    ui.scroll({ flexGrow = 1, gap = 10 }, body),
  }

  panel.render(ui.column({ gap = 10, padding = 10, align = "stretch", flexGrow = 1 }, children))
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
