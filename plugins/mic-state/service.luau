-- The mute button and volume control target the selected physical source that
-- feeds the processed voice source. The device list excludes virtual sources.

local STATE_KEY = "mic_state"
local COMMAND_KEY = "mic_state.command"
local state = { known = false, muted = false, volume = 100, sources = {}, activeSource = "" }
local polling = false
local pollAgain = false
local volumeRevision = 0
local applyingPreferred = false
local selectCaptureSource
local setVolume
local poll

local function maxVolume()
  return noctalia.getConfig("allow_volume_boost") == true and 150 or 100
end

local function finishPoll()
  polling = false
  if pollAgain then
    pollAgain = false
    poll()
  end
end

local function preferredSource()
  local dataDir = noctalia.pluginDataDir()
  local raw = dataDir and noctalia.readFile(dataDir .. "/settings.json")
  if raw then
    local ok, data = pcall(noctalia.json.decode, raw)
    if ok and type(data) == "table" and type(data.captureSource) == "string" then
      return data.captureSource
    end
  end
  local configured = noctalia.string.trim(noctalia.getConfig("capture_source") or "auto")
  if configured ~= "" and configured ~= "auto" then return configured end
  return nil
end

local function publish()
  noctalia.state.set(STATE_KEY, state)
end

local function setError(message)
  state.error = message
  publish()
end

poll = function()
  if polling then
    pollAgain = true
    return
  end
  polling = true
  local requestedVolumeRevision = volumeRevision

  noctalia.runAsync({ "pactl", "-f", "json", "list", "sources" }, function(result)
    if result.exitCode ~= 0 then
      finishPoll()
      state.known = false
      state.sources = {}
      setError("Could not read audio sources")
      return
    end

    local ok, sources = pcall(noctalia.json.decode, result.stdout or "[]")
    if not ok or type(sources) ~= "table" then
      finishPoll()
      state.known = false
      setError("Could not parse audio sources")
      return
    end

    local filtered = {}
    for _, source in ipairs(sources) do
      local props = source.properties or {}
      local api = props["device.api"]
      local mediaClass = props["media.class"] or ""
      local name = source.name or ""
      if api and mediaClass == "Audio/Source" and not name:match("%.monitor$") then
        filtered[#filtered + 1] = {
          name = name,
          description = source.description or name,
          muted = source.mute == true,
          volume = (function()
            local volume = source.volume or {}
            local first = volume["front-left"] or volume["mono"] or volume["front-center"]
            return first and first.value_percent and tonumber(first.value_percent:match("[%d%.]+")) or nil
          end)(),
        }
      end

      if name == "rnnoise_source" then
        state.known = true
      end
    end
    table.sort(filtered, function(a, b) return a.description < b.description end)
    state.sources = filtered

    noctalia.runAsync({ "pw-link", "-l" }, function(linkResult)
      state.activeSource = ""
      if linkResult.exitCode == 0 then
        local inCaptureInputs = false
        for line in (linkResult.stdout or ""):gmatch("[^\r\n]+") do
          if line:match("^capture%.rnnoise_source:input_") then
            inCaptureInputs = true
          elseif inCaptureInputs and line:match("^%S") then
            inCaptureInputs = false
          elseif inCaptureInputs then
            local name = line:match("|<%- ([^:]+):")
            if name then state.activeSource = name; break end
          end
        end
      end
      for _, source in ipairs(state.sources) do
        if source.name == state.activeSource then
          state.muted = source.muted
          if requestedVolumeRevision == volumeRevision then
            local maximum = maxVolume()
            if source.volume and source.volume > maximum then
              setVolume(maximum)
            else
              state.volume = source.volume or state.volume
            end
          end
          break
        end
      end
      state.error = state.known and "" or "Processed microphone is unavailable"
      publish()
      local preferred = preferredSource()
      local sourceAvailable = false
      for _, source in ipairs(state.sources) do
        if source.name == preferred then sourceAvailable = true; break end
      end
      if preferred and sourceAvailable and state.activeSource ~= preferred and not applyingPreferred then
        applyingPreferred = true
        selectCaptureSource(preferred, false, function() applyingPreferred = false end)
      end
      finishPoll()
    end, 1000)
  end, 1500)
end

local function toggleMute()
  local sourceName = state.activeSource
  if sourceName == "" then
    setError("Could not find the active microphone input")
    return
  end
  local muted = not state.muted
  local previous = state.muted
  state.muted = muted
  for _, source in ipairs(state.sources) do
    if source.name == sourceName then source.muted = muted; break end
  end
  publish()
  local target = muted and "1" or "0"
  noctalia.runAsync({ "pactl", "set-source-mute", sourceName, target }, function(result)
    if result.exitCode ~= 0 then
      state.muted = previous
      for _, source in ipairs(state.sources) do
        if source.name == sourceName then source.muted = previous; break end
      end
      setError("Could not change microphone mute")
    else
      noctalia.osd.show(
        muted and "microphone-off" or "microphone",
        muted and "Muted" or "Microphone on",
        { inactive = muted }
      )
      poll()
    end
  end, 1000)
end

setVolume = function(value)
  local sourceName = state.activeSource
  if sourceName == "" then
    setError("Could not find the active microphone input")
    return
  end
  local target = math.clamp(math.floor(tonumber(value) or state.volume), 0, maxVolume())
  local previous = state.volume
  volumeRevision += 1
  state.volume = target
  for _, source in ipairs(state.sources) do
    if source.name == sourceName then source.volume = target; break end
  end
  publish()
  noctalia.runAsync({ "pactl", "set-source-volume", sourceName, tostring(target) .. "%" }, function(result)
    if result.exitCode ~= 0 then
      state.volume = previous
      for _, source in ipairs(state.sources) do
        if source.name == sourceName then source.volume = previous; break end
      end
      setError("Could not change microphone volume")
    else
      noctalia.osd.show(
        state.muted and "microphone-off" or "microphone",
        (target > 100 and "Boost · " or "") .. tostring(target) .. "%",
        { progress = math.clamp(target / 100, 0, 1), inactive = state.muted }
      )
      poll()
    end
  end, 1000)
end

local function changeVolume(detents)
  local step = tonumber(noctalia.getConfig("scroll_step")) or 5
  setVolume((tonumber(state.volume) or 100) + detents * step)
end

selectCaptureSource = function(name, persist, done)
  if name then
    local allowed = false
    for _, source in ipairs(state.sources) do
      if source.name == name then allowed = true; break end
    end
    if not allowed then return end
  end

  noctalia.runAsync({ "pw-dump" }, function(result)
    if result.exitCode ~= 0 then
      setError("Could not find the RNNoise filter")
      if done then done() end
      return
    end
    local ok, objects = pcall(noctalia.json.decode, result.stdout or "[]")
    if not ok or type(objects) ~= "table" then
      setError("Could not read the PipeWire graph")
      if done then done() end
      return
    end

    local filterId = nil
    for _, object in ipairs(objects) do
      local props = object.info and object.info.props or {}
      if object.type == "PipeWire:Interface:Node" and props["node.name"] == "rnnoise_source" then
        filterId = object.id
        break
      end
    end
    if not filterId then
      setError("Could not find the RNNoise filter")
      if done then done() end
      return
    end

    local encodedName = name and noctalia.json.encode(name)
    local target = encodedName and ('{ "node.name" = ' .. encodedName .. ' }')
      or '{ "media.class" = "Audio/Source", "device.api" = "alsa" }'
    noctalia.runAsync({
      "pw-metadata", "-n", "filters", tostring(filterId), "filter.smart.target", target, "Spa:String:JSON",
    }, function(metadataResult)
      if metadataResult.exitCode ~= 0 then
        setError("Could not switch the RNNoise input")
      else
        if persist then
          local dataDir = noctalia.pluginDataDir()
          if dataDir then
            if name then
              noctalia.writeFile(dataDir .. "/settings.json", noctalia.json.encode({ captureSource = name }))
            else
              noctalia.removeFile(dataDir .. "/settings.json")
            end
          end
        end
        poll()
      end
      if done then done() end
    end, 1500)
  end, 1500)
end

noctalia.state.watch(COMMAND_KEY, function(command)
  if type(command) ~= "table" then return end
  if command.action == "refresh" then
    poll()
  elseif command.action == "toggle_mute" then
    toggleMute()
  elseif command.action == "set_volume" then
    setVolume(command.value)
  elseif command.action == "change_volume" then
    local detents = tonumber(command.delta)
    if detents then
      changeVolume(detents)
    else
      changeVolume(command.direction == "up" and 1 or -1)
    end
  elseif command.action == "set_capture_source" and type(command.name) == "string" then
    selectCaptureSource(command.name, true)
  elseif command.action == "reset_capture_source" then
    selectCaptureSource(nil, true)
  end
end)

function onIpc(event)
  if event == "toggle_mute" then toggleMute() end
end

-- pactl subscribe reports source volume and mute changes made by other apps
-- (including pavucontrol). Keep the periodic poll as a fallback, and queue a
-- follow-up if an event arrives while a source snapshot is already in flight.
noctalia.runStream("pactl subscribe", function(line)
  if line:match("on source #") then poll() end
end)

poll()

function update()
  local interval = tonumber(noctalia.getConfig("poll_interval_ms")) or 500
  noctalia.setUpdateInterval(interval)
  poll()
end

function onConfigChanged()
  poll()
end

noctalia.setUpdateInterval(tonumber(noctalia.getConfig("poll_interval_ms")) or 500)
