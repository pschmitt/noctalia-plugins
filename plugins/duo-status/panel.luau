--!nonstrict
-- Duo Status popup panel:
-- Unified Control Center view combining battery & power controls with network status & wifi list.

local state = noctalia.state.get("duo_status.state") or {}
local networks = noctalia.state.get("duo_status.networks") or {}
local showAllNetworks = false

local function sendCommand(cmd)
  noctalia.state.set("duo_status.command", cmd)
end

-- ── Battery Card ─────────────────────────────────────────────────────────────

local function batteryColor(bat)
  if bat.charging then return "#34C759" end
  if bat.powerSaver then return "#FFCC00" end
  if (bat.percent or 100) <= 15 then return "error" end
  return "primary"
end

local function batteryCard()
  local bat = state.battery or {
    percent = 100,
    charging = false,
    status = "Discharging",
    profile = "balanced",
    watts = 0,
    timeRemaining = "",
  }

  local color = batteryColor(bat)
  local statusText = bat.status or "Discharging"
  if bat.charging then
    statusText = "Charging"
  elseif bat.percent == 100 then
    statusText = "Full"
  end

  local rightParts = {}
  if bat.timeRemaining and bat.timeRemaining ~= "" then
    rightParts[#rightParts + 1] = bat.timeRemaining .. (bat.charging and " to full" or " left")
  end
  if bat.watts and bat.watts > 0 then
    rightParts[#rightParts + 1] = string.format("(%s%.1f W)", bat.charging and "+" or "-", bat.watts)
  end
  local rightText = table.concat(rightParts, " ")

  local function profileBtn(id, label, icon)
    local active = (bat.profile == id)
    return ui.button({
      variant = active and "primary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      glyph = icon,
      text = label,
      onClick = function()
        sendCommand({ action = "set_profile", profile = id })
      end,
    })
  end

  return ui.column({
    fill = "surface_container",
    radius = 12,
    padding = 12,
    gap = 10,
  }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({
          name = bat.charging and "bolt" or (bat.percent <= 20 and "battery-1" or "battery-4"),
          size = 18,
          color = color,
        }),
        ui.label({
          text = string.format("%d%%", bat.percent or 0),
          fontSize = 15,
          fontWeight = "bold",
        }),
        ui.label({
          text = "• " .. statusText,
          fontSize = 12,
          color = "on_surface_variant",
        }),
      }),
      rightText ~= "" and ui.label({
        text = rightText,
        fontSize = 11,
        color = "on_surface_variant",
      }) or ui.box({}),
    }),

    ui.progress({
      progress = math.clamp((bat.percent or 0) / 100, 0, 1),
      fill = color,
      track = "on_surface/0.14",
      height = 6,
      radius = 3,
    }),

    ui.row({ align = "center", gap = 6 }, {
      profileBtn("power-saver", "Saver", "leaf"),
      profileBtn("balanced", "Balanced", "scale"),
      profileBtn("performance", "Turbo", "rocket"),
    }),
  })
end

-- ── Network Card ─────────────────────────────────────────────────────────────

local function networkCard()
  local net = state.network or {
    connected = false,
    type = "none",
    ssid = "Disconnected",
    device = "",
    signal = 0,
    ip = "",
  }

  local isConnected = net.connected and net.type ~= "none"
  local typeGlyph = "wifi-off"
  if net.type == "ethernet" then
    typeGlyph = "device-desktop"
  elseif isConnected then
    typeGlyph = "wifi-2"
  end

  local signalDots = ""
  if net.type == "wifi" and isConnected then
    local active = math.ceil((net.signal or 0) / 25)
    for i = 1, 4 do
      signalDots = signalDots .. (i <= active and "● " or "○ ")
    end
    signalDots = signalDots .. string.format("%d%%", net.signal or 0)
  end

  return ui.column({
    fill = "surface_container",
    radius = 12,
    padding = 12,
    gap = 10,
  }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({
          name = typeGlyph,
          size = 18,
          color = isConnected and "primary" or "on_surface_variant",
        }),
        ui.column({ gap = 2 }, {
          ui.label({
            text = net.ssid or (isConnected and "Connected" or "Disconnected"),
            fontSize = 14,
            fontWeight = "semibold",
            maxLines = 1,
          }),
          net.ip ~= "" and ui.label({
            text = net.ip .. (net.device ~= "" and " (" .. net.device .. ")" or ""),
            fontSize = 11,
            color = "on_surface_variant",
          }) or ui.box({}),
        }),
      }),

      ui.row({ align = "center", gap = 4 }, {
        signalDots ~= "" and ui.label({
          text = signalDots,
          fontSize = 11,
          fontWeight = "medium",
          color = "on_surface_variant",
        }) or ui.box({}),
        ui.button({
          glyph = "refresh",
          variant = "ghost",
          controlSize = "sm",
          tooltip = "Rescan Wi-Fi",
          onClick = function()
            sendCommand({ action = "rescan" })
          end,
        }),
      }),
    }),

    ui.row({ align = "center", justify = "space_between" }, {
      ui.button({
        text = showAllNetworks and "Hide networks" or "Nearby networks",
        variant = "ghost",
        controlSize = "sm",
        glyph = showAllNetworks and "chevron-up" or "chevron-down",
        onClick = function()
          showAllNetworks = not showAllNetworks
          if showAllNetworks then
            sendCommand({ action = "scan_networks" })
          end
          render()
        end,
      }),

      ui.button({
        text = "Network settings",
        variant = "ghost",
        controlSize = "sm",
        glyph = "external-link",
        onClick = function()
          panel.close()
          if type(noctalia.openPanel) == "function" then
            pcall(function() noctalia.openPanel("control-center", "network") end)
          end
          noctalia.runAsync("noctalia msg panel-open control-center network 2>/dev/null", function() end)
        end,
      }),
    }),
  })
end

-- ── Nearby Networks List ─────────────────────────────────────────────────────

local function networkRows()
  if not showAllNetworks or #networks == 0 then
    return ui.box({})
  end

  local rows = {}
  for _, ap in ipairs(networks) do
    local isCurrent = ap.inUse
    local secGlyph = (ap.security and ap.security ~= "" and ap.security ~= "--") and "lock" or nil

    rows[#rows + 1] = ui.row({
      align = "center",
      justify = "space_between",
      paddingV = 6,
      paddingH = 8,
      radius = 8,
      fill = isCurrent and "primary/0.10" or nil,
    }, {
      ui.row({ align = "center", gap = 8, flexGrow = 1 }, {
        ui.glyph({
          name = isCurrent and "check" or "wifi",
          size = 14,
          color = isCurrent and "primary" or "on_surface_variant",
        }),
        ui.label({
          text = ap.ssid or "Hidden Network",
          fontSize = 12,
          fontWeight = isCurrent and "bold" or "normal",
          color = isCurrent and "primary" or "on_surface",
          maxLines = 1,
          flexGrow = 1,
        }),
        secGlyph and ui.glyph({ name = secGlyph, size = 11, color = "on_surface_variant" }) or ui.box({}),
      }),

      ui.row({ align = "center", gap = 6 }, {
        ui.label({
          text = string.format("%d%%", ap.signal or 0),
          fontSize = 11,
          color = "on_surface_variant",
        }),
        not isCurrent and ui.button({
          text = "Connect",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            sendCommand({ action = "connect", ssid = ap.ssid })
          end,
        }) or ui.box({}),
      }),
    })
  end

  return ui.column({
    fill = "surface_container",
    radius = 12,
    padding = 8,
    gap = 2,
  }, {
    ui.scroll({ maxHeight = 280, gap = 2 }, rows),
  })
end

-- ── Header ───────────────────────────────────────────────────────────────────

local function header()
  return ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "wifi-2", size = 16, color = "primary" }),
      ui.label({ text = "Duo Status", fontSize = 14, fontWeight = "bold" }),
    }),
    ui.row({ align = "center", gap = 4 }, {
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Refresh status",
        onClick = function()
          sendCommand({ action = "refresh" })
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Close",
        onClick = function()
          panel.close()
        end,
      }),
    }),
  })
end

-- ── Main Render ──────────────────────────────────────────────────────────────

function render()
  local children = {
    header(),
    batteryCard(),
    networkCard(),
  }

  if showAllNetworks and #networks > 0 then
    children[#children + 1] = networkRows()
  end

  panel.render(ui.column({
    padding = 12,
    gap = 10,
  }, children))
end

noctalia.state.watch("duo_status.state", function(s)
  state = s or {}
  render()
end)

noctalia.state.watch("duo_status.networks", function(n)
  networks = n or {}
  render()
end)

function onOpen()
  sendCommand({ action = "refresh" })
  render()
end

function onConfigChanged()
  render()
end

render()
