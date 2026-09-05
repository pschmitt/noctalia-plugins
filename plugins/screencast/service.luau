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

local function portalApps(nodeRaw, linkRaw)
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
  for _, link in ipairs(parseListing(linkRaw, "PipeWire:Interface:Link")) do
    local input = link["link.input.node"] or ""
    local output = link["link.output.node"] or ""
    if portalNodes[input] or portalNodes[output] then
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
  return names
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

local function poll()
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
      publish(portalApps(result.stdout or "", linkResult.stdout or ""))
    end, POLL_TIMEOUT_MS)
  end, POLL_TIMEOUT_MS)
end

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
