--!nonstrict

local shared = require("./shared.luau")
local entities = noctalia.state.get("ha.entities") or {}
local sections = noctalia.state.get("ha.sections") or {}
local barItems = noctalia.state.get("ha.bar_items") or {}
local barConfig = noctalia.state.get("ha.bar_config") or {}
local errorMessage = noctalia.state.get("ha.error") or ""
local barTargetEntity = noctalia.state.get("ha.bar_target")
local barActions = noctalia.state.get("ha.bar_actions") or {}
local animationFrame = 0
local ANIMATION_FRAME_COUNT = 24
local ANIMATION_FRAME_INTERVAL_MS = 30
local IDLE_UPDATE_INTERVAL_MS = 30000
local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(value)
  local output = {}
  for index = 1, #value, 3 do
    local a, b, c = string.byte(value, index, index + 2)
    b = b or 0
    c = c or 0
    local packed = a * 65536 + b * 256 + c
    output[#output + 1] = BASE64:sub(math.floor(packed / 262144) % 64 + 1, math.floor(packed / 262144) % 64 + 1)
    output[#output + 1] = BASE64:sub(math.floor(packed / 4096) % 64 + 1, math.floor(packed / 4096) % 64 + 1)
    output[#output + 1] = index + 1 <= #value and BASE64:sub(math.floor(packed / 64) % 64 + 1, math.floor(packed / 64) % 64 + 1) or "="
    output[#output + 1] = index + 2 <= #value and BASE64:sub(packed % 64 + 1, packed % 64 + 1) or "="
  end
  return table.concat(output)
end

local function iconSize()
  return tonumber(shared.config("bar_icon_size", 16)) or 16
end

-- One glyph per configured entity, tinted by state. Noctalia gives a bar
-- widget exactly one click target for its whole rendered area (every other
-- plugin's bar.luau in this repo only ever defines a single onClick/
-- onRightClick pair -- see pschmitt/ha-ai-usage's note on the same
-- constraint), so per-entity toggling lives in the panel, not here: clicking
-- any part of this row opens it.
local function animationsEnabled()
  return shared.config("animations_enabled", true) ~= false
end

local function animationActive()
  if not animationsEnabled() or shared.config("bar_display_mode", "entities") == "single" then return false end
  for _, entity in ipairs(entities) do
    local hasOverride = type(entity.icon) == "string" and entity.icon ~= ""
    if shared.domainOf(entity.entity_id) == "fan" and not hasOverride and shared.isOn(entity.state) then return true end
  end
  return false
end

local function segment(entity)
  local domain = shared.domainOf(entity.entity_id)
  local hasOverride = type(entity.icon) == "string" and entity.icon ~= ""
  if domain == "fan" and not hasOverride and shared.isOn(entity.state) and animationActive() then
    return ui.image({
      path = string.format("assets/fan-propeller-%02d.png", animationFrame),
      width = iconSize(),
      height = iconSize(),
      fit = "contain",
    })
  end
  return ui.glyph({ name = shared.glyphFor(domain, entity.icon, entity.state), size = iconSize(), color = shared.iconColor(entity) })
end

local function tooltip()
  local rows = {}
  local sectioned = {}
  for _, section in ipairs(sections) do
    for _, entityId in ipairs(section.entities or {}) do sectioned[entityId] = true end
  end

  -- Tooltip data is a flat list of `{ key, value }` rows; unlike the panel
  -- tree it has no separator node. Keep section-less entities first, then
  -- add a visually distinct section-heading row before each populated
  -- section. This gives the hover summary the intended grouping without
  -- relying on unsupported tooltip fields.
  local byId = {}
  for _, entity in ipairs(entities) do byId[entity.entity_id] = entity end
  local function addEntity(entity)
    rows[#rows + 1] = { key = entity.name or entity.entity_id, value = shared.statusText(entity) }
  end
  for _, entity in ipairs(entities) do
    if not sectioned[entity.entity_id] then addEntity(entity) end
  end
  for _, section in ipairs(sections) do
    local sectionRows = {}
    for _, entityId in ipairs(section.entities or {}) do
      local entity = byId[entityId]
      if entity then sectionRows[#sectionRows + 1] = entity end
    end
    if #sectionRows > 0 then
      rows[#rows + 1] = { key = "── " .. section.name .. " ──", value = "" }
      for _, entity in ipairs(sectionRows) do addEntity(entity) end
    end
  end
  if #rows == 0 then
    rows[#rows + 1] = { key = "Home Assistant", value = "No entities configured yet -- click to add some" }
  end
  if errorMessage ~= "" then rows[#rows + 1] = { key = "Status", value = errorMessage } end
  return rows
end

local function customBarItem(item)
  local color = shared.colorFor(item.state)
  local icon = ui.glyph({
    name = shared.glyphFor(shared.domainOf(item.entity_id), item.icon, item.state),
    size = iconSize(),
    color = color,
  })
  local text = ui.label({ text = item.display_state or item.state or "", fontSize = 11, fontWeight = "semibold", color = color, maxLines = 1 })
  if item.widget == "progress" then
    local percentage = tonumber(item.display_state or item.state)
    local nodes = { icon }
    if percentage ~= nil then
      nodes[#nodes + 1] = ui.progress({
        progress = math.max(0, math.min(100, percentage)) / 100,
        fill = color,
        track = "on_surface/0.16",
        width = 28,
        height = 5,
        radius = 6,
      })
    end
    nodes[#nodes + 1] = text
    return ui.row({ align = "center", gap = 5 }, nodes)
  end
  return ui.row({ align = "center", gap = 5 }, { icon, text })
end

local function badgeConfig()
  for _, item in ipairs(barConfig) do
    if item.widget == "badge" then return item end
  end
  return nil
end

local function badgeIsActive(config)
  for _, item in ipairs(barItems) do
    if item.entity_id == config.entity_id then return item.visible == true end
  end
  return false
end

local function badgeLogo(config)
  local position = config.position or "top_right"
  local color = type(config.color) == "string" and config.color:match("^#%x%x%x%x%x%x$") and config.color or "#ff0000"
  local dataDir = noctalia.pluginDataDir()
  if not dataDir then return nil end
  local fileNameColor = color:sub(2):lower()
  local active = badgeIsActive(config)
  local path = dataDir .. "/ha-badge-" .. position .. "-" .. fileNameColor .. (active and "-on.svg" or "-off.svg")
  if noctalia.fileExists(path) then return path end

  local logo = noctalia.readFile(noctalia.pluginDir() .. "/assets/home-assistant-icon.png")
  if type(logo) ~= "string" or logo == "" then return nil end
  local locations = {
    top_left = { 12, 12 },
    top_right = { 52, 12 },
    bottom_left = { 12, 52 },
    bottom_right = { 52, 52 },
  }
  local point = locations[position] or locations.top_right
  local badge = ""
  if active then
    badge = string.format('<circle cx="%d" cy="%d" r="9" fill="%s" stroke="#ffffff" stroke-width="3"/>', point[1], point[2], color)
  end
  local svg = string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><image href="data:image/png;base64,%s" width="64" height="64"/>%s</svg>',
    base64(logo),
    badge
  )
  local ok = noctalia.writeFile(path, svg)
  if not ok then return nil end
  return path
end

local function badgeNode(config)
  local path = badgeLogo(config)
  if path then return ui.image({ path = path, width = iconSize(), height = iconSize(), fit = "contain" }) end
  return ui.image({ path = "assets/home-assistant-icon.png", width = iconSize(), height = iconSize(), fit = "contain" })
end

-- "single" collapses the whole widget to one fixed icon -- for whoever wants
-- a stable bar slot rather than one that grows/shrinks/recolors with however
-- many entities happen to be configured right now. Defaults to the real
-- Home Assistant mark; Bar: Single icon glyph only takes over once it's set
-- to something other than its own "smart-home" default, for whoever would
-- rather have a plain Tabler glyph than the branded logo.
local function render()
  local children = {}
  local badge = badgeConfig()
  if badge then children[#children + 1] = badgeNode(badge) end
  if shared.config("bar_display_mode", "entities") == "single" then
    if not badge then
      local iconName = shared.trim(shared.config("bar_icon", "smart-home"))
      if iconName == "" or iconName == "smart-home" then
        children[#children + 1] = ui.image({ path = "assets/home-assistant-icon.png", width = iconSize(), height = iconSize(), fit = "contain" })
      else
        children[#children + 1] = ui.glyph({ name = iconName, size = iconSize(), color = "on_surface_variant" })
      end
    end
    -- Keep the stable single-icon slot while allowing declarative widgets
    -- (such as a washer timer) to appear beside it.
    for _, item in ipairs(barItems) do
      if item.visible and item.widget ~= "badge" then children[#children + 1] = customBarItem(item) end
    end
  else
    local customIds = {}
    for _, item in ipairs(barItems) do
      if item.visible and item.widget ~= "badge" then customIds[item.entity_id] = true end
    end
    for _, entity in ipairs(entities) do
      if not customIds[entity.entity_id] then children[#children + 1] = segment(entity) end
    end
    for _, item in ipairs(barItems) do
      if item.visible and item.widget ~= "badge" then children[#children + 1] = customBarItem(item) end
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
  noctalia.setUpdateInterval(animationActive() and ANIMATION_FRAME_INTERVAL_MS or IDLE_UPDATE_INTERVAL_MS)
end

noctalia.state.watch("ha.entities", function(value)
  entities = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.sections", function(value)
  sections = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.bar_items", function(value)
  barItems = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.bar_config", function(value)
  barConfig = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)

noctalia.state.watch("ha.bar_target", function(value)
  barTargetEntity = value
  render()
end)

noctalia.state.watch("ha.bar_actions", function(value)
  barActions = type(value) == "table" and value or {}
  render()
end)

function update()
  if animationActive() then animationFrame = (animationFrame + 1) % ANIMATION_FRAME_COUNT end
  render()
end

function onConfigChanged()
  animationFrame = 0
  render()
end

-- Same runAction()/ACTIONS convention pschmitt/battery-icon's bar.luau uses:
-- each interaction setting names one of these, so left/right/middle click
-- and scroll up/down are all independently configurable instead of hardcoded
-- to one action apiece.
local ACTIONS = {
  panel = function() noctalia.togglePanel("pschmitt/ha:panel") end,
  refresh = function() noctalia.state.set("ha.command", { action = "refresh" }) end,
  open_dashboard = function() noctalia.state.set("ha.command", { action = "open_dashboard" }) end,
}

local DEFAULT_CONTROL_ACTIONS = {
  light = { right_click = "toggle", scroll_up = "brightness_up", scroll_down = "brightness_down" },
  media_player = { right_click = "play_pause", scroll_up = "volume_up", scroll_down = "volume_down" },
  fan = { right_click = "toggle", scroll_up = "percentage_up", scroll_down = "percentage_down" },
}

local function controlEntity()
  if type(barTargetEntity) ~= "string" or barTargetEntity == "" then return nil end
  for _, entity in ipairs(entities) do
    if entity.entity_id == barTargetEntity then return entity end
  end
  return nil
end

local function runControlAction(gesture)
  local entity = controlEntity()
  if not entity then return end
  local action = barActions[gesture]
  if type(action) ~= "string" or action == "" then
    local defaults = DEFAULT_CONTROL_ACTIONS[shared.domainOf(entity.entity_id)]
    action = defaults and defaults[gesture]
  end
  if action and action ~= "none" then
    noctalia.state.set("ha.command", { action = "bar_service", entity_id = entity.entity_id, service = action })
  end
end

local function runAction(settingKey, gesture)
  local configured = noctalia.getConfig(settingKey)
  if configured == "control_entity" then
    runControlAction(gesture)
    return
  end
  local action = ACTIONS[configured]
  if action then action() end
end

function onClick()
  runAction("action_left_click", "left_click")
end

function onRightClick()
  runAction("action_right_click", "right_click")
end

function onMiddleClick()
  runAction("action_middle_click", "middle_click")
end

-- Same scroll convention as Noctalia's built-in widgets: positive steps are
-- scroll-down.
function onScroll(_axis, steps, _startsGesture)
  local gesture = steps > 0 and "scroll_down" or "scroll_up"
  runAction("action_" .. gesture, gesture)
end

render()
