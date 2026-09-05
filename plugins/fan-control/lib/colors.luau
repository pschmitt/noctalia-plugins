--!nonstrict
-- Shared color-rule resolution for widget.luau and panel.luau (no Lua state
-- is shared between plugin entries, so this is `require`d by both rather
-- than duplicated).

local M = {}

local function configuredColor(key, fallback)
  local custom = noctalia.getConfig(key)
  if type(custom) == "string" and custom ~= "" then
    return custom
  end
  return fallback
end

local function tierColor(value, lo, hi, lowColor, midColor, highColor)
  if value >= hi then
    return highColor
  elseif value >= lo then
    return midColor
  end
  return lowColor
end

function M.fullColor()
  return configuredColor("full_color", "error")
end

-- The color color_trigger currently resolves to, independent of whether the
-- icon/text actually get tinted with it — that's colorize_icon/
-- colorize_text, applied by the caller (M.icon/M.text below). Full blast is
-- deliberately excluded: it must not disguise the temperature state.
function M.ruleColor(snap)
  local trigger = noctalia.getConfig("color_trigger")
  if trigger == "temp" then
    local lo = tonumber(noctalia.getConfig("temp_threshold_low")) or 60
    local hi = tonumber(noctalia.getConfig("temp_threshold_high")) or 80
    return tierColor(
      snap.temp or 0, lo, hi,
      configuredColor("temp_low_color", "on_surface"),
      configuredColor("temp_mid_color", "primary"),
      configuredColor("temp_high_color", "error")
    )
  elseif trigger == "rpm" then
    local lo = tonumber(noctalia.getConfig("rpm_threshold_low")) or 2000
    local hi = tonumber(noctalia.getConfig("rpm_threshold_high")) or 4000
    return tierColor(
      snap.rpm or 0, lo, hi,
      configuredColor("rpm_low_color", "on_surface"),
      configuredColor("rpm_mid_color", "primary"),
      configuredColor("rpm_high_color", "error")
    )
  end
  -- trigger == "mode" (default)
  if snap.mode == "manual" then
    return configuredColor("manual_color", "primary")
  end
  return configuredColor("auto_color", "on_surface")
end

function M.icon(snap)
  if noctalia.getConfig("colorize_icon") == false then
    return "on_surface"
  end
  return M.ruleColor(snap)
end

function M.text(snap)
  if noctalia.getConfig("colorize_text") == false then
    return "on_surface"
  end
  return M.ruleColor(snap)
end

return M
