--!nonstrict

local shared = require("./shared.luau")

local panelOpen = false
local view = "list" -- "list" | "browse"

local configuredEntities = noctalia.state.get("hassio.configured") or {}
local entities = noctalia.state.get("hassio.entities") or {}
local errorMessage = noctalia.state.get("hassio.error") or ""

local domainFilter = "all"
local searchText = ""
local browseRows = {}
local browseOffset = 0
local browseMore = false
local browseLoading = false
local browseErrorMessage = noctalia.state.get("hassio.browse_error") or ""

-- Forward-declared: referenced by action handlers defined before its real
-- body below (they only ever run after the whole script has loaded once, so
-- this only needs to resolve as an upvalue, not have a body yet).
local render

local function sendCommand(command)
  noctalia.state.set("hassio.command", command)
end

local function configuredSet()
  local set = {}
  for _, id in ipairs(configuredEntities) do set[id] = true end
  return set
end

local function chunk(list, n)
  local rows, row = {}, {}
  for _, v in ipairs(list) do
    table.insert(row, v)
    if #row == n then
      table.insert(rows, row)
      row = {}
    end
  end
  if #row > 0 then table.insert(rows, row) end
  return rows
end

-- The curated subset of shared.BROWSABLE_DOMAINS worth a dedicated chip in a
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
  sendCommand({ action = "browse", domain = domainFilter, offset = browseOffset })
end

local function setDomainFilter(domain)
  if domainFilter == domain then return end
  domainFilter = domain
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
-- is in progress. entities gets replaced wholesale on every hassio.entities
-- update, so this has to live outside that table (same pattern fan-control's
-- panel uses for its own speed slider).
local sliderPreviews = {}

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

local function brightnessSlider(entity)
  local pct = entity.brightness and math.floor((entity.brightness / 255) * 100 + 0.5) or 0
  return previewSlider(entity, pct, function(target)
    sendCommand({ action = "set_brightness", entity_id = entity.entity_id, value = (target / 100) * 255 })
  end)
end

local function fanSlider(entity)
  return previewSlider(entity, entity.percentage or 0, function(target)
    sendCommand({ action = "set_percentage", entity_id = entity.entity_id, value = target })
  end)
end

local function entityRow(entity)
  local domain = shared.domainOf(entity.entity_id)
  local unavailable = shared.isUnavailable(entity.state)
  local on = shared.isOn(entity.state)
  local header = {
    ui.glyph({ name = shared.glyphFor(domain), size = 20, color = shared.colorFor(entity.state) }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = entity.name or entity.entity_id, fontSize = 13, fontWeight = "semibold", maxLines = 1 }),
      ui.label({ text = unavailable and "unavailable" or (entity.state or "—"), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
  }
  if domain == "cover" then
    header[#header + 1] = coverButtons(entity)
  elseif shared.isToggleable(domain) then
    header[#header + 1] = ui.button({
      glyph = "power",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Toggle",
      onClick = function() sendCommand({ action = "toggle", entity_id = entity.entity_id }) end,
    })
  end
  header[#header + 1] = ui.button({
    glyph = "trash",
    variant = "ghost",
    controlSize = "sm",
    tooltip = "Remove from bar",
    onClick = function() sendCommand({ action = "remove", entity_id = entity.entity_id }) end,
  })

  local rows = { ui.row({ align = "center", gap = 8 }, header) }
  -- Only while on: an off light/fan carries no brightness/percentage
  -- attribute to seed the slider from (Home Assistant clears both when the
  -- entity turns off), and a slider with nothing to show is worse than none.
  if domain == "light" and on and entity.brightness ~= nil then
    rows[#rows + 1] = ui.row({ align = "center", paddingL = 28 }, { brightnessSlider(entity) })
  elseif domain == "fan" and on and entity.percentage ~= nil then
    rows[#rows + 1] = ui.row({ align = "center", paddingL = 28 }, { fanSlider(entity) })
  end
  return ui.column({ gap = 2, paddingV = 4 }, rows)
end

local function listView()
  local content = {}
  if #entities == 0 and #configuredEntities == 0 then
    content[#content + 1] = ui.label({
      text = "No entities configured yet. Tap + Add to browse Home Assistant and pick some.",
      color = "on_surface_variant",
      fontSize = 12,
    })
  else
    -- entities (live status) drives the rows when it has data; configuredEntities
    -- alone (id only, no fetched state yet) is the fallback right after adding
    -- one, before the next refresh has come back.
    local shown = {}
    if #entities > 0 then
      for _, entity in ipairs(entities) do
        content[#content + 1] = entityRow(entity)
        shown[entity.entity_id] = true
      end
    end
    for _, id in ipairs(configuredEntities) do
      if not shown[id] then
        content[#content + 1] = entityRow({ entity_id = id, state = nil, name = id })
      end
    end
  end
  return ui.scroll({ flexGrow = 1, gap = 2 }, content)
end

-- ── Browse view ──────────────────────────────────────────────────────────────

local function domainChip(domain, label)
  local active = domainFilter == domain
  return ui.button({
    text = label,
    variant = active and "primary" or "ghost",
    controlSize = "sm",
    onClick = function() setDomainFilter(domain) end,
  })
end

local function domainChipsGrid()
  local chips = { { id = "all", label = "All" } }
  for _, domain in ipairs(PANEL_DOMAIN_CHIPS) do
    chips[#chips + 1] = { id = domain, label = shared.domainLabel(domain) }
  end
  local rows = {}
  for _, group in ipairs(chunk(chips, 3)) do
    local buttons = {}
    for _, c in ipairs(group) do buttons[#buttons + 1] = domainChip(c.id, c.label) end
    rows[#rows + 1] = ui.row({ gap = 6 }, buttons)
  end
  return ui.column({ gap = 6 }, rows)
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
    ui.input({ key = "hassio_search", placeholder = "Search entities…", value = searchText, onChange = "onSearchChange" }),
    domainChipsGrid(),
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

local function header()
  local left
  if view == "list" then
    -- Same boxed-glyph header pschmitt/ha-ai-usage uses, keyed off this
    -- plugin's own declared icon (plugin.toml's top-level `icon`) rather than
    -- a second hardcoded glyph name.
    left = {
      ui.row({ align = "center", justify = "center", width = 36, height = 36, fill = "primary/0.15", radius = 11 }, {
        ui.glyph({ name = "smart-home", size = 19, color = "primary" }),
      }),
      ui.label({ text = "Home Assistant", fontSize = 15, fontWeight = "bold" }),
    }
  else
    left = {
      ui.button({ glyph = "arrow-left", variant = "ghost", controlSize = "sm", onClick = "onBackToList" }),
      ui.label({ text = "Add entity", fontSize = 15, fontWeight = "bold" }),
    }
  end
  local right = { ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = "onCloseClicked" }) }
  if view == "list" then
    table.insert(right, 1, ui.button({ glyph = "settings", variant = "ghost", tooltip = "Plugin settings", onClick = "onSettings" }))
    table.insert(right, 1, ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Refresh", onClick = "onRefresh" }))
    table.insert(right, 1, ui.button({ text = "Add", glyph = "plus", variant = "ghost", controlSize = "sm", tooltip = "Add entity", onClick = "onOpenBrowser" }))
  end
  return ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 8 }, left),
    ui.row({ align = "center", gap = 2 }, right),
  })
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
  children[#children + 1] = view == "list" and listView() or browseView()
  panel.render(ui.column({ flexGrow = 1, padding = 12, gap = 8 }, children))
end

-- ── State watches ────────────────────────────────────────────────────────────

noctalia.state.watch("hassio.configured", function(value)
  configuredEntities = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("hassio.entities", function(value)
  entities = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("hassio.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)

noctalia.state.watch("hassio.browse_error", function(value)
  browseErrorMessage = type(value) == "string" and value or ""
  -- A failed browse request never produces a hassio.browse_result, so this
  -- is the only place that can clear the loading flag it set.
  if browseErrorMessage ~= "" then browseLoading = false end
  render()
end)

noctalia.state.watch("hassio.browse_result", function(result)
  if type(result) ~= "table" then return end
  -- Drop responses for a domain we've since navigated away from -- e.g. two
  -- quick chip clicks in a row -- rather than splicing a stale page into the
  -- list the user is now looking at.
  if result.domain ~= domainFilter then return end
  browseLoading = false
  for _, row in ipairs(result.rows or {}) do
    browseRows[#browseRows + 1] = row
  end
  browseOffset = (result.offset or 0) + (result.limit or 0)
  browseMore = result.more == true
  render()
end)

-- ── Entry points ─────────────────────────────────────────────────────────────

function onConfigChanged()
  render()
end

function onOpen()
  panelOpen = true
  view = "list"
  sendCommand({ action = "refresh" })
  render()
end

function onClose()
  panelOpen = false
end

function onRefresh()
  sendCommand({ action = "refresh" })
end

function onSettings()
  noctalia.openSettings()
end

function onOpenBrowser()
  view = "browse"
  searchText = ""
  domainFilter = "all"
  browseErrorMessage = ""
  fetchBrowsePage(true)
end

function onBackToList()
  view = "list"
  browseRows = {}
  render()
end

function onSearchChange(value)
  searchText = value or ""
  render()
end

function onCloseClicked()
  panel.close()
end
