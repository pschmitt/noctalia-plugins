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
-- The default base layer is a build-time-rasterized PNG of the bundled logo
-- (assets/timewarrior-logo-256.png -- see pkgs/noctalia-timewarrior), not the
-- SVG itself: ImageMagick's own SVG delegate is exactly what this plugin
-- collection already routes around for syncthing's badges (rsvg-convert
-- directly, at build time, not through magick). Rasterizing once at build
-- time means every runtime composite is a single `magick <png> ...
-- -annotate ...` call with no SVG involved at all.
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

local CACHE_KEY = "@cacheKey@"
local MAGICK = "@magick@"
local FIND = "@find@"

local function sanitize(s)
  return tostring(s or ""):gsub("[^%w]", "_")
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

-- `opts`: mainGlyph, badgeGlyph (both "" for "none"/bundled), position,
-- mainColor, badgeColor, badgeBgColor (real hex -- resolve_color.luau first),
-- logoPngPath (the build-time-rasterized bundled logo), assetsDir
-- (noctalia_assets_dir), size (the widget's icon_size in pixels -- the
-- output PNG is generated at exactly this size, see SUPERSAMPLE above).
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
  local key = table.concat({
    opts.mainGlyph or "",
    opts.badgeGlyph or "",
    opts.position or "",
    opts.mainColor or "",
    opts.badgeColor or "",
    opts.badgeBgColor or "",
    tostring(size),
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
    push(opts.logoPngPath)
    push("-resize")
    push(workingSize .. "x" .. workingSize)
  end

  if badgeChar ~= nil then
    local cx, cy = badgeCenter(opts.position, workingSize, badgeDiameter, badgeMargin)
    local r = math.floor(badgeDiameter / 2)
    push("-fill")
    push(opts.badgeBgColor)
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
      noctalia.log("timewarrior: badge icon render failed: " .. noctalia.string.trim(result.stderr or "unknown error"))
      callback(nil)
    end
  end, 5000)
end

-- Drop every generation but this build's. Nothing else prunes this
-- directory, so without it each plugin version leaves its composites behind
-- forever.
function M.prune()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return
  end
  local cmd = "'"
    .. FIND
    .. "' '"
    .. dir
    .. "' -maxdepth 1 -type f -name 'badge-*.png' -not -name 'badge-"
    .. CACHE_KEY
    .. "-*' -delete"
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("timewarrior: badge cache prune failed: " .. noctalia.string.trim(result.stderr or "unknown error"))
    end
  end, 5000)
end

return M
