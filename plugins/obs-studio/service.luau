--!nonstrict
-- OBS Studio — headless [[service]] entry.
--
-- Talks to obs-websocket through `obs-cli` rather than reimplementing its
-- protocol. Custom buttons can call obs-cli or any host-configured command
-- through the same argument-array runAsync() every action here uses -- no
-- shell, no quoting to get wrong, and no dependency on private utilities.

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
  previewPath = "",
}

local polling = false

-- After a launch, poll faster than the configured refresh_interval for a
-- while so the bar/panel pick up the new connection within a couple of
-- seconds of OBS actually starting, rather than waiting out whatever
-- (possibly minutes-long) interval was configured.
local FAST_POLL_MS = 1000
local FAST_POLL_TICKS = 30 -- ~30s at FAST_POLL_MS, generous for a slow OBS start
local fastPollTicksLeft = 0

local function normalIntervalMs()
  return (tonumber(noctalia.getConfig("refresh_interval")) or 5) * 1000
end

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
        obs_cli = type(button.obs_cli) == "table" and button.obs_cli or nil,
        command = type(button.command) == "table" and button.command or nil,
        -- Shorthand for the common "flip a source filter/effect" case (e.g.
        -- OBS's Freeze filter) without having to spell out the equivalent
        -- `obs_cli: [filter, toggle, Source, Filter]` array by hand.
        filter_source = type(button.filter_source) == "string" and button.filter_source ~= "" and button.filter_source or nil,
        filter_name = type(button.filter_name) == "string" and button.filter_name ~= "" and button.filter_name or nil,
        filter_action = type(button.filter_action) == "string" and button.filter_action ~= "" and button.filter_action or "toggle",
        state_filter_source = type(button.state_filter_source) == "string" and button.state_filter_source ~= "" and button.state_filter_source or nil,
        state_filter_name = type(button.state_filter_name) == "string" and button.state_filter_name ~= "" and button.state_filter_name or nil,
        active_scene = type(button.active_scene) == "string" and button.active_scene ~= "" and button.active_scene or nil,
        bg = type(button.bg) == "string" and button.bg ~= "" and button.bg or nil,
        fg = type(button.fg) == "string" and button.fg ~= "" and button.fg or nil,
      })
    end
  end
  snapshot.customButtons = buttons
end

-- ── Scene screenshot preview ─────────────────────────────────────────────────

local previewToggle = false
local capturingScreenshot = false

local function captureScreenshot(onDone)
  if noctalia.getConfig("panel_show_screenshot") == false or snapshot.currentScene == "" then
    if onDone then onDone() end
    return
  end
  if capturingScreenshot then
    if onDone then onDone() end
    return
  end
  capturingScreenshot = true
  previewToggle = not previewToggle
  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
  local targetPath = string.format("%s/noctalia-obs-preview-%s.jpg", runtimeDir, previewToggle and "1" or "2")
  local argv = obsCliArgv({
    "source", "screenshot",
    "-o", targetPath,
    "-f", "jpg",
    "--compression-quality", "75",
    "--width", "480",
    "--height", "270",
    snapshot.currentScene,
  }, false)
  noctalia.runAsync(argv, function(result)
    capturingScreenshot = false
    if result.exitCode == 0 then
      snapshot.previewPath = targetPath
      publish()
    end
    if onDone then onDone() end
  end, STATUS_TIMEOUT_MS)
end

-- ── Polling ──────────────────────────────────────────────────────────────────

-- Custom buttons can expose state when their configuration describes something
-- stable to query: state_filter_source/state_filter_name for an OBS filter, or
-- active_scene for an action that selects a scene. There is no equivalent for
-- arbitrary obs_cli/command buttons -- those run an action with no fixed
-- notion of "on" or "off" to query.
local function pollButtonStates(onDone)
  local buttons = snapshot.customButtons
  local index = 0
  local function next_()
    index += 1
    local button = buttons[index]
    if not button then
      onDone()
      return
    end
    if button.active_scene then
      button.active = snapshot.currentScene == button.active_scene
      next_()
      return
    end
    local filterSource = button.state_filter_source or button.filter_source
    local filterName = button.state_filter_name or button.filter_name
    if not filterSource or not filterName then
      button.active = nil
      next_()
      return
    end
    noctalia.runAsync(
      obsCliArgv({ "-q", "filter", "status", filterSource, filterName }, false),
      function(result)
        button.active = result.exitCode == 0
        next_()
      end,
      STATUS_TIMEOUT_MS
    )
  end
  next_()
end

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
      snapshot.previewPath = ""
      -- obs-cli's own failure output is a full Python traceback (its rich
      -- ConnectionRefusedError dump, an auth error, ...) -- useful in a log,
      -- not as panel copy. Keep it out of the UI; log it for debugging and
      -- always show the same short, friendly reason there instead.
      local reason = trim(result.stderr)
      if reason ~= "" then
        noctalia.log("obs-studio: not reachable: " .. reason)
      end
      snapshot.error = noctalia.tr("panel.not_reachable")
      loadCustomButtons()
      publish()
      polling = false
      return
    end

    local previousScene = snapshot.currentScene
    local newScene = trim(result.stdout)
    local sceneChanged = (previousScene ~= "" and previousScene ~= newScene)
    local needInitialScreenshot = (snapshot.previewPath == "")

    snapshot.connected = true
    snapshot.currentScene = newScene
    snapshot.error = ""

    pollScenes(function()
      pollRecord(function()
        loadCustomButtons()
        pollButtonStates(function()
          publish()
          polling = false
          if sceneChanged or needInitialScreenshot then
            captureScreenshot()
          end
        end)
      end)
    end)
  end, STATUS_TIMEOUT_MS)
end

-- ── Commands ─────────────────────────────────────────────────────────────────

-- Split on whitespace into an argv for runAsync -- no shell, so no quoting
-- for a launcher argument with spaces, which is fine for a plain binary name
-- or a `gtk-launch <desktop-entry-id>` pair. Wrapped in a detached
-- `systemd-run --user --scope`: runAsync's own child (and OBS, its
-- descendant either way -- directly if launch_command execs it, or via
-- gtk-launch's fork) would otherwise sit in noctalia.service's own cgroup,
-- which systemd's default KillMode=control-group tears down along with
-- everything in it on every noctalia.service restart (e.g. every
-- `home-manager switch`) -- killing OBS along with it. The transient scope
-- lives outside that cgroup and survives.
local function launchArgv()
  local cmd = trim(noctalia.getConfig("launch_command"))
  if cmd == "" then cmd = "obs" end
  local argv = { "systemd-run", "--user", "--scope", "--collect", "--" }
  for token in cmd:gmatch("%S+") do
    table.insert(argv, token)
  end
  return argv
end

-- Deliberately not routed through run(): `obs` (unlike gtk-launch) is the
-- real GUI process and blocks for as long as OBS stays open, so chaining
-- poll() onto this callback would wait for OBS to *exit* before ever
-- checking it's up. The next periodic poll (setUpdateInterval below) picks
-- up the new connection once obs-websocket is actually listening instead.
local function launchObs()
  local argv = launchArgv()
  noctalia.log("obs-studio: launching " .. table.concat(argv, " "))
  fastPollTicksLeft = FAST_POLL_TICKS
  noctalia.setUpdateInterval(FAST_POLL_MS)
  noctalia.runAsync(argv, function(result)
    noctalia.log("obs-studio: launch exit=" .. tostring(result.exitCode) .. " stderr=" .. trim(result.stderr))
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.launch_failed_title"), trim(result.stderr))
    end
  end, 30000)
end

local function run(argv, notifyOnError)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 and notifyOnError then
      noctalia.notifyError(noctalia.tr("notify.action_failed_title"), trim(result.stderr))
    end
    poll()
    -- Refresh the preview even when the action did not change the current
    -- scene (custom buttons, mute, filters, etc.). Scene changes also get a
    -- second capture from poll() once the new scene name is known.
    captureScreenshot()
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

local FILTER_ACTIONS = { toggle = true, enable = true, disable = true }

local function runFilter(source, name, action)
  if type(source) ~= "string" or source == "" or type(name) ~= "string" or name == "" then return end
  if not FILTER_ACTIONS[action] then action = "toggle" end
  run(obsCliArgv({ "filter", action, source, name }, false), true)
end

local function toggleMute()
  local micInput = trim(noctalia.getConfig("mic_input_name"))
  if micInput ~= "" then
    run(obsCliArgv({ "input", "toggle-mute", micInput }, false), true)
  else
    noctalia.notifyError(noctalia.tr("notify.mic_input_missing_title"), noctalia.tr("notify.mic_input_missing_message"))
  end
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then return end
  local action = cmd.action
  noctalia.log("obs-studio: command action=" .. tostring(action))

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
    captureScreenshot()
  elseif action == "screenshot" then
    captureScreenshot()
  elseif action == "obs_cmd" then
    launchObs()
  elseif action == "run_obs_cli" and type(cmd.args) == "table" then
    run(obsCliArgv(cmd.args, false), true)
  elseif action == "run_command" and type(cmd.args) == "table" and #cmd.args > 0 then
    run(cmd.args, true)
  elseif action == "run_filter" then
    runFilter(cmd.source, cmd.name, cmd.filter_action)
  end
end)

function update()
  poll()
  -- refresh_interval is also the preview cadence once the service has left
  -- its short post-launch fast-poll window. captureScreenshot() is guarded
  -- against overlapping requests, so a slow OBS screenshot cannot pile up.
  if snapshot.connected and fastPollTicksLeft == 0 then
    captureScreenshot()
  end
  if fastPollTicksLeft > 0 then
    fastPollTicksLeft -= 1
    if snapshot.connected or fastPollTicksLeft == 0 then
      fastPollTicksLeft = 0
      noctalia.setUpdateInterval(normalIntervalMs())
    end
  end
end

function onConfigChanged()
  poll()
end

noctalia.setUpdateInterval((tonumber(noctalia.getConfig("refresh_interval")) or 5) * 1000)

loadCustomButtons()
publish()
poll()
