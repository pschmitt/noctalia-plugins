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
-- poller can publish anything. pw-cli's human-readable listings contain the
-- same node/link properties we need, but are far smaller.
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

local function portalGraph(nodeRaw, linkRaw)
  local portalNodes = {}
  local nodeNames = {}
  for _, node in ipairs(parseListing(nodeRaw, "PipeWire:Interface:Node")) do
    local name = node["node.name"] or ""
    nodeNames[node.id] = name
    if name:find("xdg%-desktop%-portal") then
      portalNodes[node.id] = true
    end
  end

  local apps = {}
  local linkIds = {}
  for _, link in ipairs(parseListing(linkRaw, "PipeWire:Interface:Link")) do
    local input = link["link.input.node"] or ""
    local output = link["link.output.node"] or ""
    if portalNodes[input] or portalNodes[output] then
      table.insert(linkIds, link.id)
      -- A portal link has one portal endpoint and one client endpoint.
      -- Report the latter's PipeWire node name, matching the old helper.
      for _, id in ipairs({ input, output }) do
        if id ~= "" and not portalNodes[id] then
          local name = nodeNames[id] or ""
          if name ~= "" then
            apps[name] = true
          end
        end
      end
    end
  end

  local names = {}
  for name in pairs(apps) do
    table.insert(names, name)
  end
  table.sort(names)
  table.sort(linkIds, function(left, right)
    return tonumber(left) < tonumber(right)
  end)
  return names, linkIds
end

local function publish(apps)
  local active = #apps > 0
  local key = tostring(active) .. "|" .. table.concat(apps, ",")
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

      polling = false
      local apps = portalGraph(result.stdout or "", linkResult.stdout or "")
      publish(apps)
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
