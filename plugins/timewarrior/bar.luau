--!nonstrict
-- Timewarrior bar widget entry.
--
-- Declarative render (barWidget.render, not the imperative setGlyph/setText
-- API) so the Timewarrior project logo can sit next to the figure. Which
-- figure that is comes from `bar_metric` (today's total by default, see
-- metric() below), and while nothing is tracked the widget hides by default
-- or, depending on the `visibility` setting, keeps its place showing a pause
-- icon — see visibility() — or, once the day's stints are done, the clock-out
-- glyph, see clockedOut().

local duration = require("./lib/duration.luau")
local formats = require("./lib/formats.luau")
local overtime = require("./lib/overtime.luau")
local resolveColor = require("./lib/resolve_color.luau")
local badgeIcon = require("./lib/badge_icon.luau")

badgeIcon.prune()

local state = noctalia.state.get("tw_status") or { active = false, duration = "", today = "", since = "", closed = 0 }
local summary = noctalia.state.get("tw_summary") or { week = "", month = "" }

-- Forward-declared: badgeModeIcon() (below) needs to call render() again once
-- an async badge composite finishes, but render() itself is only defined
-- near the bottom of this file. `local function render()` there would
-- create a second, shadowing local instead of filling this one in.
local render

local LOGO_TRACKING = "assets/timewarrior-logo.svg"
local LOGO_STOPPED = "assets/pause.svg"
-- Build-time-rasterized copy of LOGO_TRACKING (see pkgs/noctalia-timewarrior)
-- -- badge_mode's base layer when main_glyph is empty. Not LOGO_STOPPED: in
-- badge mode the main icon is constant regardless of state (that is the
-- point of the mode), only the corner badge changes.
-- Absolute, unlike LOGO_TRACKING/LOGO_STOPPED above: those go straight to
-- ui.image, which resolves a plugin-relative path itself, but this one goes
-- to an external `magick` subprocess (badge_icon.luau) that has no notion
-- of "relative to the plugin dir" at all -- confirmed live, "unable to open
-- image" until this became noctalia.pluginDir() .. "/...".
local LOGO_PNG = noctalia.pluginDir() .. "/assets/timewarrior-logo-256.png"

-- The bundled artwork is the default for both tracking states; a glyph setting
-- replaces it for that state alone, so tracking can be a glyph while stopped
-- stays the pause image, or the other way round. A glyph takes the colour of
-- the figure beside it, which an SVG can't, so the two aren't interchangeable
-- in style — that is the point of the setting.
--
-- The clock-out state has no artwork of its own: it is a glyph (a beer by
-- default) or nothing, in which case it falls back to the stopped icon — it is
-- still a stopped tracker, just one that has earned the evening.
local GLYPH_SETTINGS = {
  tracking = "tracking_glyph",
  stopped = "stopped_glyph",
  clock_out = "clock_out_glyph",
}

local LOGOS = {
  tracking = LOGO_TRACKING,
  stopped = LOGO_STOPPED,
  clock_out = LOGO_STOPPED,
}

local function icon(kind, color)
  local size = tonumber(noctalia.getConfig("icon_size")) or 16
  local glyph = noctalia.string.trim(noctalia.getConfig(GLYPH_SETTINGS[kind]) or "")

  if glyph ~= "" then
    return ui.glyph({ name = glyph, size = size, color = color })
  end

  return ui.image({
    path = LOGOS[kind],
    width = size,
    height = size,
    fit = "contain",
  })
end

-- badge_mode's alternative to icon(): one constant main icon (the bundled
-- logo, or main_glyph if set) with the state glyph composited as a small
-- corner badge instead of replacing the whole icon. See lib/badge_icon.luau
-- for why this has to be a rendered bitmap rather than plain ui.* layout.
--
-- Returns a ui.image for the composite, or nil if badge_mode is off, or if
-- the composite isn't ready yet / can't be produced (missing
-- noctalia_assets_dir, a glyph name that doesn't resolve, ...) -- callers
-- fall back to icon() in that case, same as if badge_mode had never been
-- turned on.
local function badgeModeIcon(kind, color)
  if noctalia.getConfig("badge_mode") ~= true then
    return nil
  end

  local size = tonumber(noctalia.getConfig("icon_size")) or 16
  local assetsDir = noctalia.string.trim(noctalia.getConfig("noctalia_assets_dir") or "")
  if assetsDir == "" then
    return nil
  end

  local opts = {
    mainGlyph = noctalia.string.trim(noctalia.getConfig("main_glyph") or ""),
    badgeGlyph = noctalia.string.trim(noctalia.getConfig(GLYPH_SETTINGS[kind]) or ""),
    position = noctalia.getConfig("badge_position") or "bottom_right",
    mainColor = resolveColor.resolve(noctalia.getConfig("label_color") or "on_surface", "#9AA0A6"),
    badgeColor = resolveColor.resolve(color, "#9AA0A6"),
    -- A fixed backing chip, deliberately not the dynamic state colour: the
    -- common non-overtime case resolves to a light, low-saturation
    -- "on_surface" grey, which put the (equally light) glyph on an
    -- indistinguishable same-colour circle when the circle used it too.
    badgeBgColor = resolveColor.resolve("surface_variant", "#1E1F27"),
    logoPngPath = LOGO_PNG,
    assetsDir = assetsDir,
    size = size,
  }

  -- badgeIcon.ensure()'s callback fires synchronously on a cache hit and
  -- asynchronously otherwise (a fresh magick subprocess) -- `sync` tells
  -- resultPath's setter which case it is in, so an async completion (only)
  -- triggers a re-render instead of calling render() reentrantly from
  -- inside the render() call that is building this very frame.
  local resultPath = nil
  local sync = true
  badgeIcon.ensure(opts, function(iconPath)
    resultPath = iconPath
    if not sync then
      render()
    end
  end)
  sync = false

  if resultPath == nil then
    return nil
  end
  return ui.image({ path = resultPath, width = size, height = size, fit = "contain" })
end

-- Feierabend: once the day's stints are behind you, a paused tracker is the
-- wrong thing for the bar to say. After `clock_out_after` closed intervals
-- today — 2 being a morning and an afternoon around a lunch break — the
-- stopped icon becomes the clock-out glyph instead.
--
-- Counted in intervals rather than hours because that is what marks the shape
-- of a day: the second stop is Feierabend whether it lands at 16:00 or 19:00.
-- 0 (the default) turns the whole thing off; it is a personal rhythm, not a
-- universal one. And it is only ever an idle state — starting a third interval
-- puts the tracking icon straight back.
local function clockedOut(active)
  if active then
    return false
  end
  local after = math.floor(tonumber(noctalia.getConfig("clock_out_after")) or 0)
  if after < 1 then
    return false
  end
  return (tonumber(state.closed) or 0) >= after
end

-- Whether the slot survives an idle timer: "tracking" (vanish, the
-- long-standing default), "always", "workdays" (working days only — a time
-- tracker means nothing on a Sunday) or "working_hours" (working days, and
-- only within the configured hours of them). getConfig returns nil for a
-- setting the user has never touched, so anything unrecognised falls back to
-- "tracking".
--
-- None of these can hide a running timer: render() only consults them while
-- nothing is tracked. Tracking at 23:00 on a Sunday is exactly when you want
-- to see that you are.
local VISIBILITY_MODES = {
  always = true,
  workdays = true,
  working_hours = true,
}

local function visibility()
  local value = noctalia.getConfig("visibility")
  return VISIBILITY_MODES[value] and value or "tracking"
end

-- Which days count as working days, as ISO weekday numbers (1 = Monday,
-- 7 = Sunday) in a comma-separated list of numbers and ranges: "1-5" is the
-- default, "1-4,6" a four-day week plus Saturday, "7,1-4" a week that starts
-- on Sunday. Mon-Fri used to be hardcoded, which is only most people's week.
local DEFAULT_WORKING_DAYS = "1-5"

local function workingDays()
  local raw = noctalia.string.trim(noctalia.getConfig("working_days") or "")
  if raw == "" then
    raw = DEFAULT_WORKING_DAYS
  end

  local days = {}
  for part in raw:gmatch("[^,]+") do
    local first, last = part:match("^%s*(%d)%s*%-%s*(%d)%s*$")
    if first ~= nil then
      -- A reversed range is a typo, not a wrap-around: 5-1 and 1-5 are the
      -- same set of days, and guessing otherwise would silently include the
      -- weekend.
      local from = math.min(tonumber(first), tonumber(last))
      local to = math.max(tonumber(first), tonumber(last))
      for day = from, to do
        days[day] = true
      end
    else
      local day = tonumber(part:match("^%s*(%d)%s*$"))
      if day ~= nil then
        days[day] = true
      end
    end
  end

  if next(days) == nil then
    noctalia.log(`timewarrior: could not read working_days ("{raw}"), falling back to {DEFAULT_WORKING_DAYS}`)
    return { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
  end
  return days
end

-- %u is the ISO weekday, 1 (Monday) to 7 (Sunday), formatted in the user's
-- local timezone — so this flips at local midnight rather than UTC's. An
-- unreadable weekday counts as a workday: showing the widget on a Saturday is
-- a much smaller failure than hiding the start button on a Monday.
local function isWorkday()
  local weekday = tonumber(noctalia.formatTime("%u", math.floor(noctalia.nowMs() / 1000)))
  if weekday == nil then
    noctalia.log("timewarrior: could not read the local weekday, assuming a workday")
    return true
  end
  return workingDays()[weekday] == true
end

-- Inclusive start, exclusive end, in local hours. start > end wraps around
-- midnight (22 to 6 being the obvious case), and start == end reads as "all
-- day" rather than "never" — a zero-length window would make the setting a
-- way to hide the widget entirely, which "always" and "tracking" already
-- cover better.
local function withinWorkingHours()
  local startHour = math.clamp(math.floor(tonumber(noctalia.getConfig("working_hours_start")) or 6), 0, 23)
  local endHour = math.clamp(math.floor(tonumber(noctalia.getConfig("working_hours_end")) or 20), 1, 24)
  local hour = tonumber(noctalia.formatTime("%H", math.floor(noctalia.nowMs() / 1000)))
  if hour == nil then
    noctalia.log("timewarrior: could not read the local hour, assuming working hours")
    return true
  end
  if startHour == endHour then
    return true
  end
  if startHour < endHour then
    return hour >= startHour and hour < endHour
  end
  return hour >= startHour or hour < endHour
end

local function keepSlotWhileIdle()
  local mode = visibility()
  if mode == "always" then
    return true
  elseif mode == "workdays" then
    return isWorkday()
  elseif mode == "working_hours" then
    -- Working *hours*, which only exist on a working day: 09:00 on a Sunday
    -- is not one. This is the strictest mode, and the difference from
    -- "workdays" is that it also gives the evening back.
    return isWorkday() and withinWorkingHours()
  end
  return false
end

-- Which figure to show. Defaults to today's total: it answers the question
-- that gets asked most, and unlike the running interval it still says
-- something once the timer stops.
local METRICS = {
  -- No figure at all: the icon carries the state (logo vs pause, or whichever
  -- glyphs are configured) and the hover carries the numbers.
  icon = { source = "none", label = "icon only", overtime = false },
  interval = { source = "interval", label = "running interval", overtime = true },
  day = { source = "day", label = "today", overtime = true },
  week = { source = "week", label = "this week", overtime = false },
  month = { source = "month", label = "this month", overtime = false },
}

-- The stopped state gets its own choice, defaulting to "same" — whatever the
-- tracking state shows. A day/week/month figure carries over sensibly, while
-- "interval" has nothing to show once the timer stops, which is exactly when
-- someone might want the bar to fall back to a total instead of just the icon.
local function metric(active)
  if active then
    return METRICS[noctalia.getConfig("bar_metric")] or METRICS.day
  end

  local stopped = noctalia.getConfig("bar_metric_stopped")
  if stopped == nil or stopped == "" or stopped == "same" then
    stopped = noctalia.getConfig("bar_metric")
  end
  return METRICS[stopped] or METRICS.day
end

local function metricValue(spec)
  if spec.source == "none" then
    return ""
  elseif spec.source == "interval" then
    return state.duration or ""
  elseif spec.source == "day" then
    return state.today or ""
  elseif spec.source == "week" then
    return summary.week or ""
  end
  return summary.month or ""
end

-- setTooltip takes key/value rows as well as a plain string, which is what
-- the shell's own widgets use — so the hover reads as a small table of the
-- figures instead of one crowded sentence. Rows are built around what is
-- actually known: the running interval and its start only exist while
-- tracking, and the week/month totals only once the summary has landed.
--
-- Each figure keeps the format its own setting gives it, so the tooltip agrees
-- with the panel rather than inventing a third rendering.
local function tooltipRows(active, clockOut)
  local rows = {
    { key = "Timewarrior", value = active and "tracking" or (clockOut and "clocked out" or "not tracking") },
  }

  if active then
    if (state.since or "") ~= "" then
      table.insert(rows, { key = "Started", value = state.since })
    end
    table.insert(rows, {
      key = "Interval",
      value = duration.format(state.duration, formats.get("panel_time_format")),
    })
  end

  if (state.today or "") ~= "" then
    table.insert(rows, { key = "Today", value = duration.format(state.today, formats.get("panel_time_format")) })
  end
  -- The count the clock-out threshold is compared against, so a bar showing
  -- (or stubbornly not showing) the beer explains itself on hover.
  local closed = tonumber(state.closed) or 0
  if closed > 0 then
    table.insert(rows, { key = "Intervals", value = tostring(closed) })
  end
  if (summary.week or "") ~= "" then
    table.insert(rows, { key = "Week", value = duration.format(summary.week, formats.get("week_time_format")) })
  end
  if (summary.month or "") ~= "" then
    table.insert(rows, { key = "Month", value = duration.format(summary.month, formats.get("month_time_format")) })
  end

  return rows
end

render = function()
  local active = state.active == true
  local clockOut = clockedOut(active)
  local container = barWidget.isVertical() and ui.column or ui.row

  if not active and not keepSlotWhileIdle() then
    barWidget.setVisible(false)
    return
  end

  local spec = metric(active)
  local value = metricValue(spec)
  -- The running interval is the one figure that stops existing when the timer
  -- does; the totals stay worth showing.
  if spec.source == "interval" and not active then
    value = ""
  end

  -- An hours threshold means something for an interval or a day; a week or a
  -- month total would sit permanently above any sane one, so those keep the
  -- plain label colour. The icon follows the figure when it is a glyph.
  local color = (spec.overtime and value ~= "") and overtime.color(value)
    or (noctalia.getConfig("label_color") or "on_surface")

  local kind = active and "tracking" or (clockOut and "clock_out" or "stopped")
  local children = { badgeModeIcon(kind, color) or icon(kind, color) }
  if value ~= "" then
    table.insert(children, ui.label({ text = duration.format(value, formats.get("bar_time_format")), color = color }))
  end

  barWidget.setVisible(true)
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(tooltipRows(active, clockOut))
end

noctalia.state.watch("tw_status", function(val)
  if type(val) == "table" then
    state = val
    render()
  end
end)

-- The week and month figures live in the summary snapshot, so the bar follows
-- it too whenever one of those is what it is showing.
noctalia.state.watch("tw_summary", function(val)
  if type(val) == "table" then
    summary = val
    render()
  end
end)

render()

function update()
  render()
end
