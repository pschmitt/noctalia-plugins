--!nonstrict
-- Lan Mouse lockscreen widget — the [[desktop_widget]] entry.
--
-- A small "bring input back" button, shown only while incoming_sentinel
-- (service.luau) says a peer's input is actually flowing into this host --
-- exactly the one situation where it's needed: this host is locked while a
-- peer holds mouse/keyboard capture, and lan-mouse's normal edge-crossing
-- release can't fire because the session lock grabs input exclusively
-- (confirmed 2026-09-17 -- see releaseBind's own comment in
-- home-manager/gui/lan-mouse.nix). Clicking runs
-- ~/.config/lan-mouse/go-back (home-manager/gui/lan-mouse.nix's
-- goBackScript): it ssh's into every configured peer and deactivates+
-- reactivates whichever one currently has this host's client active,
-- forcing capture back -- same lever release_bind pulls, just reachable
-- with a click instead of the physical keyboard.

local state = noctalia.state.get("lan_mouse_status") or { incoming = false, incomingFrom = nil }
local pending = false

local function goBackPath()
  local configured = noctalia.string.trim(noctalia.getConfig("go_back_command") or "")
  if configured == "" then
    configured = "~/.config/lan-mouse/go-back"
  end
  return noctalia.expandPath(configured)
end

local function render()
  local renderer = desktopWidget or barWidget
  if renderer == nil then
    return
  end

  if not state.incoming then
    -- A committed truly-empty ui.row({}, {}) crashed Noctalia outright the
    -- first time a plugin here tried it (0x0 buffer commit -> fatal Wayland
    -- protocol error -> noctalia.service exits -> Hyprland's
    -- ext-session-lock protocol has no client left to grab the lock and
    -- falls back to its own crashed-lockscreen placeholder; see
    -- feierabend/widget.luau, confirmed live on gk4, 2026-09-11). A
    -- single-space, zero-opacity label keeps a valid non-empty surface
    -- committed instead.
    renderer.render(ui.label({ text = " ", color = "on_surface/0", fontSize = 1 }))
    return
  end

  renderer.render(ui.row({
    gap = 6,
    align = "center",
    padding = 8,
    fill = "surface_variant/0.4",
    radius = 12,
    onClick = function()
      if pending then
        return
      end
      pending = true
      render()
      noctalia.runAsync({ goBackPath() }, function(result)
        pending = false
        if result.exitCode ~= 0 then
          noctalia.log("lan-mouse go-back failed: " .. noctalia.string.trim(result.stderr or ""))
        end
        render()
      end, 5000)
    end,
  }, {
    ui.glyph({ name = "mouse", size = 14, color = "on_surface_variant" }),
    ui.label({
      text = pending and "Bringing back…" or ("Bring input back" .. (state.incomingFrom and (" (" .. state.incomingFrom .. ")") or "")),
      fontSize = 11,
      color = "on_surface_variant",
    }),
  }))
end

noctalia.state.watch("lan_mouse_status", function(value)
  if type(value) == "table" then
    state = value
    render()
  end
end)

render()

function update()
  render()
end
