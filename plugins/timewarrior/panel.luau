--!nonstrict
-- Timewarrior panel — a start/stop toggle plus week/month/year totals and
-- this week's daily breakdown, ported from the DMS TimewarriorWidget.qml
-- popoutContent.
--
-- The toggle and the editable time fields only publish commands through
-- "tw_cmd"; service.luau owns what actually runs (see its
-- start_command/stop_command handling and `timew modify` wrapper) and reports
-- back through "tw_action".

local duration = require("./lib/duration.luau")

local summary = noctalia.state.get("tw_summary") or { week = "0:00", month = "0:00", year = "0:00", days = {} }
local status = noctalia.state.get("tw_status") or { active = false, duration = "" }
local intervals = noctalia.state.get("tw_intervals") or {}
local action = nil
-- Which boundary is currently being edited, as { id, field }, or nil while the
-- list is just being read. Only one cell is ever an input at a time.
local editing = nil
-- Which day the interval list is showing, as YYYY-MM-DD, or nil for today.
-- Set by clicking a row in the weekly breakdown.
local selectedDate = nil
local render

local function currentFormat()
  local fmt = noctalia.getConfig("panel_time_format")
  return (fmt and fmt ~= "") and fmt or "{hours}h {minutes}m"
end

-- The panel's headline control: one big button that starts or stops tracking
-- depending on the current state, plus the running interval beside it.
local function toggle()
  local active = status.active == true
  local busy = action ~= nil and action.running == true
  local label
  if busy then
    label = active and "Stopping…" or "Starting…"
  else
    label = active and "Stop tracking" or "Start tracking"
  end

  return ui.column({ gap = 4 }, {
    ui.button({
      text = label,
      glyph = active and "player-stop" or "player-play",
      glyphSize = 18,
      -- "destructive" is the error-colored button variant, so stopping reads
      -- red the way it does in the rest of the shell; starting is the primary
      -- accent.
      variant = active and "destructive" or "primary",
      enabled = not busy,
      height = 44,
      flexGrow = 1,
      tooltip = active and "Stop tracking" or "Start tracking",
      onClick = "onToggle",
    }),
    ui.row({ justify = "center" }, {
      ui.label({
        text = active and ("Tracking for " .. duration.format(status.duration, currentFormat())) or "Not tracking",
        fontSize = 12,
        color = active and "primary" or "on_surface_variant",
      }),
    }),
    ui.row({ justify = "center", visible = action ~= nil and (action.message or "") ~= "" }, {
      ui.label({
        text = action and action.message or "",
        fontSize = 11,
        color = "error",
        maxLines = 2,
      }),
    }),
  })
end

local function sendCommand(cmd)
  cmd.n = noctalia.nowMs()
  noctalia.state.set("tw_cmd", cmd)
end

-- One row per interval tracked today: id, start, end, duration. The
-- boundaries read as plain labels and become an input only when clicked —
-- `focus = true` seeds keyboard focus once, at creation, so the field is ready
-- to type in. There is no blur callback in the plugin UI vocabulary, hence the
-- explicit cancel button rather than click-away-to-dismiss.
local TIME_FONT_SIZE = 13

-- `timew` stores seconds, so both precisions are just a rendering of the same
-- epoch. The edit field seeds from the rendered value, which means the choice
-- here is also the precision an edit is expressed in.
local function todayDate()
  return noctalia.formatTime("%Y-%m-%d", math.floor(noctalia.nowMs() / 1000))
end

local function activeDate()
  return selectedDate or todayDate()
end

local function secondsPrecision()
  return noctalia.getConfig("interval_precision") == "seconds"
end

local function clockText(epoch)
  if epoch == nil then
    return ""
  end
  return noctalia.formatTime(secondsPrecision() and "%H:%M:%S" or "%H:%M", epoch)
end

local function timeCellWidth()
  return secondsPrecision() and 104 or 84
end

local function timeCell(row, field, value)
  local cellWidth = timeCellWidth()
  if editing ~= nil and editing.id == row.id and editing.field == field then
    return ui.row({ gap = 2, align = "center" }, {
      ui.input({
        key = `edit-{field}-{row.id}`,
        value = value,
        width = cellWidth,
        fontSize = TIME_FONT_SIZE,
        focus = true,
        submitOnEnter = true,
        onSubmit = function(entered)
          editing = nil
          sendCommand({ action = "modify", field = field, id = row.id, value = entered })
          render()
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        width = 20,
        height = 20,
        glyphSize = 11,
        tooltip = "Cancel",
        onClick = function()
          editing = nil
          render()
        end,
      }),
    })
  end

  return ui.row({
    key = `show-{field}-{row.id}`,
    width = cellWidth,
    justify = "center",
    padding = 3,
    onClick = function()
      editing = { id = row.id, field = field }
      render()
    end,
  }, {
    ui.label({ text = value, fontSize = TIME_FONT_SIZE }),
  })
end

local function intervalRow(row, fmt)
  local children = {
    ui.label({ text = `@{row.id}`, fontSize = 11, color = "on_surface_variant", width = 24 }),
    timeCell(row, "start", clockText(row.startEpoch)),
    ui.label({ text = "→", fontSize = 12, color = "on_surface_variant" }),
  }

  -- The open interval has no end to edit: setting one is what Stop is for,
  -- and `timew modify end` on an open interval is an error anyway.
  if row.open then
    table.insert(children, ui.row({ width = timeCellWidth(), justify = "center" }, {
      ui.label({ text = "running", fontSize = TIME_FONT_SIZE, color = "primary" }),
    }))
  else
    table.insert(children, timeCell(row, "end", clockText(row.endEpoch)))
  end

  table.insert(children, ui.row({ justify = "end", flexGrow = 1 }, {
    ui.label({ text = duration.format(row.duration, fmt), fontSize = 12 }),
  }))

  return ui.row({ key = `interval-{row.id}`, gap = 6, align = "center" }, children)
end

local function intervalSection(fmt)
  local date = activeDate()
  local isToday = date == todayDate()
  local rows = intervals[date] or {}

  local heading = ui.row({ align = "center", gap = 6 }, {
    ui.label({
      text = isToday and "Today" or date,
      fontSize = 14,
      fontWeight = "bold",
    }),
    ui.label({ text = "click a time to edit", fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
  })
  -- Only offered while looking at another day: the way back is otherwise a
  -- second click on the highlighted breakdown row, which is less obvious.
  if not isToday then
    table.insert(heading.children, ui.button({
      text = "Today",
      glyph = "arrow-back-up",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        selectedDate = nil
        editing = nil
        render()
      end,
    }))
  end

  local children = { heading }
  if #rows == 0 then
    table.insert(children, ui.label({
      text = isToday and "Nothing tracked today" or "Nothing tracked that day",
      color = "on_surface_variant",
      fontSize = 13,
    }))
  else
    for _, row in ipairs(rows) do
      table.insert(children, intervalRow(row, fmt))
    end
  end

  return ui.column({ gap = 4 }, children)
end

local function statBox(label, value)
  return ui.column({
    flexGrow = 1,
    gap = 2,
    align = "center",
    padding = 10,
    fill = "surface_variant",
    radius = 8,
  }, {
    ui.label({ text = value, fontSize = 18, fontWeight = "bold" }),
    ui.label({ text = label, fontSize = 12, color = "on_surface_variant" }),
  })
end

-- Clicking a day swaps the interval list above to that day; clicking the
-- selected one goes back to today. Every day of the week is already in
-- "tw_intervals", so this costs no extra `timew` call.
local function dayRow(day, fmt)
  local date = day.date or ""
  local selected = date == activeDate()
  return ui.row({
    key = `day-{date}`,
    justify = "space_between",
    align = "center",
    padding = 3,
    radius = 6,
    fill = selected and "surface_variant" or "#00000000",
    onClick = function()
      selectedDate = (selectedDate == date or date == todayDate()) and nil or date
      editing = nil
      render()
    end,
  }, {
    ui.label({
      text = (day.dow or "") .. " " .. date,
      color = selected and "on_surface" or "on_surface_variant",
      fontSize = 13,
    }),
    ui.label({ text = duration.format(day.duration, fmt), fontSize = 13 }),
  })
end

local function header()
  return ui.row({ gap = 8, align = "center" }, {
    ui.image({
      path = "assets/timewarrior-logo.svg",
      width = 28,
      height = 28,
      fit = "contain",
    }),
    ui.label({ text = "Timewarrior", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Plugin settings",
      onClick = "onSettings",
    }),
  })
end

function render()
  local fmt = currentFormat()
  local content = {
    header(),
    toggle(),
    ui.row({ gap = 8 }, {
      statBox("Week", duration.format(summary.week, fmt)),
      statBox("Month", duration.format(summary.month, fmt)),
      statBox("Year", duration.format(summary.year, fmt)),
    }),
    ui.separator({}),
    intervalSection(fmt),
    ui.separator({}),
    ui.label({ text = "This week", fontSize = 14, fontWeight = "bold" }),
  }

  local days = summary.days or {}
  if #days > 0 then
    local rows = {}
    for _, day in ipairs(days) do
      table.insert(rows, dayRow(day, fmt))
    end
    table.insert(content, ui.scroll({ flexGrow = 1, gap = 4 }, rows))
  else
    table.insert(content, ui.label({ text = "No tracked time this week", color = "on_surface_variant", fontSize = 13 }))
  end

  panel.render(ui.column({ gap = 8, padding = 12 }, content))
end

noctalia.state.watch("tw_summary", function(val)
  if type(val) == "table" then
    summary = val
    render()
  end
end)

noctalia.state.watch("tw_intervals", function(val)
  if type(val) == "table" then
    intervals = val
    render()
  end
end)

-- The precision setting is read at render time, so a change in Settings only
-- needs a re-render to show up.
function onConfigChanged()
  render()
end

function onOpen(_context)
  -- A panel reopened later should read today, not sit in whatever cell was
  -- left mid-edit on whichever day was being inspected when it was dismissed.
  editing = nil
  selectedDate = nil
  render()
end

noctalia.state.watch("tw_status", function(val)
  if type(val) == "table" then
    status = val
    render()
  end
end)

noctalia.state.watch("tw_action", function(val)
  if type(val) == "table" then
    action = val
    render()
  end
end)

render()

function onSettings()
  noctalia.openSettings()
end

function onToggle()
  -- Optimistic local feedback: the service publishes its own "tw_action"
  -- moments later, but the click should look like it landed immediately.
  action = { action = status.active and "stop" or "start", running = true, message = "" }
  render()
  sendCommand({ action = "toggle" })
end
