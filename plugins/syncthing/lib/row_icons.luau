--!nonstrict
-- Per-row status icons for the panel's folder/device lists, mirroring the
-- indicators Syncthing's own web GUI puts at the right edge of each row.
--
-- The web GUI draws Font Awesome glyphs (fa-check / fa-sync-alt / fa-pause /
-- fa-search / fa-hourglass-half / fa-recycle / fa-exclamation-triangle for
-- folders, fa-check / fa-pause / fa-power-off plus a connection-type signal
-- meter for devices). Noctalia ships the full Tabler set, which has a
-- one-to-one equivalent for every one of those, so nothing has to be vendored
-- and no extra icon license applies.

local M = {}

-- Syncthing's raw folder states (model.State) that have their own web-GUI
-- glyph. Anything not listed here falls back to the coarse plugin state below.
local FOLDER_RAW_GLYPHS = {
  ["scanning"] = "search", -- fa-search
  ["sync-preparing"] = "hourglass", -- fa-hourglass-half
  ["sync-waiting"] = "player-pause", -- fa-pause (queued behind another folder)
  ["scan-waiting"] = "player-pause",
  ["clean-waiting"] = "player-pause",
  ["cleaning"] = "recycle", -- fa-recycle
}

local FOLDER_STATE_GLYPHS = {
  paused = "player-pause", -- fa-pause
  error = "alert-triangle", -- fa-exclamation-triangle ("Stopped"/"Failed items")
  syncing = "refresh", -- fa-sync-alt
  idle = "check", -- fa-check ("Up to Date")
}

-- Connection-type meter, the web GUI's three-level signal indicator: relay is
-- the weakest, a direct WAN connection sits in the middle, a direct local one
-- is full strength. `antenna-bars-off` stands in for the greyed-out meter next
-- to a device that is not connected at all.
local SIGNAL_GLYPHS = {
  relay = "antenna-bars-1",
  wan = "antenna-bars-3",
  lan = "antenna-bars-5",
}

-- Glyph for a folder row. Paused wins over everything (Syncthing reports a
-- paused folder's last known state), then hard errors, then the fine-grained
-- raw state, then the coarse one.
function M.folder(folder)
  if folder.paused then
    return "player-pause"
  end
  if folder.state == "error" then
    return "alert-triangle"
  end
  return FOLDER_RAW_GLYPHS[folder.rawState] or FOLDER_STATE_GLYPHS[folder.state] or "help-circle"
end

-- Glyph for the state half of a device row.
function M.device(device)
  if device.paused then
    return "player-pause" -- fa-pause
  end
  if not device.connected then
    return "power" -- fa-power-off
  end
  return "check" -- fa-check
end

-- Glyph for the signal half of a device row.
function M.signal(device)
  if not device.connected or device.paused then
    return "antenna-bars-off"
  end
  return SIGNAL_GLYPHS[device.connType] or "antenna-bars-3"
end

return M
