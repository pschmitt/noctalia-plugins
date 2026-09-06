--!nonstrict
-- Battery icon poller — renders a small Material 3 Expressive-style PNG
-- (clipped charge level and percentage inside the battery body, plus a
-- terminal or charging bolt) via ImageMagick whenever the charge level,
-- power state, or relevant settings change.
--
-- The bar-widget ui.* framework (row/column/box/label, all pure flex
-- layout) has no overlay/z-stack primitive, and even Noctalia's own
-- built-in "graphic" battery display mode places its percentage label
-- beside the icon, not on top of it (confirmed against battery_widget.cpp
-- upstream). A live-generated bitmap is the only way to draw the number
-- literally inside the shape instead of next to it.

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function sanitize(s)
  return tostring(s):gsub("[^%w]", "")
end

local lastKey = ""

-- nil until the first status read, so a charger already connected when the
-- service (re)starts doesn't trigger the sound — only an actual plug-in
-- edge does.
local lastCharging = nil

-- Same nil-on-(re)start convention as lastCharging: an already-low battery
-- when the service (re)starts must not immediately fire the critical alarm.
local lastLow = nil

-- Last successfully read power profile. A failed or empty `powerprofilesctl`
-- read is "unknown", not "off": several poll()s fire at once when the shell
-- restarts (the initial poll plus every stream's first line), and treating a
-- dropped read as false made the icon flip its Battery Saver glyph off again
-- moments after correctly showing it -- observed on gk4 as 69ds and 69dn
-- rendered nine seconds apart while the profile never changed.
local lastPowerSaver = false
local lastProfile = nil
local soundReady = { charging = false, unplug = false }

local DETAILS = "battery_icon.details"
local COMMAND = "battery_icon.command"
local FAN_STATE = "battery_icon.fan"
local POWER_PROFILES = {
  ["power-saver"] = true,
  balanced = true,
  performance = true,
}

local fanBackend = "none"
local fanDir = nil
local fanChannels = {}
local readingFan = false
local fanSnapshot = {
  available = false,
  backend = "none",
  mode = "auto",
  percent = 0,
  rpm = 0,
  cpuCount = 1,
  temp = 0,
  loadAvg = { one = 0, five = 0, fifteen = 0 },
}

-- "Is external power connected?", most portable source first.
--
-- upower's daemon-level OnBattery property is the canonical answer: it
-- aggregates *every* line-power supply the kernel exposes, so it covers
-- USB-C PD sources and docks as well as a classic barrel jack, on any
-- distro, without us knowing any device names. Prints "b false" when
-- plugged in, "b true" on battery.
--
-- If upower isn't running (busctl exits non-zero) fall back to scanning
-- sysfs for line-power supplies ourselves, selecting them by `type` since
-- the device name isn't portable (AC, ACAD, AC0, ADP1, ...). That prints
-- one 0/1 line per Mains supply, or nothing when the machine exposes none.
local AC_ONLINE_CMD = "@busctl@ --system get-property org.freedesktop.UPower "
  .. "/org/freedesktop/UPower org.freedesktop.UPower OnBattery 2>/dev/null || "
  .. "grep -lx Mains /sys/class/power_supply/*/type 2>/dev/null | sed 's|/type$|/online|' | xargs -r cat 2>/dev/null"

-- The charge level, from upower for the same reasons and — more importantly
-- — from the *same place* as the plug state above. The two sources disagree:
-- upower derives Percentage from energy rather than reading the kernel's
-- capacity, and on this laptop reports 97 where sysfs says 98. So which one
-- wins has to be settled once for the whole widget instead of per read, or
-- the number visibly flickers depending on which path updated it last.
-- Pairing them means upower answers both questions when it's running and
-- sysfs answers both when it isn't; they are never mixed.
--
-- The same call also reports the battery's charge limit, so the two reads
-- cost one process instead of two. Exactly two lines come back: the level
-- ("d 97" from upower's typed double, or a bare "97" from the kernel), then
-- the limit ("u 80", a bare "90", or empty when there is none).
--
-- The limit is only meaningful when the firmware is actually enforcing it.
-- ge2 advertises ChargeEndThreshold=80 while ChargeThresholdEnabled=false
-- and happily charges to 98, so reading the threshold without checking the
-- enabled flag would cap the scale at a limit that isn't in effect. Only
-- when upower is absent entirely do we fall back to the kernel's own knob.
local function batteryCommand(device)
  local dev = "/org/freedesktop/UPower/devices/battery_" .. device
  local prop = "@busctl@ --system get-property org.freedesktop.UPower " .. dev .. " org.freedesktop.UPower.Device "
  return "p=$("
    .. prop
    .. "Percentage 2>/dev/null || cat /sys/class/power_supply/"
    .. device
    .. "/capacity 2>/dev/null); "
    .. "e=$("
    .. prop
    .. "ChargeThresholdEnabled 2>/dev/null); "
    .. 'if [ "$e" = "b true" ]; then l=$('
    .. prop
    .. "ChargeEndThreshold 2>/dev/null); "
    .. 'elif [ -z "$e" ]; then l=$(cat /sys/class/power_supply/'
    .. device
    .. '/charge_control_end_threshold 2>/dev/null); else l=""; fi; '
    .. [[printf '%s\n%s\n' "$p" "$l"]]
end

-- Strips busctl's leading type tag ("d 97", "u 80") when present, so the
-- same parser handles a typed D-Bus reply and a bare sysfs number.
local function parseNumber(s)
  local raw = trim(s)
  local n = tonumber(raw:match("^%a%s+(.+)$") or raw)
  return n ~= nil and math.round(n) or nil
end

-- Main-pack health and charge thresholds are exposed by the kernel when the
-- firmware supports them. Other UPower devices (mouse, headset, keyboard,
-- phone, ...) are collected alongside it for the power panel; the bar icon
-- continues to be driven only by the configured main battery.
local function detailsCommand(device)
  local root = "/sys/class/power_supply/" .. device
  local mainPath = "/org/freedesktop/UPower/devices/battery_" .. device
  return "full=$(cat " .. root .. "/energy_full 2>/dev/null || cat " .. root
    .. "/charge_full 2>/dev/null); design=$(cat " .. root
    .. "/energy_full_design 2>/dev/null || cat " .. root
    .. "/charge_full_design 2>/dev/null); start=$(cat " .. root
    .. "/charge_control_start_threshold 2>/dev/null); finish=$(cat " .. root
    .. "/charge_control_end_threshold 2>/dev/null); rate=$(cat " .. root
    .. "/power_now 2>/dev/null); if [ -z \"$rate\" ]; then current=$(cat " .. root
    .. "/current_now 2>/dev/null); voltage=$(cat " .. root
    .. "/voltage_now 2>/dev/null); [ -n \"$current\" ] && [ -n \"$voltage\" ] && rate=$((current * voltage / 1000000)); fi; tofull=$(@busctl@ --system get-property org.freedesktop.UPower "
    .. mainPath
    .. " org.freedesktop.UPower.Device TimeToFull 2>/dev/null); toempty=$(@busctl@ --system get-property org.freedesktop.UPower "
    .. mainPath
    .. " org.freedesktop.UPower.Device TimeToEmpty 2>/dev/null); printf 'BATTERY\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$full\" \"$design\" \"$start\" \"$finish\" \"$rate\" \"$tofull\" \"$toempty\"; "
    .. "@upower@ -e 2>/dev/null | while IFS= read -r d; do [ \"$d\" = "
    .. "'" .. mainPath .. "' ] && continue; [ \"$d\" = '/org/freedesktop/UPower/devices/DisplayDevice' ] && continue; info=$(@upower@ -i \"$d\" 2>/dev/null); percent=$(printf '%s\\n' \"$info\" | @sed@ -n 's/^[[:space:]]*percentage:[[:space:]]*\\([0-9][0-9]*\\)%.*/\\1/p'); [ -z \"$percent\" ] && continue; label=$(printf '%s\\n' \"$info\" | @sed@ -n 's/^[[:space:]]*model:[[:space:]]*//p'); [ -z \"$label\" ] && label=${d##*/}; kind=$(printf '%s\\n' \"$info\" | @sed@ -n 's/^[[:space:]]*\\(mouse\\|keyboard\\|phone\\|tablet\\|touchpad\\|headset\\|headphones\\)$/\\1/p'); state=$(printf '%s\\n' \"$info\" | @sed@ -n 's/^[[:space:]]*state:[[:space:]]*//p'); printf 'DEVICE\\t%s\\t%s\\t%s\\t%s\\n' \"$label\" \"$percent\" \"$kind\" \"$state\"; done"
end

local function parseDetails(output)
  local details = {
    health = nil,
    thresholdStart = nil,
    thresholdEnd = nil,
    rateWatts = nil,
    timeToFull = nil,
    timeToEmpty = nil,
    devices = {},
  }
  for line in (output or ""):gmatch("[^\n]+") do
    local full, design, start, finish, rate, toFull, toEmpty =
      line:match("^BATTERY\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if full then
      local fullValue = tonumber(full)
      local designValue = tonumber(design)
      if fullValue and designValue and designValue > 0 then
        details.health = math.clamp(math.round(fullValue * 100 / designValue), 0, 100)
      end
      details.thresholdStart = tonumber(start)
      details.thresholdEnd = tonumber(finish)
      local rateMicrowatts = tonumber(rate)
      if rateMicrowatts then
        details.rateWatts = rateMicrowatts / 1000000
      end
      details.timeToFull = parseNumber(toFull)
      details.timeToEmpty = parseNumber(toEmpty)
    else
      local label, percent, kind, state = line:match("^DEVICE\t(.-)\t(%d+)\t(.-)\t(.-)$")
      if label and percent then
        table.insert(details.devices, { label = label, percent = tonumber(percent), kind = kind, state = state })
      end
    end
  end
  return details
end

local function publishDetails(percent, charging, status, profile, limit, thresholdGuessed, caffeineEnabled, output)
  local details = parseDetails(output)
  noctalia.state.set(DETAILS, {
    percent = percent,
    charging = status == "Charging",
    plugged = charging,
    status = status,
    powerProfile = POWER_PROFILES[profile] and profile or "",
    chargeLimit = limit,
    thresholdGuessed = thresholdGuessed,
    caffeineEnabled = caffeineEnabled,
    health = details.health,
    thresholdStart = details.thresholdStart,
    thresholdEnd = details.thresholdEnd,
    rateWatts = details.rateWatts,
    timeToFull = details.timeToFull,
    timeToEmpty = details.timeToEmpty,
    devices = details.devices,
  })
end

local CAFFEINE_FALLBACK_UNIT = "noctalia-battery-caffeine"

-- Noctalia 5.0.1 exposes the caffeine CLI commands but its running daemon
-- does not implement them yet. Prefer that native API when it accepts the
-- command, and otherwise hold the equivalent logind idle inhibitor in a
-- transient user service. The fallback is deliberately named and collected
-- so it goes away with the user session and remains easy to identify.
local function caffeineStatusCommand()
  return "@systemctl@ --user is-active --quiet "
    .. CAFFEINE_FALLBACK_UNIT
    .. " && echo fallback || @systemd_inhibit@ --list 2>/dev/null | @sed@ -n '/^[[:space:]]*noctalia[[:space:]].*[[:space:]]Caffeine[[:space:]]/p'"
end

local function readCaffeine(callback)
  noctalia.runAsync(caffeineStatusCommand(), function(result)
    callback(trim(result.stdout) ~= "")
  end, 5000)
end

local function publishFan()
  noctalia.state.set(FAN_STATE, {
    available = fanSnapshot.available,
    backend = fanSnapshot.backend,
    mode = fanSnapshot.mode,
    percent = fanSnapshot.percent,
    rpm = fanSnapshot.rpm,
    cpuCount = fanSnapshot.cpuCount,
    temp = fanSnapshot.temp,
    loadAvg = fanSnapshot.loadAvg,
  })
end

local function fanReadCommand()
  return [[
if [ -r /proc/acpi/ibm/fan ]; then
  echo BACKEND:thinkpad
  cat /proc/acpi/ibm/fan 2>/dev/null
else
  for d in /sys/class/hwmon/hwmon*; do
    name=$(cat "$d/name" 2>/dev/null)
    case "$name" in
      dell_smm|gpdfan)
        echo BACKEND:hwmon
        echo HWMONDIR:$d
        channel=1
        while [ "$channel" -le 8 ]; do
          if [ -e "$d/pwm$channel" ]; then
            echo CHAN:$channel
            echo PWM$channel:$(cat "$d/pwm$channel" 2>/dev/null)
            echo ENABLE$channel:$(cat "$d/pwm${channel}_enable" 2>/dev/null)
            echo RPM$channel:$(cat "$d/fan${channel}_input" 2>/dev/null)
          fi
          channel=$((channel + 1))
        done
        break
        ;;
    esac
  done
fi
echo BACKEND_END
echo CPUCOUNT:$(@nproc@)
printf 'TEMP:%s\n' "$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
read -r one five fifteen _ < /proc/loadavg 2>/dev/null
printf 'LOAD:%s %s %s\n' "$one" "$five" "$fifteen"
]]
end

local function readFan()
  if readingFan then
    return
  end
  readingFan = true
  noctalia.runAsync(fanReadCommand(), function(result)
    readingFan = false
    local out = result.stdout or ""
    local body = out

    fanBackend = body:match("BACKEND:(%a+)") or "none"
    fanDir = body:match("HWMONDIR:(%S+)")
    fanChannels = {}
    fanSnapshot = {
      available = false,
      backend = fanBackend,
      mode = "auto",
      percent = 0,
      rpm = 0,
      cpuCount = tonumber(out:match("CPUCOUNT:(%d+)")) or fanSnapshot.cpuCount or 1,
      temp = fanSnapshot.temp or 0,
      loadAvg = fanSnapshot.loadAvg or { one = 0, five = 0, fifteen = 0 },
    }

    if fanBackend == "thinkpad" then
      local speed = tonumber(body:match("speed:%s*(%d+)"))
      local level = trim(body:match("level:%s*(%S+)") or "auto"):lower()
      fanSnapshot.available = speed ~= nil
      fanSnapshot.rpm = speed or 0
      if level == "disengaged" then
        fanSnapshot.mode, fanSnapshot.percent = "full", 100
      elseif level == "auto" then
        fanSnapshot.mode, fanSnapshot.percent = "auto", 0
      else
        local numeric = tonumber(level)
        fanSnapshot.mode = "manual"
        fanSnapshot.percent = numeric and math.floor(numeric * 100 / 7 + 0.5) or 50
      end
    elseif fanBackend == "hwmon" and fanDir then
      local maxRpm = 0
      local firstPwm, firstEnable = nil, nil
      for rawChannel in body:gmatch("CHAN:(%d+)") do
        local channel = tonumber(rawChannel)
        local pwm = tonumber(body:match("PWM" .. rawChannel .. ":(%d+)"))
        local enable = tonumber(body:match("ENABLE" .. rawChannel .. ":(%d+)"))
        local rpm = tonumber(body:match("RPM" .. rawChannel .. ":(%d+)")) or 0
        table.insert(fanChannels, channel)
        if #fanChannels == 1 then
          firstPwm, firstEnable = pwm, enable
        end
        maxRpm = math.max(maxRpm, rpm)
      end
      fanSnapshot.available = #fanChannels > 0
      fanSnapshot.rpm = maxRpm
      if firstEnable == 2 then
        fanSnapshot.mode, fanSnapshot.percent = "auto", 0
      elseif firstEnable == 1 and firstPwm == 255 then
        fanSnapshot.mode, fanSnapshot.percent = "full", 100
      elseif firstEnable == 1 then
        fanSnapshot.mode = "manual"
        fanSnapshot.percent = firstPwm and math.floor(firstPwm * 100 / 255 + 0.5) or 50
      end
    end

    local rawTemp = tonumber(out:match("TEMP:(%d+)"))
    if rawTemp then
      fanSnapshot.temp = math.floor(rawTemp / 1000 + 0.5)
    end
    local one, five, fifteen = out:match("LOAD:(%S+)%s+(%S+)%s+(%S+)")
    if one then
      fanSnapshot.loadAvg = {
        one = tonumber(one) or 0,
        five = tonumber(five) or 0,
        fifteen = tonumber(fifteen) or 0,
      }
    end
    publishFan()
  end, 5000)
end

local function fanWriteCommand(mode, percent)
  if fanBackend == "thinkpad" then
    local level = "auto"
    if mode == "full" then
      level = "disengaged"
    elseif mode == "manual" then
      local normalized = math.clamp(math.floor(tonumber(percent) or 50), 0, 100)
      level = tostring(math.clamp(math.floor(normalized * 7 / 100 + 0.5), 0, 7))
    end
    return "echo level " .. level .. " > /proc/acpi/ibm/fan"
  end
  if fanBackend ~= "hwmon" or not fanDir or #fanChannels == 0 then
    return nil
  end
  local enable = mode == "auto" and 2 or 1
  local pwm = mode == "full" and 255 or math.clamp(math.floor((tonumber(percent) or 50) * 255 / 100 + 0.5), 0, 255)
  local commands = {}
  for _, channel in fanChannels do
    table.insert(commands, "echo " .. enable .. " > " .. fanDir .. "/pwm" .. channel .. "_enable")
    if mode ~= "auto" then
      table.insert(commands, "echo " .. pwm .. " > " .. fanDir .. "/pwm" .. channel)
    end
  end
  return table.concat(commands, "; ")
end

-- Highest level observed while external power was connected and the firmware
-- had stopped charging anyway. That is the charge limit making itself
-- visible through behaviour, which is the only way to see it on hardware
-- that exposes no knob at all: gk4 (a GPD G1628-04) caps at 80% purely in
-- BIOS, with no charge_control_* in sysfs, no vendor module, and nothing
-- from upower. Deliberately not persisted -- a stale learned cap would
-- silently distort the tiers long after the BIOS setting changed, and this
-- re-learns within one poll of being plugged in.
local MIN_LEARNABLE_LIMIT = 50
local learnedLimit = nil
local lastLoggedLimit = nil

-- Explicit setting wins, then a limit the firmware actually reports, then
-- what we have watched it do. 100 means "charges to full".
local function effectiveLimit(cfg, reported)
  local limit = 100
  local source = "unlimited"
  if cfg.fullAt > 0 then
    limit, source = cfg.fullAt, "configured"
  elseif reported ~= nil and reported > 0 and reported < 100 then
    limit, source = reported, "reported"
  elseif learnedLimit ~= nil and learnedLimit < 100 then
    limit, source = learnedLimit, "learned"
  end
  if limit ~= lastLoggedLimit then
    lastLoggedLimit = limit
    noctalia.log("battery-icon: charge limit " .. tostring(limit) .. "% (" .. source .. ")")
  end
  return limit, source
end

for _, name in ipairs({ "charging", "unplug" }) do
  noctalia.sound.load(name, "sounds/" .. name .. ".oga", function(ok, err)
    soundReady[name] = ok
    if not ok then
      noctalia.log("battery-icon: " .. name .. " sound failed to load: " .. tostring(err))
    end
  end)
end

-- Noctalia's own "color" settings (e.g. bar.color, widget capsule_fill)
-- accept either a hex value or a palette role name like "on_primary" —
-- see docs/user/bar/index.mdx. Its generic color-setting editor offers the
-- same role-name picker here, but a role name means nothing to
-- ImageMagick's -fill, which only understands actual colors. Resolve a
-- role name against the active custom palette file ourselves before it
-- reaches magick.
local paletteCache = { key = nil, colors = nil }

local function roleToPaletteKey(role)
  -- "on_primary" -> "mOnPrimary", matching the palette JSON's Material-ish
  -- key casing (see ~/.config/noctalia/palettes/<name>.json).
  local out = "m"
  for word in role:gmatch("[^_]+") do
    out = out .. word:sub(1, 1):upper() .. word:sub(2)
  end
  return out
end

local function resolveRoleColor(role)
  if noctalia.getSetting("theme.source") ~= "custom" then
    return nil -- built-in palettes aren't user files we can read directly
  end
  local paletteName = noctalia.getSetting("theme.custom_palette")
  if paletteName == nil or paletteName == "" then
    return nil
  end
  local mode = noctalia.isDarkMode() and "dark" or "light"
  local cacheKey = paletteName .. ":" .. mode

  if paletteCache.key ~= cacheKey then
    local raw = noctalia.readFile(noctalia.expandPath("~/.config/noctalia/palettes/" .. paletteName .. ".json"))
    local decoded = raw ~= nil and noctalia.json.decode(raw) or nil
    paletteCache = { key = cacheKey, colors = decoded ~= nil and decoded[mode] or nil }
  end

  if paletteCache.colors == nil then
    return nil
  end
  return paletteCache.colors[roleToPaletteKey(role)]
end

-- `value` is either a hex color or a Noctalia palette role name; `fallback`
-- is the fixed hex used when it's a role name that can't be resolved
-- (built-in palette, unknown role, missing palette file, ...).
local function resolveColor(value, fallback)
  if type(value) ~= "string" or value == "" then
    return fallback
  end
  if value:match("^#%x+$") then
    return value
  end
  return resolveRoleColor(value) or fallback
end

local function settings()
  return {
    device = noctalia.getConfig("battery_device") or "BAT0",
    pollMs = (tonumber(noctalia.getConfig("poll_interval")) or 15) * 1000,
    lowThreshold = tonumber(noctalia.getConfig("low_threshold")) or 20,
    mediumThreshold = tonumber(noctalia.getConfig("medium_threshold")) or 50,
    fullAt = math.clamp(tonumber(noctalia.getConfig("full_at")) or 0, 0, 100),
    lowColor = resolveColor(noctalia.getConfig("low_color"), "#EA4335"),
    mediumColor = resolveColor(noctalia.getConfig("medium_color"), "#9AA0A6"),
    highColor = resolveColor(noctalia.getConfig("high_color"), "#9AA0A6"),
    chargingColor = resolveColor(noctalia.getConfig("charging_color"), "#34A853"),
    chargingBoltColor = resolveColor(noctalia.getConfig("charging_bolt_color"), "#FFFFFF"),
    powerSaverPlusColor = resolveColor(noctalia.getConfig("power_saver_plus_color"), "#F1F3F4"),
    textColor = resolveColor(noctalia.getConfig("text_color"), "#202124"),
    emptyColor = resolveColor(noctalia.getConfig("empty_color"), "#F1F3F4"),
  }
end

-- The body colour encodes exactly one fact: how full the battery is (plus
-- the charging state, which can't hide anything since it only applies while
-- powered). It used to also carry the Power Saver profile, which meant a
-- machine left in power-saver -- gk4 lives there -- painted the same orange
-- at 78% and at 8%, so the low-battery colour could never appear. Two
-- independent facts do not fit in one channel; the profile is simply not
-- shown any more.
local function tierColor(cfg, percent, charging)
  if charging then
    return cfg.chargingColor
  end
  -- A firmware charge limit means the battery can never reach 100%, so raw
  -- thresholds permanently understate how full it is: capped at 80%, a pack
  -- one point below its cap is as full as it will ever get, yet reads as 79%
  -- of a full battery. Compare the tiers against the achievable maximum
  -- instead. Only the tiers are rescaled -- regenerate() still draws the true
  -- percentage as both the number and the level fill, so the icon never
  -- misreports the actual charge.
  --
  -- Note this rescales the whole range, not just the top of it: at fullAt=80
  -- a low_threshold of 20 turns red at 16% real charge, since 16/80 = 20%.
  -- The remaining runtime there really is the same as any battery at 16%,
  -- so if that reads as too late, lower the limit rather than the threshold.
  local level = percent
  if cfg.fullAt < 100 then
    level = math.min(percent / cfg.fullAt * 100, 100)
  end
  if level <= cfg.lowThreshold then
    return cfg.lowColor
  end
  if level <= cfg.mediumThreshold then
    return cfg.mediumColor
  end
  return cfg.highColor
end

-- Geometry follows the linked Android Material 3 Expressive reference.
-- The body is deliberately much shorter than the full canvas: unplugged
-- batteries get a small terminal on the right, while charging replaces it
-- with the larger external bolt. BODY_PATH also gives the left end slightly
-- rounder corners than the right, as in Android's 24x14 source geometry.
local BODY_PATH = "M4,21 C4,12.716 8.925,6 15,6 H81 C85.971,6 90,11.373 90,18 V46 C90,52.627 85.971,58 81,58 H15 C8.925,58 4,51.284 4,43 Z"
local TERMINAL = "94,21 101,43 3,3"

-- Adapted from AOSP's Apache-2.0 battery_unified_attr_charging vector,
-- scaled and moved just past the battery body.
-- Keeping it external means the number stays centered and legible instead
-- of being squeezed to one side at the bar's 18 px display height.
local BOLT_POLYGON = "96,56 99,39 86,39 109,8 114,8 111,27 126,27 101,56"
local BOLT_STROKE_WIDTH = 3.5

-- Battery Saver, drawn the way Android does it: a "+" occupying the same
-- slot past the body that the terminal and the bolt use. Keeping it out of
-- the body is the whole point -- the body colour stays free to encode the
-- charge level, so a low battery still turns red while saver is on. It
-- yields to the bolt when charging, since that state is the more urgent of
-- the two and the slot only fits one glyph.
-- Positioned to sit slightly *over* the body's right edge, as in Android's
-- own battery-saver icon, rather than clear of it. PLUS_GAP_ARMS is the same
-- glyph grown by 4px on every side, used to punch a transparent gap through
-- the body so the two shapes stay legible where they overlap.
local PLUS_ARMS = { "82,28 112,37", "93,17 102,47" }
local PLUS_GAP_ARMS = { "78,24 116,41", "89,13 106,51" }

-- Plug/unplug and low-battery pulses: the bar has no frame-tick API
-- (setUpdateInterval is the only clock a widget/service gets), so
-- "animation" here means briefly driving that interval fast and rendering a
-- sequence of alternating-color frames before settling on the real icon,
-- instead of a single flat cut. Two earlier attempts (a single
-- 0.85-toward-white blend, then a 5-frame 0.95-peak double-flash, both at a
-- fixed cadence) were invisible or read as a slow color fade rather than a
-- flash: on the neutral Material 3 tiers (#9AA0A6 medium/high, #F1F3F4
-- empty) a *blend toward white* barely moves the color at all, and an even
-- on/off split reads as blinking, not flashing. A real flash has a sharp
-- rise and a longer fall, so each frame now carries its own hold time
-- (short for the flash color, longer for the real one) instead of sharing
-- one fixed interval.
local ANIM_SETTLE_MS = 150 -- fallback hold for the final real-color frame
local pendingAnim = nil -- { cfg, percent, charging, powerSaver, dataDir, frames, index }

local function regenerate(cfg, percent, charging, powerSaver, dataDir, bgOverride, fillOverride, boltColorOverride)
  local bg = bgOverride or tierColor(cfg, percent, charging)
  local fg = cfg.textColor
  local label = tostring(percent)
  -- fillOverride/boltColorOverride let an animation frame draw a *different*
  -- level fill or bolt tint than the real, current state (the classic
  -- charging sweep below fills toward the real percent repeatedly and
  -- flashes the bolt yellow independently of it), without touching the
  -- number label, which always shows the real percent.
  local fillPercent = fillOverride or percent
  local boltColor = boltColorOverride or cfg.chargingBoltColor
  local outPath = dataDir
    .. "/battery-m3e-v5-"
    .. tostring(percent)
    .. (charging and "c" or "d")
    .. (powerSaver and "s" or "n")
    .. "-"
    .. sanitize(bg)
    .. "-"
    .. sanitize(fg)
    .. "-"
    .. sanitize(cfg.emptyColor)
    .. "-"
    .. sanitize(boltColor)
    .. "-"
    .. sanitize(cfg.powerSaverPlusColor)
    .. "-"
    .. tostring(fillPercent)
    .. ".png"

  if noctalia.fileExists(outPath) then
    noctalia.state.set(
      "battery_icon",
      { path = outPath, percent = percent, charging = charging, powerSaver = powerSaver }
    )
    return
  end

  -- Paint the empty body, then composite a rectangular level fill through
  -- a body-shaped mask. This produces Android's straight vertical level
  -- boundary while retaining the body's rounded outer edge; drawing a
  -- second rounded rectangle here gives the fill a visibly incorrect
  -- rounded boundary at 20% and 50%.
  local fillX = 4 + math.floor(86 * math.clamp(fillPercent, 0, 100) / 100)
  local cmd = "@magick@ -size 128x64 xc:none "
    .. "-fill '"
    .. cfg.emptyColor
    .. "' -draw 'path \""
    .. BODY_PATH
    .. "\"' "
    .. "\\( -size 128x64 xc:none -fill '"
    .. bg
    .. "' -draw 'rectangle 4,6 "
    .. tostring(fillX)
    .. ",58' "
    .. "\\( -size 128x64 xc:none -fill white -draw 'path \""
    .. BODY_PATH
    .. "\"' \\) -compose DstIn -composite \\) -compose Over -composite "

  if charging then
    cmd = cmd
      .. "-fill '"
      .. boltColor
      .. "' -stroke '"
      .. fg
      .. "' -strokewidth "
      .. tostring(BOLT_STROKE_WIDTH)
      .. " -draw 'polygon "
      .. BOLT_POLYGON
      .. "' "
  elseif powerSaver then
    -- Punch the gap first: DstOut with the oversized glyph clears both the
    -- body pixels it overlaps and a margin around the rest, then -compose
    -- Over restores normal drawing for the "+" itself. The bolt solves the
    -- same problem with a stroke, which doesn't work here -- a stroke would
    -- paint a colour, and what this needs is actual transparency so the bar
    -- shows through, matching Android's cut-out.
    cmd = cmd .. "\\( -size 128x64 xc:none -fill white"
    for _, arm in ipairs(PLUS_GAP_ARMS) do
      cmd = cmd .. " -draw 'rectangle " .. arm .. "'"
    end
    cmd = cmd .. " \\) -compose DstOut -composite -compose Over "
    cmd = cmd .. "-fill '" .. cfg.powerSaverPlusColor .. "' "
    for _, arm in ipairs(PLUS_ARMS) do
      cmd = cmd .. "-draw 'rectangle " .. arm .. "' "
    end
  else
    cmd = cmd .. "-fill '" .. cfg.emptyColor .. "' -draw 'roundrectangle " .. TERMINAL .. "' "
  end

  -- The full canvas includes the terminal/bolt area, so -17 places the
  -- text at x=47: the exact horizontal center of the 4..90 body.
  cmd = cmd
    .. "-gravity center -fill '"
    .. fg
    .. "' -stroke none -font '@font@' -pointsize 48 -annotate -17+2 '"
    .. label
    .. "' "

  cmd = cmd .. "'" .. outPath .. "'"

  noctalia.runAsync(cmd, function(result)
    if result.exitCode == 0 then
      noctalia.state.set(
      "battery_icon",
      { path = outPath, percent = percent, charging = charging, powerSaver = powerSaver }
    )
    else
      noctalia.log("battery-icon: magick failed: " .. trim(result.stderr))
    end
  end, 5000)
end

-- Renders the next queued pulse frame, if any, and reports whether the
-- caller should keep ticking fast (true) or fall back to normal poll
-- cadence (false — nothing was pending, or this was the last frame). Each
-- frame carries its own hold time: advanceAnim sets the *next* tick's
-- interval to the frame it just rendered, so a flash can stay lit briefly
-- and the real color can hold longer, instead of every step taking the same
-- amount of time. The frames in anim.frames run first; one further call
-- renders the *real* tier color (color = nil) so the icon actually settles
-- on the true state instead of being left on a flash color forever.
local function advanceAnim()
  if pendingAnim == nil then
    return false
  end
  local anim = pendingAnim
  local frame = anim.index <= #anim.frames and anim.frames[anim.index] or nil
  anim.index += 1
  local finished = anim.index > #anim.frames + 1
  if finished then
    pendingAnim = nil
  else
    noctalia.setUpdateInterval((frame and frame.ms) or ANIM_SETTLE_MS)
  end
  regenerate(
    anim.cfg,
    anim.percent,
    anim.charging,
    anim.powerSaver,
    anim.dataDir,
    frame and frame.color,
    frame and frame.fillPercent,
    frame and frame.boltColor
  )
  return not finished
end

-- Builds an alternating on/off frame list: `flashColor` held for `onMs`,
-- then `targetColor` (the real color the icon settles back on between
-- blinks) held for `offMs`, repeated `blinks` times. A short onMs/long offMs
-- pairing is what makes this read as a *flash* rather than an even blink.
local function strobeFrames(targetColor, flashColor, blinks, onMs, offMs)
  local frames = {}
  for _ = 1, blinks do
    table.insert(frames, { color = flashColor, ms = onMs })
    table.insert(frames, { color = targetColor, ms = offMs })
  end
  return frames
end

local function startStrobe(cfg, percent, charging, powerSaver, dataDir, frames)
  pendingAnim = {
    cfg = cfg,
    percent = percent,
    charging = charging,
    powerSaver = powerSaver,
    dataDir = dataDir,
    frames = frames,
    index = 1,
  }
  advanceAnim()
end

-- ImageMagick (and resolveColor) also accept #RGB/#RGBA/#RRGGBBAA; only
-- plain #RRGGBB round-trips through the on/off alternation strobeFrames
-- builds, so any caller skips straight to the real icon instead of
-- strobing a mis-parsed color.
local function isStrobeSafe(color)
  return color:match("^#%x%x%x%x%x%x$") ~= nil
end

local CHARGE_BOLT_FLASHES = 3
local CHARGE_BOLT_ON_MS = 260
local CHARGE_BOLT_OFF_MS = 260
local CHARGE_BOLT_FLASH_COLOR = "#FFD600"
local CHARGE_FILL_STEPS = 4 -- frames per rise, e.g. 25/50/75/100% of the real level
local CHARGE_FILL_STEP_MS = 260
local CHARGE_FILL_CYCLES = 3

-- The classic "plugged in" animation: the bolt flashes yellow a few times
-- (lead-in only, on an empty body), then the level fill rises from empty up
-- to the real charge level, repeated a few times -- like the level is
-- actively climbing, not just snapping to its new number. The level bar
-- always rises toward and ends exactly at the real percent (never fabricates
-- a fuller charge than what's actually there); only the fill and the bolt
-- tint animate, the printed number stays the real percent throughout. The
-- color itself never changes here (it's always the real chargingColor) --
-- unlike startCriticalPulse, which strobes the *color* because there's no
-- "level" to animate on a low-battery edge.
local function chargeSweepFrames(percent)
  local frames = {}
  for _ = 1, CHARGE_BOLT_FLASHES do
    table.insert(frames, { fillPercent = 0, boltColor = CHARGE_BOLT_FLASH_COLOR, ms = CHARGE_BOLT_ON_MS })
    table.insert(frames, { fillPercent = 0, ms = CHARGE_BOLT_OFF_MS })
  end
  for _ = 1, CHARGE_FILL_CYCLES do
    for step = 1, CHARGE_FILL_STEPS do
      table.insert(frames, { fillPercent = math.floor(percent * step / CHARGE_FILL_STEPS), ms = CHARGE_FILL_STEP_MS })
    end
  end
  return frames
end

local function startChargePulse(cfg, percent, charging, powerSaver, dataDir)
  startStrobe(cfg, percent, charging, powerSaver, dataDir, chargeSweepFrames(percent))
end

-- Plugging in gets the "filling up" animation above; unplugging just cuts
-- straight to the real (discharging) icon, no animation. This matches how
-- Android/iOS/macOS/Windows all treat a disconnect -- an instant icon swap,
-- never a flash -- plugging in is the only moment any of them animate. The
-- existing unplug sound chime (charging_sound_enabled) already carries the
-- "something changed" cue on its own.
local function startPulse(cfg, percent, charging, powerSaver, dataDir)
  if charging then
    startChargePulse(cfg, percent, charging, powerSaver, dataDir)
  else
    regenerate(cfg, percent, charging, powerSaver, dataDir)
  end
end

local CRITICAL_BLINKS = 3
local CRITICAL_ON_MS = 450 -- slow, deliberate hold -- an alarm, not a flash
local CRITICAL_OFF_MS = 200
local CRITICAL_COLOR = "#FF1E1E" -- more saturated than low_color, so this alarm reads as its own color, not just "the low-battery icon again"

-- A slower, longer-held strobe toward a distinct alarm red, fired once when
-- the battery *enters* the low tier (not on every poll while it stays
-- there). Deliberately paced differently from startPulse's quick flash
-- (long on / short off vs. short on / long off) so the two are never
-- mistaken for each other.
local function startCriticalPulse(cfg, percent, charging, powerSaver, dataDir)
  local target = tierColor(cfg, percent, charging)
  if not isStrobeSafe(target) then
    regenerate(cfg, percent, charging, powerSaver, dataDir)
    return
  end
  startStrobe(
    cfg,
    percent,
    charging,
    powerSaver,
    dataDir,
    strobeFrames(target, CRITICAL_COLOR, CRITICAL_BLINKS, CRITICAL_ON_MS, CRITICAL_OFF_MS)
  )
end

local function poll()
  readFan()
  local cfg = settings()
  local statusPath = "/sys/class/power_supply/" .. cfg.device .. "/status"

  noctalia.runAsync(batteryCommand(cfg.device), function(capResult)
    -- Two lines: level, then the firmware's charge limit (blank if none).
    local lines = string.split(capResult.stdout or "", "\n")
    local percent = parseNumber(lines[1] or "")
    if percent == nil then
      return
    end
    local reportedLimit = parseNumber(lines[2] or "")

    noctalia.runAsync("cat " .. statusPath, function(statusResult)
      local status = trim(statusResult.stdout)

      noctalia.runAsync(AC_ONLINE_CMD, function(acResult)
        -- The battery's own status describes *current flow*, not whether a
        -- charger is attached. Once the pack sits above the EC's charge
        -- limit, firmware does maintenance cycling: BAT0 alternates
        -- "Charging" and "Discharging" every minute or so with the charger
        -- never leaving the wall (current_now even vanishes with ENODEV
        -- while idle). Deriving the plugged state from status therefore made
        -- the icon, the pulse and the plug/unplug sounds flap on that same
        -- cycle. AC_ONLINE_CMD answers the question we actually mean, and
        -- stays put across the whole maintenance cycle.
        local acOnline = trim(acResult.stdout)
        local charging
        if acOnline:match("^b ") ~= nil then
          charging = acOnline == "b false" -- upower OnBattery
        elseif acOnline ~= "" then
          charging = acOnline:match("1") ~= nil -- sysfs line-power online
        else
          -- Neither upower nor a Mains supply: last-resort status heuristic.
          -- "Not charging" is the power_supply ABI's "AC present but battery
          -- not accepting current", so it counts as plugged in too.
          charging = status == "Charging" or status == "Full" or status == "Not charging"
        end

        -- Plugged in, yet the firmware has stopped charging: whatever the
        -- battery sits at now is at or just under its cap. "Full" counts as
        -- 100, so a normal battery correctly learns no limit at all.
        if charging and (status == "Not charging" or status == "Full") then
          local observed = status == "Full" and 100 or percent
          -- A pause well down the range is a thermal or protection stop, not
          -- a cap. Learning it would be actively dangerous: a "limit" of 40
          -- rescales 30% real charge to 75%, suppressing the low-battery
          -- color exactly when it matters. Firmware caps are offered at 60/
          -- 80/100 in practice, so ignore anything implausibly low.
          if observed >= MIN_LEARNABLE_LIMIT and (learnedLimit == nil or observed > learnedLimit) then
            learnedLimit = observed
          end
        end
        local limit, limitSource = effectiveLimit(cfg, reportedLimit)
        cfg.fullAt = limit

        noctalia.runAsync("@powerprofilesctl@ get", function(profileResult)
          local profile = trim(profileResult.stdout)
          local powerSaver
          if profile == "" then
            powerSaver = lastPowerSaver
            noctalia.log(
              "battery-icon: power profile read failed (exit "
                .. tostring(profileResult.exitCode)
                .. "), keeping "
                .. tostring(powerSaver)
            )
          else
            if profile ~= lastProfile then
              noctalia.log("battery-icon: power profile -> " .. profile)
              lastProfile = profile
            end
            powerSaver = profile == "power-saver"
            lastPowerSaver = powerSaver
          end
          -- nil lastCharging means this is the first read since (re)start: never
          -- an edge, so a charger already connected doesn't fire the sound/pulse.
          local edge = lastCharging ~= nil and lastCharging ~= charging

          if edge and noctalia.getConfig("charging_sound_enabled") then
            if charging and soundReady.charging then
              noctalia.sound.play("charging")
            elseif not charging and soundReady.unplug then
              noctalia.sound.play("unplug")
            end
          end
          lastCharging = charging

          -- Entering the low tier (tierColor already forces chargingColor
          -- while plugged in, so this is implicitly "discharging and at or
          -- below low_threshold"). Same nil-guard as edge: never fires on
          -- the first read, and only on the false->true transition, not on
          -- every poll while the battery stays low.
          local isLow = tierColor(cfg, percent, charging) == cfg.lowColor
          local lowEdge = lastLow ~= nil and not lastLow and isLow
          lastLow = isLow

          readCaffeine(function(caffeineEnabled)
            noctalia.runAsync(detailsCommand(cfg.device), function(detailsResult)
              -- Always publish panel data, even when the rendered icon is
              -- unchanged (for example, a wireless mouse can change charge
              -- while the laptop battery stays at 80%).
              publishDetails(
                percent,
                charging,
                status,
                profile ~= "" and profile or (lastProfile or ""),
                cfg.fullAt,
                limitSource == "learned",
                caffeineEnabled,
                detailsResult.stdout
              )

              local key = tostring(percent)
                .. (charging and "c" or "d")
                .. (powerSaver and "s" or "n")
                .. tostring(cfg.fullAt)
                .. cfg.lowColor
                .. cfg.mediumColor
                .. cfg.highColor
                .. cfg.chargingColor
                .. cfg.chargingBoltColor
                .. cfg.textColor
                .. cfg.emptyColor

              if key == lastKey then
                return
              end
              lastKey = key

              local dataDir = noctalia.pluginDataDir()
              if dataDir == nil then
                return
              end

              if edge then
                startPulse(cfg, percent, charging, powerSaver, dataDir)
              elseif lowEdge then
                startCriticalPulse(cfg, percent, charging, powerSaver, dataDir)
              else
                regenerate(cfg, percent, charging, powerSaver, dataDir)
              end
            end, 5000)
          end)
        end, 5000)
      end, 5000)
    end, 5000)
  end, 5000)
end

local function setFan(mode, percent)
  local command = fanWriteCommand(mode, percent)
  if command == nil then
    return
  end
  noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.fan_error_title"), noctalia.tr("notify.fan_error_body"))
      noctalia.log("battery-icon: fan change failed: " .. trim(result.stderr))
    end
    readFan()
  end, 5000)
end

local function setCaffeine(enabled)
  local nativeCommand = "noctalia msg caffeine-" .. (enabled and "enable" or "disable")
  noctalia.runAsync(nativeCommand, function(nativeResult)
    if nativeResult.exitCode == 0 then
      -- If this was previously using the compatibility service, native
      -- Caffeine is now authoritative and should be the sole inhibitor.
      noctalia.runAsync("@systemctl@ --user stop " .. CAFFEINE_FALLBACK_UNIT, function(_result)
        poll()
      end, 5000)
      return
    end

    local fallbackCommand
    if enabled then
      fallbackCommand = "@systemd_run@ --user --unit="
        .. CAFFEINE_FALLBACK_UNIT
        .. " --collect @systemd_inhibit@ --what=idle --mode=block --who=battery-icon --why=Caffeine @sleep@ infinity"
    else
      fallbackCommand = "@systemctl@ --user stop " .. CAFFEINE_FALLBACK_UNIT
    end
    noctalia.runAsync(fallbackCommand, function(fallbackResult)
      if fallbackResult.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("notify.caffeine_error_title"), noctalia.tr("notify.caffeine_error_body"))
        noctalia.log("battery-icon: caffeine change failed: " .. trim(fallbackResult.stderr))
      end
      poll()
    end, 5000)
  end, 5000)
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.action == "refresh" then
    poll()
  elseif cmd.action == "set_power_profile" and POWER_PROFILES[cmd.profile] then
  noctalia.runAsync("@powerprofilesctl@ set " .. cmd.profile, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(
        noctalia.tr("notify.power_profile_error_title"),
        noctalia.tr("notify.power_profile_error_body")
      )
      noctalia.log("battery-icon: power-profile change failed: " .. trim(result.stderr))
    end
    poll()
  end, 5000)
  elseif cmd.action == "set_fan_mode" and (cmd.mode == "auto" or cmd.mode == "full" or cmd.mode == "manual") then
    setFan(cmd.mode, cmd.mode == "manual" and 50 or nil)
  elseif cmd.action == "set_fan_percent" then
    setFan("manual", math.clamp(math.floor(tonumber(cmd.value) or 50), 0, 100))
  elseif cmd.action == "set_caffeine" and type(cmd.enabled) == "boolean" then
    setCaffeine(cmd.enabled)
  end
end)

poll()

-- Everything below is edge-triggered, so poll_interval is only a safety net
-- for machines without upower. Each stream is a
-- long-lived subscription that stays completely silent until something it
-- cares about actually moves.
--
-- All four merely say "something moved" and let poll() re-read the state:
-- none of them feeds its payload into the icon. Keeping every read in one
-- place is what lets poll() apply the upower-or-sysfs choice consistently
-- (see percentCommand) instead of each stream introducing its own source.
-- The streams only decide *when* to read. A duplicate line costs nothing
-- either — poll() is a no-op once the icon is current.

-- `busctl wait` subscribes with an ordinary match rule, so unlike
-- `busctl monitor` (and dbus-monitor) it doesn't need the root-only
-- BecomeMonitor call and works fine from a user session.
-- --limit-messages=infinity turns the one-shot wait into a stream, and
-- --json=short makes each signal one decodable line rather than the
-- pretty-printed GVariant text gdbus produces:
--   {"type":"sa{sv}as","data":["org.freedesktop.UPower",
--    {"OnBattery":{"type":"b","data":false}},[]]}
-- data holds PropertiesChanged's three arguments: interface, changed
-- properties, invalidated property names.
--
-- stdbuf is not optional. busctl block-buffers stdout when it isn't a tty,
-- and these signals are far too small and rare to fill a 4 KiB buffer — a
-- 75 s test run produced literally zero bytes without it.
local function propertiesChangedStream(service, objectPath)
  return "@stdbuf@ -oL @busctl@ --system --json=short --limit-messages=infinity wait "
    .. service
    .. " "
    .. objectPath
    .. " org.freedesktop.DBus.Properties PropertiesChanged"
end

-- Re-poll whenever `property` shows up in a PropertiesChanged payload from
-- `objectPath`. Filtering on the property name is the whole point of taking
-- JSON rather than gdbus's text: upower's *device* objects emit roughly two
-- signals a minute of pure telemetry (UpdateTime, Voltage, EnergyRate,
-- Energy), so an unfiltered subscription there would trigger poll() more
-- often than the old 15 s timer did.
local function watchProperty(service, objectPath, property)
  noctalia.runStream(propertiesChangedStream(service, objectPath), function(line)
    local ok, decoded = pcall(noctalia.json.decode, line)
    if not ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
      -- Unrecognized shape: poll anyway rather than risk missing an edge.
      poll()
      return
    end
    local changed = decoded.data[2]
    if type(changed) == "table" and changed[property] ~= nil then
      poll()
    end
  end)
end

-- Plug/unplug. upower's daemon-level OnBattery is the same aggregate
-- AC_ONLINE_CMD reads, and the daemon object carries nothing else we'd
-- confuse it with (only LidIsClosed).
watchProperty("org.freedesktop.UPower", "/org/freedesktop/UPower", "OnBattery")

-- Charge level. upower mangles the kernel's name into its object path, but
-- only for characters that aren't path-safe — a plain "BAT0"/"BATT" passes
-- through untouched. Read once at startup rather than per signal: the
-- battery device can't be swapped without a reboot anyway.
watchProperty(
  "org.freedesktop.UPower",
  "/org/freedesktop/UPower/devices/battery_" .. settings().device,
  "Percentage"
)


-- Battery Saver. power-profiles-daemon still owns the old net.hadess name
-- here; on a build that only exposes org.freedesktop.UPower.PowerProfiles
-- this stream simply never fires and poll_interval picks the change up.
watchProperty("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "ActiveProfile")

-- The no-upower path: without the daemon none of the D-Bus streams above
-- ever fire, and the kernel's own power_supply uevents (emitted for both the
-- AC and battery devices on a plug/unplug) still give the same edge.
noctalia.runStream("@udevadm@ monitor --udev --subsystem-match=power_supply", function(line)
  poll()
end)

function update()
  -- advanceAnim() returns false both when nothing is pending and right
  -- after it renders the pulse's last (real-color) frame — either way
  -- normal polling should resume. When it returns true it has already set
  -- the interval for the next frame itself (see advanceAnim), so this must
  -- not stomp that with a fixed interval of its own.
  if advanceAnim() then
    return
  end
  noctalia.setUpdateInterval(settings().pollMs)
  poll()
end
