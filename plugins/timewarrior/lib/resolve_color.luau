--!nonstrict
-- Resolves a Noctalia colour setting (a #hex value or a palette role name
-- like "on_surface") to an actual hex value ImageMagick can use for -fill --
-- it only understands real colours, not Noctalia's role names. Ported from
-- pschmitt/battery-icon's service.luau, which solved this same problem for
-- its own rendered bitmap.

local M = {}

local paletteCache = { key = nil, colors = nil }

local function roleToPaletteKey(role)
  local out = "m"
  for word in role:gmatch("[^_]+") do
    out = out .. word:sub(1, 1):upper() .. word:sub(2)
  end
  return out
end

local function resolveRoleColor(role)
  if noctalia.getSetting("theme.source") ~= "custom" then
    return nil -- built-in palettes aren't user files we can read directly
  end
  local paletteName = noctalia.getSetting("theme.custom_palette")
  if paletteName == nil or paletteName == "" then
    return nil
  end
  local mode = noctalia.isDarkMode() and "dark" or "light"
  local cacheKey = paletteName .. ":" .. mode

  if paletteCache.key ~= cacheKey then
    local raw = noctalia.readFile(noctalia.expandPath("~/.config/noctalia/palettes/" .. paletteName .. ".json"))
    local decoded = raw ~= nil and noctalia.json.decode(raw) or nil
    paletteCache = { key = cacheKey, colors = decoded ~= nil and decoded[mode] or nil }
  end

  if paletteCache.colors == nil then
    return nil
  end
  return paletteCache.colors[roleToPaletteKey(role)]
end

-- `value` is either a hex colour or a Noctalia palette role name; `fallback`
-- is the fixed hex used when it's a role name that can't be resolved (built-in
-- palette, unknown role, missing palette file, ...).
function M.resolve(value, fallback)
  if type(value) ~= "string" or value == "" then
    return fallback
  end
  if value:match("^#%x+$") then
    return value
  end
  return resolveRoleColor(value) or fallback
end

return M
