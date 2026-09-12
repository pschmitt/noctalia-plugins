--!nonstrict

local shared = require("./shared.luau")

local panelOpen = false
local view = "list" -- "list" | "browse" | "details"

local configuredEntities = noctalia.state.get("ha.configured") or {}
local sections = noctalia.state.get("ha.sections") or {}
local entityRemotes = noctalia.state.get("ha.entity_remotes") or {}
local panelControls = noctalia.state.get("ha.panel_controls") or {}
local domainControls = noctalia.state.get("ha.domain_controls") or {}
local favoritePositions = noctalia.state.get("ha.favorite_positions") or {}
local entities = noctalia.state.get("ha.entities") or {}
local hidden = noctalia.state.get("ha.hidden") or {}
local sectionVisibility = noctalia.state.get("ha.section_visibility") or {}
local errorMessage = noctalia.state.get("ha.error") or ""
local lastRefreshedAt = noctalia.state.get("ha.refreshed_at")

local domainFilter = "all"
local areaFilter = "all"
local areas = noctalia.state.get("ha.areas") or {} -- {id, name}, from Home Assistant's own area registry
local searchText = ""
local listSearchText = ""
local browseRows = {}
local browseOffset = 0
local browseMore = false
local browseLoading = false
local browseErrorMessage = noctalia.state.get("ha.browse_error") or ""
local details = noctalia.state.get("ha.details") or {}
local detailsLoading = false
local detailsErrorMessage = noctalia.state.get("ha.details_error") or ""
local detailsEntityId = nil
local CARD_STYLE = { fill = "surface_variant/0.58", radius = 12, padding = 10, gap = 2 }
local ENTITY_DRAG_TYPE = "ha-entity"
local SECTION_DRAG_TYPE = "ha-section"
local animationFrame = 0
local animationElapsedMs = 0
local ANIMATION_FRAME_COUNT = 24
local ANIMATION_FRAME_INTERVAL_MS = 30

-- Forward-declared: referenced by action handlers defined before its real
-- body below (they only ever run after the whole script has loaded once, so
-- this only needs to resolve as an upvalue, not have a body yet).
local render

local function sendCommand(command)
  noctalia.state.set("ha.command", command)
end

local function animationsEnabled()
  return noctalia.getConfig("animations_enabled") ~= false
end

local function panelAnimationActive()
  if not animationsEnabled() or view ~= "list" then return false end
  for _, entity in ipairs(entities) do
    local hasOverride = type(entity.icon) == "string" and entity.icon ~= ""
    if shared.domainOf(entity.entity_id) == "fan" and not hasOverride and shared.isOn(entity.state) then return true end
  end
  return false
end

local function entityIcon(entity, size)
  local domain = shared.domainOf(entity.entity_id)
  local hasOverride = type(entity.icon) == "string" and entity.icon ~= ""
  if domain == "fan" and not hasOverride and shared.isOn(entity.state) and panelAnimationActive() then
    return ui.image({
      path = string.format("assets/fan-propeller-%02d.png", animationFrame),
      width = size,
      height = size,
      fit = "contain",
    })
  end
  return ui.glyph({ name = shared.glyphFor(domain, entity.icon, entity.state), size = size, color = shared.colorFor(entity.state) })
end

local function openDetails(entityId)
  view = "details"
  detailsEntityId = entityId
  details = {}
  detailsLoading = true
  detailsErrorMessage = ""
  render()
  sendCommand({ action = "details", entity_id = entityId })
end

local function configuredSet()
  local set = {}
  for _, id in ipairs(configuredEntities) do set[id] = true end
  return set
end

-- The curated subset of shared.BROWSABLE_DOMAINS worth a dedicated option in a
-- 420px panel; the rest stay reachable via free-text search (e.g. "camera.")
-- once results are on screen. Every entry here must still be one of
-- shared.BROWSABLE_DOMAINS -- that list is also the interpolation whitelist
-- service.luau's browseSource() checks against.
local PANEL_DOMAIN_CHIPS = {
  "light", "switch", "script", "automation", "scene", "fan", "lock", "cover",
  "climate", "media_player", "sensor", "binary_sensor", "input_boolean",
}

local function fetchBrowsePage(reset)
  if reset then
    browseRows = {}
    browseOffset = 0
    browseMore = false
  end
  browseLoading = true
  render()
  sendCommand({ action = "browse", domain = domainFilter, area = areaFilter, offset = browseOffset })
end

local function setDomainFilter(domain)
  if domainFilter == domain then return end
  domainFilter = domain
  fetchBrowsePage(true)
end

local function setAreaFilter(area)
  if areaFilter == area then return end
  areaFilter = area
  fetchBrowsePage(true)
end

local function filteredBrowseRows()
  local needle = shared.trim(searchText):lower()
  if needle == "" then return browseRows end
  local out = {}
  for _, row in ipairs(browseRows) do
    if row.entity_id:lower():find(needle, 1, true) or (row.name or ""):lower():find(needle, 1, true) then
      out[#out + 1] = row
    end
  end
  return out
end

-- ── "My entities" view ───────────────────────────────────────────────────────

-- entity_id -> previewed 0-100 slider value while a brightness/fan-speed drag
-- is in progress. entities gets replaced wholesale on every ha.entities
-- update, so this has to live outside that table (same pattern fan-control's
-- panel uses for its own speed slider).
local sliderPreviews = {}
local collapsedSections = {}

local function coverButtons(entity)
  local function press(command)
    return function() sendCommand({ action = "cover", entity_id = entity.entity_id, command = command }) end
  end
  return ui.row({ gap = 2 }, {
    ui.button({ glyph = "arrow-up", variant = "ghost", controlSize = "sm", tooltip = "Open", onClick = press("open") }),
    ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm", tooltip = "Stop", onClick = press("stop") }),
    ui.button({ glyph = "arrow-down", variant = "ghost", controlSize = "sm", tooltip = "Close", onClick = press("close") }),
  })
end

local function controlServiceParts(serviceName)
  return type(serviceName) == "string" and serviceName:match("^([%w_]+)%.([%w_]+)$")
end

local function defaultControlGlyph(serviceName)
  local domain, service = controlServiceParts(serviceName)
  if domain == "lock" and service == "lock" then return "lock" end
  if domain == "lock" and service == "unlock" then return "lock-open" end
  if domain == "lock" and service == "open" then return "door-open" end
  if domain == "cover" and service == "open_cover" then return "arrow-up" end
  if domain == "cover" and service == "close_cover" then return "arrow-down" end
  if domain == "cover" and service == "stop_cover" then return "player-stop" end
  if service == "toggle" then return "power" end
  return "settings"
end

local function defaultControlTooltip(serviceName)
  local _, service = controlServiceParts(serviceName)
  return service and (service:gsub("_", " ")) or serviceName
end

local function customPanelControls(entity)
  if entity.panel_controls == nil then return nil end
  local buttons = {}
  for _, control in ipairs(entity.panel_controls) do
    local serviceName = type(control) == "string" and control or control.service
    if type(serviceName) == "string" and serviceName ~= "" then
      local glyph = type(control) == "table" and control.glyph or nil
      local tooltip = type(control) == "table" and control.tooltip or nil
      local data = type(control) == "table" and control.data or nil
      buttons[#buttons + 1] = ui.button({
        glyph = glyph or defaultControlGlyph(serviceName),
        variant = "ghost",
        controlSize = "sm",
        tooltip = tooltip or defaultControlTooltip(serviceName),
        onClick = function()
          sendCommand({ action = "panel_service", entity_id = entity.entity_id, service = serviceName, data = data })
        end,
      })
    end
  end
  return #buttons > 0 and ui.row({ gap = 2 }, buttons) or nil
end

-- Shared by brightnessSlider/fanSlider: `value01to100` is what's currently
-- known (from the last refresh, converted to 0-100), overridden by a preview
-- while dragging. onChange previews and re-renders on every tick; onDragEnd
-- is the only point that actually calls Home Assistant, so a drag never
-- floods it with a request per pixel moved.
local function previewSlider(entity, value01to100, commit)
  local previewed = sliderPreviews[entity.entity_id]
  local value = previewed or value01to100 or 0
  return ui.slider({
    min = 0,
    max = 100,
    step = 1,
    value = value,
    width = 200,
    controlSize = "sm",
    onChange = function(nextValue)
      sliderPreviews[entity.entity_id] = tonumber(nextValue) or value
      render()
    end,
    onDragEnd = function(nextValue)
      local target = sliderPreviews[entity.entity_id] or tonumber(nextValue) or value
      sliderPreviews[entity.entity_id] = nil
      commit(target)
    end,
  })
end

local function coverPositionSlider(entity)
  return previewSlider(entity, entity.position or 0, function(target)
    sendCommand({ action = "set_cover_position", entity_id = entity.entity_id, value = target })
  end)
end

local function coverFavoriteButtons(entity)
  local buttons = {}
  for _, position in ipairs(entity.favorite_positions or {}) do
    buttons[#buttons + 1] = ui.button({
      text = tostring(position) .. "%",
      variant = tonumber(entity.position) == position and "primary" or "ghost",
      controlSize = "sm",
      tooltip = "Move to " .. tostring(position) .. "%",
      onClick = function()
        sendCommand({ action = "set_cover_position", entity_id = entity.entity_id, value = position })
      end,
    })
  end
  return #buttons > 0 and ui.row({ gap = 2 }, buttons) or nil
end

local function brightnessSlider(entity)
  local pct = entity.brightness and math.floor((entity.brightness / 255) * 100 + 0.5) or 0
  return previewSlider(entity, pct, function(target)
    sendCommand({ action = "set_brightness", entity_id = entity.entity_id, value = (target / 100) * 255 })
  end)
end

local function lightColorHex(entity)
  if entity.rgb ~= nil and entity.rgb_g ~= nil and entity.rgb_b ~= nil then
    return string.format("#%02x%02x%02x", entity.rgb, entity.rgb_g, entity.rgb_b)
  end
  return "#ffffff"
end

local function lightHasColor(entity)
  return entity.rgb ~= nil and entity.rgb_g ~= nil and entity.rgb_b ~= nil
end

local function openLightColor(entity)
  noctalia.openColorPicker(lightColorHex(entity), function(color)
    if type(color) ~= "string" then return end
    local red, green, blue = color:match("^#(%x%x)(%x%x)(%x%x)$")
    if not red or not green or not blue then return end
    sendCommand({
      action = "set_color",
      entity_id = entity.entity_id,
      color = { tonumber(red, 16), tonumber(green, 16), tonumber(blue, 16) },
    })
  end)
end

local function fanSlider(entity)
  return previewSlider(entity, entity.percentage or 0, function(target)
    sendCommand({ action = "set_percentage", entity_id = entity.entity_id, value = target })
  end)
end

local function fanOscillationButton(entity)
  if entity.oscillating == nil or not shared.isOn(entity.state) then return nil end
  return ui.button({
    glyph = "arrows-left-right",
    variant = entity.oscillating and "primary" or "ghost",
    controlSize = "sm",
    tooltip = entity.oscillating and "Stop oscillation" or "Start oscillation",
    onClick = function()
      sendCommand({ action = "oscillate", entity_id = entity.entity_id, value = not entity.oscillating })
    end,
  })
end

local function lockButtons(entity, includeOpen)
  local buttons = {
    ui.button({
      glyph = "lock-open",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Unlock",
      onClick = function() sendCommand({ action = "lock", entity_id = entity.entity_id, command = "unlock" }) end,
    }),
    ui.button({
      glyph = "lock",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Lock",
      onClick = function() sendCommand({ action = "lock", entity_id = entity.entity_id, command = "lock" }) end,
    }),
  }
  if includeOpen and shared.lockSupportsOpen(entity) then
    buttons[#buttons + 1] = ui.button({
      glyph = "door-open",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Open door",
      onClick = function() sendCommand({ action = "lock", entity_id = entity.entity_id, command = "open" }) end,
    })
  end
  return ui.row({ gap = 2 }, buttons)
end

local function mediaVolumeSlider(entity)
  local pct = entity.volume_level and math.floor(entity.volume_level * 100 + 0.5) or 0
  return previewSlider(entity, pct, function(target)
    sendCommand({ action = "media", entity_id = entity.entity_id, command = "volume_set", value = target / 100 })
  end)
end

local function mediaButton(entity, glyph, tooltip, command, value)
  return ui.button({
    glyph = glyph,
    variant = "ghost",
    controlSize = "sm",
    tooltip = tooltip,
    onClick = function() sendCommand({ action = "media", entity_id = entity.entity_id, command = command, value = value }) end,
  })
end

local function mediaButtons(entity)
  local playGlyph = entity.state == "playing" and "player-pause" or "player-play"
  local muteGlyph = entity.volume_muted and "volume-off" or "volume-2"
  return ui.row({ gap = 2 }, {
    mediaButton(entity, playGlyph, entity.state == "playing" and "Pause" or "Play", "play_pause"),
    mediaButton(entity, muteGlyph, entity.volume_muted and "Unmute" or "Mute", "volume_mute", not entity.volume_muted),
    mediaButton(entity, "power", "Turn media player on/off", "power"),
  })
end

local function remoteButton(entity, glyph, tooltip, command)
  return ui.button({
    glyph = glyph,
    variant = "ghost",
    controlSize = "sm",
    tooltip = tooltip,
    onClick = function()
      sendCommand({ action = "remote", entity_id = entity.remote, command = command })
    end,
  })
end

local function remoteControls(entity)
  if type(entity.remote) ~= "string" or entity.remote == "" then return nil end
  return ui.column({ gap = 2 }, {
    ui.row({ justify = "center", gap = 2 }, {
      remoteButton(entity, "arrow-up", "Up", "up"),
    }),
    ui.row({ justify = "center", gap = 2 }, {
      remoteButton(entity, "arrow-left", "Left", "left"),
      remoteButton(entity, "circle-check", "OK", "select"),
      remoteButton(entity, "arrow-right", "Right", "right"),
    }),
    ui.row({ justify = "center", gap = 2 }, {
      remoteButton(entity, "arrow-down", "Down", "down"),
    }),
    ui.row({ justify = "center", gap = 2 }, {
      remoteButton(entity, "home", "Home", "home"),
      remoteButton(entity, "arrow-left", "Back", "back"),
    }),
  })
end

-- The details endpoint returns Home Assistant's native state object rather
-- than the compact row shape used by the list refresh. Normalize the fields
-- the existing controls need so the details view can use the same controls
-- without making another request just to translate the response.
local function detailsEntity()
  local attributes = details.attributes or {}
  local rgb = attributes.rgb_color
  return {
    entity_id = details.entity_id or detailsEntityId,
    state = details.state,
    name = attributes.friendly_name,
    icon = attributes.icon,
    remote = entityRemotes[details.entity_id or detailsEntityId],
    brightness = attributes.brightness,
    percentage = attributes.percentage,
    oscillating = attributes.oscillating,
    supported_features = attributes.supported_features,
    panel_controls = panelControls[details.entity_id or detailsEntityId]
      or domainControls[shared.domainOf(details.entity_id or detailsEntityId)],
    position = attributes.current_position,
    favorite_positions = favoritePositions[details.entity_id or detailsEntityId],
    volume_level = attributes.volume_level,
    volume_muted = attributes.is_volume_muted == true,
    media_title = attributes.media_title,
    media_artist = attributes.media_artist,
    rgb = type(rgb) == "table" and rgb[1] or nil,
    rgb_g = type(rgb) == "table" and rgb[2] or nil,
    rgb_b = type(rgb) == "table" and rgb[3] or nil,
  }
end

local function detailToggleButtons(entity, domain)
  local buttons = {}
  if domain == "light" and lightHasColor(entity) then
    buttons[#buttons + 1] = ui.button({
      glyph = "palette",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Set light color",
      onClick = function() openLightColor(entity) end,
    })
  end
  local on = shared.isOn(entity.state)
  -- The action glyph describes what the button will do: a lit bulb means
  -- "turn on" while the crossed-out bulb means "turn off".
  local toggleGlyph = domain == "light" and (on and "bulb-off" or "bulb") or "power"
  if domain == "fan" then
    local oscillationButton = fanOscillationButton(entity)
    if oscillationButton then buttons[#buttons + 1] = oscillationButton end
  end
  buttons[#buttons + 1] = ui.button({
    glyph = toggleGlyph,
    variant = "ghost",
    controlSize = "sm",
    tooltip = "Toggle",
    onClick = function() sendCommand({ action = "toggle", entity_id = entity.entity_id }) end,
  })
  return ui.row({ gap = 2 }, buttons)
end

local function detailsControls(entity)
  local domain = shared.domainOf(entity.entity_id)
  local rows = {}

  if entity.panel_controls ~= nil then
    local custom = customPanelControls(entity)
    if custom then rows[#rows + 1] = custom end
  elseif domain == "cover" then
    rows[#rows + 1] = coverButtons(entity)
    if entity.position ~= nil then
      local shownPosition = sliderPreviews[entity.entity_id] or entity.position
      rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
        ui.glyph({ name = "arrows-vertical", size = 14, color = "on_surface_variant" }),
        coverPositionSlider(entity),
        ui.label({ text = tostring(math.floor(shownPosition + 0.5)) .. "%", width = 38, fontSize = 11, color = "on_surface_variant" }),
      })
    end
    local favorites = coverFavoriteButtons(entity)
    if favorites then rows[#rows + 1] = favorites end
  elseif domain == "media_player" then
    rows[#rows + 1] = mediaButtons(entity)
    local remote = remoteControls(entity)
    if remote then rows[#rows + 1] = remote end
  elseif domain == "lock" then
    rows[#rows + 1] = lockButtons(entity, true)
  elseif shared.isToggleable(domain) then
    rows[#rows + 1] = detailToggleButtons(entity, domain)
  end

  if domain == "light" and shared.isOn(entity.state) and entity.brightness ~= nil then
    rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
      ui.box({ width = 28, height = 1, fill = "on_surface/0" }),
      brightnessSlider(entity),
    })
  elseif domain == "fan" and shared.isOn(entity.state) and entity.percentage ~= nil then
    rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
      ui.box({ width = 28, height = 1, fill = "on_surface/0" }),
      fanSlider(entity),
    })
  elseif domain == "media_player" and entity.volume_level ~= nil then
    rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = entity.volume_muted and "volume-off" or "volume-2", size = 14, color = "on_surface_variant" }),
      mediaVolumeSlider(entity),
    })
  end

  if #rows == 0 then return nil end
  return ui.column({ gap = 6 }, rows)
end

-- A single footer button (see footer() below) flips the whole list into
-- edit mode at once, rather than a per-row reveal toggle: every row's
-- rename/remove buttons show together, and its normal controls (toggle,
-- cover buttons, sliders) hide together, so edit mode reads as one clear
-- state instead of row-by-row guessing which one is "open".
local editMode = false
local editingEntityId = nil
local editingLabelDraft = ""
local editingSectionIndex = nil
local editingSectionDraft = ""
local addingSection = false
local addingSectionDraft = ""

local function editButtonHidden()
  return noctalia.getConfig("panel_hide_edit_button") == true
end

local function toggleEditMode()
  if not editMode and editButtonHidden() then return end
  editMode = not editMode
  editingEntityId = nil
  editingSectionIndex = nil
  addingSection = false
  render()
end

local function startRename(entity)
  editingEntityId = entity.entity_id
  editingLabelDraft = entity.name or entity.entity_id
  editingSectionIndex = nil
  render()
end

local function cancelRename()
  editingEntityId = nil
  render()
end

local function saveRename()
  if editingEntityId then
    sendCommand({ action = "rename", entity_id = editingEntityId, label = editingLabelDraft })
  end
  editingEntityId = nil
  render()
end

local function sectionIndexOf(entityId)
  for index, section in ipairs(sections) do
    for _, id in ipairs(section.entities or {}) do
      if id == entityId then return index end
    end
  end
  return 0
end

local function sectionName(index)
  if index and index > 0 and sections[index] then return sections[index].name end
  return "section-less"
end

local function nextSectionIndex(entityId)
  local current = sectionIndexOf(entityId)
  return current < #sections and current + 1 or 0
end

-- Drop values use stable entity ids rather than numeric positions. This is
-- important for conditional rows: a hidden row must not shift the target when
-- the user drops an entity between two visible rows.
local function entityDropValue(sectionIndex, beforeEntity)
  if beforeEntity and beforeEntity ~= "" then
    return "section:" .. tostring(sectionIndex) .. ":before:" .. beforeEntity
  end
  return "section:" .. tostring(sectionIndex) .. ":end"
end

local function entityDropZone(sectionIndex, beforeEntity)
  return ui.dropZone({
    key = "ha-entity-gap-" .. tostring(sectionIndex) .. ":" .. tostring(beforeEntity or "end"),
    accepts = { ENTITY_DRAG_TYPE },
    value = entityDropValue(sectionIndex, beforeEntity),
    onDrop = "onEntityDropped",
    height = 3,
    radius = 6,
    expandOnDrag = true,
    hitSlop = 24,
  })
end

function onEntityDropped(payload, value)
  local sectionText, beforeEntity = value:match("^section:(%d+):before:(.+)$")
  if sectionText == nil then sectionText = value:match("^section:(%d+):end$") end
  if sectionText == nil or payload == nil or payload == "" then return end
  sendCommand({
    action = "drop",
    entity_id = payload,
    target_section = tonumber(sectionText) or 0,
    before_entity = beforeEntity,
  })
end

local function sectionDropZone(targetIndex)
  return ui.dropZone({
    key = "ha-section-gap-" .. tostring(targetIndex),
    accepts = { SECTION_DRAG_TYPE },
    value = tostring(targetIndex),
    onDrop = "onSectionDropped",
    height = 4,
    radius = 6,
    expandOnDrag = true,
    hitSlop = 20,
  })
end

function onSectionDropped(payload, value)
  local fromIndex = tonumber(payload)
  local targetIndex = tonumber(value)
  if not fromIndex or not targetIndex then return end
  sendCommand({ action = "drop_section", from_index = fromIndex, target_index = targetIndex })
end

local function startRenameSection(index)
  editingSectionIndex = index
  editingSectionDraft = sections[index].name or ""
  editingEntityId = nil
  render()
end

local function cancelRenameSection()
  editingSectionIndex = nil
  render()
end

local function startAddSection()
  editMode = true
  editingEntityId = nil
  editingSectionIndex = nil
  addingSection = true
  addingSectionDraft = ""
  render()
end

local function cancelAddSection()
  addingSection = false
  addingSectionDraft = ""
  render()
end

local function saveAddSection()
  local name = shared.trim(addingSectionDraft)
  if name == "" then return end
  addingSection = false
  addingSectionDraft = ""
  sendCommand({ action = "add_section", name = name })
  render()
end

local function detailValue(value)
  local text
  if type(value) == "table" then
    text = noctalia.json.encode(value)
  elseif value == nil then
    text = "—"
  else
    text = tostring(value)
  end
  text = text or "—"
  if #text > 500 then text = text:sub(1, 497) .. "…" end
  return text
end

local function detailRow(label, value)
  return ui.row({ align = "start", gap = 10, paddingV = 4 }, {
    ui.label({ text = label, width = 125, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    ui.label({ text = detailValue(value), flexGrow = 1, fontSize = 12, maxLines = 4 }),
  })
end

local function detailsView()
  if detailsLoading then
    return ui.column({ flexGrow = 1, gap = 10 }, {
      ui.label({ text = "Loading entity details…", color = "on_surface_variant", fontSize = 12 }),
    })
  end
  if detailsErrorMessage ~= "" then
    return ui.column({ flexGrow = 1, gap = 10 }, {
      ui.label({ text = detailsErrorMessage, color = "error", fontSize = 12 }),
    })
  end

  local entity = detailsEntity()
  local controls = detailsControls(entity)
  local content = {}
  if controls then
    content[#content + 1] = ui.column(CARD_STYLE, {
      ui.label({ text = "Controls", fontSize = 13, fontWeight = "semibold" }),
      controls,
    })
  end
  content[#content + 1] = ui.column(CARD_STYLE, {
    detailRow("Entity", details.entity_id),
    detailRow("State", details.state),
    detailRow("Last changed", details.last_changed),
    detailRow("Last updated", details.last_updated),
  })
  local attributes = details.attributes or {}
  local keys = {}
  for key in pairs(attributes) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  if #keys > 0 then
    local attributeRows = {}
    for index, key in ipairs(keys) do
      if index > 80 then break end
      attributeRows[#attributeRows + 1] = detailRow(key, attributes[key])
    end
    content[#content + 1] = ui.column(CARD_STYLE, {
      ui.label({ text = "Attributes", fontSize = 13, fontWeight = "semibold" }),
      ui.column({ gap = 0 }, attributeRows),
    })
    if #keys > 80 then
      content[#content + 1] = ui.label({ text = "Showing the first 80 attributes.", fontSize = 11, color = "on_surface_variant" })
    end
  end
  return ui.scroll({ flexGrow = 1, gap = 8 }, content)
end

local function saveRenameSection()
  if editingSectionIndex then
    sendCommand({ action = "rename_section", section_index = editingSectionIndex, name = editingSectionDraft })
  end
  editingSectionIndex = nil
  render()
end

local function renameRow(entity, domain)
  return ui.row({ align = "center", gap = 8 }, {
    entityIcon(entity, 20),
    ui.input({
      key = `ha-rename-{entity.entity_id}`,
      value = editingLabelDraft,
      flexGrow = 1,
      fontSize = 13,
      focus = true,
      submitOnEnter = true,
      onChange = function(value) editingLabelDraft = value or "" end,
      onSubmit = function(value)
        editingLabelDraft = value or editingLabelDraft
        saveRename()
      end,
    }),
    ui.button({ glyph = "check", variant = "ghost", controlSize = "sm", tooltip = "Save", onClick = saveRename }),
    ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Cancel", onClick = cancelRename }),
  })
end

local function entityRow(entity)
  local domain = shared.domainOf(entity.entity_id)
  if editingEntityId == entity.entity_id then
    return ui.column(CARD_STYLE, { renameRow(entity, domain) })
  end

  local on = shared.isOn(entity.state)
  local header = {
    entityIcon(entity, 20),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = entity.name or entity.entity_id, fontSize = 13, fontWeight = "semibold", maxLines = 1 }),
      ui.label({ text = shared.statusText(entity), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
  }
  if editMode then
    local targetSection = nextSectionIndex(entity.entity_id)
    table.insert(header, 1, ui.dragSource({
      key = "ha-entity-grip-" .. entity.entity_id,
      dragType = ENTITY_DRAG_TYPE,
      payload = entity.entity_id,
      previewAncestor = 1,
      liftFromLayout = true,
      width = 22,
      height = 24,
      align = "center",
      justify = "center",
      tooltip = "Drag to reorder or move section",
    }, {
      ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
    }))
    header[#header + 1] = ui.button({
      glyph = "arrow-up",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Move up",
      onClick = function() sendCommand({ action = "reorder", entity_id = entity.entity_id, direction = -1 }) end,
    })
    header[#header + 1] = ui.button({
      glyph = "arrow-down",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Move down",
      onClick = function() sendCommand({ action = "reorder", entity_id = entity.entity_id, direction = 1 }) end,
    })
    header[#header + 1] = ui.button({
      glyph = "arrow-right",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Move to " .. sectionName(targetSection),
      onClick = function() sendCommand({ action = "move", entity_id = entity.entity_id, target_section = targetSection }) end,
    })
    header[#header + 1] = ui.button({
      glyph = "pencil",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Rename",
      onClick = function() startRename(entity) end,
    })
    header[#header + 1] = ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Remove from bar",
      onClick = function() sendCommand({ action = "remove", entity_id = entity.entity_id }) end,
    })
  elseif entity.panel_controls ~= nil then
    local custom = customPanelControls(entity)
    if custom then header[#header + 1] = custom end
  elseif domain == "cover" then
    header[#header + 1] = coverButtons(entity)
  elseif domain == "media_player" then
    header[#header + 1] = mediaButtons(entity)
  elseif domain == "lock" then
    header[#header + 1] = lockButtons(entity, false)
  elseif shared.isToggleable(domain) then
    -- The action glyph describes what the button will do, while the entity
    -- icon above carries the current light state.
    local toggleGlyph = domain == "light" and (on and "bulb-off" or "bulb") or "power"
    if not editMode and domain == "light" and lightHasColor(entity) then
      header[#header + 1] = ui.button({
        glyph = "palette",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Set light color",
        onClick = function() openLightColor(entity) end,
      })
    end
    if domain == "fan" then
      local oscillationButton = fanOscillationButton(entity)
      if oscillationButton then header[#header + 1] = oscillationButton end
    end
    header[#header + 1] = ui.button({
      glyph = toggleGlyph,
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Toggle",
      onClick = function() sendCommand({ action = "toggle", entity_id = entity.entity_id }) end,
    })
  end

  local rows = { ui.row({ align = "center", gap = 8 }, header) }
  -- Hidden in edit mode along with the toggle/cover controls above -- edit
  -- mode is for layout/name changes, not a place to also nudge a light's
  -- brightness by accident.
  if not editMode then
    -- Only while on: an off light/fan carries no brightness/percentage
    -- attribute to seed the slider from (Home Assistant clears both when the
    -- entity turns off), and a slider with nothing to show is worse than none.
    if domain == "light" and on and entity.brightness ~= nil then
      rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
        ui.box({ width = 28, height = 1, fill = "on_surface/0" }),
        brightnessSlider(entity),
      })
    elseif domain == "fan" and on and entity.percentage ~= nil then
      rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
        ui.box({ width = 28, height = 1, fill = "on_surface/0" }),
        fanSlider(entity),
      })
    elseif domain == "media_player" and entity.volume_level ~= nil then
      rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
        ui.box({ width = 28, height = 1, fill = "on_surface/0" }),
        ui.glyph({ name = entity.volume_muted and "volume-off" or "volume-2", size = 14, color = "on_surface_variant" }),
        mediaVolumeSlider(entity),
      })
    end
  end
  local cardStyle = {}
  for key, value in pairs(CARD_STYLE) do cardStyle[key] = value end
  cardStyle.key = "ha-entity-card-" .. entity.entity_id .. ":" .. (editMode and "edit" or "view")
  if not editMode then cardStyle.onClick = function() openDetails(entity.entity_id) end end
  return ui.column(cardStyle, rows)
end

local function listView()
  local content = {}
  local searchActive = shared.trim(listSearchText) ~= ""
  local needle = shared.trim(listSearchText):lower()
  local showSearch = noctalia.getConfig("panel_show_search") == true
  local searchAtBottom = noctalia.getConfig("panel_search_position") ~= "top"
  local function entitySearch()
    return ui.input({
      key = "ha_entity_search",
      placeholder = "Search entities…",
      value = listSearchText,
      onChange = "onEntitySearchChange",
    })
  end
  if showSearch and not searchAtBottom then content[#content + 1] = entitySearch() end
  if #entities == 0 and #configuredEntities == 0 and #sections == 0 then
    content[#content + 1] = ui.label({
      text = "No entities configured yet. Tap + Add to browse Home Assistant and pick some.",
      color = "on_surface_variant",
      fontSize = 12,
    })
  else
    -- entities (live status) drives the rows; configuredEntities alone (id
    -- only, no fetched state yet) is the fallback right after adding one,
    -- before the next refresh has come back. The service marks conditionally
    -- hidden entities so they do not reappear through that fallback.
    local byId, shown = {}, {}
    for _, entity in ipairs(entities) do byId[entity.entity_id] = entity end

    local function rowFor(id)
      return byId[id] or { entity_id = id, state = nil, name = id }
    end

    local function matches(entity)
      if not searchActive then return true end
      local text = (entity.entity_id or "") .. " " .. (entity.name or "") .. " " .. shared.statusText(entity)
      return text:lower():find(needle, 1, true) ~= nil
    end

    local sectionEntities = {}
    for _, section in ipairs(sections) do
      for _, id in ipairs(section.entities or {}) do sectionEntities[id] = true end
    end

    local function sectionView(section, index)
      if sectionVisibility[index] == false and not editMode then
        for _, id in ipairs(section.entities or {}) do shown[id] = true end
        return
      end
      local sectionHasMatch = false
      if searchActive then
        for _, id in ipairs(section.entities or {}) do
          if not hidden[id] and matches(rowFor(id)) then
            sectionHasMatch = true
            break
          end
        end
        if not sectionHasMatch then return end
      end
      local sectionRows, sectionShown = {}, {}
      for _, id in ipairs(section.entities or {}) do
        if not hidden[id] and matches(rowFor(id)) and not shown[id] and not sectionShown[id] then
          if editMode then sectionRows[#sectionRows + 1] = entityDropZone(index, id) end
          sectionRows[#sectionRows + 1] = entityRow(rowFor(id))
          sectionShown[id] = true
          shown[id] = true
        end
      end
      if editMode then sectionRows[#sectionRows + 1] = entityDropZone(index) end
      if #sectionRows == 0 then return end

      local key = tostring(index) .. ":" .. tostring(section.name)
      local collapsed = collapsedSections[key]
      if collapsed == nil then collapsed = section.collapsed == true end
      if searchActive and sectionHasMatch then collapsed = false end
      local sectionHeader
      local headerKey = "ha-section-header-" .. tostring(index) .. ":" .. (editMode and "edit" or "view") .. ":" .. (editingSectionIndex == index and "rename" or "normal")
      if editingSectionIndex == index then
        sectionHeader = ui.row({ key = headerKey, align = "center", gap = 4 }, {
          ui.input({
            key = `ha-section-rename-{index}`,
            value = editingSectionDraft,
            flexGrow = 1,
            fontSize = 13,
            focus = true,
            submitOnEnter = true,
            onChange = function(value) editingSectionDraft = value or "" end,
            onSubmit = function(value)
              editingSectionDraft = value or editingSectionDraft
              saveRenameSection()
            end,
          }),
          ui.button({ glyph = "check", variant = "ghost", controlSize = "sm", tooltip = "Save section name", onClick = saveRenameSection }),
          ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Cancel", onClick = cancelRenameSection }),
        })
      else
        local sectionHeaderChildren = {
          ui.button({
            text = (collapsed and "▸ " or "▾ ") .. section.name,
            variant = "ghost",
            height = 24,
            flexGrow = 1,
            fontSize = 12,
            contentAlign = "start",
            onClick = function()
              collapsedSections[key] = not collapsed
              render()
            end,
          }),
        }
        if editMode then
          table.insert(sectionHeaderChildren, 1, ui.dragSource({
            key = "ha-section-grip-" .. tostring(index),
            dragType = SECTION_DRAG_TYPE,
            payload = tostring(index),
            previewAncestor = 1,
            liftFromLayout = true,
            width = 22,
            height = 24,
            align = "center",
            justify = "center",
            tooltip = "Drag to reorder section",
          }, {
            ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
          }))
          if index > 1 then
            sectionHeaderChildren[#sectionHeaderChildren + 1] = ui.button({
              glyph = "arrow-up",
              variant = "ghost",
              controlSize = "sm",
              tooltip = "Move section up",
              onClick = function() sendCommand({ action = "reorder_section", section_index = index, direction = -1 }) end,
            })
          end
          if index < #sections then
            sectionHeaderChildren[#sectionHeaderChildren + 1] = ui.button({
              glyph = "arrow-down",
              variant = "ghost",
              controlSize = "sm",
              tooltip = "Move section down",
              onClick = function() sendCommand({ action = "reorder_section", section_index = index, direction = 1 }) end,
            })
          end
          sectionHeaderChildren[#sectionHeaderChildren + 1] = ui.button({
            glyph = "pencil",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Rename section",
            onClick = function() startRenameSection(index) end,
          })
        end
        sectionHeader = ui.row({ key = headerKey, align = "center", gap = 2 }, sectionHeaderChildren)
      end
      local children = { sectionHeader }
      if not collapsed then
        children[#children + 1] = ui.column({ gap = 8 }, sectionRows)
      elseif editMode then
        -- Keep a visible target for moving an entity into a collapsed section.
        children[#children + 1] = entityDropZone(index)
      end
      content[#content + 1] = ui.column({ key = "ha-section-" .. tostring(index) .. ":" .. (editMode and "edit" or "view"), gap = 4 }, children)
    end

    local ungrouped = {}
    for _, id in ipairs(configuredEntities) do
      if not sectionEntities[id] and not hidden[id] and matches(rowFor(id)) then
        ungrouped[#ungrouped + 1] = id
        shown[id] = true
      end
    end
    for _, id in ipairs(ungrouped) do
      if editMode then content[#content + 1] = entityDropZone(0, id) end
      content[#content + 1] = entityRow(rowFor(id))
    end
    if editMode then content[#content + 1] = entityDropZone(0) end
    for index, section in ipairs(sections) do
      if editMode then content[#content + 1] = sectionDropZone(index) end
      sectionView(section, index)
    end
    if editMode then content[#content + 1] = sectionDropZone(#sections + 1) end
    if searchActive and #ungrouped == 0 and #content == (showSearch and not searchAtBottom and 1 or 0) then
      content[#content + 1] = ui.label({ text = "No matching entities.", color = "on_surface_variant", fontSize = 12 })
    end
  end
  local entityList = ui.scroll({ flexGrow = 1, gap = 8 }, content)
  if showSearch and searchAtBottom then
    return ui.column({ flexGrow = 1, gap = 8 }, { entityList, entitySearch() })
  end
  return entityList
end

-- ── Browse view ──────────────────────────────────────────────────────────────

local function filterOptionIndex(options, selected)
  for index, option in ipairs(options) do
    if option.id == selected then return index - 1 end
  end
  return 0
end

local function optionLabels(options)
  local labels = {}
  for _, option in ipairs(options) do labels[#labels + 1] = option.label end
  return labels
end

local function domainSelect()
  local options = { { id = "all", label = "All" } }
  for _, domain in ipairs(PANEL_DOMAIN_CHIPS) do
    options[#options + 1] = { id = domain, label = shared.domainLabel(domain) }
  end
  return ui.select({
    key = "ha_domain_filter",
    options = optionLabels(options),
    selectedIndex = filterOptionIndex(options, domainFilter),
    flexGrow = 1,
    controlSize = "sm",
    onChange = function(index)
      local option = options[(tonumber(index) or 0) + 1]
      if option then setDomainFilter(option.id) end
    end,
  })
end

-- Home Assistant's own area registry (see service.luau's listAreas()) rather
-- than a fixed list like the domain chips -- fetched once when the Area tab
-- is first opened, since unlike domains, areas are per-instance.
local function areaSelect()
  local options = { { id = "all", label = #areas == 0 and "Loading…" or "All" } }
  for _, area in ipairs(areas) do
    options[#options + 1] = { id = area.id, label = area.name }
  end
  return ui.select({
    key = "ha_area_filter",
    options = optionLabels(options),
    selectedIndex = filterOptionIndex(options, areaFilter),
    flexGrow = 1,
    controlSize = "sm",
    onChange = function(index)
      local option = options[(tonumber(index) or 0) + 1]
      if option then setAreaFilter(option.id) end
    end,
  })
end

local function browseRow(row)
  local configured = configuredSet()
  local already = configured[row.entity_id] == true
  return ui.row({ align = "center", gap = 8, paddingV = 4 }, {
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = row.name, fontSize = 13, maxLines = 1 }),
      ui.label({ text = row.entity_id, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
    already
      and ui.glyph({ name = "check", size = 16, color = "primary" })
      or ui.button({
        glyph = "plus",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Add to bar",
        onClick = function() sendCommand({ action = "add", entity_id = row.entity_id }) end,
      }),
  })
end

local function browseView()
  local content = {
    ui.input({ key = "ha_search", placeholder = "Search entities…", value = searchText, onChange = "onSearchChange" }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Domain", width = 52, fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" }),
      domainSelect(),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Area", width = 52, fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" }),
      areaSelect(),
    }),
  }
  if browseErrorMessage ~= "" then
    content[#content + 1] = ui.label({ text = browseErrorMessage, color = "error", fontSize = 11 })
  end

  local rows = filteredBrowseRows()
  local results = {}
  for _, row in ipairs(rows) do results[#results + 1] = browseRow(row) end
  if #results == 0 and not browseLoading then
    results[#results + 1] = ui.label({ text = "No matches yet.", color = "on_surface_variant", fontSize = 12 })
  end
  if browseLoading then
    results[#results + 1] = ui.label({ text = "Loading…", color = "on_surface_variant", fontSize = 12 })
  elseif browseMore then
    -- Only ever fetches shared.config("browser_page_size") more entities per
    -- click -- this button, not a bigger single request, is what keeps
    -- browsing an instance with thousands of entities workable.
    results[#results + 1] = ui.button({
      text = "Load more",
      variant = "ghost",
      controlSize = "sm",
      onClick = function() fetchBrowsePage(false) end,
    })
  end
  content[#content + 1] = ui.scroll({ flexGrow = 1, gap = 2 }, results)

  return ui.column({ flexGrow = 1, gap = 10 }, content)
end

-- ── Header + root ────────────────────────────────────────────────────────────

-- Small filled dot + word, the same "is it working" read a colored status
-- LED gives at a glance. A plain ui.box circle rather than a guessed glyph
-- name: dot/circle glyphs aren't used (and so not verified) anywhere else in
-- this repo, and a box with a radius needs no such guess.
local function connectionStatus()
  if errorMessage ~= "" then return { color = "error", text = "Error" } end
  if lastRefreshedAt ~= nil then return { color = "primary", text = "Connected" } end
  return { color = "on_surface_variant", text = "Connecting…" }
end

local function header()
  if view == "list" then
    -- The real Home Assistant mark (assets/home-assistant-icon.png, from
    -- the project's own home-assistant/brands repo) rather than a generic
    -- glyph -- it already carries its own color/shape, so it renders bare
    -- rather than in ha-ai-usage's boxed-glyph style.
    local status = connectionStatus()
    local left = ui.row({ align = "center", gap = 8 }, {
      ui.image({ path = "assets/home-assistant-icon.png", width = 32, height = 32, fit = "contain" }),
      ui.column({ gap = 1 }, {
        ui.label({ text = "Home Assistant", fontSize = 15, fontWeight = "bold" }),
        ui.row({ align = "center", gap = 5 }, {
          ui.box({ width = 8, height = 8, radius = 4, fill = status.color }),
          ui.label({ text = status.text, fontSize = 11, color = "on_surface_variant" }),
          ui.button({
            glyph = "external-link",
            variant = "ghost",
            width = 18,
            height = 18,
            glyphSize = 11,
            tooltip = "Open Home Assistant",
            onClick = "onOpenDashboard",
          }),
        }),
      }),
    })
    -- No close button: dismiss_on_outside_click (plugin.toml) already closes
    -- the panel, and this repo's other panels don't duplicate that with an X.
    local right = {}
    if editMode or not editButtonHidden() then
      right[#right + 1] = ui.button({
        glyph = editMode and "check" or "pencil",
        variant = editMode and "primary" or "ghost",
        tooltip = editMode and "Done editing" or "Rename or remove entities",
        onClick = "onToggleEditMode",
      })
    end
    right[#right + 1] = ui.button({ glyph = "settings", variant = "ghost", tooltip = "Plugin settings", onClick = "onSettings" })
    return ui.row({ align = "center", justify = "space_between" }, {
      left,
      ui.row({ align = "center", gap = 2 }, right),
    })
  elseif view == "browse" then
    return ui.row({ align = "center", gap = 8 }, {
      ui.button({ glyph = "arrow-left", variant = "ghost", controlSize = "sm", onClick = "onBackToList" }),
      ui.label({ text = "Add entity", fontSize = 15, fontWeight = "bold" }),
    })
  end
  local attributes = details.attributes or {}
  local title = attributes.friendly_name or details.entity_id or detailsEntityId or "Entity details"
  local children = {
    ui.button({ glyph = "arrow-left", variant = "ghost", controlSize = "sm", onClick = "onBackToList" }),
  }
  if not detailsLoading and detailsErrorMessage == "" then children[#children + 1] = entityIcon(detailsEntity(), 20) end
  children[#children + 1] = ui.label({ text = title, fontSize = 15, fontWeight = "bold", flexGrow = 1, maxWidth = 280, maxLines = 1 })
  return ui.row({ align = "center", gap = 8 }, children)
end

-- Add controls stay in the footer while editing; the Edit/Done action lives in
-- the panel header alongside settings.
local function footer()
  local children = {}
  if addingSection then
    children[#children + 1] = ui.row({ align = "center", gap = 6 }, {
      ui.input({
        key = "ha-new-section",
        placeholder = "Section name",
        value = addingSectionDraft,
        flexGrow = 1,
        fontSize = 13,
        focus = true,
        submitOnEnter = true,
        onChange = function(value) addingSectionDraft = value or "" end,
        onSubmit = function(value)
          addingSectionDraft = value or addingSectionDraft
          saveAddSection()
        end,
      }),
      ui.button({ glyph = "check", variant = "ghost", controlSize = "sm", tooltip = "Create section", onClick = saveAddSection }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Cancel", onClick = cancelAddSection }),
    })
  end
  local buttons = {}
  if editMode then
    buttons[#buttons + 1] = ui.button({ text = "Section", glyph = "layout-list", variant = "ghost", controlSize = "sm", tooltip = "Add section", onClick = startAddSection })
    buttons[#buttons + 1] = ui.button({ text = "Add", glyph = "plus", variant = "ghost", controlSize = "sm", tooltip = "Add entity", onClick = "onOpenBrowser" })
  end
  children[#children + 1] = ui.row({ align = "center", justify = "space_between" }, buttons)
  return ui.column({ gap = 6 }, children)
end

render = function()
  if not panelOpen then return end
  local children = { header() }
  if errorMessage ~= "" and view == "list" then
    children[#children + 1] = ui.row({ fill = "error/0.08", radius = 8, paddingH = 9, paddingV = 6, align = "center", gap = 6 }, {
      ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
      ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 1 }),
    })
  end
  children[#children + 1] = view == "list" and listView() or (view == "browse" and browseView() or detailsView())
  if view == "list" and editMode then children[#children + 1] = footer() end
  panel.setNeedsFrameTick(panelAnimationActive())
  panel.render(ui.column({ flexGrow = 1, padding = 12, gap = 8 }, children))
end

-- ── State watches ────────────────────────────────────────────────────────────

noctalia.state.watch("ha.configured", function(value)
  configuredEntities = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.sections", function(value)
  sections = type(value) == "table" and value or {}
  collapsedSections = {}
  render()
end)

noctalia.state.watch("ha.entity_remotes", function(value)
  entityRemotes = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.panel_controls", function(value)
  panelControls = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.domain_controls", function(value)
  domainControls = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.favorite_positions", function(value)
  favoritePositions = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.entities", function(value)
  entities = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.hidden", function(value)
  hidden = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.section_visibility", function(value)
  sectionVisibility = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("ha.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)

noctalia.state.watch("ha.refreshed_at", function(value)
  lastRefreshedAt = value
  render()
end)

noctalia.state.watch("ha.details", function(value)
  details = type(value) == "table" and value or {}
  detailsLoading = false
  render()
end)

noctalia.state.watch("ha.details_error", function(value)
  detailsErrorMessage = type(value) == "string" and value or ""
  if detailsErrorMessage ~= "" then detailsLoading = false end
  render()
end)

noctalia.state.watch("ha.browse_error", function(value)
  browseErrorMessage = type(value) == "string" and value or ""
  -- A failed browse request never produces a ha.browse_result, so this
  -- is the only place that can clear the loading flag it set.
  if browseErrorMessage ~= "" then browseLoading = false end
  render()
end)

noctalia.state.watch("ha.browse_result", function(result)
  if type(result) ~= "table" then return end
  -- Drop responses for a domain/area we've since navigated away from -- e.g.
  -- two quick chip clicks in a row -- rather than splicing a stale page into
  -- the list the user is now looking at.
  if result.domain ~= domainFilter or result.area ~= areaFilter then return end
  browseLoading = false
  for _, row in ipairs(result.rows or {}) do
    browseRows[#browseRows + 1] = row
  end
  browseOffset = (result.offset or 0) + (result.limit or 0)
  browseMore = result.more == true
  render()
end)

noctalia.state.watch("ha.areas", function(value)
  areas = type(value) == "table" and value or {}
  render()
end)

-- ── Entry points ─────────────────────────────────────────────────────────────

function onConfigChanged()
  if editButtonHidden() then
    editMode = false
    addingSection = false
    addingSectionDraft = ""
  end
  render()
end

function onOpen()
  panelOpen = true
  view = "list"
  listSearchText = ""
  collapsedSections = {}
  editMode = false
  editingEntityId = nil
  editingSectionIndex = nil
  addingSection = false
  addingSectionDraft = ""
  detailsEntityId = nil
  animationFrame = 0
  animationElapsedMs = 0
  sendCommand({ action = "refresh" })
  render()
end

function onClose()
  panelOpen = false
  panel.setNeedsFrameTick(false)
  sendCommand({ action = "details_close" })
end

function onFrameTick(deltaMs)
  if not panelAnimationActive() then
    panel.setNeedsFrameTick(false)
    return
  end
  animationElapsedMs += tonumber(deltaMs) or ANIMATION_FRAME_INTERVAL_MS
  if animationElapsedMs < ANIMATION_FRAME_INTERVAL_MS then return end
  animationElapsedMs = animationElapsedMs % ANIMATION_FRAME_INTERVAL_MS
  animationFrame = (animationFrame + 1) % ANIMATION_FRAME_COUNT
  render()
end

function onOpenDashboard()
  sendCommand({ action = "open_dashboard" })
end

function onSettings()
  noctalia.openSettings()
end

function onToggleEditMode()
  toggleEditMode()
end

function onOpenBrowser()
  view = "browse"
  searchText = ""
  domainFilter = "all"
  areaFilter = "all"
  browseErrorMessage = ""
  if #areas == 0 then sendCommand({ action = "list_areas" }) end
  fetchBrowsePage(true)
end

function onBackToList()
  if view == "details" then sendCommand({ action = "details_close" }) end
  view = "list"
  detailsLoading = false
  detailsEntityId = nil
  browseRows = {}
  render()
end

function onSearchChange(value)
  searchText = value or ""
  render()
end

function onEntitySearchChange(value)
  listSearchText = value or ""
  render()
end
