--!nonstrict
-- Duo Status bar widget:
-- Displays the iPhone Duo status badge in the bar, with tooltips and click-to-open panel.

local iconPath = noctalia.state.get("duo_status.icon_path")
local state = noctalia.state.get("duo_status.state")

local function updateTooltip()
  if not state then
    barWidget.setTooltip({
      { key = "Duo Status", value = "Initializing..." }
    })
    return
  end

  local bat = state.battery or {}
  local net = state.network or {}

  local batText = string.format("%d%% (%s)", bat.percent or 0, bat.status or "Discharging")
  if bat.timeRemaining and bat.timeRemaining ~= "" then
    batText = batText .. " • " .. bat.timeRemaining .. (bat.charging and " to full" or " left")
  end
  if bat.watts and bat.watts > 0 then
    batText = batText .. string.format(" (%s%.1f W)", bat.charging and "+" or "-", bat.watts)
  end

  local netText
  if net.connected then
    netText = string.format("%s (%d%%)", net.ssid or "Connected", net.signal or 0)
    if net.ip and net.ip ~= "" then
      netText = netText .. " • " .. net.ip
    end
  else
    netText = "Disconnected"
  end

  barWidget.setTooltip({
    { key = "Battery", value = batText },
    { key = "Network", value = netText },
  })
end

local function render()
  local size = tonumber(noctalia.getConfig("icon_size")) or 24
  local showLabel = noctalia.getConfig("show_label") == true

  local children = {}
  if iconPath and noctalia.fileExists(iconPath) then
    children[#children + 1] = ui.image({
      path = iconPath,
      width = size,
      height = size,
      fit = "contain",
    })
  else
    children[#children + 1] = ui.glyph({
      name = "wifi-2",
      size = size * 0.8,
      color = "primary",
    })
  end

  if showLabel and state and state.battery then
    children[#children + 1] = ui.label({
      text = string.format("%d%%", state.battery.percent or 0),
      fontSize = 11,
      fontWeight = "semibold",
      color = "on_surface",
    })
  end

  barWidget.render(ui.row({
    align = "center",
    gap = 6,
  }, children))

  updateTooltip()
end

noctalia.state.watch("duo_status.icon_path", function(path)
  iconPath = path
  render()
end)

noctalia.state.watch("duo_status.state", function(s)
  state = s
  render()
end)

function onConfigChanged()
  render()
end

render()

function onClick()
  noctalia.togglePanel("pschmitt/duo-status:panel")
end

function onRightClick()
  noctalia.toggleControlCenter("network")
end
