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

local function segment(card)
  local mode = shared.config("display_mode", "summary")
  local metric = shared.metricForWindow(card, shared.config("metric_window", "short")) or card.primary
  local iconSize = tonumber(shared.config("icon_size", 16)) or 16
  local children = {
    providerIcon(card, iconSize, shared.colorFor(metric.used)),
  }
  if mode == "icon" then return ui.row({ align = "center" }, children) end
  if noctalia.getConfig("show_name") == true then
    children[#children + 1] = ui.label({ text = card.label, fontSize = 11, fontWeight = "semibold", maxLines = 1 })
  end
  if noctalia.getConfig("show_progress") ~= false and metric.used ~= nil then
    children[#children + 1] = ui.progress({
      progress = metric.used / 100,
      fill = shared.colorFor(metric.used),
      track = "on_surface/0.16",
      width = tonumber(shared.config("progress_width", 26)) or 26,
      height = tonumber(shared.config("progress_height", 5)) or 5,
      radius = 6,
    })
  end
  if noctalia.getConfig("show_value") == true then
    children[#children + 1] = ui.label({
      text = metricText(metric),
      fontSize = 11,
      fontWeight = "semibold",
      color = shared.colorFor(metric.used),
      maxLines = 1,
    })
  end
  if mode == "detailed" and noctalia.getConfig("show_reset") == true and metric.reset ~= "" then
    children[#children + 1] = ui.label({ text = "↻ " .. shared.resetText(metric.reset), fontSize = 10, color = "on_surface_variant", maxLines = 1 })
  end
  return ui.row({ align = "center", gap = tonumber(shared.config("spacing", 6)) or 6 }, children)
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
