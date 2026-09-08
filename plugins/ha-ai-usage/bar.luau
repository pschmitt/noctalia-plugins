--!nonstrict

local shared = require("./shared.luau")
local items = noctalia.state.get("ha_ai_usage.items") or {}
local errorMessage = noctalia.state.get("ha_ai_usage.error") or ""

local function providerIcon(card, size, color)
  if card.image then return ui.image({ path = card.image, width = size, height = size, fit = "contain" }) end
  return ui.glyph({ name = card.glyph, size = size, color = color })
end

local function selectedCards()
  local limit = math.max(1, math.min(20, tonumber(shared.config("bar_metric_limit", 3)) or 3))
  local cards = shared.filterCards(shared.cards(items), shared.config("bar_card_filter", ""))
  return shared.selectWindow(cards, shared.config("bar_metric_window", "short"), limit)
end

local function metricText(metric)
  return (metric.label or "Usage") .. " " .. shared.displayPercent(
    metric.used,
    noctalia.getConfig("bar_show_remaining") == true
  )
end

-- The progress bar, value and reset label for one metric -- everything
-- segment() puts beside the icon/name, minus the row wrapper, so the "both"
-- window can stack two of these in a column instead of laying them out flat.
-- `stacked` shrinks the text: a single row's height is whatever the bar
-- widget's own row height budget is, but two stacked rows split that budget
-- in half, and the 11px/10px sizes below are sized for one row, not half of
-- one -- at full size they overflowed the bar's fixed height entirely,
-- dropping its capsule background (reported live, see git log).
local function metricNodes(metric, stacked)
  local nodes = {}
  if noctalia.getConfig("bar_show_progress") ~= false and metric.used ~= nil then
    nodes[#nodes + 1] = ui.progress({
      progress = metric.used / 100,
      fill = shared.colorFor(metric.used),
      track = "on_surface/0.16",
      width = tonumber(shared.config("bar_progress_width", 26)) or 26,
      height = tonumber(shared.config("bar_progress_height", 5)) or 5,
      radius = 6,
    })
  end
  if noctalia.getConfig("bar_show_value") == true then
    nodes[#nodes + 1] = ui.label({
      text = metricText(metric),
      fontSize = stacked and 9 or 11,
      fontWeight = "semibold",
      color = shared.colorFor(metric.used),
      maxLines = 1,
    })
  end
  -- Only checks its own toggle plus the icon-mode bail-out above, same as
  -- bar_show_name/bar_show_progress/bar_show_value -- it used to also
  -- require mode == "detailed", which was redundant now that "detailed" is
  -- the only non-icon mode.
  if noctalia.getConfig("bar_show_reset") == true and metric.reset ~= "" then
    nodes[#nodes + 1] = ui.label({ text = "↻ " .. shared.resetText(metric.reset, true), fontSize = stacked and 8 or 10, color = "on_surface_variant", maxLines = 1 })
  end
  return nodes
end

-- metricForWindow always returns something (it falls back to card.primary),
-- so a category-only provider like Copilot -- with neither a "short" nor a
-- "weekly" metric of its own -- would otherwise show the same fallback quota
-- twice stacked on itself. De-duplicate down to the single row that leaves.
local function windowMetrics(card)
  local short = shared.metricForWindow(card, "short")
  local weekly = shared.metricForWindow(card, "weekly")
  local metrics = { short }
  if weekly ~= short then metrics[#metrics + 1] = weekly end
  return metrics
end

local function segment(card)
  local mode = shared.config("bar_display_mode", "detailed")
  local window = shared.config("bar_metric_window", "short")
  local metrics = window == "both" and windowMetrics(card) or { shared.metricForWindow(card, window) or card.primary }
  local iconSize = tonumber(shared.config("bar_icon_size", 16)) or 16
  local children = {
    providerIcon(card, iconSize, shared.colorFor(metrics[1].used)),
  }
  if mode == "icon" then return ui.row({ align = "center" }, children) end
  if noctalia.getConfig("bar_show_name") == true then
    children[#children + 1] = ui.label({ text = card.label, fontSize = 11, fontWeight = "semibold", maxLines = 1 })
  end
  local gap = tonumber(shared.config("bar_spacing", 6)) or 6
  if #metrics > 1 then
    local rows = {}
    for _, metric in ipairs(metrics) do
      rows[#rows + 1] = ui.row({ align = "center", gap = gap }, metricNodes(metric, true))
    end
    -- Text (value/reset) makes each row noticeably taller than a bare
    -- progress bar, so the column needs less of its own gap to stay inside
    -- the same total height budget the bar-height-derived fix above assumes.
    local textShown = noctalia.getConfig("bar_show_value") == true or noctalia.getConfig("bar_show_reset") == true
    children[#children + 1] = ui.column({ gap = textShown and 1 or 4, justify = "center" }, rows)
  else
    for _, node in ipairs(metricNodes(metrics[1], false)) do children[#children + 1] = node end
  end
  return ui.row({ align = "center", gap = gap }, children)
end

-- Every discovered account, whatever the bar itself is showing: the tooltip is
-- the "everything at a glance" view, so it deliberately ignores
-- bar_card_filter, bar_metric_limit and bar_metric_window. One quota per
-- line, each kept short ("Weekly 21%") — the tooltip ellipsizes wide values,
-- so reset times stay in the panel.
--
-- Only the headline quotas make it in: an account's own session/weekly windows,
-- never Gemini's 3P side quotas or Copilot's per-category counters. Providers
-- that expose no time window at all (Copilot) fall back to their primary quota
-- so the account still shows a number instead of an empty row.
local function tooltip(cards)
  local rows = {}
  for _, card in ipairs(cards) do
    local values = {}
    for _, metric in ipairs(card.metrics) do
      if shared.isHeadline(metric) then values[#values + 1] = metricText(metric) end
    end
    if #values == 0 and card.primary then values[#values + 1] = metricText(card.primary) end
    rows[#rows + 1] = { key = card.label, value = table.concat(values, "\n") }
  end
  if #rows == 0 then rows[#rows + 1] = { key = "AI usage", value = "Waiting for Home Assistant data" } end
  if errorMessage ~= "" then rows[#rows + 1] = { key = "Status", value = errorMessage } end
  return rows
end

local function render()
  local cards = selectedCards()
  local children = {}
  for _, card in ipairs(cards) do
    children[#children + 1] = segment(card)
  end
  if #children == 0 then
    children[#children + 1] = ui.glyph({ name = "chart-donut-3", size = tonumber(shared.config("bar_icon_size", 16)) or 16, color = "on_surface_variant" })
  end
  if errorMessage ~= "" then children[#children + 1] = ui.glyph({ name = "alert-circle", size = 12, color = "error" }) end
  local gap = tonumber(shared.config("bar_spacing", 6)) or 6
  barWidget.render(ui.row({ align = "center", gap = gap * 2 }, children))
  barWidget.setTooltip(tooltip(shared.cards(items)))
end

noctalia.state.watch("ha_ai_usage.items", function(value)
  items = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha_ai_usage.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)

function update()
  noctalia.setUpdateInterval(2000)
  render()
end

function onConfigChanged()
  render()
end

render()
