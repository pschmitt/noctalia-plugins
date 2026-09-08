--!nonstrict
-- The reset-countdown ring: an SVG, written to the plugin's data dir and
-- handed to ui.image as a path.
--
-- It used to be a PNG drawn by ImageMagick, which was the wrong shape for the
-- problem twice over. A ring is parametric — two stroked circles and a dash
-- offset — so rasterising it needed a fair amount of MVG trickery (a filled
-- wedge, an inner circle punched out with DstOut, two hand-placed discs to
-- fake round caps) to express what `stroke-linecap="round"` says in a word.
-- And it needed a subprocess, which is asynchronous: the panel asked for a
-- ring, got nothing for this frame, and drew a placeholder glyph while
-- ImageMagick ran. Since a ring is cached per (build, fraction bucket,
-- colour) and the fraction is remaining/window, the file a row needs drifts
-- with time — every ~6 minutes for a 5h window — so a panel opened and
-- dismissed within a second routinely showed placeholders, and which rows got
-- a real ring depended on which buckets some earlier, longer-lived open had
-- happened to render.
--
-- writeFile is synchronous. The path exists before ensure() returns, so the
-- placeholder is now unreachable in practice, there is no in-flight state to
-- track, and the plugin no longer needs ImageMagick at all.

local shared = require("./shared.luau")

local M = {}

-- Geometry matches the ImageMagick original: outer radius 39, inner 21, so a
-- mid-radius of 30 stroked 18 wide.
local SIZE = 88
local CENTER = SIZE / 2
local RADIUS = 30
local STROKE = 18
local CIRCUMFERENCE = 2 * math.pi * RADIUS

-- 2%-wide steps: enough to look smooth, few enough files to cache.
local BUCKETS = 50
-- Substituted with this build's output hash (see pkgs/noctalia-ha-ai-usage):
-- it namespaces the files so a new build never serves rings drawn by the
-- previous one, whatever changed — radii, caps or colours.
local CACHE_KEY = "@cacheKey@"

-- Below this a round-capped dash would still paint a dot, and above it the
-- dash gap disappears anyway, so both ends become a plain circle.
local EMPTY_BELOW = 0.004
local FULL_ABOVE = 0.996

local function sanitizeColor(hex)
  return (hex:gsub("#", ""))
end

local function circle(stroke, opacity, extra)
  return string.format(
    '<circle cx="%d" cy="%d" r="%d" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="%d"%s/>',
    CENTER,
    CENTER,
    RADIUS,
    stroke,
    opacity,
    STROKE,
    extra
  )
end

local function svg(fraction, trackColor, fillColor)
  -- The track is the same ~16% wash the linear progress bar beside it uses.
  -- stroke-opacity rather than an 8-digit hex, which not every SVG renderer
  -- takes.
  local parts = { circle(trackColor, "0.16", "") }

  if fraction >= FULL_ABOVE then
    table.insert(parts, circle(fillColor, "1", ""))
  elseif fraction > EMPTY_BELOW then
    -- Start at twelve o'clock and sweep clockwise, like the original.
    local length = fraction * CIRCUMFERENCE
    local extra = string.format(
      ' stroke-linecap="round" stroke-dasharray="%.3f %.3f" transform="rotate(-90 %d %d)"',
      length,
      CIRCUMFERENCE - length,
      CENTER,
      CENTER
    )
    table.insert(parts, circle(fillColor, "1", extra))
  end

  return string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>',
    SIZE,
    SIZE,
    SIZE,
    SIZE,
    table.concat(parts, "")
  )
end

function M.bucket(fraction)
  return math.floor(math.clamp(fraction, 0, 1) * BUCKETS + 0.5)
end

function M.path(bucket, fillColor)
  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then
    return nil
  end
  return dataDir .. "/ring-" .. CACHE_KEY .. "-" .. bucket .. "-" .. sanitizeColor(fillColor) .. ".svg"
end

-- The remaining-time fraction of a metric's window, and whether it has one at
-- all (Copilot's category quotas don't).
function M.fraction(metric)
  local remaining = shared.remainingSeconds(metric.reset)
  local windowSeconds = shared.windowSeconds(metric.window)
  if remaining == nil or windowSeconds == nil or windowSeconds <= 0 then
    return 0, false
  end
  return math.clamp(remaining / windowSeconds, 0, 1), true
end

-- The ring warms up as its window runs out (orange on the last quarter, red on
-- the last tenth) regardless of how much of the quota is actually spent;
-- windowless metrics get the muted role. None of the shipped palettes has an
-- orange role (Indigo's tertiary, which the usage colours use for their
-- warning band, is lavender), so the mid-band default is a literal hex. All
-- three take a palette role name or a hex, same as every other colour setting.
local CRITICAL_REMAINING = 0.10
local WARNING_REMAINING = 0.25

function M.color(fraction, hasWindow)
  if not hasWindow then
    return "on_surface_variant"
  end
  if fraction <= CRITICAL_REMAINING then
    return shared.config("panel_ring_critical_color", "error")
  end
  if fraction <= WARNING_REMAINING then
    return shared.config("panel_ring_warning_color", "#F5A97F")
  end
  return shared.config("panel_ring_normal_color", "primary")
end

function M.fillColor(fraction, hasWindow)
  return shared.resolveColor(M.color(fraction, hasWindow), "#9AA0A6")
end

-- Path to the ring for this fraction and colour, writing it first if it isn't
-- cached yet. nil only when the data dir is unavailable or the write failed —
-- both of which leave the caller to draw its placeholder.
function M.ensure(fraction, fillColor)
  local outPath = M.path(M.bucket(fraction), fillColor)
  if outPath == nil then
    return nil
  end
  if noctalia.fileExists(outPath) then
    return outPath
  end

  local trackColor = shared.resolveColor("on_surface", "#9AA0A6")
  local ok, err = noctalia.writeFile(outPath, svg(M.bucket(fraction) / BUCKETS, trackColor, fillColor))
  if not ok then
    noctalia.log("ha-ai-usage: ring write failed: " .. tostring(err))
    return nil
  end
  return outPath
end

-- Drop every generation but this build's. Nothing else prunes this directory,
-- so without it each plugin version leaves its rings behind forever. Safe to
-- run on load now that a missing ring is written on demand rather than waited
-- for: pruning can no longer open a window where the panel has nothing to
-- draw.
function M.prune()
  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then
    return
  end
  local cmd = "@find@ '" .. dataDir .. "' -maxdepth 1 -type f \\( -name 'ring-*.png' -o -name 'ring-*.svg' \\) "
    .. "-not -name 'ring-" .. CACHE_KEY .. "-*' -delete"
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("ha-ai-usage: ring cache prune failed: " .. shared.trim(result.stderr))
    end
  end, 5000)
end

return M
