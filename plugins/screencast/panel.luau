--!nonstrict
-- Screencast details panel — opened by clicking the active bar widget.
--
-- The service owns the PipeWire inspection and stop operation. The panel only
-- sends a small command through shared state, keeping the UI reusable and the
-- privileged-ish graph operation in one place.

local PANEL_HEIGHT = 280
local PANEL_PADDING = 14

local state = noctalia.state.get("screencast_status") or { active = false, apps = {} }
local action = nil
local isOpen = false
local commandNonce = 0

local function sendCommand(name)
  commandNonce += 1
  noctalia.state.set("screencast_cmd", noctalia.json.encode({ n = noctalia.nowMs() + commandNonce, action = name }))
end

local function header()
  return ui.row({ gap = 8, align = "center" }, {
    ui.box({ width = 10, height = 10, radius = 5, fill = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = "Screencast", fontSize = 16, fontWeight = "bold" }),
      ui.label({
        text = state.active and "Screen sharing is active" or "No active screen share",
        fontSize = 12,
        color = state.active and "error" or "on_surface_variant",
      }),
    }),
  })
end

local function appList()
  local apps = state.apps or {}
  local rows = {}
  if #apps == 0 then
    table.insert(rows, ui.label({
      text = "No PipeWire clients reported",
      fontSize = 12,
      color = "on_surface_variant",
    }))
  else
    for _, app in ipairs(apps) do
      table.insert(rows, ui.row({ gap = 8, align = "center", padding = 5 }, {
        ui.box({ width = 6, height = 6, radius = 3, fill = "error" }),
        ui.label({ text = app, fontSize = 13, maxLines = 1 }),
      }))
    end
  end
  return ui.column({ gap = 2 }, rows)
end

local function render()
  if not isOpen then
    return
  end

  local stopping = action and action.action == "stop" and action.success == nil
  local message = action and action.message or ""
  panel.render(ui.column({
    gap = 10,
    padding = PANEL_PADDING,
    height = PANEL_HEIGHT - PANEL_PADDING * 2,
  }, {
    header(),
    ui.separator({}),
    ui.label({ text = "Sharing clients", fontSize = 13, fontWeight = "bold" }),
    appList(),
    ui.label({
      text = message,
      fontSize = 11,
      color = action and action.success == false and "error" or "on_surface_variant",
      visible = message ~= "",
      maxLines = 2,
    }),
    ui.button({
      text = stopping and "Stopping…" or "Stop sharing",
      variant = "outline",
      enabled = state.active and not stopping,
      flexGrow = 1,
      onClick = "onStop",
    }),
  }))
end

noctalia.state.watch("screencast_status", function(value)
  if type(value) == "table" then
    state = value
    if not state.active and action and action.action == "stop" and action.success == nil then
      action = { action = "stop", success = true, message = "Screen sharing stopped" }
    end
    render()
  end
end)

noctalia.state.watch("screencast_action", function(value)
  if type(value) == "table" then
    action = value
    render()
  end
end)

function onOpen(_context)
  isOpen = true
  state = noctalia.state.get("screencast_status") or state
  action = nil
  render()
end

function onClose()
  isOpen = false
end

function onStop()
  if state.active then
    action = { action = "stop", success = nil, message = "Stopping screen sharing…" }
    render()
    sendCommand("stop")
  end
end

render()
