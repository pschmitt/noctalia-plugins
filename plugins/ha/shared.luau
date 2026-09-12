--!nonstrict

local M = {}

function M.trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

function M.config(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then return fallback end
  return value
end

function M.domainOf(entityId)
  local dot = string.find(entityId, ".", 1, true)
  return dot and string.sub(entityId, 1, dot - 1) or entityId
end

-- Glyph names are Tabler icon slugs, the same set every ui.glyph() call in
-- this repo draws from. Kept to the handful pozzoo/hassio already shipped and
-- confirmed render correctly (see its domainGlyph()), rather than guessing at
-- names Tabler might not have; anything else falls back to the plugin's own
-- "smart-home" icon instead of risking a blank glyph.
local DOMAIN_GLYPHS = {
  light = "bulb",
  switch = "toggle-right",
  input_boolean = "toggle-right",
  sensor = "chart-line",
  binary_sensor = "activity",
  climate = "temperature",
  -- Covers can be blinds, shades, curtains, doors or windows. `window` is a
  -- verified Tabler glyph and reads correctly for the common roller-shutter
  -- case; the old `blinds` name is not in Noctalia's bundled glyph font.
  cover = "window",
  fan = "wind",
  lock = "lock",
  media_player = "device-speaker",
  weather = "cloud",
  automation = "robot",
  script = "player-play",
  scene = "movie",
  camera = "camera",
  vacuum = "robot",
  person = "user",
  device_tracker = "map-pin",
}

-- Home Assistant commonly supplies Material Design Icons names (`mdi:...`),
-- while Noctalia ships Tabler rather than the MDI font. These are the names
-- where the two icon sets differ but a close Tabler equivalent is unambiguous.
-- Unknown MDI names still lose only their prefix and are passed through, so a
-- future Noctalia glyph or a plain Tabler-compatible override remains usable.
local MDI_TO_TABLER = {
  ["desk-lamp"] = "lamp",
  ["fan"] = "wind",
  ["lightbulb"] = "bulb",
  ["lightbulb-outline"] = "bulb",
  ["robot-vacuum"] = "robot",
  ["speaker"] = "device-speaker",
  ["television"] = "device-tv",
  ["television-classic"] = "device-tv",
  ["thermometer"] = "temperature",
  ["washing-machine"] = "wash-machine",
  ["weather-night"] = "moon",
  ["weather-sunny"] = "sun",
}

function M.glyphFor(domain, override, state)
  if type(override) == "string" and override ~= "" then
    local mdiName = override:match("^mdi:(.+)$")
    if mdiName then return MDI_TO_TABLER[mdiName] or mdiName end
    return override
  end
  if domain == "light" then return M.isOn(state) and "bulb" or "bulb-off" end
  if domain == "fan" then return M.isOn(state) and "propeller" or "propeller-off" end
  return DOMAIN_GLYPHS[domain] or "smart-home"
end

local ON_STATES = {
  on = true, open = true, unlocked = true, home = true, playing = true,
  cleaning = true, detected = true, active = true,
}
local UNAVAILABLE_STATES = { unavailable = true, unknown = true, [""] = true }

function M.isUnavailable(state)
  return UNAVAILABLE_STATES[tostring(state or ""):lower()] == true
end

function M.isOn(state)
  return ON_STATES[tostring(state or ""):lower()] == true
end

function M.colorFor(state)
  if M.isUnavailable(state) then return "on_surface_variant" end
  if M.isOn(state) then return "primary" end
  return "on_surface_variant"
end

-- Domains a plain [[homeassistant.toggle]] service call meaningfully flips.
-- Anything else (sensor, binary_sensor, person, device_tracker, camera, ...)
-- is read-only here on purpose -- this plugin is a status/quick-toggle strip,
-- not a full entity editor. cover is deliberately absent: it gets its own
-- open/stop/close row instead of a toggle (see panel.luau's coverButtons()).
local TOGGLEABLE_DOMAINS = {
  light = true, switch = true, input_boolean = true, fan = true,
  lock = true, climate = true, automation = true, script = true, siren = true,
  humidifier = true, media_player = true, vacuum = true,
}

function M.isToggleable(domain)
  return TOGGLEABLE_DOMAINS[domain] == true
end

-- Home Assistant's LockEntityFeature.OPEN is the low bit of the
-- supported_features mask. Lock and unlock are part of every lock entity;
-- only the unlatch/open action is optional.
function M.lockSupportsOpen(entity)
  local features = tonumber(entity and entity.supported_features)
  return features ~= nil and math.floor(features) % 2 == 1
end

-- The domain filter chips the browser panel offers, in display order. Kept as
-- a fixed, known-safe list: it is interpolated directly into a Jinja
-- `states.<domain>` accessor (see service.luau's browseSource()), so this
-- list is also the whitelist that guards that interpolation.
M.BROWSABLE_DOMAINS = {
  "light", "switch", "script", "automation", "scene", "fan", "lock", "cover",
  "climate", "media_player", "binary_sensor", "sensor", "input_boolean",
  "camera", "vacuum", "person", "device_tracker",
}

function M.isKnownDomain(domain)
  for _, d in ipairs(M.BROWSABLE_DOMAINS) do
    if d == domain then return true end
  end
  return false
end

function M.domainLabel(domain)
  if domain == "all" or domain == nil or domain == "" then return "All" end
  local label = domain:gsub("_", " ")
  return label:sub(1, 1):upper() .. label:sub(2)
end

-- "on · 62%" / "open · 40%" instead of a bare state word, wherever there's a
-- number worth showing: light brightness (while on), fan speed (while on),
-- cover position (whatever state it's in -- unlike brightness/percentage,
-- Home Assistant doesn't clear a cover's position when it's fully closed).
-- Shared by bar.luau's tooltip and panel.luau's entity cards so both read
-- the same thing.
function M.statusText(entity)
  local domain = M.domainOf(entity.entity_id)
  if M.isUnavailable(entity.state) then return "unavailable" end
  local state = entity.display_state or entity.state or "—"
  local on = M.isOn(entity.state)
  if domain == "light" and on and entity.brightness ~= nil then
    return state .. " · " .. math.floor((entity.brightness / 255) * 100 + 0.5) .. "%"
  end
  if domain == "fan" and on and entity.percentage ~= nil then
    return state .. " · " .. math.floor(entity.percentage + 0.5) .. "%"
  end
  if domain == "cover" and entity.position ~= nil then
    return state .. " · " .. math.floor(entity.position + 0.5) .. "%"
  end
  if domain == "media_player" and entity.media_title and entity.media_title ~= "" then
    local track = entity.media_title
    if entity.media_artist and entity.media_artist ~= "" then track = track .. " · " .. entity.media_artist end
    return state .. " · " .. track
  end
  return state
end

return M
