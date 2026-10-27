--!nonstrict
-- Poll the voice branch rather than Noctalia's default source. The default
-- meeting_source also carries soundboard audio and intentionally stays open.

local POLL_INTERVAL_MS = 500
local polling = false

local function publish(known, muted)
  noctalia.state.set("mic_state", {
    known = known,
    muted = muted == true,
  })
end

local function poll()
  if polling then
    return
  end
  polling = true

  noctalia.runAsync({ "pactl", "get-source-mute", "rnnoise_source" }, function(result)
    polling = false
    if result.exitCode ~= 0 then
      publish(false, false)
      return
    end

    local muted = (result.stdout or ""):match("Mute:%s*yes") ~= nil
    publish(true, muted)
  end, 1000)
end

publish(false, false)
poll()

function update()
  noctalia.setUpdateInterval(POLL_INTERVAL_MS)
  poll()
end
