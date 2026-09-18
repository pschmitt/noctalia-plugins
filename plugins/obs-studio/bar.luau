--!nonstrict

local SNAPSHOT = "obs.snapshot"
local COMMAND = "obs.command"
local PANEL_ID = "pschmitt/obs-studio:panel"

local snap = noctalia.state.get(SNAPSHOT) or {
  connected = false,
  currentScene = "",
  scenes = {},
  recording = false,
  streaming = false,
  virtualcam = false,
  micMuted = nil,
  error = "",
}

local isVertical = false
local reqId = 0
local blink = true

local function dispatch(payload)
  reqId += 1
  payload.requestId = tostring(os.time()) .. "-" .. tostring(reqId)
  noctalia.state.set(COMMAND, payload)
end

local function truncate(text)
  local maxLength = tonumber(noctalia.getConfig("bar_max_scene_length")) or 18
  if #text <= maxLength then return text end
  return text:sub(1, math.max(1, maxLength - 1)) .. "…"
end

local function statusColor()
  if not snap.connected then return "on_surface_variant" end
  if snap.recording then return "on_error" end
  return "on_surface"
end

local function tooltipRows()
  local rows = {}
  if not snap.connected then
    table.insert(rows, { key = noctalia.tr("tooltip.status"), value = noctalia.tr("tooltip.disconnected") })
    return rows
  end
  table.insert(rows, { key = noctalia.tr("tooltip.scene"), value = snap.currentScene or "" })
  table.insert(rows, {
    key = noctalia.tr("tooltip.recording"),
    value = snap.recording and noctalia.tr("tooltip.on") or noctalia.tr("tooltip.off"),
  })
  table.insert(rows, {
    key = noctalia.tr("tooltip.streaming"),
    value = snap.streaming and noctalia.tr("tooltip.on") or noctalia.tr("tooltip.off"),
  })
  if snap.micMuted ~= nil then
    table.insert(rows, {
      key = noctalia.tr("tooltip.mic"),
      value = snap.micMuted and noctalia.tr("tooltip.muted") or noctalia.tr("tooltip.unmuted"),
    })
  end
  return rows
end

local render

local function render_()
  local mode = noctalia.getConfig("bar_display_mode")
  local children = {}
  local iconSize = tonumber(noctalia.getConfig("bar_icon_size")) or 16

  local showIcon = mode ~= "scene_only"
  local showText = mode ~= "icon_only" and snap.connected

  if showIcon then
    local iconName = noctalia.getConfig("bar_icon")
    -- "video" is both a legit Tabler glyph and this setting's own default,
    -- doubling as the sentinel for "use the real OBS Studio logo" -- same
    -- trick pschmitt/ha's bar_icon plays with its "smart-home" default.
    -- Change it to any other glyph name to get a plain Tabler icon instead.
    if iconName == "" or iconName == "video" then
      -- Wrapped in a row pinned to the label's own line-height (rather than
      -- relying on align="center" against the label directly): a label's
      -- box is taller than its cap-height (room for descenders), so an
      -- image centered against that whole box alone still reads as sitting
      -- a little high next to the text's visual glyph center.
      table.insert(children, ui.row({ height = 18, align = "center" }, {
        ui.image({ path = "assets/obs-studio-icon.png", width = iconSize, height = iconSize, fit = "contain" }),
      }))
    else
      table.insert(children, ui.glyph({ name = iconName, size = iconSize, color = statusColor() }))
    end
  end

  if snap.recording and noctalia.getConfig("bar_show_rec_indicator") ~= false then
    table.insert(children, ui.row({
      width = 8,
      height = 8,
      radius = 4,
      fill = blink and "on_error" or "#00000000",
    }, {}))
  end

  if snap.streaming and noctalia.getConfig("bar_show_stream_indicator") ~= false then
    table.insert(children, ui.glyph({ name = "broadcast", size = 12, color = "primary" }))
  end

  if showText then
    table.insert(children, ui.label({
      text = snap.connected and truncate(snap.currentScene or "") or noctalia.tr("tooltip.disconnected"),
      fontWeight = "bold",
      color = statusColor(),
    }))
  end

  if #children == 0 then
    table.insert(children, ui.glyph({ name = noctalia.getConfig("bar_icon"), size = 14, color = statusColor() }))
  end

  local container = isVertical and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(tooltipRows())
end
render = render_

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

function update()
  isVertical = barWidget.isVertical()
  if noctalia.getConfig("animations_enabled") == true and snap.recording then
    blink = not blink
  else
    blink = true
  end
  render()
end

function onConfigChanged()
  render()
end

local ACTIONS = {
  panel = function() noctalia.togglePanel(PANEL_ID) end,
  next_scene = function() dispatch({ action = "next_scene" }) end,
  prev_scene = function() dispatch({ action = "prev_scene" }) end,
  toggle_record = function() dispatch({ action = "toggle_record" }) end,
  toggle_stream = function() dispatch({ action = "toggle_stream" }) end,
  toggle_virtualcam = function() dispatch({ action = "toggle_virtualcam" }) end,
  toggle_mute = function() dispatch({ action = "toggle_mute" }) end,
  refresh = function() dispatch({ action = "refresh" }) end,
  obs_cmd = function() dispatch({ action = "obs_cmd" }) end,
}

local function runAction(settingKey)
  local action = ACTIONS[noctalia.getConfig(settingKey)]
  if action then action() end
end

function onClick()
  runAction("action_left_click")
end

function onRightClick()
  runAction("action_right_click")
end

function onMiddleClick()
  runAction("action_middle_click")
end

function onScroll(_axis, steps, _startsGesture)
  runAction(steps > 0 and "action_scroll_down" or "action_scroll_up")
end

-- 1s ticks: only meaningfully visible while animations are on and OBS is
-- recording (the blinking REC dot); otherwise this is a cheap no-op render.
noctalia.setUpdateInterval(1000)
render()
