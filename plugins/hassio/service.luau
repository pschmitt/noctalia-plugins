--!nonstrict
-- Every Home Assistant request this service makes is scoped to a bounded set
-- of entities -- either the user's own configured handful, or one page of a
-- domain-filtered browse -- and never the instance's full entity list. See
-- plugin.toml's browser_page_size comment for why: a whole-instance
-- `/api/states` dump is both rejected by HA's own template output-length cap
-- and, when it isn't, too large for Noctalia to decode in one script tick on
-- an instance with several thousand entities.

local shared = require("./shared.luau")
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

-- ── Configured-entity persistence ───────────────────────────────────────────
-- The panel never touches this file itself (it only sends commands): the
-- service is the one long-lived Luau instance in this plugin, so it is the
-- single writer/source of truth. bar.luau and panel.luau just render whatever
-- the service last published to noctalia.state.

local ENTITIES_FILE = "entities.json"
local configuredEntities = {}

local function entitiesPath()
  local dir, err = noctalia.pluginDataDir()
  if not dir then
    noctalia.log("hassio: cannot resolve plugin data dir: " .. tostring(err))
    return nil
  end
  return dir .. "/" .. ENTITIES_FILE
end

local function loadConfiguredEntities()
  local path = entitiesPath()
  local data = path and noctalia.readFile(path)
  if data and data ~= "" then
    local parsed = noctalia.json.decode(data)
    if type(parsed) == "table" then
      configuredEntities = parsed
      return
    end
  end
  configuredEntities = {}
end

local function saveConfiguredEntities()
  local path = entitiesPath()
  if not path then return end
  local ok, writeErr = noctalia.writeFile(path, noctalia.json.encode(configuredEntities))
  if not ok then
    noctalia.log("hassio: failed to save configured entities: " .. tostring(writeErr))
  end
  noctalia.state.set("hassio.configured", configuredEntities)
end

local function hasEntity(entityId)
  for _, id in ipairs(configuredEntities) do
    if id == entityId then return true end
  end
  return false
end

-- Display-name overrides, entity_id -> label. Kept in their own file rather
-- than folded into entities.json: it stays a plain list of ids that way, and
-- an entity with no override just has no entry here instead of every entry
-- needing an optional field. Declared up here (used by parseStatusResponse's
-- caller below) but its own load/save/rename functions live after refresh(),
-- since renaming re-triggers it.
local LABELS_FILE = "labels.json"
local labels = {}

local function labelsPath()
  local dir, err = noctalia.pluginDataDir()
  if not dir then
    noctalia.log("hassio: cannot resolve plugin data dir: " .. tostring(err))
    return nil
  end
  return dir .. "/" .. LABELS_FILE
end

local function loadLabels()
  local path = labelsPath()
  local data = path and noctalia.readFile(path)
  if data and data ~= "" then
    local parsed = noctalia.json.decode(data)
    if type(parsed) == "table" then
      labels = parsed
      return
    end
  end
  labels = {}
end

local function saveLabels()
  local path = labelsPath()
  if not path then return end
  local ok, writeErr = noctalia.writeFile(path, noctalia.json.encode(labels))
  if not ok then
    noctalia.log("hassio: failed to save labels: " .. tostring(writeErr))
  end
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

-- brightness (light, 0-255), percentage (fan, 0-100) and current_position
-- (cover, 0-100) ride along on every status query so the panel can draw
-- sliders and a richer subtitle without a second request per entity.
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
  return "{% for id in " .. list .. " %}{{ id }}\t{{ states(id) }}\t"
    .. "{{ (state_attr(id,'friendly_name') or id) | replace('\\t',' ') | replace('\\n',' ') }}\t"
    .. "{{ state_attr(id,'brightness') or '' }}\t{{ state_attr(id,'percentage') or '' }}\t"
    .. "{{ state_attr(id,'current_position') or '' }}\n"
    .. "{% endfor %}"
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
    local f = splitFields(line, 6)
    local id = f[1]
    if id and id ~= "" then
      rows[#rows + 1] = {
        entity_id = id,
        state = f[2],
        name = (f[3] ~= "" and f[3] or id),
        brightness = f[4] ~= "" and tonumber(f[4]) or nil,
        percentage = f[5] ~= "" and tonumber(f[5]) or nil,
        position = f[6] ~= "" and tonumber(f[6]) or nil,
      }
    end
  end
  return rows
end

local function publishError(message)
  noctalia.state.set("hassio.error", message)
  noctalia.state.set("hassio.refreshing", false)
end

local function refresh()
  local server, token, err = credentials()
  if err then
    publishError(err)
    return
  end
  if #configuredEntities == 0 then
    noctalia.state.set("hassio.entities", {})
    noctalia.state.set("hassio.error", "")
    noctalia.state.set("hassio.refreshing", false)
    return
  end

  generation += 1
  local myGeneration = generation
  noctalia.state.set("hassio.refreshing", true)

  local started = haRequest(server, token, statusTemplate(configuredEntities), function(response)
    if myGeneration ~= generation then return end
    noctalia.state.set("hassio.refreshing", false)
    if not response.ok or response.status ~= 200 then
      publishError("Home Assistant status query failed (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local rows = parseStatusResponse(response.body)
    for _, row in ipairs(rows) do
      local override = labels[row.entity_id]
      if override and override ~= "" then row.name = override end
    end
    noctalia.state.set("hassio.entities", rows)
    noctalia.state.set("hassio.error", "")
    noctalia.state.set("hassio.refreshed_at", os.time())
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
  saveLabels()
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
      noctalia.log("hassio: open dashboard failed: " .. shared.trim(result.stderr))
    end
  end, 10000)
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

local function setFanPercentage(entityId, percentage)
  local value = math.floor((tonumber(percentage) or 0) + 0.5)
  callService("fan", "set_percentage", entityId, { percentage = math.max(0, math.min(100, value)) })
end

-- ── Add / remove ─────────────────────────────────────────────────────────────

local function addEntity(entityId)
  entityId = shared.trim(entityId)
  if entityId == "" or hasEntity(entityId) then return end
  table.insert(configuredEntities, entityId)
  saveConfiguredEntities()
  refresh()
end

local function removeEntity(entityId)
  local newList = {}
  for _, id in ipairs(configuredEntities) do
    if id ~= entityId then table.insert(newList, id) end
  end
  configuredEntities = newList
  if labels[entityId] ~= nil then
    labels[entityId] = nil
    saveLabels()
  end
  saveConfiguredEntities()
  refresh()
end

-- ── Browse (paginated, domain-scoped) ───────────────────────────────────────
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

local function browseTemplate(domain, offset, limit)
  local source = browseSource(domain)
  return "{% for s in (" .. source .. " | sort(attribute='entity_id') | list)[" .. offset .. ":" .. (offset + limit) .. "] %}"
    .. "{{ s.entity_id }}\t{{ (s.name or s.entity_id) | replace('\\t',' ') | replace('\\n',' ') }}\n"
    .. "{% endfor %}"
end

local function browse(domain, offset)
  local server, token, err = credentials()
  if err then
    noctalia.state.set("hassio.browse_error", err)
    return
  end
  offset = tonumber(offset) or 0
  local limit = pageSize()

  local started = haRequest(server, token, browseTemplate(domain, offset, limit), function(response)
    if not response.ok or response.status ~= 200 then
      noctalia.state.set("hassio.browse_error", "Browse failed (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local rows = {}
    for line in tostring(response.body or ""):gmatch("[^\n]+") do
      local id, name = line:match("^([^\t]*)\t(.*)$")
      if id and id ~= "" then
        rows[#rows + 1] = { entity_id = id, name = (name ~= "" and name or id) }
      end
    end
    noctalia.state.set("hassio.browse_error", "")
    noctalia.state.set("hassio.browse_result", {
      domain = domain or "all",
      offset = offset,
      limit = limit,
      rows = rows,
      -- A full page suggests there may be more; a short page means we hit
      -- the end. Good enough for "Load more" without a separate count call.
      more = #rows >= limit,
    })
  end)
  if not started then
    noctalia.state.set("hassio.browse_error", "Could not start browse request")
  end
end

-- ── Commands + lifecycle ─────────────────────────────────────────────────────

noctalia.state.watch("hassio.command", function(command)
  if type(command) ~= "table" then return end
  if command.action == "refresh" then
    refresh()
  elseif command.action == "open_dashboard" then
    openDashboard()
  elseif command.action == "toggle" then
    toggleEntity(command.entity_id)
  elseif command.action == "cover" then
    coverCommand(command.entity_id, command.command)
  elseif command.action == "set_brightness" then
    setBrightness(command.entity_id, command.value)
  elseif command.action == "set_percentage" then
    setFanPercentage(command.entity_id, command.value)
  elseif command.action == "add" then
    addEntity(command.entity_id)
  elseif command.action == "remove" then
    removeEntity(command.entity_id)
  elseif command.action == "rename" then
    renameEntity(command.entity_id, command.label)
  elseif command.action == "browse" then
    browse(command.domain, command.offset)
  end
end)

local function intervalMs()
  local seconds = tonumber(shared.config("refresh_interval", 30)) or 30
  return math.max(5, math.min(300, seconds)) * 1000
end

function update()
  refresh()
end

function onConfigChanged()
  noctalia.setUpdateInterval(intervalMs())
  refresh()
end

function onIpc(event)
  if event == "refresh" then refresh() end
end

loadConfiguredEntities()
noctalia.state.set("hassio.configured", configuredEntities)
noctalia.setUpdateInterval(intervalMs())
refresh()
