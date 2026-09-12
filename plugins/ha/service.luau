--!nonstrict
-- Every Home Assistant request this service makes is scoped to a bounded set
-- of entities -- either the user's own configured handful, or one page of a
-- domain-filtered browse -- and never the instance's full entity list. See
-- plugin.toml's browser_page_size comment for why: a whole-instance
-- `/api/states` dump is both rejected by HA's own template output-length cap
-- and, when it isn't, too large for Noctalia to decode in one script tick on
-- an instance with several thousand entities.

local shared = require("./shared.luau")
local layoutFile = require("./layout.luau")
local generation = 0

local function readSecret(setting)
  local path = shared.trim(noctalia.getConfig(setting))
  if path == "" then return nil, "not configured" end
  local content, err = noctalia.readFile(path)
  local value = content and shared.trim(content) or ""
  if value == "" then return nil, err or "empty or unreadable" end
  return value
end

local function credentials()
  local server, serverErr = readSecret("server_file")
  local token, tokenErr = readSecret("token_file")
  if not server or not token then
    return nil, nil, "Home Assistant " .. (serverErr or tokenErr or "credentials are unavailable")
  end
  return (server:gsub("/+$", "")), token, nil
end

local function haRequest(server, token, body, callback)
  local started = noctalia.http({
    url = server .. "/api/template",
    method = "POST",
    headers = { "Authorization: Bearer " .. token, "Content-Type: application/json" },
    body = noctalia.json.encode({ template = body }),
    allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
  }, callback)
  return started
end

-- ── Layout persistence ───────────────────────────────────────────────────────
-- The config file is declarative and read-only from the plugin's point of
-- view. The state file is the writable overlay, just like Noctalia's own
-- config.toml/settings.toml split. Once the panel changes anything, the state
-- file becomes authoritative until it is removed, allowing a user to try
-- changes in the panel without mutating a Home Manager-managed config file.
local CONFIG_FILE = "ha.yaml"
local STATE_FILE = "layout.yaml"

local configuredEntities = {}
local sections = {}
local labels = {}
local icons = {}
local entityConditions = {}
local entityRemotes = {}
local panelControls = {}
local domainControls = {}
local stateAttributes = {}
local stateTemplates = {}
local favoritePositions = {}
local barTargetEntity = nil
local barActions = {}
local currentRows = {}
local entityCacheRows = {}
local entityCacheScanRows = nil
local entityCacheOffset = 0
local entityCacheGeneration = 0
local entityCacheRequestActive = false
local entityCacheComplete = false
local entityCacheRefreshAt = 0
local activeDetailsEntityId = nil
local cameraImagePaths = {}
local cameraRequestGeneration = {}
local detailsRequestGeneration = 0
local logbookRequestGeneration = 0
local lastLogbookEntityId = nil
local lastLogbookFetchedAt = 0
local fetchDetails
local cacheEntityPage
local intervalMs
-- A details page is deliberately more eager than the normal bar refresh:
-- controls should settle visibly within a couple of seconds after a service
-- call, while the regular interval remains relaxed when no details page is open.
local DETAILS_REFRESH_INTERVAL_MS = 2000

local function xdgPath(variable, fallback)
  local value = noctalia.getenv(variable)
  if type(value) ~= "string" or value == "" then value = noctalia.getenv("HOME") .. fallback end
  return value
end

local function configPath()
  return xdgPath("XDG_CONFIG_HOME", "/.config") .. "/noctalia/" .. CONFIG_FILE
end

local function statePath()
  local dir, err = noctalia.pluginDataDir()
  if not dir then
    noctalia.log("ha: cannot resolve plugin data dir: " .. tostring(err))
    return nil
  end
  return dir .. "/" .. STATE_FILE
end

local function emptyLayout()
  return { entities = {}, sections = {}, labels = {}, icons = {}, entity_remotes = {}, panel_controls = {}, domain_controls = {}, state_attributes = {}, state_templates = {}, favorite_positions = {}, bar_target = nil, bar_actions = {} }
end

local function readLayout(path)
  local data = path and noctalia.readFile(path)
  if not data or data == "" then return nil end
  local parsed = layoutFile.parse(data)
  return type(parsed) == "table" and parsed or nil
end

local function publishLayout()
  noctalia.state.set("ha.configured", configuredEntities)
  noctalia.state.set("ha.sections", sections)
  noctalia.state.set("ha.entity_remotes", entityRemotes)
  noctalia.state.set("ha.panel_controls", panelControls)
  noctalia.state.set("ha.domain_controls", domainControls)
  noctalia.state.set("ha.favorite_positions", favoritePositions)
  noctalia.state.set("ha.bar_target", barTargetEntity)
  noctalia.state.set("ha.bar_actions", barActions)
end

local function applyLayout(layout)
  configuredEntities = layout.entities or {}
  sections = layout.sections or {}
  labels = layout.labels or {}
  icons = layout.icons or {}
  entityConditions = layout.entity_conditions or {}
  entityRemotes = layout.entity_remotes or {}
  panelControls = layout.panel_controls or {}
  domainControls = layout.domain_controls or {}
  stateAttributes = layout.state_attributes or {}
  stateTemplates = layout.state_templates or {}
  favoritePositions = layout.favorite_positions or {}
  barTargetEntity = layout.bar_target
  barActions = layout.bar_actions or {}
  publishLayout()
end

local function currentLayout()
  return {
    entities = configuredEntities,
    entity_conditions = entityConditions,
    sections = sections,
    labels = labels,
    icons = icons,
    entity_remotes = entityRemotes,
    panel_controls = panelControls,
    domain_controls = domainControls,
    state_attributes = stateAttributes,
    state_templates = stateTemplates,
    favorite_positions = favoritePositions,
    bar_target = barTargetEntity,
    bar_actions = barActions,
  }
end

local function saveLayout()
  local path = statePath()
  if not path then return false end
  local ok, writeErr = noctalia.writeFile(path, layoutFile.serialize(currentLayout()))
  if not ok then
    noctalia.log("ha: failed to save layout: " .. tostring(writeErr))
    return false
  end
  publishLayout()
  return true
end

local function hasEntity(entityId)
  for _, id in ipairs(configuredEntities) do
    if id == entityId then return true end
  end
  return false
end

local function conditionEntityIds()
  local ids = {}
  for _, condition in pairs(entityConditions) do
    if type(condition) == "table" and type(condition.entity) == "string" then
      ids[condition.entity] = true
    end
  end
  for _, section in ipairs(sections) do
    local condition = section.when
    if type(condition) == "table" and type(condition.entity) == "string" then
      ids[condition.entity] = true
    end
  end
  return ids
end

local function queryIds()
  local ids = {}
  for _, entityId in ipairs(configuredEntities) do ids[entityId] = true end
  for entityId in pairs(conditionEntityIds()) do ids[entityId] = true end
  local ordered = {}
  for entityId in pairs(ids) do ordered[#ordered + 1] = entityId end
  table.sort(ordered)
  return ordered
end

local function stateMatches(actual, expected)
  if type(expected) == "table" then
    for _, candidate in ipairs(expected) do
      if tostring(actual or "") == tostring(candidate) then return true end
    end
    return false
  end
  return tostring(actual or "") == tostring(expected)
end

local function conditionMatches(condition, states)
  if type(condition) ~= "table" or type(condition.entity) ~= "string" or condition.state == nil then
    return true
  end
  local record = states[condition.entity]
  local state = record
  if type(record) == "table" then state = record.state end
  local matches = stateMatches(state, condition.state)
  if condition["not"] == true then matches = not matches end
  if not matches then return false end

  local duration = condition["for"]
  if duration == nil then return true end
  local seconds
  if type(duration) == "number" then
    seconds = duration
  else
    local text = shared.trim(duration)
    local hours, minutes, remainder = text:match("^(%d+):(%d+):(%d+)$")
    if hours then
      seconds = tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(remainder)
    else
      local simpleMinutes, simpleSeconds = text:match("^(%d+):(%d+)$")
      if simpleMinutes then
        seconds = tonumber(simpleMinutes) * 60 + tonumber(simpleSeconds)
      else
        seconds = tonumber(text)
      end
    end
  end
  if not seconds or seconds <= 0 then return true end
  local changedAt = type(record) == "table" and tonumber(record.last_changed) or nil
  return changedAt ~= nil and os.time() - changedAt >= seconds
end

local function loadLayout()
  -- State wins over config. This is intentional: it mirrors Noctalia's own
  -- runtime overrides and means declarative changes take effect after the
  -- state overlay is removed.
  local layout = readLayout(statePath()) or readLayout(configPath())
  if layout then
    applyLayout(layout)
    return
  end
  applyLayout(emptyLayout())
end

-- ── Status refresh (the bar + "My entities" panel view) ────────────────────
-- One /api/template call naming exactly the configured entities, however few
-- or many that is -- never the full states table. Tab/newline delimited
-- rather than JSON: it sidesteps depending on Jinja's `tojson` filter (flaky
-- across HA versions/configs) and needs no per-field escaping beyond
-- flattening the delimiters themselves, same trick pozzoo/hassio's own
-- (working) id-list template used.
local function quoteJinja(value)
  return "'" .. tostring(value):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

-- brightness (light, 0-255), percentage (fan, 0-100), oscillating (fan),
-- current_position (cover, 0-100), icon, supported features, media-player metadata,
-- color capabilities and last_changed
-- (for duration-based conditions) ride along on every status query so the
-- panel can draw sliders, transport controls and a richer subtitle without a
-- second request per entity.
-- brightness/percentage are only ever present on an entity that is
-- currently on and does support them, which is exactly the condition
-- panel.luau's brightnessSlider()/fanSlider() gate on; current_position is
-- independent of on/off (a cover reports it whatever state it's in).
local function statusTemplate(ids)
  local quoted = {}
  for _, id in ipairs(ids) do
    quoted[#quoted + 1] = quoteJinja(id)
  end
  local list = "[" .. table.concat(quoted, ",") .. "]"
  local rows = {}
  for _, id in ipairs(ids) do
    local displayAttribute = stateAttributes[id]
    local displayTemplate = stateTemplates[id]
    local displayExpression
    if displayTemplate and displayTemplate ~= "" then
      -- Accept the familiar HA `{{ expression }}` form, while also allowing
      -- the expression body by itself. This deliberately supports expression
      -- templates, not block statements, so the result can stay one bounded
      -- tab-delimited field in the combined response.
      local expression = displayTemplate:match("^%s*{{(.-)}}%s*$") or displayTemplate
      displayExpression = "(" .. expression .. ")"
    else
      displayExpression = displayAttribute and ("state_attr(id," .. quoteJinja(displayAttribute) .. ") or states(id)") or "states(id)"
    end
    rows[#rows + 1] = "{% if id == " .. quoteJinja(id) .. " %}"
      .. "{{ id }}\t{{ states(id) }}\t"
      .. "{{ (state_attr(id,'friendly_name') or id) | replace('\\t',' ') | replace('\\n',' ') }}\t"
      .. "{{ (" .. displayExpression .. ") | string | replace('\\t',' ') | replace('\\n',' ') }}\t"
      .. "{{ state_attr(id,'brightness') or '' }}\t{{ state_attr(id,'percentage') or '' }}\t"
      .. "{{ state_attr(id,'current_position') or '' }}\t{{ state_attr(id,'volume_level') or '' }}\t"
      .. "{{ state_attr(id,'is_volume_muted') or '' }}\t"
      .. "{{ (state_attr(id,'media_title') or '') | string | replace('\\t',' ') | replace('\\n',' ') }}\t"
      .. "{{ (state_attr(id,'media_artist') or '') | string | replace('\\t',' ') | replace('\\n',' ') }}\t"
      .. "{{ state_attr(id,'rgb_color')[0] if state_attr(id,'rgb_color') else '' }}\t"
      .. "{{ state_attr(id,'rgb_color')[1] if state_attr(id,'rgb_color') else '' }}\t"
      .. "{{ state_attr(id,'rgb_color')[2] if state_attr(id,'rgb_color') else '' }}\t"
      .. "{{ as_timestamp(states[id].last_changed) if states[id] else '' }}\t"
      .. "{{ state_attr(id,'oscillating') if state_attr(id,'oscillating') is not none else '' }}\t"
      .. "{{ state_attr(id,'supported_features') or '' }}\t"
      .. "{{ state_attr(id,'icon') or '' }}\t"
      .. "{{ (state_attr(id,'supported_color_modes') or []) | join(',') }}\t"
      .. "{{ state_attr(id,'color_temp_kelvin') or '' }}\t"
      .. "{{ state_attr(id,'min_color_temp_kelvin') or '' }}\t"
      .. "{{ state_attr(id,'max_color_temp_kelvin') or '' }}\n{% endif %}"
  end
  return "{% for id in " .. list .. " %}" .. table.concat(rows) .. "{% endfor %}"
end

-- Home Assistant strips trailing whitespace off the *end of the whole
-- response*, not per line -- verified live: of two entities in one request,
-- only the last one (whose trailing brightness/percentage/position fields
-- are all empty, the common case) loses its trailing tabs entirely. A fixed
-- tab-count match() fails outright on that shortened last line, silently
-- dropping that entity from every refresh. Split field-by-field instead and
-- pad any missing trailing fields with "" so a short line still parses.
local function splitFields(line, count)
  local fields = {}
  local start = 1
  for i = 1, count - 1 do
    local tabPos = line:find("\t", start, true)
    if not tabPos then
      fields[i] = line:sub(start)
      for j = i + 1, count do fields[j] = "" end
      return fields
    end
    fields[i] = line:sub(start, tabPos - 1)
    start = tabPos + 1
  end
  fields[count] = line:sub(start)
  return fields
end

local function parseStatusResponse(body)
  local rows = {}
  for line in tostring(body or ""):gmatch("[^\n]+") do
    local f = splitFields(line, 22)
    local id = f[1]
    if id and id ~= "" then
      local oscillating
      if f[16] ~= "" then oscillating = f[16]:lower() == "true" end
      rows[#rows + 1] = {
        entity_id = id,
        state = f[2],
        name = (f[3] ~= "" and f[3] or id),
        display_state = (f[4] ~= "" and f[4] or f[2]),
        brightness = f[5] ~= "" and tonumber(f[5]) or nil,
        percentage = f[6] ~= "" and tonumber(f[6]) or nil,
        position = f[7] ~= "" and tonumber(f[7]) or nil,
        volume_level = f[8] ~= "" and tonumber(f[8]) or nil,
        volume_muted = f[9]:lower() == "true",
        media_title = f[10],
        media_artist = f[11],
        remote = entityRemotes[id],
        rgb = f[12] ~= "" and tonumber(f[12]) or nil,
        rgb_g = f[13] ~= "" and tonumber(f[13]) or nil,
        rgb_b = f[14] ~= "" and tonumber(f[14]) or nil,
        last_changed = f[15] ~= "" and tonumber(f[15]) or nil,
        oscillating = oscillating,
        panel_controls = panelControls[id] or domainControls[shared.domainOf(id)],
        supported_features = f[17] ~= "" and tonumber(f[17]) or nil,
        icon = f[18] ~= "" and f[18] or nil,
        supported_color_modes = f[19] ~= "" and f[19] or nil,
        color_temp_kelvin = f[20] ~= "" and tonumber(f[20]) or nil,
        min_color_temp_kelvin = f[21] ~= "" and tonumber(f[21]) or nil,
        max_color_temp_kelvin = f[22] ~= "" and tonumber(f[22]) or nil,
      }
    end
  end
  return rows
end

local function publishError(message)
  noctalia.state.set("ha.error", message)
  noctalia.state.set("ha.refreshing", false)
end

local function refresh()
  local server, token, err = credentials()
  if err then
    publishError(err)
    return
  end
  if cacheEntityPage then cacheEntityPage(false) end
  if #configuredEntities == 0 then
    noctalia.state.set("ha.entities", {})
    noctalia.state.set("ha.hidden", {})
    noctalia.state.set("ha.section_visibility", {})
    noctalia.state.set("ha.error", "")
    noctalia.state.set("ha.refreshing", false)
    return
  end

  generation += 1
  local myGeneration = generation
  noctalia.state.set("ha.refreshing", true)

  local started = haRequest(server, token, statusTemplate(queryIds()), function(response)
    if myGeneration ~= generation then return end
    noctalia.state.set("ha.refreshing", false)
    if not response.ok or response.status ~= 200 then
      publishError("Home Assistant status query failed (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local allRows = parseStatusResponse(response.body)
    local byId = {}
    for _, row in ipairs(allRows) do byId[row.entity_id] = row end
    currentRows = byId

    local sectionVisibility = {}
    local sectionHiddenEntities = {}
    for index, section in ipairs(sections) do
      sectionVisibility[index] = conditionMatches(section.when, byId)
      if not sectionVisibility[index] then
        for _, entityId in ipairs(section.entities or {}) do
          sectionHiddenEntities[entityId] = true
        end
      end
    end

    local visibleRows = {}
    local hidden = {}
    for _, entityId in ipairs(configuredEntities) do
      local row = byId[entityId]
      local visible = conditionMatches(entityConditions[entityId], byId) and not sectionHiddenEntities[entityId]
      if row and visible then
        local override = labels[entityId]
        if override and override ~= "" then row.name = override end
        local icon = icons[entityId]
        if icon and icon ~= "" then row.icon = icon end
        visibleRows[#visibleRows + 1] = row
      elseif not visible then
        hidden[entityId] = true
      end
    end

    noctalia.state.set("ha.entities", visibleRows)
    noctalia.state.set("ha.hidden", hidden)
    noctalia.state.set("ha.section_visibility", sectionVisibility)
    noctalia.state.set("ha.error", "")
    noctalia.state.set("ha.refreshed_at", os.time())
  end)
  if not started then
    publishError("Could not start Home Assistant status query")
  end
end

local function renameEntity(entityId, label)
  if type(entityId) ~= "string" or entityId == "" then return end
  label = shared.trim(label)
  -- Empty clears the override rather than storing a blank label, so the
  -- entity falls back to Home Assistant's own friendly_name again.
  labels[entityId] = label ~= "" and label or nil
  saveLayout()
  refresh()
end

-- ── Service calls: toggle, cover open/stop/close, brightness, fan speed ─────

local function callService(domain, service, entityId, extraData)
  if type(entityId) ~= "string" or entityId == "" then return end
  local server, token, err = credentials()
  if err then
    publishError(err)
    return
  end
  local payload = { entity_id = entityId }
  if type(extraData) == "table" then
    for k, v in pairs(extraData) do payload[k] = v end
  end
  local started = noctalia.http({
    url = server .. "/api/services/" .. domain .. "/" .. service,
    method = "POST",
    headers = { "Authorization: Bearer " .. token, "Content-Type: application/json" },
    body = noctalia.json.encode(payload),
    allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
  }, function(response)
    if not response.ok then
      publishError(domain .. "." .. service .. " failed for " .. entityId .. " (HTTP " .. tostring(response.status) .. ")")
    end
    refresh()
    if activeDetailsEntityId then fetchDetails(activeDetailsEntityId) end
  end)
  if not started then
    publishError("Could not start " .. domain .. "." .. service .. " request for " .. entityId)
  end
end

local function toggleEntity(entityId)
  callService("homeassistant", "toggle", entityId)
end

-- The runtime only takes a command *line*, so the URL has to be shell-quoted
-- by hand. gio, not xdg-open: with XDG_CURRENT_DESKTOP=KDE (set for Qt
-- theming under niri) but no KDE session, xdg-open takes the kfmclient path
-- and no-ops with exit 0; gio resolves the x-scheme-handler/http default
-- directly. Ported from pschmitt/ha-ai-usage's service.luau, which solved
-- this same problem for its own "open in Home Assistant" button.
local function shq(value)
  local quoted = tostring(value or ""):gsub("'", "'\\''")
  return "'" .. quoted .. "'"
end

local function openDashboard()
  local server, serverErr = readSecret("server_file")
  if not server then
    publishError("Home Assistant " .. (serverErr or "credentials are unavailable"))
    return
  end
  local path = shared.trim(noctalia.getConfig("panel_dashboard_path"))
  if path == "" then path = "/" end
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  local url = shq(server:gsub("/+$", "") .. path)
  noctalia.runAsync("gio open " .. url .. " || xdg-open " .. url, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("ha: open dashboard failed: " .. shared.trim(result.stderr))
    end
  end, 10000)
end

local function openCameraStream(entityId)
  if shared.domainOf(entityId) ~= "camera" then return end
  local server, token, err = credentials()
  if err then
    publishError(err)
    return
  end

  local encodedEntityId = tostring(entityId):gsub("([^%w%._%-])", function(character)
    return string.format("%%%02X", string.byte(character))
  end)
  local url = server:gsub("/+$", "") .. "/api/camera_proxy_stream/" .. encodedEntityId
  local header = "Authorization: Bearer " .. token
  -- VLC handles HA's multipart MJPEG response as a sequence of frames. Keep
  -- this path first: mpv's current libavformat integration can display the
  -- first JPEG part and then wait forever on this particular live response.
  if noctalia.commandExists("vlc") and noctalia.commandExists("curl") then
    local command = "curl --fail --silent --show-error --no-buffer --location --header " .. shq(header) .. " " .. shq(url) .. " | vlc --demux=mjpeg -"
    local started = noctalia.runAsync(command)
    if not started then noctalia.notifyError("Camera stream", "Could not start VLC") end
    return
  end

  if noctalia.commandExists("mpv") then
    -- HA exposes this endpoint as multipart/x-mixed-replace. Force mpv to
    -- use its MJPEG demuxer and disable caching for installations without
    -- VLC. Some mpv/FFmpeg combinations still only render the first part.
    local started = noctalia.runAsync({
      "mpv",
      "--force-window=yes",
      "--cache=no",
      "--demuxer=lavf",
      "--demuxer-lavf-format=mpjpeg",
      "--http-header-fields=" .. header,
      url,
    })
    if not started then noctalia.notifyError("Camera stream", "Could not start mpv") end
    return
  end

  noctalia.notifyError("Camera stream", "Install mpv or VLC (and curl for the VLC fallback)")
end

local COVER_SERVICES = { open = "open_cover", close = "close_cover", stop = "stop_cover" }

local function coverCommand(entityId, command)
  local service = COVER_SERVICES[command]
  if not service then return end
  callService("cover", service, entityId)
end

-- brightness arrives as 0-255 (Home Assistant's own scale for light.turn_on)
-- so the panel's 0-100% slider converts before sending it here.
local function setBrightness(entityId, brightness)
  local value = math.floor((tonumber(brightness) or 0) + 0.5)
  callService("light", "turn_on", entityId, { brightness = math.max(0, math.min(255, value)) })
end

local function setLightColor(entityId, color)
  if type(color) ~= "table" then return end
  local rgb = {}
  for index = 1, 3 do
    local value = tonumber(color[index])
    if value == nil then return end
    rgb[index] = math.max(0, math.min(255, math.floor(value + 0.5)))
  end
  callService("light", "turn_on", entityId, { rgb_color = rgb })
end

local function setLightColorTemperature(entityId, kelvin)
  local value = math.floor((tonumber(kelvin) or 0) + 0.5)
  if value <= 0 then return end
  callService("light", "turn_on", entityId, { color_temp_kelvin = value })
end

local function setFanPercentage(entityId, percentage)
  local value = math.floor((tonumber(percentage) or 0) + 0.5)
  callService("fan", "set_percentage", entityId, { percentage = math.max(0, math.min(100, value)) })
end

local function setFanOscillation(entityId, oscillating)
  if type(oscillating) ~= "boolean" then return end
  callService("fan", "oscillate", entityId, { oscillating = oscillating })
end

local function setFanDirection(entityId, direction)
  direction = tostring(direction or ""):lower()
  if direction ~= "forward" and direction ~= "reverse" then return end
  callService("fan", "set_direction", entityId, { direction = direction })
end

local LOCK_SERVICES = { lock = "lock", unlock = "unlock", open = "open" }

local function lockCommand(entityId, command)
  local service = LOCK_SERVICES[command]
  if not service then return end
  callService("lock", service, entityId)
end

local MEDIA_SERVICES = {
  play_pause = "media_play_pause",
}

local function mediaCommand(entityId, command, value)
  if command == "volume_set" then
    local volume = tonumber(value)
    if volume == nil then return end
    callService("media_player", "volume_set", entityId, { volume_level = math.max(0, math.min(1, volume)) })
    return
  end
  if command == "volume_mute" then
    callService("media_player", "volume_mute", entityId, { is_volume_muted = value == true })
    return
  end
  if command == "power" then
    callService("homeassistant", "toggle", entityId)
    return
  end
  local service = MEDIA_SERVICES[command]
  if service then callService("media_player", service, entityId) end
end

-- Bar control actions use short aliases for the common domain-aware actions;
-- a literal `domain.service` value is also accepted as an override. The
-- latter deliberately carries no extra service data, keeping the layout
-- syntax small while still allowing any Home Assistant service to be used.
local function barService(entityId, action)
  if type(entityId) ~= "string" or entityId == "" or type(action) ~= "string" then return end
  local domain = shared.domainOf(entityId)
  if action == "toggle" then
    toggleEntity(entityId)
  elseif action == "brightness_up" and domain == "light" then
    callService("light", "turn_on", entityId, { brightness_step_pct = 10 })
  elseif action == "brightness_down" and domain == "light" then
    callService("light", "turn_on", entityId, { brightness_step_pct = -10 })
  elseif action == "volume_up" and domain == "media_player" then
    callService("media_player", "volume_up", entityId)
  elseif action == "volume_down" and domain == "media_player" then
    callService("media_player", "volume_down", entityId)
  elseif action == "play_pause" and domain == "media_player" then
    callService("media_player", "media_play_pause", entityId)
  elseif action == "percentage_up" and domain == "fan" then
    local percentage = currentRows[entityId] and tonumber(currentRows[entityId].percentage)
    if percentage ~= nil then setFanPercentage(entityId, percentage + 10) end
  elseif action == "percentage_down" and domain == "fan" then
    local percentage = currentRows[entityId] and tonumber(currentRows[entityId].percentage)
    if percentage ~= nil then setFanPercentage(entityId, percentage - 10) end
  else
    local serviceDomain, service = action:match("^([%w_]+)%.([%w_]+)$")
    if serviceDomain and service then callService(serviceDomain, service, entityId) end
  end
end

-- Panel control overrides use the same literal `domain.service` form as bar
-- overrides, but may also carry a small JSON object as service data.
local function panelService(entityId, serviceName, data)
  if type(entityId) ~= "string" or entityId == "" or type(serviceName) ~= "string" then return end
  local serviceDomain, service = serviceName:match("^([%w_]+)%.([%w_]+)$")
  if serviceDomain and service then
    callService(serviceDomain, service, entityId, type(data) == "table" and data or nil)
  end
end

local REMOTE_COMMANDS = {
  up = "DPAD_UP",
  down = "DPAD_DOWN",
  left = "DPAD_LEFT",
  right = "DPAD_RIGHT",
  select = "DPAD_CENTER",
  home = "HOME",
  back = "BACK",
}

local function remoteCommand(remoteId, command)
  local remoteCommandName = REMOTE_COMMANDS[command]
  if not remoteCommandName then return end
  callService("remote", "send_command", remoteId, { command = remoteCommandName })
end

-- ── Add / remove ─────────────────────────────────────────────────────────────

local function addEntity(entityId)
  entityId = shared.trim(entityId)
  if entityId == "" or hasEntity(entityId) then return end
  table.insert(configuredEntities, entityId)
  saveLayout()
  refresh()
end

local function removeEntity(entityId)
  local newList = {}
  for _, id in ipairs(configuredEntities) do
    if id ~= entityId then table.insert(newList, id) end
  end
  configuredEntities = newList
  for _, section in ipairs(sections) do
    local kept = {}
    for _, id in ipairs(section.entities or {}) do
      if id ~= entityId then kept[#kept + 1] = id end
    end
    section.entities = kept
  end
  if labels[entityId] ~= nil then
    labels[entityId] = nil
  end
  if icons[entityId] ~= nil then
    icons[entityId] = nil
  end
  if stateAttributes[entityId] ~= nil then
    stateAttributes[entityId] = nil
  end
  if stateTemplates[entityId] ~= nil then
    stateTemplates[entityId] = nil
  end
  if entityRemotes[entityId] ~= nil then
    entityRemotes[entityId] = nil
  end
  if favoritePositions[entityId] ~= nil then
    favoritePositions[entityId] = nil
  end
  if barTargetEntity == entityId then
    barTargetEntity = nil
    barActions = {}
  end
  saveLayout()
  refresh()
end

local function reorderList(list, value, direction)
  local index
  for i, candidate in ipairs(list) do
    if candidate == value then
      index = i
      break
    end
  end
  if not index then return false end
  local target = index + direction
  if target < 1 or target > #list then return false end
  list[index], list[target] = list[target], list[index]
  return true
end

local function sectionIndexOf(entityId)
  for index, section in ipairs(sections) do
    for _, id in ipairs(section.entities or {}) do
      if id == entityId then return index end
    end
  end
  return 0
end

local function reorderEntity(entityId, direction)
  local sectionIndex = sectionIndexOf(entityId)
  local changed = false
  if sectionIndex > 0 then
    changed = reorderList(sections[sectionIndex].entities, entityId, direction)
  else
    -- configuredEntities also contains section members, so exchange only
    -- with the neighbouring section-less entity. This keeps section order
    -- independent from the top-level selection list.
    local positions = {}
    for index, id in ipairs(configuredEntities) do
      if sectionIndexOf(id) == 0 then positions[#positions + 1] = index end
    end
    local current
    for position, index in ipairs(positions) do
      if configuredEntities[index] == entityId then
        current = position
        break
      end
    end
    local target = current and (current + direction) or nil
    if target and positions[target] then
      local index = positions[current]
      local targetIndex = positions[target]
      configuredEntities[index], configuredEntities[targetIndex] = configuredEntities[targetIndex], configuredEntities[index]
      changed = true
    end
  end
  if changed then
    saveLayout()
    refresh()
  end
end

local function moveEntity(entityId, targetSection)
  targetSection = tonumber(targetSection) or 0
  if targetSection < 0 or targetSection > #sections then return end
  for _, section in ipairs(sections) do
    local kept = {}
    for _, id in ipairs(section.entities or {}) do
      if id ~= entityId then kept[#kept + 1] = id end
    end
    section.entities = kept
  end
  if targetSection > 0 then
    table.insert(sections[targetSection].entities, entityId)
  end
  saveLayout()
  refresh()
end

local function removeAll(list, value)
  local kept = {}
  for _, candidate in ipairs(list) do
    if candidate ~= value then kept[#kept + 1] = candidate end
  end
  for index = #list, 1, -1 do list[index] = nil end
  for _, candidate in ipairs(kept) do list[#list + 1] = candidate end
end

local function insertBeforeOrAppend(list, value, before)
  if before and before ~= "" then
    for index, candidate in ipairs(list) do
      if candidate == before then
        table.insert(list, index, value)
        return
      end
    end
  end
  table.insert(list, value)
end

local function dropEntity(entityId, targetSection, beforeEntity)
  targetSection = tonumber(targetSection) or 0
  if type(entityId) ~= "string" or entityId == "" or targetSection < 0 or targetSection > #sections then return end

  -- The panel sends an insertion target rather than a numeric position. That
  -- keeps a drop correct when hidden/conditional rows are interspersed and
  -- also handles moving across sections without index adjustment.
  for _, section in ipairs(sections) do removeAll(section.entities, entityId) end
  if targetSection > 0 then
    insertBeforeOrAppend(sections[targetSection].entities, entityId, beforeEntity)
  else
    removeAll(configuredEntities, entityId)
    insertBeforeOrAppend(configuredEntities, entityId, beforeEntity)
  end
  saveLayout()
  refresh()
end

local function reorderSection(index, direction)
  index = tonumber(index)
  direction = tonumber(direction)
  if not index or not direction then return end
  local target = index + direction
  if index < 1 or target < 1 or target > #sections then return end
  sections[index], sections[target] = sections[target], sections[index]
  saveLayout()
  refresh()
end

local function renameSection(index, name)
  index = tonumber(index)
  name = shared.trim(name)
  if not index or not sections[index] or name == "" then return end
  sections[index].name = name
  saveLayout()
  refresh()
end

local function addSection(name)
  name = shared.trim(name)
  if name == "" then return end
  sections[#sections + 1] = { name = name, collapsed = false, entities = {} }
  saveLayout()
  refresh()
end

local function dropSection(fromIndex, targetIndex)
  fromIndex = tonumber(fromIndex)
  targetIndex = tonumber(targetIndex)
  if not fromIndex or not targetIndex or fromIndex < 1 or fromIndex > #sections then return end
  if targetIndex < 1 or targetIndex > #sections + 1 then return end
  local section = table.remove(sections, fromIndex)
  if fromIndex < targetIndex then targetIndex = targetIndex - 1 end
  table.insert(sections, math.max(1, math.min(targetIndex, #sections + 1)), section)
  saveLayout()
  refresh()
end

-- ── Browse (paginated, optionally domain- and area-scoped) ──────────────────
-- `domain` only ever reaches this function as one of shared.BROWSABLE_DOMAINS
-- (the panel only offers those as chips) or "all"/nil, and is checked against
-- that same list again here before being spliced into the template as
-- `states.<domain>` -- belt and braces against a hand-edited settings.toml or
-- a future caller passing something unexpected through.
local function browseSource(domain)
  if type(domain) == "string" and shared.isKnownDomain(domain) then
    return "states." .. domain
  end
  return "states"
end

local function pageSize()
  local n = tonumber(shared.config("browser_page_size", 200)) or 200
  -- Kept in step with plugin.toml's browser_page_size max (250): Noctalia
  -- silently drops a ui node's children past 256, and each result row is one.
  return math.max(50, math.min(250, n))
end

-- Areas come from Home Assistant's own area registry (see listAreas() below),
-- not a fixed whitelist like domains -- quoteJinja() is what keeps an area id
-- from breaking out of the template if it ever contained something odd.
--
-- area_entities() returns plain entity_id strings, not State objects, so
-- this branch looks up each one's name via state_attr() instead of the
-- `states`/`states.<domain>` branch's s.name -- the two sources don't share
-- a common item shape, hence the two different for-loop bodies below rather
-- than one shared template for both.
local function browseTemplate(domain, area, offset, limit)
  local slice = "[" .. offset .. ":" .. (offset + limit) .. "]"
  if type(area) == "string" and area ~= "" and area ~= "all" then
    local source = "area_entities(" .. quoteJinja(area) .. ")"
    if type(domain) == "string" and shared.isKnownDomain(domain) then
      source = source .. " | select('match', '^" .. domain .. "\\\\.')"
    end
    return "{% for id in (" .. source .. " | sort | list)" .. slice .. " %}"
      .. "{{ id }}\t{{ (state_attr(id,'friendly_name') or id) | replace('\\t',' ') | replace('\\n',' ') }}\n"
      .. "{% endfor %}"
  end
  local source = browseSource(domain)
  return "{% for s in (" .. source .. " | sort(attribute='entity_id') | list)" .. slice .. " %}"
    .. "{{ s.entity_id }}\t{{ (s.name or s.entity_id) | replace('\\t',' ') | replace('\\n',' ') }}\n"
    .. "{% endfor %}"
end

-- Keep a bounded cache of Home Assistant's state-backed entity list for the
-- main panel search. This deliberately uses the same paginated template as
-- the Add entity browser instead of `/api/states`: the latter is an
-- unbounded, multi-megabyte response on a large Home Assistant instance and
-- can exceed both HA's template limit and Noctalia's callback CPU budget.
local function publishEntityCacheScanStart()
  noctalia.state.set("ha.entity_cache_scan", {
    generation = entityCacheGeneration,
    reset = true,
  })
end

local function publishEntityCachePage(rows, source, complete)
  noctalia.state.set("ha.entity_cache_page", {
    generation = entityCacheGeneration,
    rows = rows or {},
    source = source,
    complete = complete == true,
  })
end

local function cacheRows(rows)
  local cached = {}
  for _, row in ipairs(rows or {}) do
    if type(row) == "table" and type(row.entity_id) == "string" and row.entity_id ~= "" then
      cached[row.entity_id] = {
        entity_id = row.entity_id,
        name = type(row.name) == "string" and row.name ~= "" and row.name or row.entity_id,
      }
    end
  end
  return cached
end

local function mergeEntityCache(rows)
  local cached = cacheRows(rows)
  for entityId, row in pairs(cached) do entityCacheRows[entityId] = row end
  if entityCacheScanRows then
    for entityId, row in pairs(cached) do entityCacheScanRows[entityId] = row end
  end
end

cacheEntityPage = function(reset)
  if entityCacheRequestActive then return end
  if entityCacheComplete then
    if os.time() < entityCacheRefreshAt then return end
    reset = true
  end
  if reset then
    entityCacheGeneration += 1
    entityCacheOffset = 0
    entityCacheScanRows = {}
    entityCacheComplete = false
    entityCacheRefreshAt = 0
    publishEntityCacheScanStart()
  end
  if not entityCacheScanRows then
    entityCacheScanRows = {}
    publishEntityCacheScanStart()
  end

  local server, token, err = credentials()
  if err then
    noctalia.state.set("ha.entity_cache_loading", false)
    noctalia.state.set("ha.entity_cache_error", err)
    entityCacheRefreshAt = os.time() + 60
    return
  end

  local pageOffset = entityCacheOffset
  local pageLimit = pageSize()
  local myGeneration = entityCacheGeneration
  entityCacheRequestActive = true
  noctalia.state.set("ha.entity_cache_loading", true)
  noctalia.state.set("ha.entity_cache_error", "")

  local started = haRequest(server, token, browseTemplate("all", "all", pageOffset, pageLimit), function(response)
    if myGeneration ~= entityCacheGeneration then return end
    entityCacheRequestActive = false
    if not response.ok or response.status ~= 200 then
      noctalia.state.set("ha.entity_cache_loading", false)
      noctalia.state.set("ha.entity_cache_error", "Could not cache Home Assistant entities (HTTP " .. tostring(response.status) .. ")")
      entityCacheRefreshAt = os.time() + 60
      return
    end

    local rows = {}
    for line in tostring(response.body or ""):gmatch("[^\n]+") do
      local id, name = line:match("^([^\t]*)\t(.*)$")
      if id and id ~= "" then
        rows[#rows + 1] = { entity_id = id, name = (name ~= "" and name or id) }
      end
    end
    local cached = cacheRows(rows)
    for entityId, row in pairs(cached) do entityCacheScanRows[entityId] = row end

    if #rows >= pageLimit then
      publishEntityCachePage(rows, "scan", false)
      entityCacheOffset += pageLimit
      -- Continue one page at a time. Each callback only decodes one bounded
      -- response, while the asynchronous request chain fills the cache
      -- without making the user click through every page.
      cacheEntityPage(false)
    else
      entityCacheComplete = true
      entityCacheRows = entityCacheScanRows
      entityCacheScanRows = nil
      publishEntityCachePage(rows, "scan", true)
      entityCacheRefreshAt = os.time() + 15 * 60
      noctalia.state.set("ha.entity_cache_loading", false)
      noctalia.state.set("ha.entity_cache_updated_at", os.time())
    end
  end)
  if not started then
    entityCacheRequestActive = false
    noctalia.state.set("ha.entity_cache_loading", false)
    noctalia.state.set("ha.entity_cache_error", "Could not start Home Assistant entity cache request")
    entityCacheRefreshAt = os.time() + 60
  end
end

local function browse(domain, area, offset)
  local server, token, err = credentials()
  if err then
    noctalia.state.set("ha.browse_error", err)
    return
  end
  offset = tonumber(offset) or 0
  local limit = pageSize()

  local started = haRequest(server, token, browseTemplate(domain, area, offset, limit), function(response)
    if not response.ok or response.status ~= 200 then
      noctalia.state.set("ha.browse_error", "Browse failed (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local rows = {}
    for line in tostring(response.body or ""):gmatch("[^\n]+") do
      local id, name = line:match("^([^\t]*)\t(.*)$")
      if id and id ~= "" then
        rows[#rows + 1] = { entity_id = id, name = (name ~= "" and name or id) }
      end
    end
    mergeEntityCache(rows)
    publishEntityCachePage(rows, "browse", false)
    noctalia.state.set("ha.browse_error", "")
    noctalia.state.set("ha.browse_result", {
      domain = domain or "all",
      area = area or "all",
      offset = offset,
      limit = limit,
      rows = rows,
      -- A full page suggests there may be more; a short page means we hit
      -- the end. Good enough for "Load more" without a separate count call.
      more = #rows >= limit,
    })
  end)
  if not started then
    noctalia.state.set("ha.browse_error", "Could not start browse request")
  end
end

-- Home Assistant's own area registry, via the areas()/area_name() template
-- functions -- typically a couple dozen entries at most (verified: 10 on
-- this instance), so unlike everything else in this file, this one request
-- is never paginated.
local function listAreas()
  local server, token, err = credentials()
  if err then
    noctalia.state.set("ha.browse_error", err)
    return
  end
  local template = "{% for a in areas() %}{{ a }}\t{{ area_name(a) | replace('\\t',' ') | replace('\\n',' ') }}\n{% endfor %}"
  local started = haRequest(server, token, template, function(response)
    if not response.ok or response.status ~= 200 then
      noctalia.state.set("ha.browse_error", "Could not list areas (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local rows = {}
    for line in tostring(response.body or ""):gmatch("[^\n]+") do
      local id, name = line:match("^([^\t]*)\t(.*)$")
      if id and id ~= "" then
        rows[#rows + 1] = { id = id, name = (name ~= "" and name or id) }
      end
    end
    noctalia.state.set("ha.areas", rows)
  end)
  if not started then
    noctalia.state.set("ha.browse_error", "Could not start area list request")
  end
end

local function urlPathPart(value)
  return tostring(value):gsub("([^%w%._%-])", function(character)
    return string.format("%%%02X", string.byte(character))
  end)
end

local function cameraImageDestination(entityId)
  local dataDir, err = noctalia.pluginDataDir()
  if not dataDir then
    noctalia.log("ha: cannot download camera preview: " .. tostring(err))
    return nil
  end
  local filePart = tostring(entityId):gsub("[^%w_-]", "_")
  return dataDir .. "/camera-" .. filePart .. "-" .. tostring(math.floor(noctalia.nowMs())) .. ".jpg"
end

local function downloadCameraImage(server, entityId, parsed)
  if shared.domainOf(entityId) ~= "camera" then return end
  local attributes = parsed.attributes or {}
  local picture = attributes.entity_picture
  if type(picture) ~= "string" or picture == "" then return end

  local url = picture
  if picture:match("^https?://") == nil then
    url = server .. (picture:sub(1, 1) == "/" and picture or "/" .. picture)
  end
  local destination = cameraImageDestination(entityId)
  if not destination then return end

  local requestId = (cameraRequestGeneration[entityId] or 0) + 1
  cameraRequestGeneration[entityId] = requestId
  local started = noctalia.download(url, destination, function(ok)
    if not ok then
      noctalia.log("ha: camera preview download failed for " .. entityId)
      return
    end
    if activeDetailsEntityId ~= entityId or cameraRequestGeneration[entityId] ~= requestId then
      noctalia.removeFile(destination)
      return
    end

    local previous = cameraImagePaths[entityId]
    cameraImagePaths[entityId] = destination
    local current = noctalia.state.get("ha.details")
    if type(current) == "table" and current.entity_id == entityId then
      current.camera_image = destination
      noctalia.state.set("ha.details", current)
    end
    if previous and previous ~= destination then noctalia.removeFile(previous) end
  end)
  if not started then
    noctalia.log("ha: could not start camera preview download for " .. entityId)
  end
end

local function logbookStartTimestamp()
  return os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - 24 * 60 * 60)
end

local function activityActor(entry)
  local userId = type(entry) == "table" and entry.context_user_id or nil
  if type(userId) ~= "string" or userId == "" then return nil end
  local names = noctalia.getConfig("activity_user_names")
  if type(names) ~= "table" then return nil end
  local name = names[userId]
  if type(name) ~= "string" then return nil end
  name = shared.trim(name)
  return name ~= "" and name or nil
end

local function isIntermediateState(state)
  return state == "locking" or state == "unlocking" or state == "opening" or state == "closing"
end

local function fetchLogbook(server, token, entityId)
  logbookRequestGeneration += 1
  local requestId = logbookRequestGeneration
  local url = server .. "/api/logbook/" .. urlPathPart(logbookStartTimestamp()) .. "?entity=" .. urlPathPart(entityId)
  local started = noctalia.http({
    url = url,
    method = "GET",
    headers = { "Authorization: Bearer " .. token, "Content-Type: application/json" },
    allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
  }, function(response)
    if activeDetailsEntityId ~= entityId or requestId ~= logbookRequestGeneration then return end
    if not response.ok or response.status ~= 200 then
      noctalia.state.set("ha.logbook_error", "Could not load activity (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local raw = noctalia.json.decode(response.body or "")
    if type(raw) ~= "table" then
      noctalia.state.set("ha.logbook_error", "Home Assistant returned invalid activity data")
      return
    end
    -- HA returns the oldest entry first. The raw logbook also contains
    -- repeated rows for attribute updates and service calls. Keep only rows
    -- carrying a state and collapse consecutive duplicates so the timeline
    -- represents actual state transitions (for example, recording ->
    -- unavailable), not every underlying logbook event.
    local transitions = {}
    local previousState = nil
    local previousActor = nil
    for _, entry in ipairs(raw) do
      if type(entry) == "table" and type(entry.state) == "string" and entry.state ~= "" then
        local actor = activityActor(entry)
        if actor then previousActor = actor end
        if previousState == nil or entry.state ~= previousState then
          transitions[#transitions + 1] = {
            when = entry.when,
            name = entry.name,
            message = entry.message,
            domain = entry.domain,
            state = entry.state,
            actor = actor or (isIntermediateState(previousState) and previousActor or nil),
          }
        end
        previousState = entry.state
        if not isIntermediateState(entry.state) then previousActor = nil end
      end
    end

    local entries = {}
    for index = #transitions, 1, -1 do
      entries[#entries + 1] = transitions[index]
      if #entries >= 50 then break end
    end
    noctalia.state.set("ha.logbook_error", "")
    noctalia.state.set("ha.logbook", entries)
  end)
  if not started then
    noctalia.state.set("ha.logbook_error", "Could not start activity request")
  end
end

fetchDetails = function(entityId)
  if type(entityId) ~= "string" or entityId == "" then return end
  local server, token, err = credentials()
  if err then
    noctalia.state.set("ha.details_error", err)
    return
  end
  detailsRequestGeneration += 1
  local requestId = detailsRequestGeneration
  noctalia.state.set("ha.details_error", "")
  local started = noctalia.http({
    url = server .. "/api/states/" .. urlPathPart(entityId),
    method = "GET",
    headers = { "Authorization: Bearer " .. token, "Content-Type: application/json" },
    allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
  }, function(response)
    if activeDetailsEntityId ~= entityId or requestId ~= detailsRequestGeneration then return end
    if not response.ok or response.status ~= 200 then
      noctalia.state.set("ha.details_error", "Could not load details (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local parsed = noctalia.json.decode(response.body or "")
    if type(parsed) ~= "table" then
      noctalia.state.set("ha.details_error", "Home Assistant returned invalid entity details")
      return
    end
    parsed.camera_image = cameraImagePaths[entityId]
    noctalia.state.set("ha.details", parsed)
    downloadCameraImage(server, entityId, parsed)
    local now = os.time()
    if lastLogbookEntityId ~= entityId or now - lastLogbookFetchedAt >= 15 then
      lastLogbookEntityId = entityId
      lastLogbookFetchedAt = now
      fetchLogbook(server, token, entityId)
    end
  end)
  if not started then
    noctalia.state.set("ha.details_error", "Could not start entity details request")
  end
end

-- ── Commands + lifecycle ─────────────────────────────────────────────────────

noctalia.state.watch("ha.command", function(command)
  if type(command) ~= "table" then return end
  if command.action == "refresh" then
    refresh()
  elseif command.action == "open_dashboard" then
    openDashboard()
  elseif command.action == "open_camera_stream" then
    openCameraStream(command.entity_id)
  elseif command.action == "toggle" then
    toggleEntity(command.entity_id)
  elseif command.action == "cover" then
    coverCommand(command.entity_id, command.command)
  elseif command.action == "set_cover_position" then
    local position = tonumber(command.value)
    if position ~= nil then
      callService("cover", "set_cover_position", command.entity_id, { position = math.max(0, math.min(100, math.floor(position + 0.5))) })
    end
  elseif command.action == "set_brightness" then
    setBrightness(command.entity_id, command.value)
  elseif command.action == "set_color" then
    setLightColor(command.entity_id, command.color)
  elseif command.action == "set_color_temperature" then
    setLightColorTemperature(command.entity_id, command.value)
  elseif command.action == "set_percentage" then
    setFanPercentage(command.entity_id, command.value)
  elseif command.action == "oscillate" then
    setFanOscillation(command.entity_id, command.value)
  elseif command.action == "direction" then
    setFanDirection(command.entity_id, command.value)
  elseif command.action == "lock" then
    lockCommand(command.entity_id, command.command)
  elseif command.action == "media" then
    mediaCommand(command.entity_id, command.command, command.value)
  elseif command.action == "bar_service" then
    barService(command.entity_id, command.service)
  elseif command.action == "panel_service" then
    panelService(command.entity_id, command.service, command.data)
  elseif command.action == "remote" then
    remoteCommand(command.entity_id, command.command)
  elseif command.action == "add" then
    addEntity(command.entity_id)
  elseif command.action == "remove" then
    removeEntity(command.entity_id)
  elseif command.action == "rename" then
    renameEntity(command.entity_id, command.label)
  elseif command.action == "reorder" then
    reorderEntity(command.entity_id, command.direction)
  elseif command.action == "move" then
    moveEntity(command.entity_id, command.target_section)
  elseif command.action == "drop" then
    dropEntity(command.entity_id, command.target_section, command.before_entity)
  elseif command.action == "reorder_section" then
    reorderSection(command.section_index, command.direction)
  elseif command.action == "rename_section" then
    renameSection(command.section_index, command.name)
  elseif command.action == "add_section" then
    addSection(command.name)
  elseif command.action == "drop_section" then
    dropSection(command.from_index, command.target_index)
  elseif command.action == "browse" then
    browse(command.domain, command.area, command.offset)
  elseif command.action == "list_areas" then
    listAreas()
  elseif command.action == "details" then
    activeDetailsEntityId = command.entity_id
    lastLogbookEntityId = nil
    lastLogbookFetchedAt = 0
    noctalia.state.set("ha.logbook_error", "")
    noctalia.setUpdateInterval(DETAILS_REFRESH_INTERVAL_MS)
    fetchDetails(command.entity_id)
  elseif command.action == "details_close" then
    activeDetailsEntityId = nil
    detailsRequestGeneration += 1
    logbookRequestGeneration += 1
    lastLogbookEntityId = nil
    lastLogbookFetchedAt = 0
    noctalia.state.set("ha.logbook", {})
    noctalia.state.set("ha.logbook_error", "")
    noctalia.setUpdateInterval(intervalMs())
  end
end)

intervalMs = function()
  local seconds = tonumber(shared.config("refresh_interval", 30)) or 30
  return math.max(5, math.min(300, seconds)) * 1000
end

function update()
  refresh()
  if activeDetailsEntityId then fetchDetails(activeDetailsEntityId) end
end

function onConfigChanged()
  noctalia.setUpdateInterval(activeDetailsEntityId and DETAILS_REFRESH_INTERVAL_MS or intervalMs())
  loadLayout()
  refresh()
end

function onIpc(event)
  if event == "refresh" then refresh() end
end

loadLayout()
noctalia.setUpdateInterval(intervalMs())
refresh()
