--!nonstrict
-- Screencast indicator poller — the headless [[service]] entry.
--
-- A live xdg-desktop-portal capture appears as a PipeWire link touching an
-- xdg-desktop-portal node. Query that graph directly instead of depending on
-- an external busctl watcher or a shared /tmp state file. `@pw-cli@` is
-- substituted by the Nix package, so the only prerequisite is the PipeWire
-- session that portal-based screensharing already requires.

local PW_CLI = "@pw-cli@"
local POLL_TIMEOUT_MS = 5000
local lastKey = ""
local polling = false
local stopPending = false
local lastCommand = 0
local poll

local function pollMs()
  return (tonumber(noctalia.getConfig("poll_interval")) or 2) * 1000
end

-- pw-dump emits the complete object graph as JSON. On a real desktop that is
-- large enough for Noctalia's Luau CPU budget to abort json.decode before the
-- poller can publish anything. pw-cli's human-readable listings (and its
-- per-object `info` dump, used below for client pid/name) contain the same
-- properties we need, but are far smaller.
-- Keep the small parser here so detection remains part of the reusable plugin.
local function parseListing(raw, wantedType)
  local objects = {}
  local current = nil

  for line in raw:gmatch("[^\r\n]+") do
    local id, objectType = line:match("^%s*id%s+(%d+),%s+type%s+([^/]+)/")
    if id then
      current = nil
      if objectType == wantedType then
        current = { id = id }
        table.insert(objects, current)
      end
    elseif current then
      local key, value = line:match("^%s+([%w_.%-]+)%s*=%s*\"(.*)\"%s*$")
      if key then
        current[key] = value
      end
    end
  end

  return objects
end

-- Each portal-linked node also carries a client.id -- the PipeWire client
-- (app connection) that owns it. Keep that alongside the node name so the
-- caller can enrich the record with the client's own properties (pid,
-- application.name) via a follow-up `pw-cli info <clientId>` -- `ls Node`'s
-- compact listing doesn't carry those, only the full per-object dump does.
local function portalGraph(nodeRaw, linkRaw)
  local portalNodes = {}
  local nodeInfo = {}
  for _, node in ipairs(parseListing(nodeRaw, "PipeWire:Interface:Node")) do
    local name = node["node.name"] or ""
    nodeInfo[node.id] = { name = name, clientId = node["client.id"] }
    if name:find("xdg%-desktop%-portal") then
      portalNodes[node.id] = true
    end
  end

  local records = {}
  local seen = {}
  local linkIds = {}
  for _, link in ipairs(parseListing(linkRaw, "PipeWire:Interface:Link")) do
    local input = link["link.input.node"] or ""
    local output = link["link.output.node"] or ""
    if portalNodes[input] or portalNodes[output] then
      table.insert(linkIds, link.id)
      -- A portal link has one portal endpoint and one client endpoint.
      -- Report the latter's node name/client id, matching the old helper.
      for _, id in ipairs({ input, output }) do
        if id ~= "" and not portalNodes[id] then
          local info = nodeInfo[id]
          if info and info.name ~= "" then
            -- Dedup by client id where we have one (the same app can open
            -- more than one node touching the portal); fall back to name.
            local key = info.clientId or info.name
            if not seen[key] then
              seen[key] = true
              table.insert(records, { name = info.name, clientId = info.clientId })
            end
          end
        end
      end
    end
  end

  table.sort(linkIds, function(left, right)
    return tonumber(left) < tonumber(right)
  end)
  return records, linkIds
end

-- Chases down each sharing client's pid and application.name via one
-- `pw-cli info` round trip per client (there are only ever a handful of
-- these at once). `ls Client`'s compact listing does carry a pid
-- (pipewire.sec.pid), but it's the pid of whatever process opened the
-- PipeWire connection -- a browser's sandboxed GPU/content process, not the
-- window Hyprland knows about. application.process.id from the full client
-- dump is the one that actually matches `hyprctl clients`' own pid field.
local function fetchClientInfo(clientIds, index, results, callback)
  if index > #clientIds then
    callback(results)
    return
  end
  local id = clientIds[index]
  noctalia.runAsync({ PW_CLI, "info", id }, function(result)
    if result.exitCode == 0 then
      local out = result.stdout or ""
      results[id] = {
        pid = out:match('application%.process%.id = "(%d+)"'),
        name = out:match('application%.name = "([^"]*)"'),
      }
    end
    fetchClientInfo(clientIds, index + 1, results, callback)
  end, POLL_TIMEOUT_MS)
end

local function publish(apps)
  local active = #apps > 0
  local parts = {}
  for _, app in ipairs(apps) do
    table.insert(parts, (app.name or "") .. ":" .. tostring(app.pid or ""))
  end
  local key = tostring(active) .. "|" .. table.concat(parts, ",")
  if key == lastKey then
    return
  end
  lastKey = key

  noctalia.state.set("screencast_status", {
    active = active,
    apps = apps,
  })
end

local function fail(message)
  polling = false
  noctalia.log("pw-cli failed: " .. noctalia.string.trim(message or "unknown error"))
  publish({})
end

local function publishCommand(command, success, message)
  noctalia.state.set("screencast_action", {
    n = command.n,
    action = command.action,
    success = success,
    message = message or "",
  })
end

local function finishStop(command, failed)
  stopPending = false
  if #failed == 0 then
    publishCommand(command, true, "Screen sharing stopped")
  else
    publishCommand(command, false, `Could not remove PipeWire link(s): {table.concat(failed, ", ")}`)
  end
  poll()
end

local function destroyLinks(command, linkIds, index, failed)
  if index > #linkIds then
    finishStop(command, failed)
    return
  end

  local linkId = linkIds[index]
  noctalia.runAsync({ PW_CLI, "destroy", linkId }, function(result)
    if result.exitCode ~= 0 then
      table.insert(failed, linkId)
    end
    destroyLinks(command, linkIds, index + 1, failed)
  end, POLL_TIMEOUT_MS)
end

local function stopSharing(command)
  if stopPending then
    return
  end
  stopPending = true

  noctalia.runAsync({ PW_CLI, "ls", "Node" }, function(result)
    if result.exitCode ~= 0 then
      stopPending = false
      publishCommand(command, false, noctalia.string.trim(result.stderr or "pw-cli failed"))
      return
    end

    noctalia.runAsync({ PW_CLI, "ls", "Link" }, function(linkResult)
      if linkResult.exitCode ~= 0 then
        stopPending = false
        publishCommand(command, false, noctalia.string.trim(linkResult.stderr or "pw-cli failed"))
        return
      end

      local _, linkIds = portalGraph(result.stdout or "", linkResult.stdout or "")
      if #linkIds == 0 then
        stopPending = false
        publishCommand(command, false, "No active screencast links found")
        poll()
        return
      end
      destroyLinks(command, linkIds, 1, {})
    end, POLL_TIMEOUT_MS)
  end, POLL_TIMEOUT_MS)
end

poll = function()
  if polling then
    return
  end
  polling = true

  noctalia.runAsync({ PW_CLI, "ls", "Node" }, function(result)
    if result.exitCode ~= 0 then
      fail(result.stderr)
      return
    end

    noctalia.runAsync({ PW_CLI, "ls", "Link" }, function(linkResult)
      if linkResult.exitCode ~= 0 then
        fail(linkResult.stderr)
        return
      end

      local records = portalGraph(result.stdout or "", linkResult.stdout or "")
      local clientIds = {}
      for _, record in ipairs(records) do
        if record.clientId then
          table.insert(clientIds, record.clientId)
        end
      end

      fetchClientInfo(clientIds, 1, {}, function(infoByClient)
        polling = false
        local apps = {}
        for _, record in ipairs(records) do
          local info = record.clientId and infoByClient[record.clientId]
          table.insert(apps, {
            name = (info and info.name and info.name ~= "" and info.name) or record.name,
            pid = info and info.pid,
          })
        end
        table.sort(apps, function(left, right)
          return left.name < right.name
        end)
        publish(apps)
      end)
    end, POLL_TIMEOUT_MS)
  end, POLL_TIMEOUT_MS)
end

local initialCommand = noctalia.state.get("screencast_cmd")
if initialCommand then
  local command = noctalia.json.decode(initialCommand)
  lastCommand = command and tonumber(command.n) or 0
end

noctalia.state.watch("screencast_cmd", function(raw)
  local command = raw and noctalia.json.decode(raw) or nil
  local nonce = command and tonumber(command.n) or 0
  if not command or nonce <= lastCommand then
    return
  end
  lastCommand = nonce
  if command.action == "stop" then
    stopSharing(command)
  end
end)

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
