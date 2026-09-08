--!nonstrict
-- Resolves a Tabler icon glyph name (the same names the glyph settings
-- already take) to the literal UTF-8 character its codepoint maps to, so
-- ImageMagick can -annotate it using Noctalia's own bundled icon font.
--
-- Regex-extracts just the one field needed straight out of the raw
-- tabler.json text instead of decoding all ~5900 entries through
-- noctalia.json: Noctalia's own Luau CPU budget has aborted json.decode on
-- comparably large data elsewhere in this plugin collection (see
-- ha-ai-usage's service.luau, on pw-dump's full graph).

local M = {}

local rawJson = nil
local rawJsonDir = nil
local cache = {}

local function loadRaw(dir)
  if rawJson ~= nil and rawJsonDir == dir then
    return rawJson
  end
  rawJson = noctalia.readFile(dir .. "/tabler.json")
  rawJsonDir = dir
  return rawJson
end

-- Tabler's codepoints live in Unicode private-use areas (U+E000-U+F8FF),
-- always in the Basic Multilingual Plane, so a single utf8.char() call is
-- enough -- no surrogate-pair handling needed.
local function charFromHex(hex)
  local code = tonumber(hex, 16)
  if code == nil then
    return nil
  end
  return utf8.char(code)
end

-- `name` -> the glyph's literal character, or nil if it can't be resolved
-- (bad name, missing/unreadable tabler.json). Cached per (assetsDir, name)
-- so a repeat lookup -- every poll tick calls this for the same handful of
-- configured glyphs -- costs a table read, not a fresh scan.
function M.char(name, assetsDir)
  if name == nil or name == "" or assetsDir == nil or assetsDir == "" then
    return nil
  end
  local cacheKey = assetsDir .. ":" .. name
  local cached = cache[cacheKey]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  local raw = loadRaw(assetsDir)
  if raw == nil then
    cache[cacheKey] = false
    return nil
  end

  -- Two-phase lookup: a plain (non-pattern) substring search for the key
  -- first, which Lua's string library fast-paths well below the cost of its
  -- pattern engine, then the actual codepoint pattern runs only over a short
  -- window right after the match instead of the whole ~480KB file. The
  -- single-pass version of this (the pattern doing both jobs at once, with a
  -- lazy `[^}]-` in the middle) had this scan exceed Noctalia's Luau CPU
  -- budget outright on some loads -- confirmed live, badge_mode disabled
  -- after "repeated timeouts" every time this ran cold. tabler.json's ~5900
  -- entries make either the key or its codepoint land arbitrarily far into
  -- the file, so there is no bounding this without a plain search first.
  local start = raw:find('"' .. name .. '"', 1, true)
  local char = nil
  if start ~= nil then
    local window = raw:sub(start, start + 200)
    local escaped = name:gsub("(%p)", "%%%1")
    local hex = window:match('"' .. escaped .. '"%s*:%s*{[^}]-"codepoint"%s*:%s*"U%+(%x+)"')
    char = hex ~= nil and charFromHex(hex) or nil
  end
  cache[cacheKey] = char or false
  return char
end

return M
