--!nonstrict
-- Timewarrior poller — the headless [[service]] entry.
--
-- Calls the `timew` CLI directly and decodes its JSON export with Noctalia's
-- built-in JSON API. This keeps the plugin self-contained: it has no Nix
-- helper binaries and no jq dependency. Two snapshots are published:
-- "tw_status" (current tracking state, for bar.luau), "tw_summary"
-- (week/month/year totals + day breakdown, for panel.luau) and
-- "tw_intervals" (the breakdown window's intervals grouped by local date,
-- which is what the panel's editable rows are built from — for any day it
-- lists, not just today).
--
-- It also owns starting and stopping tracking, and editing interval
-- boundaries: the panel's toggle button, the bar's middle click and the
-- panel's time fields only publish a command through "tw_cmd", and the outcome
-- comes back through "tw_action".

local function trim(s)
  return noctalia.string.trim(s or "")
end

-- The breakdown window: `breakdown_days` days ending today. One export covers
-- it, and both the per-day totals and the per-day interval lists come out of
-- that one call.
local function breakdownDays()
  return math.clamp(math.floor(tonumber(noctalia.getConfig("breakdown_days")) or 14), 2, 62)
end

-- Only the calendar date is used, so the hour that a DST change adds or drops
-- to a 86400-second day cannot shift the window by more than the boundary day
-- itself — and `timew` is given "<date> - tomorrow", which is inclusive of
-- everything tracked today.
local function breakdownStartDate()
  local now = math.floor(noctalia.nowMs() / 1000)
  return noctalia.formatTime("%Y-%m-%d", now - (breakdownDays() - 1) * 86400)
end

local function pollMs()
  return (tonumber(noctalia.getConfig("poll_interval")) or 5) * 1000
end

local function databasePath()
  local configured = noctalia.string.trim(noctalia.getConfig("database_path") or "")
  if configured == "" then
    configured = noctalia.getenv("TIMEWARRIORDB") or "~/.config/timewarrior"
  end
  return noctalia.expandPath(configured)
end

local COMMAND = "tw_cmd"
local ACTION = "tw_action"

local summary = { week = "0:00", month = "0:00", year = "0:00", days = {} }
-- Mirrors the last published "tw_status", so a "toggle" command knows which
-- way to go without re-exporting.
local tracking = false
local pending = nil

local function runTimew(args, callback, timeoutMs)
  local argv = { "env", "TIMEWARRIORDB=" .. databasePath(), "timew" }
  for _, arg in ipairs(args) do
    table.insert(argv, arg)
  end
  noctalia.runAsync(argv, callback, timeoutMs or 5000)
end

-- Timewarrior timestamps are UTC in YYYYMMDDTHHMMSSZ form. Convert them to a
-- Unix timestamp without a shell/date dependency. The civil-date calculation
-- is Howard Hinnant's public-domain days-from-civil algorithm.
local function utcEpoch(timestamp)
  local year, month, day, hour, minute, second = timestamp:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
  if not year then
    return nil
  end

  local y = tonumber(year)
  local m = tonumber(month)
  local d = tonumber(day)
  local h = tonumber(hour)
  local min = tonumber(minute)
  local s = tonumber(second)
  if not y or not m or not d or not h or not min or not s then
    return nil
  end

  if m <= 2 then
    y -= 1
  end
  local era = math.floor(y / 400)
  local yearOfEra = y - era * 400
  local monthOfYear = m + (m > 2 and -3 or 9)
  local dayOfYear = math.floor((153 * monthOfYear + 2) / 5) + d - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  local daysSinceEpoch = era * 146097 + dayOfEra - 719468
  return daysSinceEpoch * 86400 + h * 3600 + min * 60 + s
end

local function formatDuration(seconds)
  local totalSeconds = math.max(0, math.floor(seconds or 0))
  return string.format("%d:%02d", math.floor(totalSeconds / 3600), math.floor(totalSeconds % 3600 / 60))
end

local function parseExport(result)
  if result.exitCode ~= 0 then
    noctalia.log("timew export failed: " .. trim(result.stderr))
    return {}
  end
  local decoded = noctalia.json.decode(result.stdout)
  return type(decoded) == "table" and decoded or {}
end

local function intervalDuration(interval, now)
  local start = utcEpoch(interval.start or "")
  if not start then
    return 0
  end
  local finish = utcEpoch(interval["end"] or "") or now
  return math.max(0, finish - start)
end

local function totalDuration(intervals)
  local now = math.floor(noctalia.nowMs() / 1000)
  local total = 0
  for _, interval in ipairs(intervals) do
    total += intervalDuration(interval, now)
  end
  return formatDuration(total)
end

local function publishSummary()
  noctalia.state.set("tw_summary", summary)
end

-- Intervals in the shape the panel's editable rows need: raw boundary epochs
-- plus the `timew` id to address them by. Formatting is the panel's business
-- (it owns the interval_precision setting), so the snapshot stays
-- precision-agnostic and a setting change needs no re-poll. The open interval
-- carries no end, and is flagged rather than given a placeholder.
--
-- Grouped by local calendar date so the panel can show any day the breakdown
-- lists from one export — clicking a day needs no extra query, and the ids
-- stay valid for `timew modify` whichever day they came from.
local function intervalsByDate(intervals, now)
  local byDate = {}
  for _, interval in ipairs(intervals) do
    local start = utcEpoch(interval.start or "")
    if start then
      local finish = utcEpoch(interval["end"] or "")
      -- Group by the local date of the interval's start, matching how the
      -- breakdown attributes its totals.
      local date = noctalia.formatTime("%Y-%m-%d", start)
      local rows = byDate[date] or {}
      table.insert(rows, {
        id = tonumber(interval.id) or 0,
        startEpoch = start,
        endEpoch = finish,
        open = finish == nil,
        duration = formatDuration((finish or now) - start),
      })
      byDate[date] = rows
    end
  end

  for _, rows in pairs(byDate) do
    table.sort(rows, function(a, b)
      return a.startEpoch < b.startEpoch
    end)
  end
  return byDate
end

local function dayBreakdown(intervals)
  local now = math.floor(noctalia.nowMs() / 1000)
  local totals = {}
  for _, interval in ipairs(intervals) do
    local start = utcEpoch(interval.start or "")
    if start then
      -- Render in the user's configured local timezone rather than assigning
      -- the UTC timestamp directly to a calendar day.
      local date = noctalia.formatTime("%Y-%m-%d", start)
      local weekday = noctalia.formatTime("%a", start)
      local entry = totals[date] or { date = date, dow = weekday, seconds = 0 }
      entry.seconds += intervalDuration(interval, now)
      totals[date] = entry
    end
  end

  local days = {}
  for _, entry in pairs(totals) do
    table.insert(days, {
      date = entry.date,
      dow = entry.dow,
      duration = formatDuration(entry.seconds),
    })
  end
  -- Newest first: with a two-week window, today matters more than the oldest
  -- day in it, and the panel shows this list in a scroll area.
  table.sort(days, function(a, b)
    return a.date > b.date
  end)
  return days
end

local function refreshSummary()
  -- One export for both things the breakdown window feeds: the per-day totals
  -- and the per-day interval lists.
  runTimew({ "export", breakdownStartDate(), "-", "tomorrow" }, function(r)
    local intervals = parseExport(r)
    summary.days = dayBreakdown(intervals)
    publishSummary()
    noctalia.state.set("tw_intervals", intervalsByDate(intervals, math.floor(noctalia.nowMs() / 1000)))
  end)

  -- The "Week" figure keeps its own :week export rather than being summed out
  -- of the window above: `timew` owns where the week starts.
  runTimew({ "export", ":week" }, function(r)
    summary.week = totalDuration(parseExport(r))
    publishSummary()
  end)

  runTimew({ "export", ":month" }, function(r)
    summary.month = totalDuration(parseExport(r))
    publishSummary()
  end)

  runTimew({ "export", ":year" }, function(r)
    summary.year = totalDuration(parseExport(r))
    publishSummary()
  end)
end

local function poll()
  runTimew({ "export", ":day" }, function(r)
    local intervals = parseExport(r)
    local now = math.floor(noctalia.nowMs() / 1000)

    for _, interval in ipairs(intervals) do
      if interval["end"] == nil then
        tracking = true
        noctalia.state.set("tw_status", {
          active = true,
          duration = formatDuration(intervalDuration(interval, now)),
        })
        refreshSummary()
        return
      end
    end

    tracking = false
    noctalia.state.set("tw_status", { active = false, duration = "" })
    refreshSummary()
  end)
end

-- ── Starting and stopping ─────────────────────────────────────────────────
--
-- What a start/stop actually runs is configurable. `timew start` / `timew stop`
-- is only the default: point start_command/stop_command at a wrapper (a shell
-- function, a script) and it can own the rest of the ritual — bring a VPN up,
-- dismiss a reminder, start a task in Taskwarrior, sync afterwards — while the
-- plugin keeps owning the widget, the panel and the polling.
--
-- runAsync's string form goes through /bin/sh -c, so a configured command is a
-- shell command line, not an argv array. It is run with the resolved
-- TIMEWARRIORDB exported, so a wrapper always talks to the database the widget
-- is displaying.

local function commandTimeoutMs()
  return (tonumber(noctalia.getConfig("command_timeout")) or 120) * 1000
end

local function configuredCommand(action)
  return trim(noctalia.getConfig(action == "stop" and "stop_command" or "start_command") or "")
end

local function publishAction(action, running, success, message)
  noctalia.state.set(ACTION, {
    n = noctalia.nowMs(),
    action = action,
    running = running,
    success = success,
    message = message or "",
  })
end

-- Wrappers are chatty (sync progress, a closing `timew summary`), and the
-- panel has room for a line, not a transcript — so only the last non-empty
-- output line is surfaced, and only when the command failed.
local function lastLine(text)
  local result = ""
  for line in trim(text):gmatch("[^\n]+") do
    local candidate = trim(line)
    if candidate ~= "" then
      result = candidate
    end
  end
  return result
end

local FAILURE_TEXT = {
  start = "Could not start tracking: ",
  stop = "Could not stop tracking: ",
  modify = "Could not change the interval: ",
  delete = "Could not delete the interval: ",
}

local function finishCommand(action, result)
  pending = nil
  if result.exitCode == 0 then
    publishAction(action, false, true, "")
  else
    local message = lastLine(result.stderr or "")
    if message == "" then
      message = lastLine(result.stdout or "")
    end
    if message == "" then
      message = "exit code " .. tostring(result.exitCode)
    end
    noctalia.log("timewarrior " .. action .. " failed: " .. message)
    noctalia.notifyError("Timewarrior", (FAILURE_TEXT[action] or "Timewarrior failed: ") .. message)
    publishAction(action, false, false, message)
  end
  poll()
end

local function runCommand(action)
  if pending ~= nil then
    return
  end
  pending = action
  publishAction(action, true, nil, "")

  local custom = configuredCommand(action)
  local finish = function(result)
    finishCommand(action, result)
  end

  if custom == "" then
    runTimew({ action }, finish, commandTimeoutMs())
  else
    noctalia.runAsync("TIMEWARRIORDB='" .. databasePath() .. "' " .. custom, finish, commandTimeoutMs())
  end
end

-- ── Editing today's boundaries ────────────────────────────────────────────
--
-- `timew modify start|end @<id> <time>` is the whole mechanism. Times are
-- accepted as HH:MM (or HH:MM:SS) and normalised here rather than in the
-- panel, so every entry point — panel field, IPC, a future launcher action —
-- gets the same validation. rc.confirmation=off keeps `timew` from waiting on
-- a prompt no one can answer from a bar panel.
--
-- Interval ids are positional (@1 is the newest), so they shift when an
-- interval is added. The panel re-renders from each poll, which keeps the
-- window where a stale id could be submitted down to one poll interval.
local function normalizeTime(value)
  local hour, minute, second = value:match("^(%d%d?):(%d%d):(%d%d)$")
  if hour == nil then
    hour, minute = value:match("^(%d%d?):(%d%d)$")
    second = "00"
  end
  if hour == nil then
    return nil
  end
  local h, m, sec = tonumber(hour), tonumber(minute), tonumber(second)
  if h == nil or m == nil or sec == nil or h > 23 or m > 59 or sec > 59 then
    return nil
  end
  return string.format("%02d:%02d:%02d", h, m, sec)
end

local function modifyInterval(field, id, value)
  local intervalId = math.floor(tonumber(id) or 0)
  if field ~= "start" and field ~= "end" then
    return
  end
  if intervalId < 1 then
    return
  end

  local raw = trim(tostring(value or ""))
  local time = normalizeTime(raw)
  if time == nil then
    publishAction("modify", false, false, `"{raw}" is not a HH:MM time`)
    return
  end

  publishAction("modify", true, nil, "")
  runTimew({ "rc.confirmation=off", "modify", field, `@{intervalId}`, time }, function(result)
    finishCommand("modify", result)
  end, commandTimeoutMs())
end

-- `timew delete @<id>` is destructive and irreversible, so the panel asks
-- first — this end only checks that it is being told about a real id.
-- rc.confirmation=off is the same reason as in modify: nobody can answer a
-- terminal prompt from a bar panel.
local function deleteInterval(id)
  local intervalId = math.floor(tonumber(id) or 0)
  if intervalId < 1 then
    return
  end

  publishAction("delete", true, nil, "")
  runTimew({ "rc.confirmation=off", "delete", `@{intervalId}` }, function(result)
    finishCommand("delete", result)
  end, commandTimeoutMs())
end

local function dispatch(cmd)
  local action = cmd.action
  if action == "toggle" then
    action = tracking and "stop" or "start"
  end
  if action == "start" or action == "stop" then
    runCommand(action)
  elseif action == "modify" then
    modifyInterval(cmd.field, cmd.id, cmd.value)
  elseif action == "delete" then
    deleteInterval(cmd.id)
  end
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) == "table" then
    dispatch(cmd)
  end
end)

function onIpc(event)
  dispatch({ action = event })
end


poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
