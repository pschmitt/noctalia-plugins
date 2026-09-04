--!nonstrict
-- Timewarrior poller — the headless [[service]] entry.
--
-- Calls the `timew` CLI directly and decodes its JSON export with Noctalia's
-- built-in JSON API. This keeps the plugin self-contained: it has no Nix
-- helper binaries and no jq dependency. Two snapshots are published:
-- "tw_status" (current tracking state, for bar.luau) and "tw_summary"
-- (week/month/year totals + day breakdown, for panel.luau).

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function pollMs()
  return (tonumber(noctalia.getConfig("poll_interval")) or 5) * 1000
end

local summary = { week = "0:00", month = "0:00", year = "0:00", days = {} }

local function runTimew(args, callback)
  local argv = { "timew" }
  for _, arg in ipairs(args) do
    table.insert(argv, arg)
  end
  noctalia.runAsync(argv, callback, 5000)
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

local function weekBreakdown(intervals)
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
  table.sort(days, function(a, b)
    return a.date < b.date
  end)
  return days
end

local function refreshSummary()
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

  runTimew({ "export", ":week" }, function(r)
    summary.days = weekBreakdown(parseExport(r))
    publishSummary()
  end)
end

local function poll()
  runTimew({ "export", ":day" }, function(r)
    local now = math.floor(noctalia.nowMs() / 1000)
    for _, interval in ipairs(parseExport(r)) do
      if interval["end"] == nil then
        noctalia.state.set("tw_status", {
          active = true,
          duration = formatDuration(intervalDuration(interval, now)),
        })
        refreshSummary()
        return
      end
    end

    noctalia.state.set("tw_status", { active = false, duration = "" })
    refreshSummary()
  end)
end

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
