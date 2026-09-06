--!nonstrict

local M = {}

local INVALID_STATES = { unknown = true, unavailable = true, none = true, [""] = true }

function M.trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

function M.config(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then return fallback end
  return value
end

function M.number(value)
  local result = tonumber(value)
  return result and math.max(0, math.min(100, result)) or nil
end

function M.validState(value)
  return value ~= nil and not INVALID_STATES[M.trim(value):lower()]
end

function M.displayPercent(used, remaining)
  if used == nil then return "—" end
  local value = remaining and (100 - used) or used
  return string.format("%d%%", math.floor(value + 0.5))
end

function M.colorFor(used)
  if used == nil then return "on_surface_variant" end
  local critical = tonumber(M.config("critical_threshold", 90)) or 90
  local warning = tonumber(M.config("warning_threshold", 75)) or 75
  if used >= critical then return M.config("critical_color", "error") end
  if used >= warning then return M.config("warning_color", "tertiary") end
  return M.config("normal_color", "primary")
end

local function contains(value, fragment)
  return value:lower():find(fragment:lower(), 1, true) ~= nil
end

local PROVIDERS = {
  claude = { label = "Claude", image = "assets/claude-code.svg", order = 1 },
  codex = { label = "Codex", glyph = "brand-openai", order = 2 },
  copilot = { label = "GitHub Copilot", glyph = "brand-github-copilot", order = 3 },
  gemini = { label = "Gemini", image = "assets/google-antigravity.svg", order = 4 },
}

local function cardDetails(item)
  local integration = M.trim(item.integration)
  local provider = PROVIDERS[integration] or { label = integration, glyph = "chart-donut-3", order = 99 }
  local source = M.trim(item.name)
  local label = provider.label
  if integration == "claude" then
    local account = source:match("%((.-)%)") or ""
    account = account:gsub("^Philipp%s*%-%s*", "")
    account = account:gsub("^Philipp Schmitt%s*", "")
    if account ~= "" then label ..= " · " .. account end
  end
  return integration .. ":" .. label, label, provider.glyph, provider.image, provider.order
end

local function metricDetails(item)
  local entity = M.trim(item.entity_id)
  local source = M.trim(item.name)
  local window = "other"
  local label = "Usage"
  if entity:find("_session_usage$", 1, false) or entity:find("_5h_used$", 1, false) then
    window = "short"
    label = entity:find("_5h_used$", 1, false) and "5h" or "Session"
  -- Each integration spells its weekly entity differently: Claude uses
  -- _week_usage, Codex _weekly_used, Gemini _weekly_usage. Missing one here
  -- silently demotes it to the "other" bucket, where the weekly bar mode can
  -- no longer find it.
  elseif entity:find("_week_usage$", 1, false) or entity:find("_weekly_used$", 1, false) or entity:find("_weekly_usage$", 1, false) then
    window = "weekly"
    label = "Weekly"
  elseif contains(source, "premium") then
    label = "Premium"
  elseif contains(source, "completion") then
    label = "Completions"
  elseif contains(source, "chat") then
    label = "Chat"
  end
  -- Gemini's third-party model quotas share the account card with its own
  -- models; flag them so they sort after (and never become) the card's primary
  -- metric, which is what the bar renders.
  local secondary = M.trim(item.integration) == "gemini" and contains(source, "3p models")
  if secondary then
    label = "3P " .. label
  end
  return window, label, secondary
end

local function metricOrder(metric)
  local penalty = metric.secondary and 10 or 0
  if metric.window == "short" then return 1 + penalty end
  if metric.window == "weekly" then return 2 + penalty end
  if metric.label == "Premium" then return 3 + penalty end
  if metric.label == "Chat" then return 4 + penalty end
  if metric.label == "Completions" then return 5 + penalty end
  return 99 + penalty
end

function M.metricReset(item)
  for _, key in ipairs({ "reset_time", "resets_at", "quota_reset_date_utc" }) do
    local value = M.trim(item[key])
    if M.validState(value) then return value end
  end
  if item.entity_id:find("_weekly_used$", 1, false) then return M.trim(item.secondary_reset_time) end
  if item.entity_id:find("_5h_used$", 1, false) then return M.trim(item.primary_reset_time) end
  return M.trim(item.primary_reset_time)
end

function M.cards(items)
  local byId = {}
  for _, item in ipairs(items) do
    local entity = M.trim(item.entity_id)
    local used = M.number(item.state)
    if entity ~= "" and used ~= nil then
      local id, label, glyph, image, order = cardDetails(item)
      local card = byId[id]
      if not card then
        card = { id = id, label = label, glyph = glyph, image = image, order = order, metrics = {} }
        byId[id] = card
      end
      local window, metricLabel, secondary = metricDetails(item)
      card.metrics[#card.metrics + 1] = {
        entity = entity,
        label = metricLabel,
        window = window,
        secondary = secondary,
        used = used,
        reset = M.metricReset(item),
        available = true,
      }
    end
  end
  local cards = {}
  for _, card in pairs(byId) do
    table.sort(card.metrics, function(a, b)
      if metricOrder(a) == metricOrder(b) then return a.label < b.label end
      return metricOrder(a) < metricOrder(b)
    end)
    card.primary = card.metrics[1]
    cards[#cards + 1] = card
  end
  table.sort(cards, function(a, b)
    if a.order == b.order then return a.label < b.label end
    return a.order < b.order
  end)
  return cards
end

function M.select(cards, limit)
  local selected = {}
  for _, card in ipairs(cards) do
    selected[#selected + 1] = card
    if #selected >= limit then break end
  end
  return selected
end

function M.filterCards(cards, filter)
  local terms = {}
  for term in tostring(filter or ""):gmatch("[^,]+") do
    term = M.trim(term):lower()
    if term ~= "" then terms[#terms + 1] = term end
  end
  if #terms == 0 then return cards end
  local filtered = {}
  for _, card in ipairs(cards) do
    local value = (card.label .. " " .. card.id):lower()
    for _, term in ipairs(terms) do
      if value:find(term, 1, true) then
        filtered[#filtered + 1] = card
        break
      end
    end
  end
  return filtered
end

function M.metricWindow(card)
  return card.primary and card.primary.window or "other"
end

function M.metricForWindow(card, window)
  if window == "all" then return card.primary end
  for _, metric in ipairs(card.metrics or {}) do
    if metric.window == window then return metric end
  end
  -- Providers such as Copilot expose quota categories rather than paired
  -- time windows. Keep their representative quota visible in either view.
  return card.primary
end

function M.selectWindow(cards, window, limit)
  local selected = {}
  for _, card in ipairs(cards) do
    if M.metricForWindow(card, window) then
      selected[#selected + 1] = card
      if #selected >= limit then break end
    end
  end
  return selected
end

local function timestamp(value)
  local year, month, day, hour, minute, second, zone = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
  if not year then return nil end
  local localEpoch = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second) })
  if not localEpoch then return nil end
  local sign, zoneHour, zoneMinute = zone:match("^([+-])(%d%d):(%d%d)$")
  if sign then
    local offset = (tonumber(zoneHour) * 3600) + (tonumber(zoneMinute) * 60)
    if sign == "-" then offset = -offset end
    local utcAsLocal = os.time(os.date("!*t", localEpoch))
    return localEpoch - (utcAsLocal - localEpoch) - offset
  end
  if zone == "Z" then
    local utcAsLocal = os.time(os.date("!*t", localEpoch))
    return localEpoch - (utcAsLocal - localEpoch)
  end
  return localEpoch
end

function M.resetText(value)
  if not M.validState(value) then return "—" end
  local epoch = timestamp(value)
  if not epoch then return value end
  local format = M.config("reset_time_format", "relative")
  if format == "local_short" then return os.date("%a %H:%M", epoch) end
  if format == "local_long" then return os.date("%a, %d %b %Y %H:%M", epoch) end
  if format == "iso" then return os.date("%Y-%m-%d %H:%M", epoch) end
  local seconds = math.floor(os.difftime(epoch, os.time()))
  if seconds <= 0 then return "now" end
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  if days > 0 then return string.format("in %dd %dh", days, hours) end
  if hours > 0 then return string.format("in %dh %dm", hours, minutes) end
  return string.format("in %dm", math.max(1, minutes))
end

return M
