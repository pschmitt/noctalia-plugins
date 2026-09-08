--!nonstrict
-- Composited "main icon + corner state badge" bitmap for the bar widget's
-- optional badge_mode -- an alternative to swapping the whole icon per state
-- (tracking_glyph/stopped_glyph/clock_out_glyph normally replace the icon
-- outright; in badge mode they become a small overlay instead).
--
-- Noctalia's plugin ui.* tree has no overlay/z-stack primitive: every
-- container is pure flex layout, and leaf types (box/image/glyph) are
-- hard-blocked from having children at all (the reconciler logs "cannot
-- have children, N dropped" and drops them -- confirmed against the actual
-- upstream source, not just inferred). A flattened bitmap, regenerated on
-- change and cached by a path that already encodes its own parameters --
-- same convention as battery-icon's bolt/percentage bitmap -- is the only
-- way to draw one icon actually on top of another here.
--
-- The default base layer is assets/timewarrior-logo-simple.svg, rasterized at
-- runtime via rsvg-convert at exactly the working resolution each composite
-- needs (see ensureMainRaster below) -- not through ImageMagick's own SVG
-- delegate, which this plugin collection already routes around for
-- syncthing's badges the same way, and not a fixed-size pre-rasterized PNG
-- resized after the fact either: an earlier version did that (a build-time
-- 256px PNG, resized down per icon_size) and it was visually identical to
-- rendering fresh from the vector source, which only confirmed the
-- blurriness at small icon_size wasn't a resampling loss at all -- it was the
-- full logo's own fine detail (see the simplified SVG's own header comment).
--
-- The badge (and a custom main_glyph, if set) are drawn from Noctalia's own
-- bundled icon font -- there is no per-glyph vector source available to this
-- plugin (see tabler_codepoint.luau), which is also why badge_mode needs
-- `noctalia_assets_dir` pointed at Noctalia's own installed
-- `share/noctalia/assets/fonts`.

local tablerCodepoint = require("./tabler_codepoint.luau")

local M = {}

-- Rendered at SUPERSAMPLE times the widget's actual icon_size, then
-- ImageMagick's own high-quality -resize brings it back down to the exact
-- display size as the final step -- so ui.image never has to scale the
-- result itself. It matters: an early version rendered at a fixed 128x128
-- and let ui.image downscale that to a 16px icon, an 8x ratio that looked
-- soft (naive minification loses most of a font glyph's fine detail) on top
-- of a badge that was already too small a fraction of the icon to read.
-- Supersampling then downsampling with a real filter is what "generate once,
-- always crisp at the target size" from ha-ai-usage's SVG rings amounted to
-- for a vector source -- this is the raster equivalent of the same idea.
local SUPERSAMPLE = 4
-- Big enough to actually carry a recognisable glyph, verified by generating
-- real output at several icon_size values: still a blur at the 16px default,
-- clearly the right shape from 24px up. A badge is inherently a small
-- fraction of an already-small icon, so it needs as much of that fraction as
-- it can get without eating the main icon entirely -- 0.62 leaves a sliver
-- of main icon showing behind the badge's corner. Nothing here can make a
-- corner badge legible on an icon too small to spare the pixels; see the
-- README for the icon_size this needs in practice.
local BADGE_DIAMETER_RATIO = 0.62
local BADGE_MARGIN_RATIO = 0.03
local BADGE_FONT_RATIO = 0.62 -- of the badge diameter
local MAIN_FONT_RATIO = 0.72 -- of the full icon size, unaffected by the badge

-- Optional pulse (see M.ensure's `pulseAlpha` doc below): rather than
-- regenerate a fresh composite on every ~100ms animation tick, alpha is
-- bucketed into this many discrete steps and each bucket is cached like any
-- other combination -- one `magick` call per bucket the very first time its
-- phase of the pulse is reached, cache hits (synchronous) every time after,
-- for the rest of that combination's lifetime. 20 steps over a ~1s period is
-- a new frame roughly every 60ms, smooth enough for a breathing effect and
-- few enough that a full cycle warms up in about one period.
local PULSE_FRAME_COUNT = 20
-- Floor of the badge's fade range, matching screencast's dot -- it dims, it
-- does not disappear, so the state it names is never briefly unreadable.
local PULSE_MIN_ALPHA = 0.25

-- Dilates the rasterized main logo by this many pixels at working
-- resolution, after the simplified SVG's own ring removal already did most
-- of the work: verified live at the real 4x-supersample working size (64px
-- for the 16px default), radius 1 makes the helmet's visor cut read as two
-- distinct legs instead of a grey smear, radius 2 starts closing the cut
-- into a blob. 0 would skip it, but there is no setting for this -- it is a
-- fixed correction for a fixed rendering pipeline, not a per-user tradeoff.
local MAIN_DILATE_RADIUS = 1

local CACHE_KEY = "@cacheKey@"
local MAGICK = "@magick@"
local RSVG_CONVERT = "@rsvgConvert@"
local FIND = "@find@"

local function sanitize(s)
  return tostring(s or ""):gsub("[^%w]", "_")
end

-- Rounds a continuous 0..1 alpha to one of PULSE_FRAME_COUNT+1 steps, so the
-- same phase of the pulse always maps to the same cache key instead of
-- spawning a new `magick` process for every slightly-different float a fast
-- timer tick produces. Returns nil unchanged (nil means "no pulse: fully
-- opaque, the original non-pulsing behaviour").
local function quantizeAlpha(alpha)
  if alpha == nil then
    return nil
  end
  local clamped = math.clamp(tonumber(alpha) or 1, 0, 1)
  local step = math.floor(clamped * PULSE_FRAME_COUNT + 0.5)
  return step / PULSE_FRAME_COUNT
end

-- Appends an alpha channel to a plain "#RRGGBB" colour (what resolve_color.luau
-- always hands back) so ImageMagick's -fill / -draw / -annotate alpha-blend it
-- against whatever is already on the canvas -- the main icon underneath,
-- drawn first and left fully opaque, so only the badge itself fades.
-- Anything not in that exact shape (should not happen, but a resolver
-- fallback is still a string of unknown shape) is returned as-is rather than
-- mangled.
local function withAlpha(hexColor, alpha)
  if alpha == nil then
    return hexColor
  end
  local hex = tostring(hexColor or "")
  if not hex:match("^#%x%x%x%x%x%x$") then
    return hexColor
  end
  return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
end

-- Center point of the badge circle for each corner, in working (supersampled)
-- pixels. Lua division always produces a float, and string.format's %d
-- rejects a float that isn't integer-VALUED in some hosts -- floor
-- everything up front so every caller downstream only ever sees integers.
local function badgeCenter(position, workingSize, diameter, margin)
  local r = math.floor(diameter / 2)
  if position == "top_left" then
    return margin + r, margin + r
  elseif position == "top_right" then
    return workingSize - margin - r, margin + r
  elseif position == "bottom_left" then
    return margin + r, workingSize - margin - r
  end
  return workingSize - margin - r, workingSize - margin - r -- bottom_right, the default
end

local function path(key)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/badge-" .. CACHE_KEY .. "-" .. sanitize(key) .. ".png"
end

local function mainRasterPath(workingSize)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/main-" .. CACHE_KEY .. "-" .. tostring(workingSize) .. ".png"
end

-- Renders the bundled logo SVG fresh at exactly `workingSize` pixels via
-- rsvg-convert -- real vector rasterization at the target resolution, the
-- same thing a font glyph gets automatically -- then dilates it slightly
-- (see MAIN_DILATE_RADIUS). Cached per workingSize alone (== icon_size,
-- since SUPERSAMPLE is a fixed constant): independent of badge glyph,
-- colour, or pulse, so resolving it once covers every subsequent composite
-- at that icon_size, pulsing's many alpha buckets included -- only the badge
-- overlay differs between those, not this layer.
--
-- Calls `callback(path)` -- synchronously on a cache hit (an existing raster
-- for this exact workingSize), asynchronously otherwise, once rsvg-convert
-- and the dilate both finish. Either way M.ensure's own caller only ever
-- observes the outer composite's runAsync as the async step, since that call
-- always follows this one. `callback(nil)` means rsvg-convert or the dilate
-- failed.
local function ensureMainRaster(svgPath, workingSize, callback)
  local outPath = mainRasterPath(workingSize)
  if outPath == nil then
    callback(nil)
    return
  end
  if noctalia.fileExists(outPath) then
    callback(outPath)
    return
  end

  local dir = noctalia.pluginDataDir()
  -- Not versioned by CACHE_KEY or otherwise made unique: it is consumed and
  -- overwritten immediately below, never read back across generations, so it
  -- does not need its own cache-invalidation story.
  local rawPath = dir .. "/main-raw-" .. tostring(workingSize) .. ".png"

  noctalia.runAsync({
    RSVG_CONVERT,
    "-w",
    tostring(workingSize),
    "-h",
    tostring(workingSize),
    "-o",
    rawPath,
    svgPath,
  }, function(rsvgResult)
    if rsvgResult.exitCode ~= 0 or not noctalia.fileExists(rawPath) then
      noctalia.log(
        "timewarrior: main icon SVG render failed: " .. noctalia.string.trim(rsvgResult.stderr or "unknown error")
      )
      callback(nil)
      return
    end

    noctalia.runAsync({
      MAGICK,
      rawPath,
      "-morphology",
      "Dilate",
      "Disk:" .. tostring(MAIN_DILATE_RADIUS),
      outPath,
    }, function(dilateResult)
      if dilateResult.exitCode == 0 and noctalia.fileExists(outPath) then
        callback(outPath)
      else
        noctalia.log(
          "timewarrior: main icon dilate failed: " .. noctalia.string.trim(dilateResult.stderr or "unknown error")
        )
        callback(nil)
      end
    end, 5000)
  end, 5000)
end

-- `opts`: mainGlyph, badgeGlyph (both "" for "none"/bundled), position,
-- mainColor, badgeColor, badgeBgColor (real hex -- resolve_color.luau first),
-- logoSvgPath (the bundled logo's simplified vector source, rasterized fresh
-- per workingSize -- see ensureMainRaster), assetsDir
-- (noctalia_assets_dir), size (the widget's icon_size in pixels -- the
-- output PNG is generated at exactly this size, see SUPERSAMPLE above),
-- pulseAlpha (optional, 0..1 -- see quantizeAlpha above; nil means the badge
-- is fully opaque, the original non-pulsing behaviour). Only the chip fades
-- with it -- the glyph on top always renders at full opacity, see the fill
-- order below.
--
-- badgeColor tints the badge glyph itself, not its circle: it is the same
-- dynamic state/overtime colour swap mode would have tinted the whole icon
-- with, and on the built-in palette that is often a light, low-saturation
-- "on_surface" grey outside of overtime -- putting that on a same-colour
-- circle (confirmed live: an early version did exactly this) rendered as one
-- indistinct pale blob. badgeBgColor is a separate, fixed backing colour so
-- the badge reads as a chip against the main icon regardless of what state
-- colour lands on it.
--
-- Calls `callback(path)` -- synchronously with the cached path when one
-- already exists for this exact combination, otherwise asynchronously once
-- generated. `callback(nil)` means "nothing to show yet or ever for this
-- input" -- the caller falls back to the plain, badge-less icon.
function M.ensure(opts, callback)
  local size = math.max(1, math.floor(tonumber(opts.size) or 16))
  local pulseAlpha = quantizeAlpha(opts.pulseAlpha)
  local key = table.concat({
    opts.mainGlyph or "",
    opts.badgeGlyph or "",
    opts.position or "",
    opts.mainColor or "",
    opts.badgeColor or "",
    opts.badgeBgColor or "",
    tostring(size),
    pulseAlpha ~= nil and string.format("p%.3f", pulseAlpha) or "static",
  }, "|")
  local outPath = path(key)
  if outPath == nil then
    callback(nil)
    return
  end
  if noctalia.fileExists(outPath) then
    callback(outPath)
    return
  end

  local mainChar = nil
  if opts.mainGlyph ~= "" then
    mainChar = tablerCodepoint.char(opts.mainGlyph, opts.assetsDir)
    if mainChar == nil then
      -- A configured main glyph that fails to resolve (bad name, missing
      -- assets dir) should not silently fall back to the logo: that would
      -- hide a misconfiguration behind a different icon than the one asked
      -- for. Bail; the caller shows the plain (non-badge) icon instead.
      callback(nil)
      return
    end
  end

  local badgeChar = nil
  if opts.badgeGlyph ~= "" then
    badgeChar = tablerCodepoint.char(opts.badgeGlyph, opts.assetsDir)
    if badgeChar == nil then
      callback(nil)
      return
    end
  end

  local workingSize = size * SUPERSAMPLE
  local badgeDiameter = math.floor(workingSize * BADGE_DIAMETER_RATIO)
  local badgeMargin = math.max(1, math.floor(workingSize * BADGE_MARGIN_RATIO))
  local font = opts.assetsDir .. "/noctalia-tabler.ttf"

  -- `mainSource`: nil when mainChar ~= nil (the font-glyph main icon is drawn
  -- directly below, nothing to composite from a file); otherwise the
  -- already-workingSize-exact rasterized logo path from ensureMainRaster.
  local function finish(mainSource)
    local args = { MAGICK }
    local function push(v) table.insert(args, v) end

    if mainChar ~= nil then
      push("-size")
      push(workingSize .. "x" .. workingSize)
      push("xc:none")
      push("-gravity")
      push("center")
      push("-fill")
      push(opts.mainColor)
      push("-font")
      push(font)
      push("-pointsize")
      push(tostring(math.floor(workingSize * MAIN_FONT_RATIO)))
      push("-annotate")
      push("+0+0")
      push(mainChar)
    else
      -- Already exactly workingSize -- no -resize needed, unlike the old
      -- fixed-256px-PNG source, which is exactly the point.
      push(mainSource)
    end

    if badgeChar ~= nil then
      local cx, cy = badgeCenter(opts.position, workingSize, badgeDiameter, badgeMargin)
      local r = math.floor(badgeDiameter / 2)
      push("-fill")
      -- Only the chip fades, never the glyph on top of it: the glyph is
      -- already a handful of thin font strokes at a small supersampled size
      -- (the same detail an earlier pass found barely legible at 16px), and
      -- fading it too pushed it toward invisible for most of the cycle --
      -- read live as the badge going blurry, not pulsing. A solid circle has
      -- no fine detail to lose, so it can fade on its own without taking
      -- legibility down with it.
      push(withAlpha(opts.badgeBgColor, pulseAlpha))
      push("-draw")
      push(string.format("circle %d,%d %d,%d", cx, cy, cx + r, cy))
      push("-gravity")
      push("center")
      push("-fill")
      push(opts.badgeColor)
      push("-font")
      push(font)
      push("-pointsize")
      push(tostring(math.floor(badgeDiameter * BADGE_FONT_RATIO)))
      push("-annotate")
      -- Offsets are from the canvas center, not the badge's own center: the
      -- badge lives off in a corner, so both axes need shifting there.
      push(string.format("%+d%+d", cx - math.floor(workingSize / 2), cy - math.floor(workingSize / 2)))
      push(badgeChar)
    end

    -- The one high-quality downsample, right at the end: ui.image then
    -- displays this at 1:1 with the widget's actual icon_size, no further
    -- scaling (and no further softening) on the client side.
    push("-resize")
    push(size .. "x" .. size)

    push(outPath)

    noctalia.runAsync(args, function(result)
      if result.exitCode == 0 and noctalia.fileExists(outPath) then
        callback(outPath)
      else
        noctalia.log(
          "timewarrior: badge icon render failed: " .. noctalia.string.trim(result.stderr or "unknown error")
        )
        callback(nil)
      end
    end, 5000)
  end

  if mainChar ~= nil then
    finish(nil)
  else
    ensureMainRaster(opts.logoSvgPath, workingSize, function(mainSource)
      if mainSource == nil then
        callback(nil)
        return
      end
      finish(mainSource)
    end)
  end
end

-- Drop every generation but this build's. Nothing else prunes this
-- directory, so without it each plugin version leaves its composites behind
-- forever. main-raw-*.png (ensureMainRaster's scratch file) is deliberately
-- excluded: it carries no CACHE_KEY at all, so it would look permanently
-- stale to this same pattern otherwise, and it is small and constantly
-- overwritten anyway.
function M.prune()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return
  end
  local cmd = "'"
    .. FIND
    .. "' '"
    .. dir
    .. "' -maxdepth 1 -type f \\( -name 'badge-*.png' -o -name 'main-*.png' \\)"
    .. " -not -name 'main-raw-*.png' -not -name '*-"
    .. CACHE_KEY
    .. "-*' -delete"
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("timewarrior: badge cache prune failed: " .. noctalia.string.trim(result.stderr or "unknown error"))
    end
  end, 5000)
end

return M
