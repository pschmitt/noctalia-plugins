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
local formats = require("./lib/formats.luau")
local overtime = require("./lib/overtime.luau")

local summary = noctalia.state.get("tw_summary") or { week = "0:00", month = "0:00", year = "0:00", days = {} }
local status = noctalia.state.get("tw_status") or { active = false, duration = "" }
local intervals = noctalia.state.get("tw_intervals") or {}
local action = nil
local pendingToggle = nil
local pendingEdit = nil
local breakdownExpanded = false
-- Which boundary is currently being edited, as { id, field }, or nil while the
-- list is just being read. Only one cell is ever an input at a time.
local editing = nil
-- Which interval is showing its delete button, as its id, or nil. Rows are
-- read far more often than they are deleted, so the trash stays out of sight
-- until the row's id or its duration is clicked.
local revealed = nil
-- Which interval is one click away from being deleted, as its id, or nil.
-- Deleting is irreversible, so the trash button only arms the confirmation and
-- a second, deliberately different control commits it.
local pendingDelete = nil
-- A delete keeps its row visible while the command runs, then fades the row
-- out after the service publishes the refreshed interval list.
local deleting = nil
local fadingDelete = nil
local deleteFadeDurationMs = 240
-- Which day the interval list is showing, as YYYY-MM-DD, or nil for today.
-- Set by clicking a row in the weekly breakdown.
local selectedDate = nil
local render

local function currentFormat()
  return formats.get("panel_time_format")
end

-- Every command runs through the same "tw_action" state, and this button is
-- the panel's only place to say something is in flight — so it has to name the
-- command that is actually running. It used to read the tracking state
-- instead, which meant a sync (or an edit, or a delete) announced itself as
-- "Starting…".
local BUSY_STATES = {
  start = { text = "Starting…", glyph = "player-play", variant = "primary" },
  stop = { text = "Stopping…", glyph = "player-stop", variant = "destructive" },
  sync = { text = "Syncing…", glyph = "refresh", variant = "secondary" },
  modify = { text = "Saving…", glyph = "pencil", variant = "secondary" },
  delete = { text = "Deleting…", glyph = "trash", variant = "secondary" },
}

local syncFrame = 0
local syncElapsedMs = 0
local SYNC_FRAME_COUNT = 12
local SYNC_FRAME_INTERVAL_MS = 60
-- The start/stop button's own icon cycles an hourglass filling up while its
-- command runs. Noctalia's glyphs cannot be rotated, so the motion is a swap
-- between glyphs, driven by the same frame tick as the spinner.
local BUSY_GLYPH_FRAMES = { "hourglass-empty", "hourglass-low", "hourglass-high", "hourglass" }
local BUSY_GLYPH_INTERVAL_MS = 200
local glyphFrame = 1
local glyphElapsedMs = 0

local function syncBusy()
  return action ~= nil and action.action == "sync" and action.running == true
end

local function animationActive()
  local actionBusy = action ~= nil and action.running == true
  return noctalia.getConfig("animations_enabled") ~= false
    and (actionBusy or deleting ~= nil or fadingDelete ~= nil)
end

local function syncSpinner(size)
  return ui.image({
    path = string.format("assets/sync-spinner-%02d.png", syncFrame),
    width = size,
    height = size,
    fit = "contain",
  })
end

local function animatedBusyGlyph(busy)
  if busy.glyph == "refresh" or noctalia.getConfig("animations_enabled") == false then
    return busy.glyph
  end
  return BUSY_GLYPH_FRAMES[glyphFrame]
end

-- The panel's headline control: one big button that starts or stops tracking
-- depending on the current state, plus the running interval beside it.
local function toggle()
  local active = status.active == true
  local busy = nil
  if action ~= nil and action.running == true then
    busy = BUSY_STATES[action.action]
  end

  -- Just the verb: the subtitle above already says whether anything is being
  -- tracked, so "Stop tracking" on the button was saying it twice. The tooltip
  -- keeps the long form.
  local label = busy and busy.text or (active and "Stop" or "Start")
  if busy ~= nil and action.action == "sync" and pendingToggle ~= nil then
    label = (pendingToggle == "start" and "Started" or "Stopped") .. " · Syncing…"
  elseif busy == nil and pendingToggle ~= nil then
    label = pendingToggle == "start" and "Started" or "Stopped"
  end
  local targetActive = active
  if pendingToggle ~= nil then
    targetActive = pendingToggle == "start"
  end
  local buttonBusy = busy ~= nil or pendingToggle ~= nil

  local children = {
    ui.button({
      text = label,
      glyph = busy and (animatedBusyGlyph(busy)) or (targetActive and "player-stop" or "player-play"),
      glyphSize = 18,
      -- Keep the actual control mounted while work runs. Its label explains
      -- the current action; the adjacent spinner supplies motion without
      -- swapping the button for a different-looking loading surface.
      variant = busy and busy.variant or (targetActive and "destructive" or "primary"),
      enabled = not buttonBusy,
      height = 44,
      flexGrow = 1,
      tooltip = buttonBusy and label or (active and "Stop tracking" or "Start tracking"),
      onClick = "onToggle",
    }),
  }
  if busy ~= nil and action.action ~= "sync" then
    table.insert(children, ui.row({ width = 20, height = 44, align = "center", justify = "center" }, {
      syncSpinner(18),
    }))
  end
  table.insert(children, ui.row({ justify = "center", visible = action ~= nil and (action.message or "") ~= "" }, {
    ui.label({
      text = action and action.message or "",
      fontSize = 11,
      color = "error",
      maxLines = 2,
    }),
  }))
  return ui.column({ gap = 4 }, { ui.row({ gap = 6, align = "center" }, children) })
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
local PANEL_PADDING = 12

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

local function findInterval(date, id, source)
  for _, row in ipairs((source or intervals)[date] or {}) do
    if tostring(row.id) == tostring(id) then
      return row
    end
  end
  return nil
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

local function normalizedClockText(value)
  local hour, minute, second = value:match("^(%d%d?):(%d%d):(%d%d)$")
  if hour == nil then
    hour, minute = value:match("^(%d%d?):(%d%d)$")
    second = "00"
  end
  if hour == nil then
    return nil
  end
  local h, m, s = tonumber(hour), tonumber(minute), tonumber(second)
  if h == nil or m == nil or s == nil or h > 23 or m > 59 or s > 59 then
    return nil
  end
  if secondsPrecision() then
    return string.format("%02d:%02d:%02d", h, m, s)
  end
  return string.format("%02d:%02d", h, m)
end

local function breakdownTitle()
  local days = math.floor(tonumber(noctalia.getConfig("breakdown_days")) or 14)
  return `Last {days} days`
end

local function breakdownHeading()
  return ui.row({
    gap = 6,
    align = "center",
    paddingV = 2,
    tooltip = breakdownExpanded and "Collapse daily breakdown" or "Expand daily breakdown",
    onClick = function()
      breakdownExpanded = not breakdownExpanded
      render()
    end,
  }, {
    ui.glyph({
      name = breakdownExpanded and "chevron-down" or "chevron-right",
      size = 14,
      color = "on_surface_variant",
    }),
    ui.label({ text = breakdownTitle(), fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
  })
end

local function timeCellWidth()
  return secondsPrecision() and 104 or 84
end

local function timeCell(row, field, value)
  local cellWidth = timeCellWidth()
  if pendingEdit ~= nil and pendingEdit.id == row.id and pendingEdit.field == field then
    value = pendingEdit.value
  end
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
          pendingEdit = { id = row.id, field = field, value = entered }
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
      pendingDelete = nil
      render()
    end,
  }, {
    ui.label({ text = value, fontSize = TIME_FONT_SIZE }),
  })
end

local function intervalRow(row, fmt, options)
  options = options or {}
  local isDeleting = options.deleting == true
  local opacity = options.opacity or 1
  -- The id and the duration are the row's "handles": clicking either reveals
  -- the delete button, clicking again puts it away. Neither is an editable
  -- value, so a click on them has nothing else to mean.
  local toggleReveal = function()
    revealed = revealed == row.id and nil or row.id
    pendingDelete = nil
    render()
  end

  local children = {
    -- Fixed-width and right-aligned: a bare label with a width still lays out
    -- its own text, so a two-digit id ("@10") pushed the times a few pixels
    -- further right than a one-digit one ("@9") and the columns stopped
    -- lining up between rows.
    ui.row({ width = 34, justify = "end", padding = 3, onClick = toggleReveal }, {
      ui.label({ text = `@{row.id}`, fontSize = 11, color = "on_surface_variant" }),
    }),
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

  table.insert(children, ui.row({ justify = "end", flexGrow = 1, padding = 3, onClick = toggleReveal }, {
    ui.label({ text = duration.format(row.duration, fmt), fontSize = 12 }),
  }))

  -- An empty slot the width of the button keeps the durations in one column
  -- whether or not a row is showing its trash.
  if isDeleting then
    table.insert(children, ui.row({ width = 22, height = 22, align = "center", justify = "center" }, {
      syncSpinner(16),
    }))
  elseif revealed ~= row.id then
    table.insert(children, ui.row({ width = 22 }, {}))
  elseif pendingDelete == row.id then
    table.insert(children, ui.button({
      glyph = "trash",
      variant = "destructive",
      controlSize = "sm",
      glyphSize = 12,
      tooltip = `Delete interval @{row.id} — this cannot be undone`,
      onClick = function()
        pendingDelete = nil
        revealed = nil
        deleting = { id = row.id, date = activeDate(), row = row }
        action = { action = "delete", running = true, message = "" }
        sendCommand({ action = "delete", id = row.id })
        render()
      end,
    }))
    table.insert(children, ui.button({
      glyph = "x",
      variant = "ghost",
      width = 22,
      height = 22,
      glyphSize = 11,
      tooltip = "Keep it",
      onClick = function()
        pendingDelete = nil
        revealed = nil
        render()
      end,
    }))
  else
    table.insert(children, ui.button({
      glyph = "trash",
      variant = "ghost",
      width = 22,
      height = 22,
      glyphSize = 11,
      tooltip = "Delete interval",
      onClick = function()
        pendingDelete = row.id
        editing = nil
        render()
      end,
    }))
  end

  return ui.row({ key = `interval-{row.id}`, gap = 6, align = "center", opacity = opacity }, children)
end

-- The weekday the breakdown row was labelled with, so clicking "Fr 2026-09-04"
-- doesn't drop the "Fr" from the heading it opens. The breakdown is the same
-- source, with the intervals themselves as the fallback for a day it doesn't
-- list (an empty day reached through the panel's open context).
local function weekdayFor(date)
  for _, day in ipairs(summary.days or {}) do
    if day.date == date then
      return day.dow or ""
    end
  end
  local rows = intervals[date]
  if rows ~= nil and rows[1] ~= nil then
    return noctalia.formatTime("%a", rows[1].startEpoch)
  end
  return ""
end

-- The hint leans on everything available to say "aside" quietly: a pencil, a
-- smaller size, the muted role colour — and an italic face when
-- italic_font_family names one, since a label cannot ask for a slant.
local function editHint()
  local family = noctalia.getConfig("italic_font_family")
  local label = {
    text = "click a time to edit",
    fontSize = 10,
    color = "on_surface_variant",
  }
  if family ~= nil and family ~= "" then
    label.fontFamily = family
  end

  return ui.row({ gap = 3, align = "center" }, {
    ui.glyph({ name = "pencil", size = 10, color = "on_surface_variant" }),
    ui.label(label),
  })
end

local function intervalSection(fmt)
  local date = activeDate()
  local isToday = date == todayDate()
  local rows = intervals[date] or {}
  local visibleRows = {}
  for _, row in ipairs(rows) do
    table.insert(visibleRows, { row = row })
  end
  if fadingDelete ~= nil and fadingDelete.date == date then
    local present = false
    for _, row in ipairs(rows) do
      if tostring(row.id) == tostring(fadingDelete.row.id) then
        present = true
        break
      end
    end
    if not present then
      table.insert(visibleRows, { row = fadingDelete.row, opacity = math.max(0, 1 - fadingDelete.elapsedMs / deleteFadeDurationMs) })
    end
  end
  local weekday = weekdayFor(date)

  local heading = ui.row({ align = "center", gap = 6 }, {
    ui.label({
      text = isToday and "Today" or (weekday ~= "" and `{weekday} {date}` or date),
      fontSize = 14,
      fontWeight = "bold",
      -- The heading takes the slack, so the hint sits against the right edge
      -- (or against the "Today" button, when that is there) instead of
      -- floating next to the title.
      flexGrow = 1,
    }),
    editHint(),
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
        pendingDelete = nil
        revealed = nil
        render()
      end,
    }))
  end

  local children = { heading }
  if #visibleRows == 0 then
    table.insert(children, ui.label({
      text = isToday and "Nothing tracked today" or "Nothing tracked that day",
      color = "on_surface_variant",
      fontSize = 13,
    }))
  else
    for _, entry in ipairs(visibleRows) do
      local row = entry.row
      local isDeleting = deleting ~= nil and deleting.date == date and tostring(deleting.id) == tostring(row.id)
      table.insert(children, intervalRow(row, fmt, {
        deleting = isDeleting,
        opacity = entry.opacity,
      }))
    end
  end

  return ui.column({ gap = 4 }, children)
end

-- Which week/month/year the figure above is actually about. The totals come
-- from `timew`'s own :week/:month/:year, so this is only ever the current one —
-- the ISO week number (Monday-based, like timew's week), the abbreviated month
-- name, and the year. Rendered in the box's own label to keep the boxes one
-- line tall, and via noctalia.formatTime, so month names follow the same
-- locale as the weekday labels in the breakdown.
local function statContext(kind)
  local now = math.floor(noctalia.nowMs() / 1000)
  if kind == "week" then
    return noctalia.formatTime("%V", now)
  elseif kind == "month" then
    return noctalia.formatTime("%b", now)
  end
  return noctalia.formatTime("%Y", now)
end

local function statBox(label, kind, value)
  local context = statContext(kind)
  return ui.column({
    flexGrow = 1,
    gap = 2,
    align = "center",
    padding = 10,
    fill = "surface_variant",
    radius = 8,
  }, {
    ui.label({ text = value, fontSize = 18, fontWeight = "bold" }),
    ui.label({
      text = context ~= "" and `{label} ({context})` or label,
      fontSize = 12,
      color = "on_surface_variant",
    }),
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
      pendingDelete = nil
      revealed = nil
      render()
    end,
  }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({
        text = (day.dow or "") .. " " .. date,
        color = selected and "on_surface" or "on_surface_variant",
        fontSize = 13,
      }),
      -- Today is the one date in a fortnight worth recognising without
      -- reading it, and unlike the selection highlight this stays put when
      -- another day is being inspected. Hidden rather than omitted on the
      -- other rows, so every row lays its date and duration out identically.
      ui.row({
        visible = date == todayDate(),
        fill = "primary/0.18",
        radius = 5,
        paddingH = 5,
        paddingV = 1,
      }, {
        ui.label({ text = "TODAY", fontSize = 9, fontWeight = "bold", color = "primary" }),
      }),
    }),
    -- Same overtime threshold and colours the bar widget uses, so a long day
    -- reads the same here as it did in the bar while it was being worked.
    ui.label({ text = duration.format(day.duration, fmt), fontSize = 13, color = overtime.color(day.duration) }),
  })
end

-- Optional, and off unless sync_enabled says otherwise: a sync is a
-- Timewarrior deployment choice, not something every user of this widget has.
-- ui.row with no children is the "render nothing" spelling, since a nil child
-- would be a hole in the header's child list.
local function syncButton()
  if noctalia.getConfig("sync_enabled") ~= true and not syncBusy() then
    return ui.row({ visible = false }, {})
  end

  local busy = syncBusy()
  if busy then
    return ui.row({ width = 32, height = 32, align = "center", justify = "center" }, {
      syncSpinner(16),
    })
  end
  return ui.button({
    glyph = "refresh",
    variant = "ghost",
    controlSize = "sm",
    enabled = not busy,
    tooltip = busy and "Syncing…" or "Sync now",
    onClick = "onSync",
  })
end

local function header()
  local active = status.active == true
  return ui.row({ gap = 8, align = "center" }, {
    -- Sized against the title and subtitle stacked beside it (16px + 11px
    -- plus the column gap), so the logo reads as the panel's mark rather than
    -- a small icon in front of the text.
    ui.image({
      path = "assets/timewarrior-logo.svg",
      width = 34,
      height = 34,
      fit = "contain",
    }),
    -- The tracking state belongs next to the title, not under the button: it
    -- says what the plugin is doing, while the button says what a click will
    -- do to it.
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = "Timewarrior", fontSize = 16, fontWeight = "bold" }),
      ui.label({
        text = active and ("Tracking for " .. duration.format(status.duration, currentFormat())) or "Not tracking",
        fontSize = 11,
        color = active and "primary" or "on_surface_variant",
      }),
    }),
    syncButton(),
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
  panel.setNeedsFrameTick(animationActive())
  local fmt = currentFormat()
  local content = {
    header(),
    toggle(),
    ui.row({ gap = 8 }, {
      statBox("Week", "week", duration.format(summary.week, formats.get("week_time_format"))),
      statBox("Month", "month", duration.format(summary.month, formats.get("month_time_format"))),
      statBox("Year", "year", duration.format(summary.year, formats.get("year_time_format"))),
    }),
    ui.separator({}),
    intervalSection(fmt),
    ui.separator({}),
    breakdownHeading(),
  }

  local days = summary.days or {}
  if breakdownExpanded and #days > 0 then
    local rows = {}
    for _, day in ipairs(days) do
      table.insert(rows, dayRow(day, fmt))
    end
    local configuredDays = math.floor(tonumber(noctalia.getConfig("breakdown_days")) or 14)
    if configuredDays <= 14 then
      -- The content-height panel can fit the default fortnight without an
      -- inner scroll area, so expanding it grows the popup instead.
      table.insert(content, ui.column({ gap = 4 }, rows))
    else
      -- Longer configured windows can exceed max_height; keep those usable.
      table.insert(content, ui.scroll({ flexGrow = 1, gap = 4 }, rows))
    end
  elseif breakdownExpanded then
    table.insert(content, ui.label({ text = "No tracked time in this window", color = "on_surface_variant", fontSize = 13 }))
  end

  panel.render(ui.column({
    gap = 8,
    padding = PANEL_PADDING,
  }, content))
end

noctalia.state.watch("tw_summary", function(val)
  if type(val) == "table" then
    summary = val
    render()
  end
end)

noctalia.state.watch("tw_intervals", function(val)
  if type(val) == "table" then
    if pendingEdit ~= nil then
      local target = normalizedClockText(pendingEdit.value)
      if target ~= nil then
        for _, rows in pairs(val) do
          for _, row in ipairs(rows) do
            if row.id == pendingEdit.id then
              local epoch = pendingEdit.field == "start" and row.startEpoch or row.endEpoch
              if epoch ~= nil and clockText(epoch) == target then
                pendingEdit = nil
              end
              break
            end
          end
          if pendingEdit == nil then
            break
          end
        end
      end
    end
    if deleting ~= nil and findInterval(deleting.date, deleting.id, val) == nil then
      if noctalia.getConfig("animations_enabled") ~= false then
        fadingDelete = { date = deleting.date, row = deleting.row, elapsedMs = 0 }
      end
      deleting = nil
    end
    intervals = val
    render()
  end
end)

-- The precision setting is read at render time, so a change in Settings only
-- needs a re-render to show up.
function onConfigChanged()
  render()
end

function onOpen(context)
  -- A panel reopened later should read today, not sit in whatever cell was
  -- left mid-edit on whichever day was being inspected when it was dismissed.
  -- A YYYY-MM-DD context opens straight on that day instead, so a keybind or
  -- `noctalia msg panel-open pschmitt/timewarrior:panel 2026-09-01` can land
  -- on the day it means.
  editing = nil
  breakdownExpanded = false
  pendingDelete = nil
  revealed = nil
  deleting = nil
  fadingDelete = nil
  selectedDate = nil
  if type(context) == "string" and context:match("^%d%d%d%d%-%d%d%-%d%d$") then
    selectedDate = context
  end
  render()
end

function onClose()
  panel.setNeedsFrameTick(false)
end

function onFrameTick(deltaMs)
  if not animationActive() then
    panel.setNeedsFrameTick(false)
    return
  end
  local elapsed = tonumber(deltaMs) or SYNC_FRAME_INTERVAL_MS
  syncElapsedMs += tonumber(deltaMs) or SYNC_FRAME_INTERVAL_MS
  if fadingDelete ~= nil then
    fadingDelete.elapsedMs += elapsed
    if fadingDelete.elapsedMs >= deleteFadeDurationMs then
      fadingDelete = nil
    end
  end
  if action ~= nil and action.running == true then
    glyphElapsedMs += elapsed
    if glyphElapsedMs >= BUSY_GLYPH_INTERVAL_MS then
      glyphElapsedMs = glyphElapsedMs % BUSY_GLYPH_INTERVAL_MS
      glyphFrame = glyphFrame % #BUSY_GLYPH_FRAMES + 1
    end
    if syncElapsedMs >= SYNC_FRAME_INTERVAL_MS then
      syncElapsedMs = syncElapsedMs % SYNC_FRAME_INTERVAL_MS
      syncFrame = (syncFrame + 1) % SYNC_FRAME_COUNT
    end
  end
  render()
end

noctalia.state.watch("tw_status", function(val)
  if type(val) == "table" then
    status = val
    if (pendingToggle == "start" and val.active == true) or (pendingToggle == "stop" and val.active == false) then
      pendingToggle = nil
    end
    render()
  end
end)

noctalia.state.watch("tw_action", function(val)
  if type(val) == "table" then
    action = val
    if (val.action == "start" or val.action == "stop") and val.running ~= true and val.success == false then
      pendingToggle = nil
    end
    if val.action == "modify" and val.running ~= true and val.success == false then
      pendingEdit = nil
    end
    if deleting ~= nil and val.action == "delete" and val.running ~= true and val.success == false then
      deleting = nil
    end
    render()
  end
end)

render()

function onSettings()
  noctalia.openSettings()
end

function onSync()
  -- Same optimistic feedback as the toggle: the service publishes its own
  -- "tw_action" a moment later.
  pendingToggle = nil
  action = { action = "sync", running = true, message = "" }
  render()
  sendCommand({ action = "sync" })
end

function onToggle()
  -- Optimistic local feedback: the service publishes its own "tw_action"
  -- moments later, but the click should look like it landed immediately.
  pendingToggle = status.active and "stop" or "start"
  action = { action = pendingToggle, running = true, message = "" }
  render()
  sendCommand({ action = "toggle" })
end
