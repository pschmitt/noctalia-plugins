--!nonstrict
-- iPhone Duo parametric SVG generator:
-- Draws a circular status badge with an outer battery arc, a center Wi-Fi glyph,
-- and 4 signal dots curved along the bottom opening.

local M = {}

local CACHE_KEY = "@cacheKey@"
if CACHE_KEY:find("@") then
  CACHE_KEY = "v3"
end
local SIZE = 64
local CENTER = SIZE / 2
local RADIUS = 24
local STROKE_W = 5.6
local CIRCUMFERENCE = 2 * math.pi * RADIUS
local ARC_SPAN_DEG = 255
local GAP_DEG = 360 - ARC_SPAN_DEG
local ARC_LENGTH = (ARC_SPAN_DEG / 360.0) * CIRCUMFERENCE
local START_ANGLE = 90 + GAP_DEG / 2.0

-- 4 signal dots spaced across the bottom gap (centered around 90 deg)
local DOT_ANGLES = { 126, 102, 78, 54 }
local DOT_RADIUS = 3.0

local function sanitizeColor(hex)
  if type(hex) ~= "string" or hex == "" then return "currentColor" end
  return hex
end

local function generateSvg(batteryPct, signalPct, charging, powerSaver, netType, colors)
  local fgNormal = colors.normal or "#E2E8F0"
  local trackColor = "rgba(226, 232, 240, 0.22)"
  local bgColor = "#16161E"

  local batteryColor = fgNormal
  if charging then
    batteryColor = colors.charging or "#34C759"
  elseif powerSaver then
    batteryColor = colors.powerSaver or "#FFCC00"
  elseif batteryPct <= (colors.criticalThreshold or 10) then
    batteryColor = colors.critical or "#FF3B30"
  elseif batteryPct <= (colors.lowThreshold or 20) then
    batteryColor = colors.powerSaver or "#FFCC00"
  end

  local fillFraction = math.clamp(batteryPct / 100.0, 0.0, 1.0)
  local fillLength = math.max(0.1, fillFraction * ARC_LENGTH)

  -- 4 signal dots
  local dotsActive = 0
  if netType == "wifi" then
    if signalPct > 75 then
      dotsActive = 4
    elseif signalPct > 50 then
      dotsActive = 3
    elseif signalPct > 25 then
      dotsActive = 2
    elseif signalPct > 0 then
      dotsActive = 1
    end
  elseif netType == "ethernet" then
    dotsActive = 4
  end

  local dotsParts = {}
  for i, deg in ipairs(DOT_ANGLES) do
    local rad = math.rad(deg)
    local cx = CENTER + RADIUS * math.cos(rad)
    local cy = CENTER + RADIUS * math.sin(rad)
    local isDotActive = (i <= dotsActive)
    local dotColor = isDotActive and fgNormal or trackColor
    dotsParts[#dotsParts + 1] = string.format(
      '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" />',
      cx, cy, DOT_RADIUS, dotColor
    )
  end

  -- Center connectivity glyph
  local rInner = 6.8
  local rOuter = 13.0
  local swInner = 3.2
  local swOuter = 3.4
  local wedgeR = 2.8
  -- Focal point so that vertical midpoint of the glyph is optically and
  -- geometrically centered at CENTER (32.0).
  local fy = CENTER + (rOuter + swOuter / 2.0 - 1.2) / 2.0

  local dx1 = rInner * 0.7071
  local dy1 = -rInner * 0.7071
  local innerArc = string.format("M %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f",
    CENTER - dx1, fy + dy1, rInner, rInner, CENTER + dx1, fy + dy1)

  local dx2 = rOuter * 0.7071
  local dy2 = -rOuter * 0.7071
  local outerArc = string.format("M %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f",
    CENTER - dx2, fy + dy2, rOuter, rOuter, CENTER + dx2, fy + dy2)

  local wx = wedgeR * 0.7071
  local wy = -wedgeR * 0.7071
  local wedge = string.format("M %.2f %.2f L %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f Z",
    CENTER, fy + 1.2, CENTER - wx, fy + wy, wedgeR, wedgeR, CENTER + wx, fy + wy)

  local centerGlyph
  if netType == "ethernet" then
    centerGlyph = string.format([[
    <g transform="translate(32, 32)" stroke="%s" stroke-linecap="round" stroke-linejoin="round" fill="none">
      <rect x="-6" y="-5.5" width="12" height="9" rx="2" stroke-width="2.2" />
      <path d="M -3 3.5 L -3 6.5 M 3 3.5 L 3 6.5 M -6 6.5 L 6 6.5" stroke-width="2.0" />
    </g>]], fgNormal)
  elseif netType == "disconnected" or netType == "none" then
    centerGlyph = string.format([[
    <g stroke="%s" stroke-linecap="round" fill="none">
      <path d="%s" fill="%s" stroke="none" opacity="0.35" />
      <path d="%s" stroke-width="%.1f" opacity="0.35" />
      <path d="%s" stroke-width="%.1f" opacity="0.35" />
      <path d="M 23 23 L 41 41" stroke="#FF3B30" stroke-width="2.6" />
    </g>]], trackColor, wedge, trackColor, innerArc, swInner, outerArc, swOuter)
  else
    -- iPhone Duo 2-wave Wi-Fi + base wedge
    centerGlyph = string.format([[
    <g stroke="%s" stroke-linecap="round" fill="none">
      <path d="%s" fill="%s" stroke="none" />
      <path d="%s" stroke-width="%.1f" />
      <path d="%s" stroke-width="%.1f" />
    </g>]], fgNormal, wedge, fgNormal, innerArc, swInner, outerArc, swOuter)
  end

  -- Charging lightning badge
  local boltGlyph = ""
  if charging then
    boltGlyph = string.format([[
    <g transform="translate(44, 11)" fill="%s" stroke="%s" stroke-width="1.0">
      <path d="M 2.5 -5 L -2 0.5 L 0.5 0.8 L -2 5 L 3.5 -0.5 L 1 -0.8 Z" />
    </g>]], colors.charging or "#34C759", bgColor)
  end

  return string.format([[<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">
  <!-- Battery Background Track -->
  <circle cx="%d" cy="%d" r="%d" fill="none"
          stroke="%s" stroke-width="%.1f"
          stroke-linecap="round"
          stroke-dasharray="%.2f %.2f"
          transform="rotate(%.1f %d %d)" />

  <!-- Battery Progress Fill -->
  <circle cx="%d" cy="%d" r="%d" fill="none"
          stroke="%s" stroke-width="%.1f"
          stroke-linecap="round"
          stroke-dasharray="%.2f %.2f"
          transform="rotate(%.1f %d %d)" />

  <!-- Signal Dots -->
  %s

  <!-- Center Connectivity Glyph -->
  %s

  <!-- Charging Badge -->
  %s
</svg>]],
    SIZE, SIZE, SIZE, SIZE,
    CENTER, CENTER, RADIUS, trackColor, STROKE_W, ARC_LENGTH, CIRCUMFERENCE, START_ANGLE, CENTER, CENTER,
    CENTER, CENTER, RADIUS, batteryColor, STROKE_W, fillLength, CIRCUMFERENCE, START_ANGLE, CENTER, CENTER,
    table.concat(dotsParts, "\n  "),
    centerGlyph,
    boltGlyph
  )
end

function M.ensure(batteryPct, signalPct, charging, powerSaver, netType, colors)
  local dataDir = noctalia.pluginDataDir()
  if not dataDir or dataDir == "" then return "" end

  local bBucket = math.floor(math.clamp(batteryPct or 0, 0, 100) / 2) * 2
  local sBucket = math.floor(math.clamp(signalPct or 0, 0, 100) / 10) * 10
  local cTag = charging and "c1" or "c0"
  local pTag = powerSaver and "p1" or "p0"
  local nTag = netType or "wifi"

  local filename = string.format("duo-%s-%d-%d-%s-%s-%s.svg", CACHE_KEY, bBucket, sBucket, cTag, pTag, nTag)
  local filePath = dataDir .. "/" .. filename

  if noctalia.fileExists(filePath) then
    return filePath
  end

  local svgCode = generateSvg(bBucket, sBucket, charging, powerSaver, nTag, colors)
  noctalia.writeFile(filePath, svgCode)
  return filePath
end

function M.prune()
  local dataDir = noctalia.pluginDataDir()
  if not dataDir or dataDir == "" then return end
  local cmd = "@find@ '" .. dataDir .. "' -maxdepth 1 -type f -name 'duo-*.svg' "
    .. "-not -name 'duo-" .. CACHE_KEY .. "-*' -delete"
  if cmd:find("@find@") then return end
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 and result.stderr ~= "" then
      noctalia.log("duo-status: cache prune failed: " .. result.stderr)
    end
  end)
end

return M
