--!nonstrict
-- OBS Studio — headless [[service]] entry.
--
-- Talks to obs-websocket through two existing CLIs rather than reimplementing
-- either: `obs-cli` (pschmitt/obs-cli) for scene/record/stream/virtualcam/
-- input status and switching, and `obs-control` (pkgs/local/obs-control) for
-- the higher-level actions it already owns (mic mute that also syncs OBS's
-- "Microphone off" overlay, scene shortcuts, freeze-filter toggle, replay,
-- emoji reactions). Custom buttons can call either, or any other command,
-- through the same argument-array runAsync() every action here uses -- no
-- shell, no quoting to get wrong.

local configFile = require("./lib/config.luau")

local SNAPSHOT = "obs.snapshot"
local COMMAND = "obs.command"
local STATUS_TIMEOUT_MS = 4000
local ACTION_TIMEOUT_MS = 8000
local CUSTOM_BUTTONS_FILE = "obs-studio.yaml"

local snapshot = {
  connected = false,
  currentScene = "",
  scenes = {}, -- array of { name = ..., index = ... }
  recording = false,
  streaming = false,
  virtualcam = false,
  micMuted = nil, -- boolean, or nil when mic_input_name isn't configured
  error = "",
  customButtons = {},
}

local polling = false

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function expandHome(path)
  path = trim(path)
  if path:sub(1, 2) == "~/" then
    local home = noctalia.getenv("HOME") or ""
    return home .. path:sub(2)
  end
  return path
end

local function password()
  local path = expandHome(noctalia.getConfig("password_file"))
  if path == "" then return "" end
  local content = noctalia.readFile(path)
  return content and trim(content) or ""
end

-- Base argv shared by every obs-cli invocation: binary, connection flags, and
-- (only when configured) the password flag. `wantJson` appends `-j` for
-- commands that support structured output; the boolean status subcommands
-- deliberately don't use it (see below), relying on exit code instead.
local function obsCliArgv(subArgs, wantJson)
  local argv = {
    trim(noctalia.getConfig("obs_cli_path")) ~= "" and noctalia.getConfig("obs_cli_path") or "obs-cli",
    "-H", trim(noctalia.getConfig("host")) ~= "" and noctalia.getConfig("host") or "localhost",
    "-P", tostring(tonumber(noctalia.getConfig("port")) or 6277),
  }
  local pw = password()
  if pw ~= "" then
    table.insert(argv, "-p")
    table.insert(argv, pw)
  end
  if wantJson then
    table.insert(argv, "-j")
  end
  for _, arg in subArgs do
    table.insert(argv, tostring(arg))
  end
  return argv
end

local function obsControlArgv(subArgs)
  local argv = {
    trim(noctalia.getConfig("obs_control_path")) ~= "" and noctalia.getConfig("obs_control_path") or "obs-control",
  }
  for _, arg in subArgs do
    table.insert(argv, tostring(arg))
  end
  return argv
end

local function publish()
  noctalia.state.set(SNAPSHOT, snapshot)
end

-- ── Custom buttons (declarative, read-only config) ──────────────────────────
-- ~/.config/noctalia/obs-studio.yaml, the same base-file convention
-- pschmitt/ha's ha.yaml uses -- a plain Home Manager-managed file, no writable
-- state overlay, since buttons aren't edited from the panel.

local function xdgPath(variable, fallback)
  local value = noctalia.getenv(variable)
  if type(value) ~= "string" or value == "" then value = noctalia.getenv("HOME") .. fallback end
  return value
end

local function customButtonsPath()
  return xdgPath("XDG_CONFIG_HOME", "/.config") .. "/noctalia/" .. CUSTOM_BUTTONS_FILE
end

local function loadCustomButtons()
  local text = noctalia.readFile(customButtonsPath())
  if not text or text == "" then
    snapshot.customButtons = {}
    return
  end
  local ok, parsed = pcall(configFile.parse, text)
  if not ok or type(parsed) ~= "table" then
    noctalia.log("obs-studio: failed to parse " .. CUSTOM_BUTTONS_FILE)
    snapshot.customButtons = {}
    return
  end
  local buttons = {}
  for _, button in parsed.buttons or {} do
    if type(button.label) == "string" and button.label ~= "" then
      table.insert(buttons, {
        label = button.label,
        icon = type(button.icon) == "string" and button.icon ~= "" and button.icon or "player-play",
        obs_control = type(button.obs_control) == "string" and button.obs_control or nil,
        obs_cli = type(button.obs_cli) == "table" and button.obs_cli or nil,
        command = type(button.command) == "table" and button.command or nil,
      })
    end
  end
  snapshot.customButtons = buttons
end

-- ── Polling ──────────────────────────────────────────────────────────────────

local function pollMicMute(onDone)
  local micInput = trim(noctalia.getConfig("mic_input_name"))
  if micInput == "" then
    snapshot.micMuted = nil
    onDone()
    return
  end
  noctalia.runAsync(obsCliArgv({ "input", "is-muted", micInput }, false), function(result)
    if result.exitCode == 0 then
      snapshot.micMuted = trim(result.stdout) == "enabled"
    end
    onDone()
  end, STATUS_TIMEOUT_MS)
end

local function pollVirtualcam(onDone)
  noctalia.runAsync(obsCliArgv({ "-q", "virtualcam", "status" }, false), function(result)
    snapshot.virtualcam = result.exitCode == 0
    pollMicMute(onDone)
  end, STATUS_TIMEOUT_MS)
end

local function pollStream(onDone)
  noctalia.runAsync(obsCliArgv({ "-q", "stream", "status" }, false), function(result)
    snapshot.streaming = result.exitCode == 0
    pollVirtualcam(onDone)
  end, STATUS_TIMEOUT_MS)
end

local function pollRecord(onDone)
  noctalia.runAsync(obsCliArgv({ "-q", "record", "status" }, false), function(result)
    snapshot.recording = result.exitCode == 0
    pollStream(onDone)
  end, STATUS_TIMEOUT_MS)
end

local function pollScenes(onDone)
  noctalia.runAsync(obsCliArgv({ "scene", "list" }, true), function(result)
    if result.exitCode ~= 0 then
      onDone()
      return
    end
    local decoded = noctalia.json.decode(result.stdout or "")
    if type(decoded) ~= "table" then
      onDone()
      return
    end
    local scenes = {}
    for _, scene in decoded do
      table.insert(scenes, {
        name = scene.sceneName,
        index = tonumber(scene.sceneIndex) or 0,
      })
    end
    table.sort(scenes, function(a, b) return a.index < b.index end)
    snapshot.scenes = scenes
    onDone()
  end, STATUS_TIMEOUT_MS)
end

local function poll()
  if polling then return end
  polling = true

  noctalia.runAsync(obsCliArgv({ "scene", "current" }, false), function(result)
    if result.exitCode ~= 0 then
      snapshot.connected = false
      snapshot.currentScene = ""
      snapshot.scenes = {}
      snapshot.recording = false
      snapshot.streaming = false
      snapshot.virtualcam = false
      snapshot.micMuted = nil
      snapshot.error = trim(result.stderr) ~= "" and trim(result.stderr) or "OBS is not reachable"
      loadCustomButtons()
      publish()
      polling = false
      return
    end

    snapshot.connected = true
    snapshot.currentScene = trim(result.stdout)
    snapshot.error = ""

    pollScenes(function()
      pollRecord(function()
        loadCustomButtons()
        publish()
        polling = false
      end)
    end)
  end, STATUS_TIMEOUT_MS)
end

-- ── Commands ─────────────────────────────────────────────────────────────────

local function run(argv, notifyOnError)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 and notifyOnError then
      noctalia.notifyError(noctalia.tr("notify.action_failed_title"), trim(result.stderr))
    end
    poll()
  end, ACTION_TIMEOUT_MS)
end

local function switchScene(name)
  if type(name) ~= "string" or name == "" then return end
  run(obsCliArgv({ "scene", "switch", name }, false), true)
end

local function stepScene(direction)
  local scenes = snapshot.scenes
  if #scenes == 0 then return end
  local currentIndex = 1
  for i, scene in scenes do
    if scene.name == snapshot.currentScene then
      currentIndex = i
      break
    end
  end
  local nextIndex = ((currentIndex - 1 + direction) % #scenes) + 1
  switchScene(scenes[nextIndex].name)
end

local function toggleMute()
  local micInput = trim(noctalia.getConfig("mic_input_name"))
  if micInput ~= "" then
    run(obsCliArgv({ "input", "toggle-mute", micInput }, false), true)
  else
    run(obsControlArgv({ "toggle-mute" }), true)
  end
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then return end
  local action = cmd.action

  if action == "switch_scene" then
    switchScene(cmd.scene)
  elseif action == "next_scene" then
    stepScene(1)
  elseif action == "prev_scene" then
    stepScene(-1)
  elseif action == "toggle_record" then
    run(obsCliArgv({ "record", "toggle" }, false), true)
  elseif action == "toggle_stream" then
    run(obsCliArgv({ "stream", "toggle" }, false), true)
  elseif action == "toggle_virtualcam" then
    run(obsCliArgv({ "virtualcam", "toggle" }, false), true)
  elseif action == "toggle_mute" then
    toggleMute()
  elseif action == "refresh" then
    poll()
  elseif action == "run_obs_control" and type(cmd.args) == "table" then
    run(obsControlArgv(cmd.args), true)
  elseif action == "run_obs_cli" and type(cmd.args) == "table" then
    run(obsCliArgv(cmd.args, false), true)
  elseif action == "run_command" and type(cmd.args) == "table" and #cmd.args > 0 then
    run(cmd.args, true)
  end
end)

function update()
  poll()
end

function onConfigChanged()
  poll()
end

noctalia.setUpdateInterval((tonumber(noctalia.getConfig("refresh_interval")) or 5) * 1000)

loadCustomButtons()
publish()
poll()
