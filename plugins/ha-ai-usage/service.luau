--!nonstrict
-- Inspect just the supported Home Assistant integration domains, then ask HA
-- for the active quota metrics belonging to loaded instances. This avoids both
-- a user-maintained source list and decoding HA's complete state/config registry.

local shared = require("./shared.luau")
local inFlight = false
local generation = 0

local SUPPORTED_INTEGRATIONS = {
  { domain = "hass_claude_usage", id = "claude", prefix = "sensor.claude_usage_" },
  { domain = "openai_usage_monitor", id = "codex", prefix = "sensor.codex_usage_" },
  { domain = "github_copilot_usage", id = "copilot", prefix = "sensor.github_copilot_" },
  { domain = "gemini_usage", id = "gemini", prefix = "sensor.google_gemini_" },
}

local function intervalMs()
  local seconds = tonumber(shared.config("refresh_interval", 60)) or 60
  return math.max(10, math.min(3600, seconds)) * 1000
end

local function readSecret(setting)
  local path = shared.trim(noctalia.getConfig(setting))
  if path == "" then return nil, "not configured" end
  local content, err = noctalia.readFile(path)
  local value = content and shared.trim(content) or ""
  if value == "" then return nil, err or "empty or unreadable" end
  return value
end

local function publishError(message)
  noctalia.state.set("ha_ai_usage.error", message)
  noctalia.state.set("ha_ai_usage.refreshing", false)
end

local function discoveryTemplate(monitors)
  local encoded = noctalia.json.encode(monitors)
  local template = [[
{%- set monitors = __MONITORS__ -%}
{%- set ns = namespace(items=[]) -%}
{%- for item in states.sensor -%}
  {%- set id = item.entity_id -%}
  {%- for monitor in monitors -%}
    {%- set claude = monitor.id == 'claude' and (id.endswith('_session_usage') or id.endswith('_week_usage')) -%}
    {%- set codex = monitor.id == 'codex' and (id.endswith('_5h_used') or id.endswith('_weekly_used')) -%}
    {%- set copilot = monitor.id == 'copilot' and id.endswith('_used') -%}
    {%- set gemini = monitor.id == 'gemini' and id.endswith('_usage') and not id.endswith('_usage_pace') -%}
    {%- if id.startswith(monitor.prefix) and (claude or codex or copilot or gemini) and item.state | float(-1) >= 0 -%}
      {%- set attrs = item.attributes -%}
      {%- set reset_id = id | replace('_session_usage', '_session_reset_time') | replace('_week_usage', '_weekly_reset_time') -%}
      {%- set reset = states[reset_id] -%}
      {%- set ns.items = ns.items + [{"integration": monitor.id, "entity_id": id, "state": item.state, "name": item.name, "icon": attrs.icon | default('', true), "reset_time": reset.state if monitor.id == 'claude' and reset is not none else attrs.reset_time | default('', true), "resets_at": attrs.resets_at | default('', true), "quota_reset_date_utc": attrs.quota_reset_date_utc | default('', true), "primary_reset_time": attrs.primary_reset_time | default('', true), "secondary_reset_time": attrs.secondary_reset_time | default('', true)}] -%}
    {%- endif -%}
  {%- endfor -%}
{%- endfor -%}
{{- ns.items | tojson -}}
]]
  return template:gsub("__MONITORS__", encoded)
end

local function requestMetrics(server, token, requestGeneration, monitors, failures)
  if #monitors == 0 then
    inFlight = false
    noctalia.state.set("ha_ai_usage.items", {})
    publishError(#failures > 0 and ("Integration discovery failed: " .. table.concat(failures, ", ")) or "No supported, enabled AI usage integrations were found")
    return
  end
  local started = noctalia.http({
    url = server .. "/api/template",
    method = "POST",
    headers = { "Authorization: Bearer " .. token, "Content-Type: application/json" },
    body = noctalia.json.encode({ template = discoveryTemplate(monitors) }),
    allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
  }, function(response)
    if requestGeneration ~= generation then return end
    inFlight = false
    noctalia.state.set("ha_ai_usage.refreshing", false)
    if not response.ok or response.status ~= 200 then
      publishError("Home Assistant usage discovery failed (HTTP " .. tostring(response.status) .. ")")
      return
    end
    local items = noctalia.json.decode(response.body or "")
    if type(items) ~= "table" then
      publishError("Home Assistant returned invalid usage data")
      return
    end
    noctalia.state.set("ha_ai_usage.items", items)
    noctalia.state.set("ha_ai_usage.error", #failures > 0 and ("Integration lookup issue: " .. table.concat(failures, ", ")) or "")
    noctalia.state.set("ha_ai_usage.refreshed_at", os.time())
  end)
  if not started then
    inFlight = false
    publishError("Could not start Home Assistant usage discovery")
  end
end

local function discoverIntegrations(server, token, requestGeneration)
  local pending = #SUPPORTED_INTEGRATIONS
  local monitors = {}
  local failures = {}

  local function finish()
    pending -= 1
    if pending == 0 and requestGeneration == generation then
      requestMetrics(server, token, requestGeneration, monitors, failures)
    end
  end

  for _, integration in ipairs(SUPPORTED_INTEGRATIONS) do
    local started = noctalia.http({
      url = server .. "/api/config/config_entries/entry?domain=" .. noctalia.string.urlEncode(integration.domain),
      headers = { "Authorization: Bearer " .. token },
      allow_insecure_tls = noctalia.getConfig("allow_insecure_tls") == true,
    }, function(response)
      if requestGeneration ~= generation then return end
      if response.ok and response.status == 200 then
        local entries = noctalia.json.decode(response.body or "")
        if type(entries) == "table" then
          for _, entry in ipairs(entries) do
            if entry.state == "loaded" then
              monitors[#monitors + 1] = integration
              break
            end
          end
        else
          failures[#failures + 1] = integration.id .. " invalid JSON"
        end
      else
        failures[#failures + 1] = integration.id .. " HTTP " .. tostring(response.status)
      end
      finish()
    end)
    if not started then
      failures[#failures + 1] = integration.id .. " request not started"
      finish()
    end
  end
end

local function refresh()
  if inFlight then return end
  inFlight = true
  noctalia.state.set("ha_ai_usage.refreshing", true)

  local server, serverErr = readSecret("server_file")
  local token, tokenErr = readSecret("token_file")
  if not server or not token then
    inFlight = false
    publishError("Home Assistant " .. (serverErr or tokenErr or "credentials are unavailable"))
    return
  end

  generation += 1
  discoverIntegrations(server:gsub("/+$", ""), token, generation)
end

noctalia.state.watch("ha_ai_usage.command", function(command)
  if type(command) == "table" and command.action == "refresh" then refresh() end
end)

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

noctalia.setUpdateInterval(intervalMs())
refresh()
