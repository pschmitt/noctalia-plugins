--!nonstrict
-- Battery icon bar widget — displays the pre-rendered PNG from the
-- service (percentage baked directly into the icon body). Left-click opens
-- this plugin's compact power panel under the bar widget.

local state = noctalia.state.get("battery_icon")
local PANEL_ID = "pschmitt/battery-icon:power"

local function render()
  if state == nil or state.path == nil then
    barWidget.setVisible(false)
    return
  end

  local width = tonumber(noctalia.getConfig("icon_width")) or 36
  local height = tonumber(noctalia.getConfig("icon_height")) or 18

  barWidget.setVisible(true)
  barWidget.render(ui.row({}, {
    -- fit="contain": the rendered PNG is 128x64 (2:1, wider than the
    -- battery body itself to leave room for either the terminal or charging
    -- bolt) — without contain, a mismatched display box stretches it.
    ui.image({ path = state.path, width = width, height = height, fit = "contain" }),
  }))
  local suffix = state.charging and " (charging)" or (state.powerSaver and " (Battery Saver)" or "")
  barWidget.setTooltip(tostring(state.percent) .. "%" .. suffix)
end

noctalia.state.watch("battery_icon", function(val)
  state = val
  render()
end)

render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
