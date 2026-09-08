--!nonstrict

local shared = require("./shared.luau")
local items = noctalia.state.get("ha_ai_usage.items") or {}
local errorMessage = noctalia.state.get("ha_ai_usage.error") or ""

local function providerIcon(card, size, color)
  if card.image then return ui.image({ path = card.image, width = size, height = size, fit = "contain" }) end
  return ui.glyph({ name = card.glyph, size = size, color = color })
end

local function selectedCards()
  local limit = math.max(1, math.min(20, tonumber(shared.config("metric_limit", 3)) or 3))
  local cards = shared.filterCards(shared.cards(items), shared.config("card_filter", ""))
  return shared.selectWindow(cards, shared.config("metric_window", "short"), limit)
end

local function metricText(metric)
  return (metric.label or "Usage") .. " " .. shared.displayPercent(
    metric.used,
    noctalia.getConfig("show_remaining") == true
  )
end

-- The progress bar, value and reset label for one metric -- everything
-- segment() puts beside the icon/name, minus the row wrapper, so the "both"
-- window can stack two of these in a column instead of laying them out flat.
local function metricNodes(metric)
  local nodes = {}
  if noctalia.getConfig("show_progress") ~= false and metric.used ~= nil then
    nodes[#nodes + 1] = ui.progress({
      progress = metric.used / 100,
      fill = shared.colorFor(metric.used),
      track = "on_surface/0.16",
      width = tonumber(shared.config("progress_width", 26)) or 26,
      height = tonumber(shared.config("progress_height", 5)) or 5,
      radius = 6,
    })
  end
  if noctalia.getConfig("show_value") == true then
    nodes[#nodes + 1] = ui.label({
      text = metricText(metric),
      fontSize = 11,
      fontWeight = "semibold",
      color = shared.colorFor(metric.used),
      maxLines = 1,
    })
  end
  -- Unlike display_mode's docstring implies, this used to require
  -- mode == "detailed" on top of its own toggle -- the only one of the four
  -- show_* toggles gated by mode, so flipping it while in summary mode (the
  -- plugin's own default) silently did nothing. Dropped for consistency with
  -- show_name/show_progress/show_value, which only ever check their own
  -- toggle plus the icon-mode bail-out above.
  if noctalia.getConfig("show_reset") == true and metric.reset ~= "" then
    nodes[#nodes + 1] = ui.label({ text = "↻ " .. shared.resetText(metric.reset, true), fontSize = 10, color = "on_surface_variant", maxLines = 1 })
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
  local mode = shared.config("display_mode", "summary")
  local window = shared.config("metric_window", "short")
  local metrics = window == "both" and windowMetrics(card) or { shared.metricForWindow(card, window) or card.primary }
  local iconSize = tonumber(shared.config("icon_size", 16)) or 16
  local children = {
    providerIcon(card, iconSize, shared.colorFor(metrics[1].used)),
  }
  if mode == "icon" then return ui.row({ align = "center" }, children) end
  if noctalia.getConfig("show_name") == true then
    children[#children + 1] = ui.label({ text = card.label, fontSize = 11, fontWeight = "semibold", maxLines = 1 })
  end
  local gap = tonumber(shared.config("spacing", 6)) or 6
  if #metrics > 1 then
    local rows = {}
    for _, metric in ipairs(metrics) do
      rows[#rows + 1] = ui.row({ align = "center", gap = gap }, metricNodes(metric))
    end
    children[#children + 1] = ui.column({ gap = 4, justify = "center" }, rows)
  else
    for _, node in ipairs(metricNodes(metrics[1])) do children[#children + 1] = node end
  end
  return ui.row({ align = "center", gap = gap }, children)
end

-- Every discovered account, whatever the bar itself is showing: the tooltip is
-- the "everything at a glance" view, so it deliberately ignores card_filter,
-- metric_limit and metric_window. One quota per line, each kept short ("Weekly
-- 21%") — the tooltip ellipsizes wide values, so reset times stay in the panel.
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
    children[#children + 1] = ui.glyph({ name = "chart-donut-3", size = tonumber(shared.config("icon_size", 16)) or 16, color = "on_surface_variant" })
  end
  if errorMessage ~= "" then children[#children + 1] = ui.glyph({ name = "alert-circle", size = 12, color = "error" }) end
  local gap = tonumber(shared.config("spacing", 6)) or 6
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
