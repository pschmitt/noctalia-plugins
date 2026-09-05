--!nonstrict
-- Fan Control — headless [[service]] entry.
--
-- Fork of piero-93/thinkpad-fan, generalized past thinkpad_acpi to also drive
-- any fan exposed through the standard Linux hwmon PWM ABI (pwmN / pwmN_enable
-- / fanN_input under /sys/class/hwmon/hwmonN) — e.g. dell-smm-hwmon (Dell) or
-- gpdfan (GPD Pocket). Backend is auto-detected once per load: prefer
-- thinkpad_acpi's /proc/acpi/ibm/fan (its 0-7 levels are a distinct, richer
-- control than plain PWM), otherwise scan hwmon for a known/named chip.
--
-- Both backends publish the same "auto / full / manual 0-100%" shape so the
-- widget/panel don't need to know which is active.

local SNAPSHOT = "fan.snapshot"
local COMMAND = "fan.command"

local THINKPAD_FAN_PATH = "/proc/acpi/ibm/fan"
local HWMON_ROOT = "/sys/class/hwmon"
-- hwmon chip names known to expose the standard pwmN/pwmN_enable ABI for a
-- fan we want this plugin to drive. Extend via the hwmon_name setting for
-- anything else (e.g. nct6775/it87 on a desktop board).
local KNOWN_HWMON_NAMES = { dell_smm = true, gpdfan = true }
local MAX_HWMON_CHANNELS = 8

local POLL_MS = 2500
local READ_TIMEOUT_MS = 4000
local WRITE_TIMEOUT_MS = 4000
local SEP = "__NTF_SEP__"
local LOAD_SEP = "__NTF_LOAD_SEP__"
local CPU_SEP = "__NTF_CPU_SEP__"
local LOADAVG_PATH = "/proc/loadavg"
local POWER_PROFILES = {
  ["power-saver"] = true,
  balanced = true,
  performance = true,
}

-- backend = "thinkpad" | "hwmon" | "none". Detected once; cleared (like
-- configXml below) whenever the plugin settings change, since hwmon_name is a
-- setting.
local backend = nil
local hwmonDir = nil -- hwmon backend only: absolute path to the matched hwmon*/ dir
local hwmonChannels = {} -- hwmon backend only: array of channel numbers, e.g. {1, 2}
-- Hardware cannot distinguish Full from Manual at 100%: both are manual PWM
-- 255 to support dell-smm-hwmon. Keep the last explicit user choice for that
-- one ambiguous readback; a fresh service starts by reporting it as Full.
local hwmonMaxMode = nil -- "full" | "manual" | nil
local detecting = false
local detected = false

local snapshot = {
  backend = "none",
  available = false,
  temp = 0,
  mode = "auto", -- "auto" | "full" | "manual"
  level = "auto", -- thinkpad raw value, kept for its own tooltip text
  percent = 0, -- unified 0-100 manual duty, meaningful when mode == "manual"
  rpm = 0, -- primary/max RPM, for the widget
  fanCount = 0,
  fans = {}, -- hwmon only: { { rpm = N }, ... }, one per channel
  loadAvg = { one = 0, five = 0, fifteen = 0 },
  cpuCount = 0,
  powerProfile = "",
}

local reading = false
local readingPowerProfile = false
local readPowerProfile

-- Rolling temp/RPM/load history for the panel's graph, oldest first. Capped
-- rather than windowed by time: at the 2.5s poll interval this stores 10
-- minutes without the snapshot (re-sent to the panel on every poll) growing
-- unbounded.
local MAX_HISTORY = 240
local history = {}

local function pushHistory()
  table.insert(history, {
    temp = snapshot.temp,
    rpm = snapshot.rpm,
    load = snapshot.loadAvg.one,
  })
  if #history > MAX_HISTORY then
    table.remove(history, 1)
  end
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function thermalPath()
  local z = noctalia.getConfig("thermal_zone")
  if type(z) ~= "string" or z == "" then
    z = "thermal_zone0"
  end
  z = noctalia.string.trim(z):gsub("/+$", ""):match("[^/]+$") or "thermal_zone0"
  return "/sys/class/thermal/" .. z .. "/temp"
end

local function publish()
  noctalia.state.set(SNAPSHOT, {
    backend = snapshot.backend,
    available = snapshot.available,
    temp = snapshot.temp,
    mode = snapshot.mode,
    level = snapshot.level,
    percent = snapshot.percent,
    rpm = snapshot.rpm,
    fanCount = snapshot.fanCount,
    fans = snapshot.fans,
    loadAvg = snapshot.loadAvg,
    cpuCount = snapshot.cpuCount,
    powerProfile = snapshot.powerProfile,
    history = history,
  })
end

-- ── ThinkPad (thinkpad_acpi) backend ─────────────────────────────────────────

local function thinkpadModeAndPercent(level)
  if level == "auto" then
    return "auto", 0
  elseif level == "disengaged" then
    return "full", 100
  end
  local n = tonumber(level)
  if n then
    return "manual", math.floor(n * 100 / 7 + 0.5)
  end
  return "auto", 0
end

local function thinkpadLevelFromPercent(percent)
  local n = math.clamp(math.floor(percent * 7 / 100 + 0.5), 0, 7)
  return tostring(n)
end

local function parseThinkpad(content)
  if not content or content == "" then
    snapshot.available = false
    return
  end
  snapshot.available = true
  for line in content:gmatch("[^\n]+") do
    local rpm = line:match("^speed:%s*(%d+)")
    if rpm then
      snapshot.rpm = tonumber(rpm) or 0
      snapshot.fanCount = 1
      snapshot.fans = { { rpm = snapshot.rpm } }
    end
    local level = line:match("^level:%s*(%S+)")
    if level then
      level = noctalia.string.trim(level):lower()
      snapshot.level = level
      snapshot.mode, snapshot.percent = thinkpadModeAndPercent(level)
    end
  end
end

local function thinkpadReadCmd()
  return "cat " .. shellQuote(THINKPAD_FAN_PATH) .. " 2>/dev/null; echo " .. SEP
    .. "; cat " .. shellQuote(thermalPath()) .. " 2>/dev/null; echo " .. LOAD_SEP
    .. "; cat " .. LOADAVG_PATH .. " 2>/dev/null; echo " .. CPU_SEP .. "; nproc 2>/dev/null"
end

local function thinkpadWriteCmd(level)
  return "echo level " .. level .. " > " .. shellQuote(THINKPAD_FAN_PATH)
end

-- ── hwmon (generic PWM) backend ──────────────────────────────────────────────

local function hwmonModeAndPercent(channels)
  -- All channels are driven together, so the mode/percent shown is that of
  -- channel 1; a setup that somehow left channels disagreeing just shows the
  -- first one; the write path always re-applies the chosen mode to all.
  local first = channels[1]
  if not first then
    return "auto", 0
  end
  if first.enable == 2 then
    return "auto", 0
  elseif first.enable == 0 then
    return "full", 100
  elseif first.enable == 1 and first.pwm == 255 then
    return hwmonMaxMode or "full", 100
  end
  return "manual", math.floor((first.pwm or 0) * 100 / 255 + 0.5)
end

local function parseHwmon(content)
  if not content then
    snapshot.available = false
    return
  end
  local channels = {}
  local maxRpm = 0
  for _, chan in hwmonChannels do
    local pwm = tonumber(content:match("PWM" .. chan .. ":(%d+)"))
    local enable = tonumber(content:match("ENABLE" .. chan .. ":(%d+)"))
    local rpm = tonumber(content:match("RPM" .. chan .. ":(%d+)")) or 0
    if rpm > maxRpm then
      maxRpm = rpm
    end
    table.insert(channels, { pwm = pwm, enable = enable, rpm = rpm })
  end
  if #channels == 0 then
    snapshot.available = false
    return
  end
  snapshot.available = true
  snapshot.rpm = maxRpm
  snapshot.fanCount = #channels
  snapshot.fans = channels
  snapshot.mode, snapshot.percent = hwmonModeAndPercent(channels)
end

local function hwmonReadCmd()
  local parts = {}
  for _, chan in hwmonChannels do
    table.insert(
      parts,
      `echo PWM{chan}:$(cat {shellQuote(hwmonDir .. "/pwm" .. chan)} 2>/dev/null); `
        .. `echo ENABLE{chan}:$(cat {shellQuote(hwmonDir .. "/pwm" .. chan .. "_enable")} 2>/dev/null); `
        .. `echo RPM{chan}:$(cat {shellQuote(hwmonDir .. "/fan" .. chan .. "_input")} 2>/dev/null)`
    )
  end
  return table.concat(parts, "; ") .. "; echo " .. SEP .. "; cat " .. shellQuote(thermalPath())
    .. " 2>/dev/null; echo " .. LOAD_SEP .. "; cat " .. LOADAVG_PATH
    .. " 2>/dev/null; echo " .. CPU_SEP .. "; nproc 2>/dev/null"
end

-- `pwm*_enable = 0` is often described as full/no control, but it is not
-- universally supported (dell-smm-hwmon rejects it). Full is consequently
-- represented by manual control at PWM 255; automatic and manual modes use
-- the portable 2 and 1 values respectively.
local function hwmonWriteCmd(enable, pwmValue, selectedIndex)
  local parts = {}
  for i, chan in hwmonChannels do
    local enablePath = shellQuote(hwmonDir .. "/pwm" .. chan .. "_enable")
    table.insert(parts, "echo " .. enable .. " > " .. enablePath)
    if pwmValue and (not selectedIndex or i == selectedIndex) then
      table.insert(parts, "echo " .. pwmValue .. " > " .. shellQuote(hwmonDir .. "/pwm" .. chan))
    end
  end
  return table.concat(parts, "; ")
end

-- ── Backend detection ────────────────────────────────────────────────────────

local function extraHwmonNames()
  local extra = noctalia.string.trim(noctalia.getConfig("hwmon_name") or "")
  return extra ~= "" and extra or nil
end

local function detectCmd()
  local nameChecks = {}
  for name in KNOWN_HWMON_NAMES do
    table.insert(nameChecks, name)
  end
  local extra = extraHwmonNames()
  if extra then
    table.insert(nameChecks, extra)
  end
  local nameList = table.concat(nameChecks, " ")
  local channelChecks = {}
  for i = 1, MAX_HWMON_CHANNELS do
    table.insert(channelChecks, `[ -e "$d/pwm{i}" ] && echo CHAN:{i}`)
  end
  return "if [ -r " .. shellQuote(THINKPAD_FAN_PATH) .. " ]; then\n"
    .. "  echo BACKEND:thinkpad\n"
    .. "else\n"
    .. "  for d in " .. HWMON_ROOT .. "/hwmon*; do\n"
    .. "    n=$(cat \"$d/name\" 2>/dev/null)\n"
    .. "    for want in " .. nameList .. "; do\n"
    .. "      if [ \"$n\" = \"$want\" ]; then\n"
    .. "        echo BACKEND:hwmon\n"
    .. "        echo HWMONDIR:$d\n"
    .. "        " .. table.concat(channelChecks, "\n        ") .. "\n"
    .. "        exit 0\n"
    .. "      fi\n"
    .. "    done\n"
    .. "  done\n"
    .. "  echo BACKEND:none\n"
    .. "fi"
end

local function runDetect(cb)
  if detecting then
    return
  end
  detecting = true
  local launched = noctalia.runAsync(detectCmd(), function(res)
    detecting = false
    local out = res.stdout or ""
    backend = out:match("BACKEND:(%a+)") or "none"
    hwmonDir = out:match("HWMONDIR:(%S+)")
    hwmonChannels = {}
    hwmonMaxMode = nil
    for chan in out:gmatch("CHAN:(%d+)") do
      table.insert(hwmonChannels, tonumber(chan))
    end
    detected = true
    snapshot.backend = backend
    cb()
  end, READ_TIMEOUT_MS)
  if not launched then
    detecting = false
  end
end

-- ── Polling ──────────────────────────────────────────────────────────────────

local function readNow()
  if reading then
    return
  end
  if backend == "none" then
    snapshot.available = false
    publish()
    return
  end
  reading = true
  local cmd = (backend == "thinkpad") and thinkpadReadCmd() or hwmonReadCmd()
  local launched = noctalia.runAsync(cmd, function(res)
    reading = false
    local out = res.stdout or ""
    local sepAt = out:find(SEP, 1, true)
    local body = sepAt and out:sub(1, sepAt - 1) or out
    local tempAndLoad = sepAt and out:sub(sepAt + #SEP) or ""
    local loadAt = tempAndLoad:find(LOAD_SEP, 1, true)
    local tempOut = loadAt and tempAndLoad:sub(1, loadAt - 1) or tempAndLoad
    local loadAndCpuOut = loadAt and tempAndLoad:sub(loadAt + #LOAD_SEP) or ""
    local cpuAt = loadAndCpuOut:find(CPU_SEP, 1, true)
    local loadOut = cpuAt and loadAndCpuOut:sub(1, cpuAt - 1) or loadAndCpuOut
    local cpuOut = cpuAt and loadAndCpuOut:sub(cpuAt + #CPU_SEP) or ""
    if backend == "thinkpad" then
      parseThinkpad(body)
    else
      parseHwmon(body)
    end
    local raw = tonumber(noctalia.string.trim(tempOut))
    if raw then
      snapshot.temp = math.floor(raw / 1000 + 0.5)
    end
    local loadOne, loadFive, loadFifteen = loadOut:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
    if loadOne then
      snapshot.loadAvg = {
        one = tonumber(loadOne) or 0,
        five = tonumber(loadFive) or 0,
        fifteen = tonumber(loadFifteen) or 0,
      }
    end
    local cpuCount = tonumber(noctalia.string.trim(cpuOut))
    if cpuCount and cpuCount > 0 then
      snapshot.cpuCount = cpuCount
    end
    if snapshot.available then
      pushHistory()
    end
    publish()
  end, READ_TIMEOUT_MS)
  if not launched then
    reading = false
  end
end

readPowerProfile = function()
  if readingPowerProfile then
    return
  end
  readingPowerProfile = true
  local launched = noctalia.runAsync("powerprofilesctl get 2>/dev/null", function(res)
    readingPowerProfile = false
    local profile = noctalia.string.trim(res.stdout or "")
    snapshot.powerProfile = POWER_PROFILES[profile] and profile or ""
    publish()
  end, READ_TIMEOUT_MS)
  if not launched then
    readingPowerProfile = false
  end
end

local function poll()
  if noctalia.getConfig("alt_mode") == true then
    -- Keep this independent from hwmon reads: a missing/slow
    -- powerprofilesctl must not delay RPM or temperature updates.
    readPowerProfile()
  end
  if not detected then
    runDetect(readNow)
  else
    readNow()
  end
end

-- ── Commands from UI entries ─────────────────────────────────────────────────

-- Relies on plain group-file permissions (fan_ctl, from the setup script/
-- NixOS module): noctalia's own process needs to have been started *after*
-- that group existed to have it. True on any normal boot (the group/udev
-- rule are already there before login), so this is not wrapped in `sg`/
-- `newgrp` — that only matters right after *adding* the group to an
-- already-running session, and re-logging in (or rebooting) once at setup
-- time is a one-off, not a steady-state runtime dependency.
local function runWrite(cmd, onDone)
  noctalia.runAsync(cmd, function(res)
    if res.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.fan_error_title"), noctalia.tr("notify.fan_error_body"))
      noctalia.log("fan control write failed: " .. (res.stderr or ""))
    end
    onDone()
  end, WRITE_TIMEOUT_MS)
end

-- When leaving Auto, hwmon's current PWM is the best available estimate of
-- the firmware-selected duty. ThinkPad's "auto" does not report one, so use
-- a conservative 50% starting point instead of an unexpected full blast.
local function manualStartPercent()
  if backend == "hwmon" then
    local first = snapshot.fans[1]
    local pwm = first and tonumber(first.pwm)
    if pwm then
      return math.clamp(math.floor(pwm * 100 / 255 + 0.5), 0, 100)
    end
  end
  return 50
end

-- Auto/full are absolute mode writes; Manual uses the current PWM estimate
-- when available. The sliders then change individual channels where the
-- backend exposes more than one.
local function applyMode(mode)
  if backend == "thinkpad" then
    local level
    if mode == "auto" then
      level = "auto"
      snapshot.percent = 0
    elseif mode == "full" then
      level = "disengaged"
      snapshot.percent = 100
    else
      snapshot.percent = manualStartPercent()
      level = thinkpadLevelFromPercent(snapshot.percent)
    end
    snapshot.level = level
    snapshot.mode = mode
    publish()
    runWrite(thinkpadWriteCmd(level), readNow)
  elseif backend == "hwmon" then
    snapshot.mode = mode
    if mode == "auto" then
      hwmonMaxMode = nil
      snapshot.percent = 0
      publish()
      runWrite(hwmonWriteCmd(2, nil), readNow)
    else
      hwmonMaxMode = mode
      snapshot.percent = mode == "manual" and manualStartPercent() or 100
      publish()
      local pwmValue = math.floor(snapshot.percent * 255 / 100 + 0.5)
      runWrite(hwmonWriteCmd(1, pwmValue), readNow)
    end
  end
end

local function applyPercent(percent, selectedIndex)
  percent = math.clamp(math.floor(tonumber(percent) or 0), 0, 100)
  snapshot.mode = "manual"
  snapshot.percent = percent
  publish()
  if backend == "thinkpad" then
    local level = thinkpadLevelFromPercent(percent)
    snapshot.level = level
    runWrite(thinkpadWriteCmd(level), readNow)
  elseif backend == "hwmon" then
    hwmonMaxMode = "manual"
    local pwmValue = math.clamp(math.floor(percent * 255 / 100 + 0.5), 0, 255)
    if selectedIndex then
      for i, fan in snapshot.fans do
        if i == selectedIndex then
          fan.pwm = pwmValue
        end
        fan.enable = 1
      end
    end
    runWrite(hwmonWriteCmd(1, pwmValue, selectedIndex), readNow)
  end
end

local function applyPowerProfile(profile)
  if not POWER_PROFILES[profile] then
    return
  end
  snapshot.powerProfile = profile
  publish()
  noctalia.runAsync("powerprofilesctl set " .. shellQuote(profile), function(res)
    if res.exitCode ~= 0 then
      noctalia.notifyError(
        noctalia.tr("notify.power_profile_error_title"),
        noctalia.tr("notify.power_profile_error_body")
      )
      noctalia.log("power-profile change failed: " .. (res.stderr or ""))
    end
    readPowerProfile()
  end, WRITE_TIMEOUT_MS)
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if noctalia.getConfig("alt_mode") == true then
    if cmd.action == "set_power_profile" then
      applyPowerProfile(cmd.profile)
    end
    return
  end
  if not detected or backend == "none" then
    return
  end
  if cmd.action == "set_mode" and (cmd.mode == "auto" or cmd.mode == "full" or cmd.mode == "manual") then
    applyMode(cmd.mode)
  elseif cmd.action == "set_percent" then
    applyPercent(cmd.value, tonumber(cmd.index))
  end
end)

function update()
  poll()
end

function onConfigChanged()
  reading = false
  detected = false
  poll()
end

noctalia.setUpdateInterval(POLL_MS)

publish()
poll()
