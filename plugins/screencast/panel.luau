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
    ui.box({ width = 10, height = 10, radius = 5, fill = state.active and "error" or "on_surface_variant" }),
    ui.label({
      text = state.active and "Screen sharing is active" or "No active screen share",
      fontSize = 14,
      fontWeight = "bold",
      color = state.active and "error" or "on_surface_variant",
    }),
  })
end

-- Best-effort glyph per PipeWire client name -- these are the app's own
-- node.name (see service.luau's portalGraph()), not a desktop-file id, so
-- matching is substring/case-insensitive rather than exact. Unrecognized
-- clients fall back to a plain window glyph rather than the recording dot
-- the row used to show, which told you nothing a red dot next to a red dot
-- didn't already say.
local CLIENT_ICONS = {
  { match = "firefox", glyph = "brand-firefox" },
  { match = "librewolf", glyph = "brand-firefox" },
  { match = "chromium", glyph = "brand-chrome" },
  { match = "chrome", glyph = "brand-chrome" },
  { match = "discord", glyph = "brand-discord" },
  { match = "slack", glyph = "brand-slack" },
  { match = "zoom", glyph = "brand-zoom" },
  { match = "teams", glyph = "brand-teams" },
  { match = "telegram", glyph = "brand-telegram" },
  { match = "whatsapp", glyph = "brand-whatsapp" },
  { match = "skype", glyph = "brand-skype" },
  { match = "spotify", glyph = "brand-spotify" },
  { match = "steam", glyph = "brand-steam" },
  { match = "vlc", glyph = "brand-vlc" },
  { match = "code", glyph = "brand-vscode" },
  { match = "obs", glyph = "video" },
}

local function clientIcon(name)
  local lower = name:lower()
  for _, entry in ipairs(CLIENT_ICONS) do
    if lower:find(entry.match, 1, true) then
      return entry.glyph
    end
  end
  return "app-window"
end

-- Best-effort window focus. Tries the pid first -- service.luau resolves
-- application.process.id, which is the pid `hyprctl clients` itself reports
-- for the window, unlike PipeWire's own connection pid (a browser's sandboxed
-- content/GPU process, not what owns the toplevel). Falls back to a
-- class/title substring match on the app name when there's no pid or it
-- doesn't match any window, rather than trusting
-- `hyprctl dispatch focuswindow class:<name>`'s own regex engine to get
-- case-sensitivity and anchoring right. Silently does nothing on any failure
-- -- wrong compositor, hyprctl missing, no match -- since this is a
-- convenience on top of the panel, not something worth surfacing an error
-- for.
local function focusApp(app)
  noctalia.runAsync({ "hyprctl", "-j", "clients" }, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("screencast: hyprctl clients failed: " .. noctalia.string.trim(result.stderr or "unknown error"))
      return
    end
    local clients = noctalia.json.decode(result.stdout or "")
    if type(clients) ~= "table" then
      return
    end

    local function focus(client)
      noctalia.runAsync({ "hyprctl", "dispatch", "focuswindow", "address:" .. tostring(client.address) })
    end

    local pid = tonumber(app.pid)
    if pid then
      for _, client in ipairs(clients) do
        if tonumber(client.pid) == pid then
          focus(client)
          return
        end
      end
    end

    local needle = (app.name or ""):lower()
    if needle == "" then
      return
    end
    for _, client in ipairs(clients) do
      local class = tostring(client.class or client.initialClass or ""):lower()
      local title = tostring(client.title or client.initialTitle or ""):lower()
      if class:find(needle, 1, true) or title:find(needle, 1, true) then
        focus(client)
        return
      end
    end
  end, 3000)
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
      table.insert(rows, ui.row({
        gap = 8,
        align = "center",
        padding = 5,
        tooltip = "Focus " .. app.name,
        onClick = function() focusApp(app) end,
      }, {
        ui.glyph({ name = clientIcon(app.name), size = 14, color = "on_surface_variant" }),
        ui.label({ text = app.name, fontSize = 13, maxLines = 1, flexGrow = 1 }),
        ui.label({
          text = app.pid and ("PID " .. app.pid) or "",
          fontSize = 10,
          color = "on_surface_variant",
          maxLines = 1,
          visible = app.pid ~= nil,
        }),
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
      glyph = "player-stop",
      text = stopping and "Stopping…" or "Stop sharing",
      -- The error-filled variant (same one timewarrior's own Stop uses), not
      -- outline + a content-color tint: that only reddened the text/glyph,
      -- leaving the background/border neutral.
      variant = "destructive",
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
