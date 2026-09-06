--!nonstrict

local shared = require("./shared.luau")
local items = noctalia.state.get("ha_ai_usage.items") or {}
local errorMessage = noctalia.state.get("ha_ai_usage.error") or ""
local panelOpen = false

local function providerIcon(card, size, color)
  if card.image then return ui.image({ path = card.image, width = size, height = size, fit = "contain" }) end
  return ui.glyph({ name = card.glyph, size = size, color = color })
end

local function metricRow(metric)
  local used = metric.used
  local color = shared.colorFor(used)
  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = metric.label, fontSize = 12, color = "on_surface_variant" }),
      ui.label({ text = shared.displayPercent(used, false), fontSize = 15, fontWeight = "bold", color = color }),
    }),
  }
  if used ~= nil then
    children[#children + 1] = ui.progress({ progress = used / 100, fill = color, track = "on_surface/0.16", height = 7, radius = 7 })
  end
  if metric.reset ~= "" then
    children[#children + 1] = ui.label({ text = "Reset: " .. shared.resetText(metric.reset), fontSize = 10, color = "on_surface_variant", maxLines = 1 })
  end
  return ui.column({ gap = 4 }, children)
end

local function card(card)
  return ui.column({ fill = "surface_variant/0.58", radius = 14, padding = 12, gap = 9 }, {
    ui.row({ align = "center", gap = 8 }, {
      providerIcon(card, 18, shared.colorFor(card.primary.used)),
      ui.label({ text = card.label, fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
    }),
    (function()
      local rows = {}
      for _, metric in ipairs(card.metrics) do rows[#rows + 1] = metricRow(metric) end
      return ui.column({ gap = 9 }, rows)
    end)(),
  })
end

local function render()
  if not panelOpen then return end
  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.row({ align = "center", justify = "center", width = 36, height = 36, fill = "primary/0.15", radius = 11 }, {
        ui.glyph({ name = "chart-donut-3", size = 19, color = "primary" }),
      }),
      ui.column({ gap = 1 }, {
        ui.label({ text = "AI usage", fontSize = 17, fontWeight = "bold" }),
        ui.label({ text = "Home Assistant", fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.row({ align = "center", gap = 2 }, {
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Refresh now", onClick = "onRefresh" }),
      ui.button({ glyph = "settings", variant = "ghost", tooltip = "Plugin settings", onClick = "onSettings" }),
      ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = "onCloseClicked" }),
    }),
  })
  local content = {}
  for _, item in ipairs(shared.cards(items)) do content[#content + 1] = card(item) end
  if #content == 0 then content[#content + 1] = ui.label({ text = "No active AI usage metrics were discovered.", color = "on_surface_variant" }) end
  local children = { header }
  if errorMessage ~= "" then
    children[#children + 1] = ui.row({ fill = "error/0.08", radius = 8, paddingH = 9, paddingV = 6, align = "center", gap = 6 }, {
      ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
      ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 1 }),
    })
  end
  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 10 }, content)
  panel.render(ui.column({ flexGrow = 1, padding = 14, gap = 10 }, children))
end

noctalia.state.watch("ha_ai_usage.items", function(value)
  items = type(value) == "table" and value or {}
  render()
end)
noctalia.state.watch("ha_ai_usage.error", function(value)
  errorMessage = type(value) == "string" and value or ""
  render()
end)
function onOpen()
  panelOpen = true
  noctalia.state.set("ha_ai_usage.command", { action = "refresh" })
  render()
end
function onClose() panelOpen = false end
function onRefresh() noctalia.state.set("ha_ai_usage.command", { action = "refresh" }) end
function onSettings() noctalia.openSettings() end
function onCloseClicked() panel.close() end
