--!nonstrict
-- Lan Mouse lockscreen widget — the [[desktop_widget]] entry.
--
-- A small "bring input back" button, always present on the lockscreen.
-- Exists for exactly one situation: this host is locked while a peer holds
-- mouse/keyboard capture, and lan-mouse's normal edge-crossing release
-- can't fire because the session lock grabs input exclusively (confirmed
-- 2026-09-17 -- see releaseBind's own comment in
-- home-manager/gui/lan-mouse.nix). Clicking runs
-- ~/.config/lan-mouse/go-back (home-manager/gui/lan-mouse.nix's
-- goBackScript): it ssh's into every configured peer and deactivates+
-- reactivates whichever one currently has this host's client active,
-- forcing capture back -- same lever release_bind pulls, just reachable
-- with a click instead of the physical keyboard. A no-op when nothing
-- actually needs releasing, so this stays visible unconditionally rather
-- than trying to detect "is a peer currently capturing me" (lan-mouse
-- exposes no such query, see service.luau).

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
      text = pending and "Bringing back…" or "Bring input back",
      fontSize = 11,
      color = "on_surface_variant",
    }),
  }))
end

render()

function update()
  render()
end
