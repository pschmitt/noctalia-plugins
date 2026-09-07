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
local today = noctalia.state.get("tw_today") or {}
local action = nil

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

-- One row per interval tracked today: id, start, end, duration. Both
-- boundaries are plain text fields — type HH:MM, press Enter, and the service
-- runs `timew modify` for that interval. The fields are uncontrolled (the host
-- owns the buffer, `value` only seeds it), and `key` keeps each field tied to
-- its interval across re-renders so a poll can't overwrite half-typed input.
local function intervalRow(row, fmt)
  local timeField = function(field, value)
    return ui.input({
      key = `{field}-{row.id}`,
      value = value,
      width = 62,
      fontSize = 12,
      submitOnEnter = true,
      textAlign = "center",
      onSubmit = function(entered)
        sendCommand({ action = "modify", field = field, id = row.id, value = entered })
      end,
    })
  end

  local children = {
    ui.label({ text = `@{row.id}`, fontSize = 11, color = "on_surface_variant", width = 24 }),
    timeField("start", row.start),
    ui.label({ text = "→", fontSize = 12, color = "on_surface_variant" }),
  }

  -- The open interval has no end to edit: setting one is what Stop is for,
  -- and `timew modify end` on an open interval is an error anyway.
  if row.open then
    table.insert(children, ui.row({ width = 62, justify = "center" }, {
      ui.label({ text = "running", fontSize = 12, color = "primary" }),
    }))
  else
    table.insert(children, timeField("end", row.stop))
  end

  table.insert(children, ui.row({ justify = "end", flexGrow = 1 }, {
    ui.label({ text = duration.format(row.duration, fmt), fontSize = 12 }),
  }))

  return ui.row({ key = `interval-{row.id}`, gap = 6, align = "center" }, children)
end

local function todaySection(fmt)
  local children = {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({ text = "Today", fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = "HH:MM, Enter to apply", fontSize = 10, color = "on_surface_variant" }),
    }),
  }

  if #today == 0 then
    table.insert(children, ui.label({ text = "Nothing tracked today", color = "on_surface_variant", fontSize = 13 }))
  else
    for _, row in ipairs(today) do
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

local function dayRow(day, fmt)
  return ui.row({ justify = "space_between", padding = 2 }, {
    ui.label({ text = (day.dow or "") .. " " .. (day.date or ""), color = "on_surface_variant", fontSize = 13 }),
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

local function render()
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
    todaySection(fmt),
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

noctalia.state.watch("tw_today", function(val)
  if type(val) == "table" then
    today = val
    render()
  end
end)

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
