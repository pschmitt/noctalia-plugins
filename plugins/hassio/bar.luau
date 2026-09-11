--!nonstrict

local shared = require("./shared.luau")
local entities = noctalia.state.get("hassio.entities") or {}
local errorMessage = noctalia.state.get("hassio.error") or ""

local function iconSize()
  return tonumber(shared.config("bar_icon_size", 16)) or 16
end

-- One glyph per configured entity, tinted by state. Noctalia gives a bar
-- widget exactly one click target for its whole rendered area (every other
-- plugin's bar.luau in this repo only ever defines a single onClick/
-- onRightClick pair -- see pschmitt/ha-ai-usage's note on the same
-- constraint), so per-entity toggling lives in the panel, not here: clicking
-- any part of this row opens it.
local function segment(entity)
  local domain = shared.domainOf(entity.entity_id)
  return ui.glyph({ name = shared.glyphFor(domain), size = iconSize(), color = shared.colorFor(entity.state) })
end

local function tooltip()
  local rows = {}
  for _, entity in ipairs(entities) do
    rows[#rows + 1] = { key = entity.name or entity.entity_id, value = entity.state or "—" }
  end
  if #rows == 0 then
    rows[#rows + 1] = { key = "Home Assistant", value = "No entities configured yet -- click to add some" }
  end
  if errorMessage ~= "" then rows[#rows + 1] = { key = "Status", value = errorMessage } end
  return rows
end

-- "single" collapses the whole widget to one fixed, configurable glyph --
-- for whoever wants a stable bar slot rather than one that grows/shrinks/
-- recolors with however many entities happen to be configured right now.
local function render()
  local children = {}
  if shared.config("bar_display_mode", "entities") == "single" then
    local iconName = shared.trim(shared.config("bar_icon", "smart-home"))
    children[#children + 1] = ui.glyph({ name = iconName ~= "" and iconName or "smart-home", size = iconSize(), color = "on_surface_variant" })
  else
    for _, entity in ipairs(entities) do
      children[#children + 1] = segment(entity)
    end
    if #children == 0 then
      children[#children + 1] = ui.glyph({ name = "smart-home", size = iconSize(), color = "on_surface_variant" })
    end
  end
  if errorMessage ~= "" then
    children[#children + 1] = ui.glyph({ name = "alert-circle", size = 12, color = "error" })
  end
  local gap = tonumber(shared.config("bar_spacing", 6)) or 6
  barWidget.render(ui.row({ align = "center", gap = gap }, children))
  barWidget.setTooltip(tooltip())
end

noctalia.state.watch("hassio.entities", function(value)
  entities = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("hassio.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)

function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel("pschmitt/hassio:panel")
end

function onRightClick()
  noctalia.state.set("hassio.command", { action = "refresh" })
end

render()
