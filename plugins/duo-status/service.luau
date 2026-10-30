--!nonstrict
-- Duo Status background service:
-- Continuously monitors battery power & wireless network connectivity,
-- renders the SVG badge on change, and manages power & wifi actions.

local svg = require("./svg.luau")

local STATE_KEY = "duo_status.state"
local ICON_KEY = "duo_status.icon_path"
local NETWORKS_KEY = "duo_status.networks"
local COMMAND_KEY = "duo_status.command"

svg.prune()

local state = {
  battery = {
    percent = 100,
    charging = false,
    status = "Unknown",
    powerSaver = false,
    profile = "balanced",
    watts = 0,
    timeRemaining = "",
  },
  network = {
    connected = false,
    type = "wifi", -- "wifi", "ethernet", "none"
    ssid = "",
    device = "",
    signal = 0,
    ip = "",
    frequency = "",
  },
}

local paletteCache = { key = "", colors = nil }

local function roleToPaletteKey(role)
  local map = {
    primary = "primary",
    on_primary = "onPrimary",
    surface = "surface",
    on_surface = "onSurface",
    on_surface_variant = "onSurfaceVariant",
    surface_container = "surfaceContainer",
    outline = "outline",
    outline_variant = "outlineVariant",
    error = "error",
    tertiary = "tertiary",
  }
  return map[role] or role
end

local function resolveColor(value, fallback)
  if type(value) ~= "string" or value == "" then return fallback end
  if value:match("^#%x+$") then return value end
  if noctalia.getSetting("theme.source") ~= "custom" then return fallback end
  local paletteName = noctalia.getSetting("theme.custom_palette")
  if not paletteName or paletteName == "" then return fallback end
  local mode = noctalia.isDarkMode() and "dark" or "light"
  local cacheKey = paletteName .. ":" .. mode

  if paletteCache.key ~= cacheKey then
    local raw = noctalia.readFile(noctalia.expandPath("~/.config/noctalia/palettes/" .. paletteName .. ".json"))
    local decoded = raw ~= nil and noctalia.json.decode(raw) or nil
    paletteCache = { key = cacheKey, colors = decoded ~= nil and decoded[mode] or nil }
  end

  if paletteCache.colors then
    return paletteCache.colors[roleToPaletteKey(value)] or fallback
  end
  return fallback
end

local function updateIcon()
  local colors = {
    normal = resolveColor(noctalia.getConfig("normal_color"), "#E2E8F0"),
    charging = resolveColor(noctalia.getConfig("charging_color"), "#34C759"),
    powerSaver = resolveColor(noctalia.getConfig("power_saver_color"), "#FFCC00"),
    critical = resolveColor(noctalia.getConfig("critical_color"), "#FF3B30"),
    lowThreshold = tonumber(noctalia.getConfig("low_battery_threshold")) or 20,
    criticalThreshold = tonumber(noctalia.getConfig("critical_battery_threshold")) or 10,
  }

  local path = svg.ensure(
    state.battery.percent,
    state.network.signal,
    state.battery.charging,
    state.battery.powerSaver,
    state.network.type,
    colors
  )
  if path and path ~= "" then
    noctalia.state.set(ICON_KEY, path)
  end
  noctalia.state.set(STATE_KEY, state)
end

-- ── Battery polling ──────────────────────────────────────────────────────────

local function pollBattery()
  local device = noctalia.getConfig("battery_device") or "BAT0"
  local root = "/sys/class/power_supply/" .. device

  local capRaw = noctalia.readFile(root .. "/capacity")
  if capRaw then
    state.battery.percent = tonumber(noctalia.string.trim(capRaw)) or state.battery.percent
  end

  local statusRaw = noctalia.readFile(root .. "/status")
  if statusRaw then
    local s = noctalia.string.trim(statusRaw)
    state.battery.status = s
    state.battery.charging = (s == "Charging")
  end

  -- Power rate in Watts
  local powerRaw = noctalia.readFile(root .. "/power_now")
  if powerRaw then
    local microwatts = tonumber(noctalia.string.trim(powerRaw)) or 0
    state.battery.watts = math.floor(microwatts / 100000) / 10.0 -- 1 decimal place
  else
    local curr = tonumber(noctalia.string.trim(noctalia.readFile(root .. "/current_now") or "0")) or 0
    local volt = tonumber(noctalia.string.trim(noctalia.readFile(root .. "/voltage_now") or "0")) or 0
    if curr > 0 and volt > 0 then
      state.battery.watts = math.floor((curr * volt / 100000000000.0) * 10) / 10.0
    end
  end

  -- Power profiles
  noctalia.runAsync("powerprofilesctl get 2>/dev/null", function(res)
    if res.exitCode == 0 and res.stdout ~= "" then
      local prof = noctalia.string.trim(res.stdout)
      state.battery.profile = prof
      state.battery.powerSaver = (prof == "power-saver")
      -- Publish right away. This callback races the upower one below, and the
      -- state was only published from that one, so a freshly switched profile
      -- reached the panel a whole poll late.
      updateIcon()
    end
  end)

  -- Time remaining via upower
  local upowerDevice = "/org/freedesktop/UPower/devices/battery_" .. device
  noctalia.runAsync("busctl --system get-property org.freedesktop.UPower " .. upowerDevice .. " org.freedesktop.UPower.Device " .. (state.battery.charging and "TimeToFull" or "TimeToEmpty") .. " 2>/dev/null", function(res)
    if res.exitCode == 0 and res.stdout ~= "" then
      local sec = tonumber(res.stdout:match("(%d+)"))
      -- Filter out bogus/infinite estimates (cap at 48 hours = 172800 seconds)
      if sec and sec > 60 and sec < 172800 then
        local hours = math.floor(sec / 3600)
        local mins = math.floor((sec % 3600) / 60)
        if hours > 0 then
          state.battery.timeRemaining = string.format("%dh %02dm", hours, mins)
        else
          state.battery.timeRemaining = string.format("%dm", mins)
        end
      else
        state.battery.timeRemaining = ""
      end
    end
    updateIcon()
  end)
end

-- ── Network polling ──────────────────────────────────────────────────────────

local function parseWireless()
  local raw = noctalia.readFile("/proc/net/wireless")
  if not raw then return nil end
  for line in raw:gmatch("[^\r\n]+") do
    local iface, quality = line:match("^%s*([%w%-_]+):%s*%x+%s*([%d%.]+)")
    if iface and quality then
      local q = tonumber(quality) or 0
      -- Link quality in /proc/net/wireless is usually out of 70
      local pct = math.floor((math.min(q, 70.0) / 70.0) * 100 + 0.5)
      return iface, pct
    end
  end
  return nil
end

local function pollNetwork()
  local wifiIface, qualityPct = parseWireless()

  noctalia.runAsync("nmcli -t -f TYPE,STATE,DEVICE,CONNECTION dev 2>/dev/null", function(res)
    if res.exitCode ~= 0 then return end
    local foundActive = false

    for line in res.stdout:gmatch("[^\r\n]+") do
      local parts = string.split(line, ":")
      local devType = parts[1]
      local devState = parts[2]
      local devName = parts[3]
      local connName = parts[4]

      if devState == "connected" then
        if devType == "wifi" then
          state.network.connected = true
          state.network.type = "wifi"
          state.network.device = devName
          state.network.ssid = connName or ""
          state.network.signal = qualityPct or state.network.signal
          foundActive = true
          break
        elseif devType == "ethernet" then
          state.network.connected = true
          state.network.type = "ethernet"
          state.network.device = devName
          state.network.ssid = connName or "Ethernet"
          state.network.signal = 100
          foundActive = true
          break
        end
      end
    end

    if not foundActive then
      state.network.connected = false
      state.network.type = "none"
      state.network.ssid = "Disconnected"
      state.network.signal = 0
    end

    -- Get IP address if connected
    if state.network.connected and state.network.device ~= "" then
      noctalia.runAsync("ip -br -4 addr show " .. state.network.device .. " 2>/dev/null", function(ipRes)
        if ipRes.exitCode == 0 and ipRes.stdout ~= "" then
          local ip = ipRes.stdout:match("%s+(%d+%.%d+%.%d+%.%d+)/")
          state.network.ip = ip or ""
        end
        updateIcon()
      end)
    else
      state.network.ip = ""
      updateIcon()
    end
  end)
end

local function shellQuote(s)
  return "'" .. string.gsub(tostring(s or ""), "'", "'\\''") .. "'"
end

local function scanNetworks()
  noctalia.runAsync("nmcli -t -f NAME connection show 2>/dev/null", function(savedRes)
    local saved = {}
    if savedRes and savedRes.exitCode == 0 and savedRes.stdout then
      for line in savedRes.stdout:gmatch("[^\r\n]+") do
        local name = string.gsub(line, "\\:", ":")
        saved[name] = true
      end
    end

    noctalia.runAsync("nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY,CHAN,FREQ dev wifi 2>/dev/null", function(res)
      if res.exitCode ~= 0 or not res.stdout then return end
      local list = {}
      local seen = {}

      for line in res.stdout:gmatch("[^\r\n]+") do
        local parts = string.split(line, ":")
        local inUse = (parts[1] == "*")
        local ssid = parts[2] or ""
        local signal = tonumber(parts[3]) or 0
        local security = parts[4] or ""
        local chan = parts[5] or ""
        local freq = parts[6] or ""

        if ssid ~= "" and not seen[ssid] then
          seen[ssid] = true
          local isSecured = (security ~= "" and security ~= "--")
          list[#list + 1] = {
            inUse = inUse,
            ssid = ssid,
            signal = signal,
            security = security,
            secured = isSecured,
            saved = (saved[ssid] == true),
            channel = chan,
            frequency = freq,
          }
        end
      end

      table.sort(list, function(a, b)
        if a.inUse ~= b.inUse then return a.inUse end
        return a.signal > b.signal
      end)

      noctalia.state.set(NETWORKS_KEY, list)
    end)
  end)
end

-- ── Command Handling ─────────────────────────────────────────────────────────

noctalia.state.watch(COMMAND_KEY, function(cmd)
  if type(cmd) ~= "table" then return end
  local action = cmd.action

  if action == "set_profile" and cmd.profile then
    noctalia.runAsync("powerprofilesctl set " .. shellQuote(cmd.profile), function()
      pollBattery()
    end)
  elseif action == "wifi_toggle" then
    local target = cmd.enabled and "on" or "off"
    noctalia.runAsync("nmcli radio wifi " .. target, function()
      pollNetwork()
    end)
  elseif action == "rescan" then
    noctalia.runAsync("nmcli dev wifi rescan", function()
      scanNetworks()
    end)
  elseif action == "connect" and cmd.ssid then
    local c = "nmcli dev wifi connect " .. shellQuote(cmd.ssid)
    if cmd.password and cmd.password ~= "" then
      c = c .. " password " .. shellQuote(cmd.password)
    end
    noctalia.runAsync(c, function(res)
      if res and res.exitCode ~= 0 then
        noctalia.state.set("duo_status.connect_error", {
          ssid = cmd.ssid,
          message = res.stderr or res.stdout or "Failed to connect",
          time = os.time(),
        })
      else
        noctalia.state.set("duo_status.connect_error", nil)
      end
      pollNetwork()
      scanNetworks()
    end)
  elseif action == "scan_networks" then
    scanNetworks()
  elseif action == "refresh" then
    pollBattery()
    pollNetwork()
  end
end)

-- ── Main Loop ────────────────────────────────────────────────────────────────

local function tick()
  pollBattery()
  pollNetwork()
end

tick()
scanNetworks()

local intervalSec = tonumber(noctalia.getConfig("poll_interval")) or 5
noctalia.setUpdateInterval(math.max(1000, intervalSec * 1000))

function update()
  tick()
end
