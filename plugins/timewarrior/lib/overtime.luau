--!nonstrict
-- Overtime colouring, shared by bar.luau and panel.luau so the bar's tracked
-- duration and the panel's per-day totals agree on what counts as overtime and
-- which colour says so.
--
-- Every duration in this plugin is "H:MM" text, so the hour is just the part
-- before the colon; the comparison is strictly greater, matching what the bar
-- has always done (exactly 7h on a 7h threshold is not yet overtime).

local M = {}

function M.isOvertime(duration)
  local hours = tonumber(string.match(duration or "", "^(%d+):"))
  local threshold = tonumber(noctalia.getConfig("overtime_hours")) or 7
  return hours ~= nil and hours > threshold
end

function M.color(duration)
  if M.isOvertime(duration) then
    return noctalia.getConfig("label_overtime_color") or "error"
  end
  return noctalia.getConfig("label_color") or "on_surface"
end

return M
