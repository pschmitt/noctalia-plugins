--!nonstrict

local ring = require("./ring.luau")
local shared = require("./shared.luau")

-- One cache generation per build; drop the others.
ring.prune()
local items = noctalia.state.get("ha_ai_usage.items") or {}
local errorMessage = noctalia.state.get("ha_ai_usage.error") or ""
local panelOpen = false

local function providerIcon(card, size, color)
  if card.image then return ui.image({ path = card.image, width = size, height = size, fit = "contain" }) end
  return ui.glyph({ name = card.glyph, size = size, color = color })
end

-- The reset-countdown ring on the left, usage percentage on the right (a
-- linear bar): the bar answers "how much is used", the ring answers "how
-- long until it's back", and neither substitutes for the other.
-- The ring tracks time, the bar tracks usage, so they answer different
-- questions and get their own colours: the ring warms up as its window runs
-- out (orange on the last quarter, red on the last tenth) regardless of how
-- much of the quota is actually spent. Same palette roles as the usage
-- colours, so a card still reads as one thing.
-- None of the shipped palettes has an orange role (Indigo's tertiary, which
-- the usage colours use for their warning band, is lavender), so the
-- mid-band default is a literal hex. All three take a palette role name or a
-- hex, same as every other colour setting here.
local function ringVisual(metric, size)
  local fraction, hasWindow = ring.fraction(metric)
  local color = ring.color(fraction, hasWindow)
  local imagePath = ring.ensure(fraction, ring.fillColor(fraction, hasWindow))
  if imagePath ~= nil then
    return ui.image({ path = imagePath, width = size, height = size, fit = "contain" })
  end
  -- Same footprint as the image it stands in for: a bare glyph is narrower,
  -- which shunts the whole text column sideways until the PNG lands.
  return ui.row({ width = size, height = size, align = "center", justify = "center" }, {
    ui.glyph({ name = "chart-donut-3", size = math.floor(size * 0.6), color = color }),
  })
end

-- Windowless metrics (Copilot's category quotas) have no countdown to draw,
-- but they belong in the same column as the rings: an empty box the width of
-- one keeps their label, bar and countdown on the same left edge.
local function ringSlot(metric, size)
  if shared.windowSeconds(metric.window) == nil then
    -- Explicitly zero-alpha: a fill-less ui.box still paints a hairline.
    return ui.box({ width = size, height = size, fill = "on_surface/0" })
  end
  return ringVisual(metric, size)
end

-- The text side of a ring card: headline, bar, reset countdown, pace.
-- Compact mode keeps all four -- pace and the reset countdown are exactly
-- the numbers worth glancing at, not chrome to shed -- and only shrinks
-- fonts/gaps and drops the absolute-reset tack-on (redundant with the
-- relative countdown right next to it) to fit more providers per screen.
local function ringLines(metric, compact)
  local color = shared.colorFor(metric.used)
  -- Pace sits beside the label rather than on a line of its own: it is a
  -- two-glyph aside, and a whole row per metric costs more vertical space
  -- than the panel can spare once every metric is stacked in one card.
  local heading = {
    ui.label({ text = metric.label, fontSize = compact and 12 or 13, fontWeight = "bold", maxLines = 1 }),
  }
  if metric.pace ~= nil then
    local paceColor = shared.paceColor(metric.pace)
    heading[#heading + 1] = ui.row({ align = "center", gap = 3 }, {
      ui.glyph({ name = shared.paceGlyph(metric.pace), size = compact and 9 or 10, color = paceColor }),
      ui.label({ text = shared.paceText(metric.pace), fontSize = compact and 9 or 10, color = paceColor, maxLines = 1 }),
    })
  end
  local lines = {
    ui.row({ align = "center", gap = 6 }, {
      ui.row({ align = "center", gap = 6, flexGrow = 1 }, heading),
      ui.label({ text = shared.displayPercent(metric.used, false), fontSize = compact and 12 or 13, fontWeight = "bold", color = color, maxLines = 1 }),
    }),
  }
  if metric.used ~= nil then
    lines[#lines + 1] = ui.progress({ progress = metric.used / 100, fill = color, track = "on_surface/0.16", height = compact and 4 or 6, radius = 6 })
  end
  -- A hover-tooltip button (ui.button, the only control that carries one)
  -- turned out to render worse than the problem it solved: no visible
  -- tooltip in practice, and the button's own hover fill/padding looked
  -- broken next to a plain label. Simplest fix -- put the absolute end time
  -- right on the line instead of hiding it behind a hover: same " · "
  -- separator the banked-resets line above already uses for a second fact
  -- tacked onto a countdown.
  local resetLine = "—"
  if metric.reset ~= "" then
    resetLine = "Reset " .. shared.resetText(metric.reset)
    -- Only worth appending when the row itself is the relative countdown;
    -- an absolute reset_time_format already shows this and would just repeat
    -- itself. Compact drops it outright even then -- it is the one line here
    -- that's a repeat of information already on the row, not new information.
    if not compact and shared.config("reset_time_format", "relative") == "relative" then
      resetLine ..= " · " .. shared.resetAbsoluteText(metric.reset)
    end
  end
  lines[#lines + 1] = ui.label({ text = resetLine, fontSize = compact and 10 or 11, color = "on_surface_variant", maxLines = 1 })
  return lines
end

-- Experiment: instead of one card per window sitting side by side (which
-- halves the width each bar gets), stack every headline window of a provider
-- in a single card -- full-width bars, one ring each. Providers differ in how
-- many headline windows they have (Copilot one, Gemini Antigravity four), so
-- this is the only renderer for them: a one-window provider must not fall
-- back to a differently-sized ring in a differently-shaped card next to a
-- two-window one.
local RING_DISPLAY_SIZE = 34
local RING_DISPLAY_SIZE_COMPACT = 22

local function ringCard(metrics, compact)
  local rows = {}
  for _, metric in ipairs(metrics) do
    rows[#rows + 1] = ui.row({ align = "center", gap = compact and 7 or 10 }, {
      ringSlot(metric, compact and RING_DISPLAY_SIZE_COMPACT or RING_DISPLAY_SIZE),
      ui.column({ gap = 3, flexGrow = 1 }, ringLines(metric, compact)),
    })
  end
  return ui.column({
    gap = compact and 5 or 8,
    fill = "surface_variant/0.4",
    radius = compact and 10 or 12,
    padding = compact and 7 or 10,
    flexGrow = 1,
  }, rows)
end

local function card(card, compact, allMetrics)
  local headline, rest = {}, {}
  for _, metric in ipairs(card.metrics) do
    if shared.isHeadline(metric) then
      headline[#headline + 1] = metric
    else
      rest[#rest + 1] = metric
    end
  end
  -- Providers with no fixed-length window (Copilot's category quotas) never
  -- produce a headline metric above, which left their card without a ring
  -- entirely. Promote the card's primary metric into one ring so every card
  -- gets at least one, same as Claude/Codex/Gemini.
  if #headline == 0 and card.primary ~= nil and card.primary.reset ~= "" then
    headline[#headline + 1] = card.primary
    for i, metric in ipairs(rest) do
      if metric == card.primary then
        table.remove(rest, i)
        break
      end
    end
  end
  local titleRow = {
    providerIcon(card, compact and 14 or 18, shared.colorFor(card.primary.used)),
    ui.label({ text = card.label, fontSize = compact and 13 or 15, fontWeight = "bold", flexGrow = 1 }),
  }
  local bankedText = shared.bankedResetsText(card.bankedAvailable, card.bankedExpiry)
  if bankedText ~= nil and not compact then
    titleRow[#titleRow + 1] = ui.row({ align = "center", gap = 4 }, {
      ui.glyph({ name = "ticket", size = 11, color = "on_surface_variant" }),
      ui.label({ text = bankedText, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    })
  end
  local sections = {
    ui.row({ align = "center", gap = compact and 6 or 8 }, titleRow),
  }
  -- `rest` is exactly the metrics with no fixed-length window of their own
  -- (Copilot's Chat/Completions once Premium is promoted above, Gemini's 3P
  -- session/weekly): the ones panel_all_metrics=false hides, keeping only
  -- each card's headline windows (or its promoted primary for Copilot).
  if #headline > 0 or (allMetrics and #rest > 0) then
    local ordered = {}
    for _, metric in ipairs(headline) do ordered[#ordered + 1] = metric end
    if allMetrics then
      for _, metric in ipairs(rest) do ordered[#ordered + 1] = metric end
    end
    sections[#sections + 1] = ringCard(ordered, compact)
  end
  return ui.column({
    fill = "surface_variant/0.58",
    radius = compact and 11 or 14,
    padding = compact and 8 or 12,
    gap = compact and 6 or 9,
  }, sections)
end

local function render()
  if not panelOpen then return end
  local compact = noctalia.getConfig("compact_panel") == true
  local allMetrics = noctalia.getConfig("panel_all_metrics") ~= false
  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.row({ align = "center", justify = "center", width = 36, height = 36, fill = "primary/0.15", radius = 11 }, {
        ui.glyph({ name = "chart-donut-3", size = 19, color = "primary" }),
      }),
      ui.column({ gap = 1 }, {
        ui.label({ text = "AI usage", fontSize = 17, fontWeight = "bold" }),
        ui.row({ align = "center", gap = 4 }, {
          ui.label({ text = "Home Assistant", fontSize = 11, color = "on_surface_variant" }),
          ui.button({
            glyph = "external-link",
            variant = "ghost",
            width = 18,
            height = 18,
            glyphSize = 11,
            tooltip = "Open in Home Assistant",
            onClick = "onOpenHa",
          }),
        }),
      }),
    }),
    ui.row({ align = "center", gap = 2 }, {
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Refresh now", onClick = "onRefresh" }),
      ui.button({ glyph = "settings", variant = "ghost", tooltip = "Plugin settings", onClick = "onSettings" }),
      ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = "onCloseClicked" }),
    }),
  })
  local content = {}
  for _, item in ipairs(shared.cards(items)) do content[#content + 1] = card(item, compact, allMetrics) end
  if #content == 0 then content[#content + 1] = ui.label({ text = "No active AI usage metrics were discovered.", color = "on_surface_variant" }) end
  local children = { header }
  if errorMessage ~= "" then
    children[#children + 1] = ui.row({ fill = "error/0.08", radius = 8, paddingH = 9, paddingV = 6, align = "center", gap = 6 }, {
      ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
      ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 1 }),
    })
  end
  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = compact and 6 or 10 }, content)
  panel.render(ui.column({ flexGrow = 1, padding = compact and 10 or 14, gap = compact and 6 or 10 }, children))
end

noctalia.state.watch("ha_ai_usage.items", function(value)
  items = type(value) == "table" and value or {}
  render()
end)
noctalia.state.watch("ha_ai_usage.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)
function onConfigChanged() render() end
function onOpen()
  panelOpen = true
  noctalia.state.set("ha_ai_usage.command", { action = "refresh" })
  render()
end
function onClose() panelOpen = false end
function onRefresh() noctalia.state.set("ha_ai_usage.command", { action = "refresh" }) end
function onOpenHa() noctalia.state.set("ha_ai_usage.command", { action = "open_dashboard" }) end
function onSettings() noctalia.openSettings() end
function onCloseClicked() panel.close() end
