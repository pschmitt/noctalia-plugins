--!nonstrict
-- Duration formatting shared by bar.luau and panel.luau. Every duration this
-- plugin displays (state.duration, week/month/year totals, day breakdown) is
-- "H:MM" text calculated directly from Timewarrior's JSON export, so parsing
-- it is the same everywhere.
--
-- The format settings use {days}/{hours}/{minutes} placeholder substitution —
-- the same {token} style noctalia.tr() uses for translation strings elsewhere
-- in this codebase — rather than strftime, which has no meaning for an elapsed
-- duration (as opposed to a wall-clock time). Each caller resolves its own
-- setting and default; this module just substitutes.
--
-- {days} only means something once you say how long a day is, so it splits the
-- hours by `hours_per_day` (default 8 — a work day; 24 gives calendar days)
-- and {hours} becomes the remainder. A format without {days} leaves {hours} as
-- the full count, exactly as before.

local M = {}

local DEFAULT_HOURS_PER_DAY = 8

local function hoursPerDay()
  local value = tonumber(noctalia.getConfig("hours_per_day")) or DEFAULT_HOURS_PER_DAY
  return math.clamp(math.floor(value), 1, 24)
end

function M.format(duration, fmt)
  duration = duration or ""
  local h, m = duration:match("^(%d+):(%d+)")
  if not h or not fmt or fmt == "" then
    return duration
  end
  local hours = tonumber(h) or 0
  local minutes = tonumber(m) or 0

  local out = fmt
  if string.find(fmt, "{days}", 1, true) then
    local perDay = hoursPerDay()
    local days = math.floor(hours / perDay)
    hours -= days * perDay
    out = (out:gsub("{days}", tostring(days)))
  end
  return (out:gsub("{hours}", tostring(hours)):gsub("{minutes}", string.format("%02d", minutes)))
end

return M
