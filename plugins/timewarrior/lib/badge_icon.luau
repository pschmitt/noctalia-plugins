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
-- (assets/timewarrior-logo-128.png -- see pkgs/noctalia-timewarrior), not the
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

-- Fixed regardless of the bar's configured icon_size (a per-widget setting a
-- shared, cached bitmap can't chase) -- same approach battery-icon's fixed
-- "128x64" canvas takes. ui.image scales the result to whatever size each
-- widget instance actually wants.
local SIZE = 128
local BADGE_DIAMETER = 56
local BADGE_MARGIN = 2
local BADGE_FONT_SIZE = 32
local MAIN_FONT_SIZE = 92
local BADGE_GLYPH_COLOR = "white"

local CACHE_KEY = "@cacheKey@"
local MAGICK = "@magick@"
local FIND = "@find@"

local function sanitize(s)
  return tostring(s or ""):gsub("[^%w]", "_")
end

-- Center point of the badge circle for each corner. Lua division always
-- produces a float (even 56 / 2), and string.format's %d rejects a float
-- that isn't integer-VALUED in some hosts -- floor everything up front so
-- every caller downstream only ever sees plain integers.
local function badgeCenter(position)
  local r = math.floor(BADGE_DIAMETER / 2)
  if position == "top_left" then
    return BADGE_MARGIN + r, BADGE_MARGIN + r
  elseif position == "top_right" then
    return SIZE - BADGE_MARGIN - r, BADGE_MARGIN + r
  elseif position == "bottom_left" then
    return BADGE_MARGIN + r, SIZE - BADGE_MARGIN - r
  end
  return SIZE - BADGE_MARGIN - r, SIZE - BADGE_MARGIN - r -- bottom_right, the default
end

local function path(key)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/badge-" .. CACHE_KEY .. "-" .. sanitize(key) .. ".png"
end

-- `opts`: mainGlyph, badgeGlyph (both "" for "none"/bundled), position,
-- mainColor, badgeColor (real hex -- resolve_color.luau first), logoPngPath
-- (the build-time-rasterized bundled logo), assetsDir (noctalia_assets_dir).
--
-- Calls `callback(path)` -- synchronously with the cached path when one
-- already exists for this exact combination, otherwise asynchronously once
-- generated. `callback(nil)` means "nothing to show yet or ever for this
-- input" -- the caller falls back to the plain, badge-less icon.
function M.ensure(opts, callback)
  local key = table.concat({
    opts.mainGlyph or "",
    opts.badgeGlyph or "",
    opts.position or "",
    opts.mainColor or "",
    opts.badgeColor or "",
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

  local font = opts.assetsDir .. "/noctalia-tabler.ttf"
  local args = { MAGICK }
  local function push(v) table.insert(args, v) end

  if mainChar ~= nil then
    push("-size")
    push(SIZE .. "x" .. SIZE)
    push("xc:none")
    push("-gravity")
    push("center")
    push("-fill")
    push(opts.mainColor)
    push("-font")
    push(font)
    push("-pointsize")
    push(tostring(MAIN_FONT_SIZE))
    push("-annotate")
    push("+0+0")
    push(mainChar)
  else
    push(opts.logoPngPath)
    push("-resize")
    push(SIZE .. "x" .. SIZE)
  end

  if badgeChar ~= nil then
    local cx, cy = badgeCenter(opts.position)
    local r = math.floor(BADGE_DIAMETER / 2)
    push("-fill")
    push(opts.badgeColor)
    push("-draw")
    push(string.format("circle %d,%d %d,%d", cx, cy, cx + r, cy))
    push("-gravity")
    push("center")
    push("-fill")
    push(BADGE_GLYPH_COLOR)
    push("-font")
    push(font)
    push("-pointsize")
    push(tostring(BADGE_FONT_SIZE))
    push("-annotate")
    -- Offsets are from the canvas center, not the badge's own center: the
    -- badge lives off in a corner, so both axes need shifting there.
    push(string.format("%+d%+d", cx - math.floor(SIZE / 2), cy - math.floor(SIZE / 2)))
    push(badgeChar)
  end

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
