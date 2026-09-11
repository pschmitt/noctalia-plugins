--!nonstrict
-- Feierabend countdown poller — the headless [[service]] entry.
--
-- `zhj feierabend countdown` writes the remaining seconds as plain text to
-- state_file once a second while armed (via the shell's `notification::
-- countdown --file`), and removes it on stop/abort (`zhj feierabend
-- countdown-stop`) or once it reaches zero and hands off to
-- `sudo shutdown -h now`. noctalia.readFile/fileExists are synchronous, so
-- no subprocess is needed to tail it.

local function pollMs()
  return math.clamp(math.floor(tonumber(noctalia.getConfig("poll_interval")) or 1), 1, 10) * 1000
end

local function statePath()
  local configured = noctalia.string.trim(noctalia.getConfig("state_file") or "")
  if configured == "" then
    configured = "~/.local/state/feierabend-countdown"
  end
  return noctalia.expandPath(configured)
end

local function poll()
  local path = statePath()
  local raw = noctalia.fileExists(path) and noctalia.readFile(path) or nil
  local seconds = raw and tonumber(noctalia.string.trim(raw)) or nil
  noctalia.state.set("feierabend_countdown", { active = seconds ~= nil, seconds = seconds or 0 })
end

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
