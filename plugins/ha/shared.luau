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
    local tablerName = override:match("^tabler:(.+)$")
    if tablerName and tablerName ~= "" then return tablerName end
    local mdiName = override:match("^mdi:(.+)$")
    if mdiName then return MDI_TO_TABLER[mdiName] or DOMAIN_GLYPHS[domain] or "smart-home" end
    -- HA integrations sometimes provide namespaced icons (for example
    -- `hue:bulb-classic-hung`). Those belong to HA's icon set, not
    -- Noctalia's glyph font. Fall back to the domain glyph so an
    -- integration-specific override cannot produce a missing-glyph warning.
    if override:match("^[%w_-]+:") then
      if domain == "light" then return M.isOn(state) and "bulb" or "bulb-off" end
      if domain == "fan" then return M.isOn(state) and "propeller" or "propeller-off" end
      return DOMAIN_GLYPHS[domain] or "smart-home"
    end
    return override
  end
  if domain == "light" then return M.isOn(state) and "bulb" or "bulb-off" end
  if domain == "fan" then return M.isOn(state) and "propeller" or "propeller-off" end
  return DOMAIN_GLYPHS[domain] or "smart-home"
end

local ON_STATES = {
  on = true, open = true, unlocked = true, home = true, playing = true,
  cleaning = true, detected = true, active = true, running = true,
  spinning = true, rinsing = true, reserved = true, rinse_hold = true,
  drying = true, detecting = true, steam_softening = true, cool_down = true,
  refreshing = true, pause = true,
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

local ACTIVITY_TRANSITION_STATES = {
  opening = true, closing = true, locking = true, unlocking = true,
  turning_on = true, turning_off = true, moving = true, pending = true,
}

-- Activity icons get a little more context than the normal entity color:
-- transitions use the theme's secondary color, failures/unavailability use
-- error, active/positive states use primary, and settled inactive states stay
-- muted. This keeps a timeline readable without assigning colors per domain.
function M.activityColorFor(state, message)
  local stateText = tostring(state or ""):lower()
  local messageText = tostring(message or ""):lower()
  local text = stateText ~= "" and stateText or messageText
  if text:find("unavailable", 1, true)
    or text:find("unknown", 1, true)
    or text:find("error", 1, true)
    or text:find("failed", 1, true)
    or text:find("fault", 1, true)
  then
    return "error"
  end
  if ACTIVITY_TRANSITION_STATES[stateText]
    or messageText:find("opening", 1, true)
    or messageText:find("closing", 1, true)
    or messageText:find("locking", 1, true)
    or messageText:find("unlocking", 1, true)
  then
    return "secondary"
  end
  if M.isOn(stateText) then return "primary" end
  return "on_surface_variant"
end

-- Use Home Assistant's current RGB color for active lights when available.
-- White-only lights and entities without an RGB attribute retain the normal
-- state color, as do off and unavailable lights.
function M.iconColor(entity)
  if M.domainOf(entity.entity_id) == "light" and M.isOn(entity.state) then
    local red = tonumber(entity.rgb)
    local green = tonumber(entity.rgb_g)
    local blue = tonumber(entity.rgb_b)
    if red ~= nil and green ~= nil and blue ~= nil then
      red = math.max(0, math.min(255, math.floor(red + 0.5)))
      green = math.max(0, math.min(255, math.floor(green + 0.5)))
      blue = math.max(0, math.min(255, math.floor(blue + 0.5)))
      return string.format("#%02x%02x%02x", red, green, blue)
    end
  end
  return M.colorFor(entity.state)
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

-- Home Assistant's FanEntityFeature.DIRECTION is bit 2 (value 4) in the
-- supported_features mask. Keep the control hidden for fans that cannot
-- accept fan.set_direction rather than relying on the presence of an
-- integration-specific direction attribute.
function M.fanSupportsDirection(entity)
  local features = tonumber(entity and entity.supported_features)
  return features ~= nil and math.floor(features / 4) % 2 == 1
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
  -- A cached search result may not have fetched the entity's live state yet.
  -- That is different from Home Assistant explicitly reporting unavailable.
  if entity.state ~= nil and M.isUnavailable(entity.state) then return "unavailable" end
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
  local unit = entity.unit_of_measurement
    or (type(entity.attributes) == "table" and entity.attributes.unit_of_measurement)
    or entity.unit
  if unit and unit ~= "" and state ~= "—" and not M.isUnavailable(state) then
    local unitStr = M.trim(tostring(unit))
    if unitStr ~= "" and not state:find(unitStr, 1, true) then
      local sep = (unitStr == "%") and "" or " "
      return state .. sep .. unitStr
    end
  end
  return state
end

local function isWordBoundary(str, pos)
  if pos <= 1 then return true end
  local b = string.byte(str, pos - 1)
  -- space (32), dot (46), underscore (95), hyphen (45), colon (58), slash (47)
  return b == 32 or b == 46 or b == 95 or b == 45 or b == 58 or b == 47
end

function M.prepareSearch(query)
  local q = M.trim(query):lower()
  if q == "" then return nil end
  local domain, remainder = q:match("^([%w_]+)%.(.*)$")
  if not domain then remainder = q end
  local terms = {}
  for term in remainder:gsub("[._-]", " "):gmatch("%S+") do
    terms[#terms + 1] = term
  end
  return {
    raw = q,
    domain = domain,
    remainder = remainder,
    terms = terms,
  }
end

function M.matchScore(entityId, name, section, state, pq)
  if type(pq) == "string" then
    pq = M.prepareSearch(pq)
  end
  if not pq then return nil end

  local eid = entityId and (entityId:match("%u") and entityId:lower() or entityId) or ""
  local nm = name and (name:match("%u") and name:lower() or name) or ""
  if pq.domain and M.domainOf(eid) ~= pq.domain then return nil end
  if #pq.terms == 0 then return 1 end

  -- 1. Full string exact match
  if (eid ~= "" and eid == pq.remainder) or (nm ~= "" and nm == pq.remainder) then
    return 10000 - #eid
  end

  -- 2. Exact prefix match
  if (eid ~= "" and eid:find(pq.remainder, 1, true) == 1) or (nm ~= "" and nm:find(pq.remainder, 1, true) == 1) then
    return 8000 - #nm
  end

  local sec = section and (section:match("%u") and section:lower() or section) or nil
  local st = state and (state:match("%u") and state:lower() or state) or nil

  local totalScore = 4000
  for i = 1, #pq.terms do
    local term = pq.terms[i]
    local pName = nm ~= "" and nm:find(term, 1, true)
    if pName then
      local score = 600 - pName
      if isWordBoundary(nm, pName) then score = score + 200 end
      totalScore = totalScore + score
    else
      local pEid = eid ~= "" and eid:find(term, 1, true)
      if pEid then
        local score = 450 - pEid
        if isWordBoundary(eid, pEid) then score = score + 150 end
        totalScore = totalScore + score
      else
        local pSec = sec and sec:find(term, 1, true)
        if pSec then
          local score = 300 - pSec
          if isWordBoundary(sec, pSec) then score = score + 100 end
          totalScore = totalScore + score
        else
          local pSt = st and st:find(term, 1, true)
          if pSt then
            totalScore = totalScore + (200 - pSt)
          else
            return nil
          end
        end
      end
    end
  end

  totalScore = totalScore - (#nm + #eid) * 0.1
  return totalScore
end

local ACTIONABLE_DOMAINS = {
  light = true, switch = true, input_boolean = true, input_button = true,
  button = true, cover = true, climate = true, fan = true, lock = true,
  media_player = true, vacuum = true, scene = true, script = true,
  automation = true,
}

function M.actionabilityRank(entityId)
  local domain = M.domainOf(entityId or "")
  if ACTIONABLE_DOMAINS[domain] then return 0 end
  if domain == "sensor" or domain == "binary_sensor" then return 2 end
  return 1
end

-- Fuzzy relevance scoring for entities across their ID, friendly name,
-- section/area, and state/status. Returns a positive score (higher = better
-- match), or nil if query does not match.
function M.fuzzyScore(target, query)
  local pq = type(query) == "table" and query or M.prepareSearch(query)
  if not pq then return 1 end

  local entityId, name, section, state
  if type(target) == "table" then
    entityId = target.entity_id or target._eid_lower
    name = target.name or target.friendly_name or target._name_lower
    section = target.section
    state = target.display_state or target.state or (type(target.statusText) == "string" and target.statusText)
  elseif type(target) == "string" then
    entityId = target
    name = target
  end

  return M.matchScore(entityId, name, section, state, pq)
end

function M.fuzzyMatch(target, query)
  return M.fuzzyScore(target, query) ~= nil
end

function M.isNumericEntity(entity)
  if type(entity) ~= "table" then return false end
  local entityId = type(entity.entity_id) == "string" and entity.entity_id or ""
  local domain = M.domainOf(entityId)
  if domain == "sensor" or domain == "number" or domain == "input_number" or domain == "counter" then
    return true
  end
  if tonumber(entity.state) ~= nil then
    return true
  end
  if entity.unit_of_measurement ~= nil and entity.unit_of_measurement ~= "" then
    return true
  end
  local attrs = entity.attributes
  if type(attrs) == "table" and (attrs.unit_of_measurement ~= nil or attrs.state_class ~= nil) then
    return true
  end
  return false
end

return M
