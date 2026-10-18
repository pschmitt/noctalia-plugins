--!nonstrict
-- Lan Mouse details panel — opened by clicking the bar widget.
--
-- Read-only status plus one real action per peer (toggle its lan-mouse
-- connection via `lan-mouse cli activate`/`deactivate`), plus one action for
-- the local service as a whole (start/stop `lan-mouse.service`, with optional
-- command overrides) -- the service owns polling, the panel just renders its
-- state and dispatches commands.

local PANEL_HEIGHT = 340
local PANEL_PADDING = 14

local state = noctalia.state.get("lan_mouse_status") or { away = false, peerName = nil, peers = {} }
local isOpen = false
local pending = {}
local stopping = false
local starting = false
local controlService -- forward-declared: header() below closes over it
local openGui -- forward-declared: header() below closes over it

local function statusLabel()
  if not state.serviceActive then
    return "Lan Mouse isn't running", "error"
  end
  if state.away then
    return "Control is on " .. (state.peerName or "a peer"), "primary"
  end
  return "Lan Mouse is running", "primary"
end

local function header()
  local text, color = statusLabel()
  return ui.row({ gap = 8, align = "center" }, {
    ui.image({ path = "assets/lan-mouse.svg", width = 32, height = 32, fit = "contain" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = "Lan Mouse", fontSize = 15, fontWeight = "bold" }),
      ui.row({ align = "center", gap = 5 }, {
        ui.box({ width = 8, height = 8, radius = 4, fill = color }),
        ui.label({ text = text, fontSize = 11, color = color, maxLines = 1 }),
      }),
    }),
    state.serviceActive and ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = "external-link",
        variant = "ghost",
        tooltip = "Open Lan Mouse",
        onClick = openGui,
      }),
      ui.button({
        glyph = "power",
        variant = "ghost",
        tooltip = stopping and "Stopping…" or "Stop Lan Mouse",
        enabled = not stopping and not starting,
        onClick = controlService,
      }),
    }) or ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = "Plugin settings",
      onClick = function() noctalia.openSettings() end,
    }),
  })
end
-- Overridable via the `stop_command` setting (a shell command line, same as
-- timewarrior's start_command/stop_command) for anyone who wants the button
-- to do more than a plain `systemctl --user stop`.
local function commandFor(action)
  local configured = noctalia.string.trim(noctalia.getConfig(action .. "_command") or "")
  if configured ~= "" then
    return configured
  end
  return "systemctl --user " .. action .. " lan-mouse.service"
end

controlService = function()
  local start = state.serviceActive ~= true
  if starting or stopping then
    return
  end
  starting = start
  stopping = not start
  render()
  local action = start and "start" or "stop"
  noctalia.runAsync(commandFor(action), function(result)
    starting = false
    stopping = false
    if result.exitCode ~= 0 then
      noctalia.log("lan-mouse " .. action .. " command failed: " .. noctalia.string.trim(result.stderr or ""))
    end
    render()
  end, 5000)
end

openGui = function()
  local command = noctalia.string.trim(noctalia.getConfig("gui_command") or "")
  if command == "" then
    command = "lan-mouse"
  end
  isOpen = false
  panel.close()
  noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("lan-mouse GUI command failed: " .. noctalia.string.trim(result.stderr or ""))
    end
  end, 5000)
end

local function toggle(peer)
  if pending[peer.id] then
    return
  end
  pending[peer.id] = true
  local action = peer.active and "deactivate" or "activate"
  noctalia.runAsync({ "lan-mouse", "cli", action, tostring(peer.id) }, function(result)
    pending[peer.id] = nil
    if result.exitCode ~= 0 then
      noctalia.log("lan-mouse cli " .. action .. " " .. peer.id .. " failed: " .. noctalia.string.trim(result.stderr or ""))
    end
    render()
  end, 3000)
end

local function peerList()
  local peers = state.peers or {}
  local rows = {}
  if #peers == 0 then
    table.insert(rows, ui.label({
      text = "No peers configured",
      fontSize = 12,
      color = "on_surface_variant",
    }))
  else
    for _, peer in ipairs(peers) do
      local remoteState = peer.remoteServiceState or "checking"
      local remoteLabel = "Checking…"
      local remoteColor = "on_surface_variant"
      if remoteState == "running" then
        remoteLabel = "Running"
        remoteColor = "primary"
      elseif remoteState == "stopped" then
        remoteLabel = "Stopped"
        remoteColor = "error"
      elseif remoteState == "failed" then
        remoteLabel = "Failed"
        remoteColor = "error"
      elseif remoteState == "starting" then
        remoteLabel = "Starting"
      elseif remoteState == "stopping" then
        remoteLabel = "Stopping"
      elseif remoteState == "missing" then
        remoteLabel = "No service"
        remoteColor = "error"
      elseif remoteState == "unreachable" then
        remoteLabel = "Unreachable"
      end
      local peerPending = pending[peer.id] == true
      local peerActive = peer.active == true
      local buttonText = peerPending and "…" or nil
      if not peerPending and not peerActive then
        buttonText = "Enable"
      end
      table.insert(rows, ui.column({ gap = 7, padding = 8, fill = "surface_variant/0.5", radius = 8 }, {
        ui.row({ gap = 8, align = "center" }, {
          ui.glyph({
            name = peerActive and "plug-connected" or "plug",
            size = 15,
            color = peerActive and "primary" or "on_surface_variant",
          }),
          ui.label({ text = peer.hostname, fontSize = 13, maxLines = 1, flexGrow = 1 }),
          ui.box({ width = 6, height = 6, radius = 3, fill = remoteColor }),
          ui.label({ text = remoteLabel, fontSize = 10, color = remoteColor, maxLines = 1 }),
        }),
        ui.row({ gap = 6, align = "center" }, {
          ui.label({ text = "Position", fontSize = 10, color = "on_surface_variant" }),
          ui.label({ text = peer.position, fontSize = 11, flexGrow = 1 }),
          ui.button({
            text = buttonText,
            glyph = peerActive and not peerPending and "plug-off" or nil,
            tooltip = peerActive and "Disable" or "Enable",
            variant = peerActive and "outline" or "primary",
            enabled = not peerPending,
            onClick = function() toggle(peer) end,
          }),
        }),
      }))
    end
  end
  return ui.column({ gap = 8 }, rows)
end

local function stoppedContent()
  return ui.column({ flexGrow = 1, gap = 14, align = "center", justify = "center" }, {
    ui.image({ path = "assets/lan-mouse.svg", width = 48, height = 48, fit = "contain", opacity = 0.65 }),
    ui.button({
      text = starting and "Starting…" or "Start Lan Mouse",
      glyph = "player-play",
      variant = "primary",
      enabled = not starting and not stopping,
      onClick = controlService,
    }),
    ui.button({
      text = "Open Lan Mouse",
      variant = "outline",
      onClick = openGui,
    }),
  })
end

local function runningContent()
  return ui.column({ gap = 8 }, {
    ui.label({ text = "Peers", fontSize = 13, fontWeight = "bold" }),
    peerList(),
  })
end

function render()
  if not isOpen then
    return
  end
  panel.render(ui.column({
    gap = 10,
    padding = PANEL_PADDING,
    height = PANEL_HEIGHT - PANEL_PADDING * 2,
  }, {
    header(),
    ui.separator({}),
    state.serviceActive and runningContent() or stoppedContent(),
  }))
end
noctalia.state.watch("lan_mouse_status", function(value)
  if type(value) == "table" then
    state = value
    render()
  end
end)

function onOpen(_context)
  isOpen = true
  state = noctalia.state.get("lan_mouse_status") or state
  render()
end

function onClose()
  isOpen = false
end

render()
