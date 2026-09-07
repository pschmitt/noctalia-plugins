--!nonstrict

local shared = require("./shared.luau")
local items = noctalia.state.get("ha_ai_usage.items") or {}
local errorMessage = noctalia.state.get("ha_ai_usage.error") or ""
local panelOpen = false
local render -- forward-declared: the ring renderer below re-triggers it once a PNG finishes

local function providerIcon(card, size, color)
  if card.image then return ui.image({ path = card.image, width = size, height = size, fit = "contain" }) end
  return ui.glyph({ name = card.glyph, size = size, color = color })
end

-- Home Assistant only gives us each window's reset target, never when it
-- started, so the ring's sweep is an approximation: remaining-time fraction
-- of the fixed cadence every supported integration's session/weekly windows
-- actually run on (see shared.windowSeconds), not a measured elapsed time.
-- Noctalia's Luau UI has no native circular/donut progress control (only
-- ui.progress, a linear bar), so the ring itself is a PNG rendered on demand
-- with ImageMagick and cached by pluginDataDir()+geometry+fraction
-- bucket+color -- the same technique pschmitt/battery-icon uses for its
-- rendered bitmap. Geometry is part of the cache key specifically so a
-- stroke-width tweak like this one doesn't silently keep serving PNGs
-- rendered with the old radii.
local RING_SIZE = 88
local RING_CENTER = RING_SIZE / 2
local RING_OUTER_R = 39
local RING_INNER_R = 21
local RING_BUCKETS = 50 -- 2%-wide steps: enough to look smooth, few enough files to cache
-- Substituted with this build's output hash (see pkgs/noctalia-ha-ai-usage):
-- it namespaces the on-disk PNGs so a new plugin build never serves rings
-- drawn by the previous one, whatever changed -- radii, caps or colours.
local RING_CACHE_KEY = "@cacheKey@"
local RING_MID_R = (RING_OUTER_R + RING_INNER_R) / 2
local RING_CAP_R = (RING_OUTER_R - RING_INNER_R) / 2 -- a cap is exactly as wide as the stroke

local pendingRings = {}

-- Drop every generation but this build's, once, when the panel script loads.
-- Nothing else prunes this directory, so without it each plugin version
-- leaves its rings behind forever.
local function pruneRingCache()
  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then return end
  local cmd = "@find@ '" .. dataDir .. "' -maxdepth 1 -type f -name 'ring-*.png' "
    .. "-not -name 'ring-" .. RING_CACHE_KEY .. "-*' -delete"
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("ha-ai-usage: ring cache prune failed: " .. shared.trim(result.stderr))
    end
  end, 5000)
end

pruneRingCache()

local function sanitizeColor(hex) return (hex:gsub("#", "")) end

local function ringPoint(angleDeg)
  local rad = math.rad(angleDeg)
  return RING_CENTER + RING_OUTER_R * math.cos(rad), RING_CENTER + RING_OUTER_R * math.sin(rad)
end

local function midPoint(angleDeg)
  local rad = math.rad(angleDeg)
  return RING_CENTER + RING_MID_R * math.cos(rad), RING_CENTER + RING_MID_R * math.sin(rad)
end

-- A filled circle minus a smaller filled circle (DstOut) turns into a flat
-- ring; the same trick applied to a center-to-edge pie wedge instead turns
-- it into a ring-shaped arc segment. Ported from pschmitt/battery-icon's
-- body/fill compositing, which punches shapes out the same way.
local function ringLayer(fillColor, path)
  return "\\( -size "
    .. RING_SIZE .. "x" .. RING_SIZE
    .. " xc:none -fill '" .. fillColor .. "' -draw 'path \"" .. path .. "\"' "
    .. "\\( -size " .. RING_SIZE .. "x" .. RING_SIZE .. " xc:none -fill white -draw 'circle "
    .. RING_CENTER .. "," .. RING_CENTER .. " " .. RING_CENTER .. "," .. (RING_CENTER - RING_INNER_R) .. "' \\) "
    .. "-compose DstOut -composite \\) -compose Over -composite "
end

-- MVG has no stroke-linecap for a filled path, so round the arc's ends by
-- hand: a disc of half the stroke width centred on the mid-radius at each
-- end angle covers exactly the square corners the wedge leaves behind. It
-- has to composite *after* the annulus punch above -- the inner-circle
-- DstOut would otherwise bite the inner half out of each cap.
local function capCircle(x, y)
  return "circle " .. x .. "," .. y .. " " .. x .. "," .. (y - RING_CAP_R)
end

local function capLayer(fillColor, fraction)
  local startX, startY = midPoint(-90)
  local endX, endY = midPoint(-90 + fraction * 360)
  return "\\( -size "
    .. RING_SIZE .. "x" .. RING_SIZE
    .. " xc:none -fill '" .. fillColor .. "' "
    .. "-draw '" .. capCircle(startX, startY) .. "' "
    .. "-draw '" .. capCircle(endX, endY) .. "' \\) -compose Over -composite "
end

-- MVG (like SVG) can't express a full 360deg sweep as one arc command --
-- identical start/end points are degenerate -- so trace it as two clean
-- semicircle arcs (top-to-bottom, then back) instead.
local function fullRingPath()
  local topX, topY = RING_CENTER, RING_CENTER - RING_OUTER_R
  local bottomX, bottomY = RING_CENTER, RING_CENTER + RING_OUTER_R
  return "M " .. topX .. "," .. topY
    .. " A " .. RING_OUTER_R .. "," .. RING_OUTER_R .. " 0 0,1 " .. bottomX .. "," .. bottomY
    .. " A " .. RING_OUTER_R .. "," .. RING_OUTER_R .. " 0 0,1 " .. topX .. "," .. topY
    .. " Z"
end

local function arcWedgePath(fraction)
  local startX, startY = ringPoint(-90)
  local endX, endY = ringPoint(-90 + fraction * 360)
  local largeArc = fraction > 0.5 and 1 or 0
  return "M " .. RING_CENTER .. "," .. RING_CENTER
    .. " L " .. startX .. "," .. startY
    .. " A " .. RING_OUTER_R .. "," .. RING_OUTER_R .. " 0 " .. largeArc .. ",1 " .. endX .. "," .. endY
    .. " Z"
end

local function ringCommand(fraction, trackColor, fillColor, outPath)
  local cmd = "@magick@ -size " .. RING_SIZE .. "x" .. RING_SIZE .. " xc:none "
  cmd ..= ringLayer(trackColor, fullRingPath())
  if fraction > 0.004 then
    if fraction >= 0.996 then
      cmd ..= ringLayer(fillColor, fullRingPath())
    else
      cmd ..= ringLayer(fillColor, arcWedgePath(fraction))
      cmd ..= capLayer(fillColor, fraction)
    end
  end
  cmd ..= "'" .. outPath .. "'"
  return cmd
end

-- Returns the cached ring PNG's path if it is already rendered; otherwise
-- kicks off (at most one in-flight) render and returns nil for this frame --
-- the next state change once it lands calls render() again.
local function ensureRing(fraction, fillColor)
  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then return nil end
  fraction = math.clamp(fraction, 0, 1)
  local bucket = math.floor(fraction * RING_BUCKETS + 0.5)
  local trackColor = shared.resolveColor("on_surface", "#9AA0A6") .. "29" -- ~16% alpha, matches the linear progress track
  local outPath = dataDir .. "/ring-" .. RING_CACHE_KEY .. "-" .. bucket .. "-" .. sanitizeColor(fillColor) .. ".png"
  if noctalia.fileExists(outPath) then return outPath end
  if pendingRings[outPath] then return nil end
  pendingRings[outPath] = true
  noctalia.runAsync(ringCommand(bucket / RING_BUCKETS, trackColor, fillColor, outPath), function(result)
    pendingRings[outPath] = nil
    if result.exitCode == 0 then
      render()
    else
      noctalia.log("ha-ai-usage: ring render failed: " .. shared.trim(result.stderr))
    end
  end, 5000)
  return nil
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
local RING_CRITICAL_REMAINING = 0.10
local RING_WARNING_REMAINING = 0.25

local function ringColor(fraction, hasWindow)
  if not hasWindow then return "on_surface_variant" end
  if fraction <= RING_CRITICAL_REMAINING then return shared.config("ring_critical_color", "error") end
  if fraction <= RING_WARNING_REMAINING then return shared.config("ring_warning_color", "#F5A97F") end
  return shared.config("ring_normal_color", "primary")
end

local function ringVisual(metric, size)
  local remaining = shared.remainingSeconds(metric.reset)
  local windowSeconds = shared.windowSeconds(metric.window)
  local hasWindow = remaining ~= nil and windowSeconds ~= nil
  local fraction = hasWindow and (remaining / windowSeconds) or 0
  local color = ringColor(fraction, hasWindow)
  local fillColor = shared.resolveColor(color, "#9AA0A6")
  local imagePath = ensureRing(fraction, fillColor)
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
local function ringLines(metric)
  local color = shared.colorFor(metric.used)
  -- Pace sits beside the label rather than on a line of its own: it is a
  -- two-glyph aside, and a whole row per metric costs more vertical space
  -- than the panel can spare once every metric is stacked in one card.
  local heading = {
    ui.label({ text = metric.label, fontSize = 13, fontWeight = "bold", maxLines = 1 }),
  }
  if metric.pace ~= nil then
    local paceColor = shared.paceColor(metric.pace)
    heading[#heading + 1] = ui.row({ align = "center", gap = 3 }, {
      ui.glyph({ name = shared.paceGlyph(metric.pace), size = 10, color = paceColor }),
      ui.label({ text = shared.paceText(metric.pace), fontSize = 10, color = paceColor, maxLines = 1 }),
    })
  end
  local lines = {
    ui.row({ align = "center", gap = 6 }, {
      ui.row({ align = "center", gap = 6, flexGrow = 1 }, heading),
      ui.label({ text = shared.displayPercent(metric.used, false), fontSize = 13, fontWeight = "bold", color = color, maxLines = 1 }),
    }),
  }
  if metric.used ~= nil then
    lines[#lines + 1] = ui.progress({ progress = metric.used / 100, fill = color, track = "on_surface/0.16", height = 6, radius = 6 })
  end
  lines[#lines + 1] = ui.label({ text = metric.reset ~= "" and ("Reset " .. shared.resetText(metric.reset)) or "—", fontSize = 11, color = "on_surface_variant", maxLines = 1 })
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

local function ringCard(metrics)
  local rows = {}
  for _, metric in ipairs(metrics) do
    rows[#rows + 1] = ui.row({ align = "center", gap = 10 }, {
      ringSlot(metric, RING_DISPLAY_SIZE),
      ui.column({ gap = 3, flexGrow = 1 }, ringLines(metric)),
    })
  end
  return ui.column({
    gap = 8,
    fill = "surface_variant/0.4",
    radius = 12,
    padding = 10,
    flexGrow = 1,
  }, rows)
end

local function card(card)
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
    providerIcon(card, 18, shared.colorFor(card.primary.used)),
    ui.label({ text = card.label, fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
  }
  local bankedText = shared.bankedResetsText(card.bankedAvailable, card.bankedExpiry)
  if bankedText ~= nil then
    titleRow[#titleRow + 1] = ui.row({ align = "center", gap = 4 }, {
      ui.glyph({ name = "ticket", size = 11, color = "on_surface_variant" }),
      ui.label({ text = bankedText, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    })
  end
  local sections = {
    ui.row({ align = "center", gap = 8 }, titleRow),
  }
  if #headline > 0 or #rest > 0 then
    local ordered = {}
    for _, metric in ipairs(headline) do ordered[#ordered + 1] = metric end
    for _, metric in ipairs(rest) do ordered[#ordered + 1] = metric end
    sections[#sections + 1] = ringCard(ordered)
  end
  return ui.column({ fill = "surface_variant/0.58", radius = 14, padding = 12, gap = 9 }, sections)
end

function render()
  if not panelOpen then return end
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
  for _, item in ipairs(shared.cards(items)) do content[#content + 1] = card(item) end
  if #content == 0 then content[#content + 1] = ui.label({ text = "No active AI usage metrics were discovered.", color = "on_surface_variant" }) end
  local children = { header }
  if errorMessage ~= "" then
    children[#children + 1] = ui.row({ fill = "error/0.08", radius = 8, paddingH = 9, paddingV = 6, align = "center", gap = 6 }, {
      ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
      ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 1 }),
    })
  end
  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 10 }, content)
  panel.render(ui.column({ flexGrow = 1, padding = 14, gap = 10 }, children))
end

noctalia.state.watch("ha_ai_usage.items", function(value)
  items = type(value) == "table" and value or {}
  render()
end)
noctalia.state.watch("ha_ai_usage.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)
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
