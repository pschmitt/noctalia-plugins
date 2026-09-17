--!nonstrict
-- Feierabend countdown poller — the headless [[service]] entry.
--
-- `zhj feierabend countdown` writes the remaining seconds as plain text to
-- state_file once a second while armed (via the shell's `notification::
-- countdown --file`), and removes it on stop/abort (`zhj feierabend
-- countdown-stop`) or once it reaches zero and hands off to
-- `sudo shutdown -h now`. A short-lived event_file carries `cancelled` or
-- `achieved` after the numeric state disappears. noctalia.readFile/fileExists
-- are synchronous, so no subprocess is needed to tail either file.

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

local function eventPath()
  local configured = noctalia.string.trim(noctalia.getConfig("event_file") or "")
  if configured == "" then
    configured = "~/.local/state/feierabend-event"
  end
  return noctalia.expandPath(configured)
end

local function poll()
  local path = statePath()
  local raw = noctalia.fileExists(path) and noctalia.readFile(path) or nil
  local seconds = raw and tonumber(noctalia.string.trim(raw)) or nil
  local eventFile = eventPath()
  local eventRaw = noctalia.fileExists(eventFile) and noctalia.readFile(eventFile) or nil
  local event = eventRaw and noctalia.string.trim(eventRaw) or ""
  if event ~= "cancelled" and event ~= "achieved" then
    event = ""
  end
  noctalia.state.set("feierabend_countdown", {
    active = seconds ~= nil,
    seconds = seconds or 0,
    event = event,
  })
end

poll()

function update()
  noctalia.setUpdateInterval(pollMs())
  poll()
end
