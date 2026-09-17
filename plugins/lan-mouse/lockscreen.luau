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

  -- Always commit the *same* row/glyph/label tree and toggle its own
  -- `visible` prop, rather than swapping between two differently-shaped
  -- trees (an earlier version rendered a single near-invisible ui.label
  -- while idle and this full ui.row only once incoming). That swap is the
  -- likely cause of a real bug seen live 2026-09-17: after the button was
  -- used once and the widget went idle, the *next* time it should have
  -- reappeared it rendered as a visible-but-empty button (background/
  -- padding present, glyph and label missing) -- consistent with Noctalia
  -- mis-measuring/mis-laying-out a structurally different tree on
  -- reappearance. `ui.row({ visible = false }, {...})` is an established
  -- pattern elsewhere in this repo (e.g. timewarrior/panel.luau) for
  -- exactly this "keep the tree, toggle visibility" case.
  renderer.render(ui.row({
    gap = 6,
    align = "center",
    padding = 8,
    fill = "surface_variant/0.4",
    radius = 12,
    visible = state.incoming == true,
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
