--!nonstrict
-- One place for the duration-format settings and their defaults.
--
-- getConfig returns nil for a setting the user has never touched, so every
-- reader needs the manifest default anyway; keeping them here means the bar,
-- the panel and the tooltip can't drift on what "unset" means.

local M = {}

local DEFAULTS = {
  bar_time_format = "{hours}:{minutes}",
  panel_time_format = "{hours}h {minutes}m",
  week_time_format = "{hours}h {minutes}m",
  month_time_format = "{hours}h",
  year_time_format = "{hours}h",
}

function M.get(key)
  local fmt = noctalia.getConfig(key)
  if fmt == nil or fmt == "" then
    return DEFAULTS[key]
  end
  return fmt
end

return M
