--!nonstrict
-- Screencast indicator poller — the headless [[service]] entry.
--
-- A live xdg-desktop-portal capture appears as a PipeWire link touching an
-- xdg-desktop-portal node. Query that graph directly instead of depending on
-- an external busctl watcher or a shared /tmp state file. `@pw-dump@` is
-- substituted by the Nix package, so the only prerequisite is the PipeWire
-- session that portal-based screensharing already requires.

local PW_DUMP = "@pw-dump@"
local lastKey = ""

local function pollMs()
  return (tonumber(noctalia.getConfig("poll_interval")) or 2) * 1000
end

local function nodeProps(object)
  local info = object.info or {}
  return info.props or object.props or {}
end

local function portalApps(raw)
  local graph = noctalia.json.decode(raw)
  if type(graph) ~= "table" then
    return {}
  end

  local portalNodes = {}
  local nodes = {}
  for _, object in ipairs(graph) do
    if object.type == "PipeWire:Interface:Node" then
      local props = nodeProps(object)
      local id = tostring(object.id)
      nodes[id] = props
      if tostring(props["node.name"] or ""):find("xdg%-desktop%-portal") then
        portalNodes[id] = true
      end
    end
  end

  local apps = {}
  for _, object in ipairs(graph) do
    if object.type == "PipeWire:Interface:Link" then
      local info = object.info or {}
      local props = nodeProps(object)
      local input = tostring(info["input-node-id"] or props["link.input.node"] or "")
      local output = tostring(info["output-node-id"] or props["link.output.node"] or "")
      if portalNodes[input] or portalNodes[output] then
        -- A portal link has one portal endpoint and one client endpoint.
        -- Report the latter's PipeWire node name, matching the old helper.
        for _, id in ipairs({ input, output }) do
          if id ~= "" and not portalNodes[id] then
            local name = tostring((nodes[id] or {})["node.name"] or "")
            if name ~= "" then
              apps[name] = true
            end
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

local function poll()
  noctalia.runAsync({ PW_DUMP }, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("pw-dump failed: " .. noctalia.string.trim(result.stderr or ""))
      publish({})
      return
    end
    publish(portalApps(result.stdout or ""))
  end, 5000)
end

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
