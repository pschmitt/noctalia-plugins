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
-- with ImageMagick and cached by pluginDataDir()+fraction bucket+color --
-- the same technique pschmitt/battery-icon uses for its rendered bitmap.
local RING_SIZE = 88
local RING_CENTER = RING_SIZE / 2
local RING_OUTER_R = 38
local RING_INNER_R = 30
local RING_BUCKETS = 50 -- 2%-wide steps: enough to look smooth, few enough files to cache

local pendingRings = {}

local function sanitizeColor(hex) return (hex:gsub("#", "")) end

local function ringPoint(angleDeg)
  local rad = math.rad(angleDeg)
  return RING_CENTER + RING_OUTER_R * math.cos(rad), RING_CENTER + RING_OUTER_R * math.sin(rad)
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
    cmd ..= ringLayer(fillColor, fraction >= 0.996 and fullRingPath() or arcWedgePath(fraction))
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
  local outPath = dataDir .. "/ring-" .. bucket .. "-" .. sanitizeColor(fillColor) .. ".png"
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

local function ringCard(metric)
  local remaining = shared.remainingSeconds(metric.reset)
  local windowSeconds = shared.windowSeconds(metric.window)
  local fraction = (remaining ~= nil and windowSeconds ~= nil) and (remaining / windowSeconds) or 0
  local fillColor = shared.resolveColor(shared.colorFor(metric.used), "#9AA0A6")
  local imagePath = ensureRing(fraction, fillColor)
  local visual = imagePath ~= nil
    and ui.image({ path = imagePath, width = 40, height = 40, fit = "contain" })
    or ui.glyph({ name = "chart-donut-3", size = 24, color = "on_surface_variant" })
  return ui.row({
    align = "center",
    justify = "space_between",
    fill = "surface_variant/0.4",
    radius = 12,
    padding = 10,
    flexGrow = 1,
  }, {
    ui.column({ gap = 2 }, {
      ui.label({ text = metric.label .. " reset", fontSize = 13, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = metric.reset ~= "" and shared.resetText(metric.reset) or "—", fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
    visual,
  })
end

local function metricRow(metric)
  local used = metric.used
  local color = shared.colorFor(used)
  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = metric.label, fontSize = 12, color = "on_surface_variant" }),
      ui.label({ text = shared.displayPercent(used, false), fontSize = 15, fontWeight = "bold", color = color }),
    }),
  }
  if used ~= nil then
    children[#children + 1] = ui.progress({ progress = used / 100, fill = color, track = "on_surface/0.16", height = 7, radius = 7 })
  end
  if metric.reset ~= "" then
    children[#children + 1] = ui.label({ text = "Reset: " .. shared.resetText(metric.reset), fontSize = 10, color = "on_surface_variant", maxLines = 1 })
  end
  if metric.pace ~= nil then
    local paceColor = shared.paceColor(metric.pace)
    children[#children + 1] = ui.row({ align = "center", gap = 4 }, {
      ui.glyph({ name = shared.paceGlyph(metric.pace), size = 11, color = paceColor }),
      ui.label({ text = shared.paceText(metric.pace), fontSize = 10, color = paceColor, maxLines = 1 }),
    })
  end
  return ui.column({ gap = 4 }, children)
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
  local sections = {
    ui.row({ align = "center", gap = 8 }, {
      providerIcon(card, 18, shared.colorFor(card.primary.used)),
      ui.label({ text = card.label, fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
    }),
  }
  if #headline > 0 then
    local ringRow = {}
    for _, metric in ipairs(headline) do ringRow[#ringRow + 1] = ringCard(metric) end
    sections[#sections + 1] = ui.row({ gap = 8 }, ringRow)
  end
  if #rest > 0 then
    local rows = {}
    for _, metric in ipairs(rest) do rows[#rows + 1] = metricRow(metric) end
    sections[#sections + 1] = ui.column({ gap = 9 }, rows)
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
        ui.label({ text = "Home Assistant", fontSize = 11, color = "on_surface_variant" }),
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
function onSettings() noctalia.openSettings() end
function onCloseClicked() panel.close() end
