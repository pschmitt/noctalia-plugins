--!nonstrict
-- iPhone Duo parametric SVG generator:
-- Draws a circular status badge with an outer battery arc, a center Wi-Fi glyph,
-- and 4 signal dots curved along the bottom opening.

local M = {}

local CACHE_KEY = "@cacheKey@"
local SIZE = 64
local CENTER = SIZE / 2
local RADIUS = 24
local STROKE_W = 4.2
local CIRCUMFERENCE = 2 * math.pi * RADIUS
local ARC_SPAN_DEG = 265
local GAP_DEG = 360 - ARC_SPAN_DEG
local ARC_LENGTH = (ARC_SPAN_DEG / 360.0) * CIRCUMFERENCE
local START_ANGLE = 90 + GAP_DEG / 2.0

-- 4 signal dots spaced across the bottom gap (centered around 90 deg)
local DOT_ANGLES = { 124, 101, 79, 56 }
local DOT_RADIUS = 2.4

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

  -- Center glyph
  local centerGlyph
  if netType == "ethernet" then
    centerGlyph = string.format([[
    <g transform="translate(32, 29)" stroke="%s" stroke-linecap="round" stroke-linejoin="round" fill="none">
      <rect x="-6" y="-6" width="12" height="10" rx="2" stroke-width="2.2" />
      <path d="M -3 4 L -3 7 M 3 4 L 3 7 M -6 7 L 6 7" stroke-width="2.0" />
    </g>]], fgNormal)
  elseif netType == "disconnected" or netType == "none" then
    centerGlyph = string.format([[
    <g transform="translate(32, 29)" stroke="%s" stroke-linecap="round" fill="none">
      <circle cx="0" cy="5.2" r="1.4" fill="%s" stroke="none" />
      <path d="M -4 1.5 A 5.5 5.5 0 0 1 4 1.5" stroke-width="2.2" stroke-opacity="0.3" />
      <path d="M -7.5 -2.2 A 10.5 10.5 0 0 1 7.5 -2.2" stroke-width="2.4" stroke-opacity="0.3" />
      <path d="M -11 -6 A 15.5 15.5 0 0 1 11 -6" stroke-width="2.6" stroke-opacity="0.3" />
      <path d="M -8 -8 L 8 8" stroke="#FF3B30" stroke-width="2.4" />
    </g>]], trackColor, trackColor)
  else
    -- Standard 3-wave Wi-Fi
    centerGlyph = string.format([[
    <g transform="translate(32, 29)" stroke="%s" stroke-linecap="round" fill="none">
      <circle cx="0" cy="5.2" r="1.4" fill="%s" stroke="none" />
      <path d="M -4 1.5 A 5.5 5.5 0 0 1 4 1.5" stroke-width="2.2" />
      <path d="M -7.5 -2.2 A 10.5 10.5 0 0 1 7.5 -2.2" stroke-width="2.4" />
      <path d="M -11 -6 A 15.5 15.5 0 0 1 11 -6" stroke-width="2.6" />
    </g>]], fgNormal, fgNormal)
  end

  -- Charging lightning badge
  local boltGlyph = ""
  if charging then
    boltGlyph = string.format([[
    <g transform="translate(44, 12)" fill="%s" stroke="%s" stroke-width="1.2">
      <path d="M 3 -6 L -2.5 0.5 L 0.5 1 L -2.5 6 L 4 -0.5 L 1 -1 Z" />
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
