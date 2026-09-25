--!nonstrict
-- Lan Mouse details panel — opened by clicking the bar widget.
--
-- Read-only status plus one real action per peer (toggle its lan-mouse
-- connection via `lan-mouse cli activate`/`deactivate`), plus one action for
-- the local service as a whole (stop `lan-mouse.service`, or whatever
-- `stop_command` is configured to run instead) -- the service owns polling,
-- the panel just renders its state and dispatches commands.

local PANEL_HEIGHT = 280
local PANEL_PADDING = 14

local state = noctalia.state.get("lan_mouse_status") or { away = false, peerName = nil, peers = {} }
local isOpen = false
local pending = {}
local stopping = false
local stopService -- forward-declared: header() below closes over it

local function header()
  local text = state.away and ("Control is on " .. (state.peerName or "a peer")) or "Control is on this host"
  return ui.row({ gap = 8, align = "center" }, {
    ui.box({ width = 10, height = 10, radius = 5, fill = state.away and "error" or "on_surface_variant" }),
    ui.label({
      text = text,
      fontSize = 14,
      fontWeight = "bold",
      color = state.away and "error" or "on_surface_variant",
      flexGrow = 1,
    }),
    ui.button({
      text = stopping and "Stopping…" or "Stop",
      variant = "destructive",
      enabled = state.serviceActive == true and not stopping,
      onClick = stopService,
    }),
  })
end

-- Overridable via the `stop_command` setting (a shell command line, same as
-- timewarrior's start_command/stop_command) for anyone who wants the button
-- to do more than a plain `systemctl --user stop`.
local function stopCommand()
  local configured = noctalia.string.trim(noctalia.getConfig("stop_command") or "")
  if configured == "" then
    configured = "systemctl --user stop lan-mouse.service"
  end
  return configured
end

stopService = function()
  if stopping or state.serviceActive ~= true then
    return
  end
  stopping = true
  render()
  noctalia.runAsync(stopCommand(), function(result)
    stopping = false
    if result.exitCode ~= 0 then
      noctalia.log("lan-mouse stop command failed: " .. noctalia.string.trim(result.stderr or ""))
    end
    render()
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
      table.insert(rows, ui.row({ gap = 8, align = "center", padding = 5 }, {
        ui.glyph({
          name = peer.active and "plug-connected" or "plug",
          size = 14,
          color = peer.active and "primary" or "on_surface_variant",
        }),
        ui.label({ text = peer.hostname, fontSize = 13, maxLines = 1, flexGrow = 1 }),
        ui.label({ text = peer.position, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
        ui.button({
          text = pending[peer.id] and "…" or (peer.active and "Disable" or "Enable"),
          variant = peer.active and "outline" or "primary",
          enabled = not pending[peer.id],
          onClick = function() toggle(peer) end,
        }),
      }))
    end
  end
  return ui.column({ gap = 2 }, rows)
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
    ui.label({ text = "Peers", fontSize = 13, fontWeight = "bold" }),
    peerList(),
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
