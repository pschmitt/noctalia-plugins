--!nonstrict
-- Duo Status popup panel:
-- Unified Control Center view combining battery & power controls with network status & wifi list.

local state = noctalia.state.get("duo_status.state") or {}
local networks = noctalia.state.get("duo_status.networks") or {}
local iconPath = noctalia.state.get("duo_status.icon_path")
local showAllNetworks = false
local activePasswordSSID = nil
local passwordDraft = ""
local connectError = noctalia.state.get("duo_status.connect_error")

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

  local subParts = {}
  if net.ip and net.ip ~= "" then
    subParts[#subParts + 1] = net.ip .. (net.device ~= "" and (" (" .. net.device .. ")") or "")
  end
  if net.type == "wifi" and isConnected and net.signal then
    subParts[#subParts + 1] = string.format("%d%%", net.signal)
  end
  local subText = #subParts > 0 and table.concat(subParts, " • ") or (isConnected and "Active" or "")

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
          subText ~= "" and ui.label({
            text = subText,
            fontSize = 11,
            color = "on_surface_variant",
          }) or ui.box({}),
        }),
      }),

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
        glyph = "external-link",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Network settings",
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
    local requiresPassword = (ap.secured or secGlyph ~= nil) and not ap.saved

    local subDetails = {}
    if secGlyph then
      subDetails[#subDetails + 1] = ui.glyph({ name = secGlyph, size = 10, color = "on_surface_variant" })
    end
    if ap.signal then
      subDetails[#subDetails + 1] = ui.label({
        text = string.format("%d%%", ap.signal),
        fontSize = 10,
        color = "on_surface_variant",
      })
    end
    if isCurrent then
      subDetails[#subDetails + 1] = ui.label({
        text = "• Connected",
        fontSize = 10,
        fontWeight = "medium",
        color = "primary",
      })
    end

    local function handleConnectClick()
      if isCurrent then return end
      if requiresPassword then
        if activePasswordSSID == ap.ssid then
          activePasswordSSID = nil
          passwordDraft = ""
        else
          activePasswordSSID = ap.ssid
          passwordDraft = ""
        end
        render()
      else
        sendCommand({ action = "connect", ssid = ap.ssid })
      end
    end

    local rowItem = ui.row({
      align = "center",
      justify = "space_between",
      paddingV = 6,
      paddingH = 8,
      radius = 8,
      fill = isCurrent and "primary/0.10" or nil,
      onClick = not isCurrent and handleConnectClick or nil,
    }, {
      ui.row({ align = "center", gap = 10, flexGrow = 1 }, {
        ui.glyph({
          name = isCurrent and "check" or "wifi",
          size = 16,
          color = isCurrent and "primary" or "on_surface_variant",
        }),
        ui.column({ gap = 1, flexGrow = 1 }, {
          ui.label({
            text = ap.ssid or "Hidden Network",
            fontSize = 12,
            fontWeight = isCurrent and "bold" or "medium",
            color = isCurrent and "primary" or "on_surface",
            maxLines = 1,
          }),
          #subDetails > 0 and ui.row({ align = "center", gap = 4 }, subDetails) or ui.box({}),
        }),
      }),

      not isCurrent and ui.button({
        glyph = (activePasswordSSID == ap.ssid and "chevron-up" or "arrow-right"),
        variant = "ghost",
        controlSize = "sm",
        tooltip = requiresPassword and "Enter password" or ("Connect to " .. (ap.ssid or "network")),
        onClick = handleConnectClick,
      }) or ui.box({}),
    })

    if activePasswordSSID == ap.ssid then
      local pwdItems = {
        ui.row({ align = "center", gap = 6, paddingH = 6, paddingV = 4 }, {
          ui.input({
            key = "wifi-pwd-" .. (ap.ssid or ""),
            placeholder = "Password for " .. (ap.ssid or "network"),
            password = true,
            value = passwordDraft,
            flexGrow = 1,
            fontSize = 12,
            focus = true,
            submitOnEnter = true,
            onChange = function(val) passwordDraft = val or "" end,
            onSubmit = function(val)
              local p = val or passwordDraft
              if p and p ~= "" then
                sendCommand({ action = "connect", ssid = ap.ssid, password = p })
                activePasswordSSID = nil
                passwordDraft = ""
                render()
              end
            end,
          }),
          ui.button({
            glyph = "check",
            variant = "primary",
            controlSize = "sm",
            tooltip = "Connect",
            onClick = function()
              if passwordDraft and passwordDraft ~= "" then
                sendCommand({ action = "connect", ssid = ap.ssid, password = passwordDraft })
                activePasswordSSID = nil
                passwordDraft = ""
                render()
              end
            end,
          }),
          ui.button({
            glyph = "x",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Cancel",
            onClick = function()
              activePasswordSSID = nil
              passwordDraft = ""
              render()
            end,
          }),
        }),
      }

      if connectError and connectError.ssid == ap.ssid then
        table.insert(pwdItems, ui.row({ paddingH = 8, paddingV = 2 }, {
          ui.label({
            text = connectError.message or "Connection failed",
            fontSize = 11,
            color = "error",
            maxLines = 1,
          }),
        }))
      end

      rows[#rows + 1] = ui.column({
        gap = 2,
        radius = 8,
        fill = "surface_container_highest/0.4",
        padding = 4,
      }, {
        rowItem,
        ui.column({ gap = 2 }, pwdItems),
      })
    else
      rows[#rows + 1] = rowItem
    end
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
  local iconWidget
  if iconPath and noctalia.fileExists(iconPath) then
    iconWidget = ui.image({
      path = iconPath,
      width = 36,
      height = 36,
      fit = "contain",
    })
  else
    iconWidget = ui.glyph({ name = "wifi-2", size = 28, color = "primary" })
  end

  return ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 10 }, {
      iconWidget,
      ui.label({ text = "Duo Status", fontSize = 16, fontWeight = "bold" }),
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

noctalia.state.watch("duo_status.icon_path", function(p)
  iconPath = p
  render()
end)

noctalia.state.watch("duo_status.state", function(s)
  state = s or {}
  render()
end)

noctalia.state.watch("duo_status.networks", function(n)
  networks = n or {}
  render()
end)

noctalia.state.watch("duo_status.connect_error", function(err)
  connectError = err
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
