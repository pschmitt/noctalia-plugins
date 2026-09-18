--!nonstrict
-- Syncthing detail panel — the [[panel]] entry.
--
-- Header with live state + refresh and a pause toggle that targets whatever
-- is on screen (bulk pause-all/resume-all on the list views, the single
-- selected folder/device in a detail view), stat tiles (devices / folders /
-- pending), list views, and folder/device detail pages with their relevant
-- actions and metadata (rescan/open-folder, device QR/shared folders).
--
-- Per-row buttons pass a closure that captures the row's folder or device, so
-- neither list has a length limit and there are no numbered callback globals.

local statusIcon = require("./lib/status_icon.luau")
local stateColors = require("./lib/state_colors.luau")
local rowIcons = require("./lib/row_icons.luau")

-- Must match height = … in the [[panel]] entry of plugin.toml. The root
-- column's height is what actually sizes the content, and it is measured
-- inside the padding, so the padding has to come off it or the last row is
-- clipped by the panel edge.
local PANEL_HEIGHT = 500
local PANEL_PADDING = 14

local snapshot = nil
local isOpen = false
local cmdNonce = 0
-- Active list tab: "folders" | "devices" (Syncthing Tray-style tabs).
local view = "folders"
local selectedFolderId = nil
local selectedDeviceId = nil
local folderDetail = nil
local folderDetailLoading = false
local deviceQr = nil
local deviceQrLoading = false
local render

-- Hover handlers exist only to keep the indicator buttons' input areas live
-- (see folderRow); there is nothing to do when the pointer arrives.
function noop() end

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function sendCmd(action, folderId, deviceId)
  cmdNonce += 1
  local command = { n = cmdNonce, action = action }
  if folderId then
    command.folder = folderId
  end
  if deviceId then
    command.device = deviceId
  end
  noctalia.state.set("st.cmd", noctalia.json.encode(command))
end

local function selectedFolder()
  if not snapshot or not selectedFolderId then
    return nil
  end
  for _, folder in snapshot.folders do
    if folder.id == selectedFolderId then
      return folder
    end
  end
  return nil
end

local function selectedDevice()
  if not snapshot or not selectedDeviceId then
    return nil
  end
  for _, device in snapshot.devicesList do
    if device.id == selectedDeviceId then
      return device
    end
  end
  return nil
end

local function splitTimestamp(value)
  return (value or ""):match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
end

local function shortTimestamp(value)
  local date, time = splitTimestamp(value)
  return date and `{date} {time}` or value or ""
end

local function formatBytes(bytes)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local value = tonumber(bytes) or 0
  local index = 1
  while value >= 1024 and index < #units do
    value /= 1024
    index += 1
  end
  local rounded = (value >= 10 or index == 1) and tostring(math.round(value)) or string.format("%.1f", value)
  return `{rounded} {units[index]}`
end

local function statusSummary()
  if not snapshot then
    return tr("state.unconfigured")
  end
  local state = snapshot.state
  if state == "idle" then
    if snapshot.devices.configured > 0 then
      return tr("summary.idle-devices", {
        connected = snapshot.devices.connected,
        configured = snapshot.devices.configured,
      })
    end
    return tr("summary.idle-no-devices")
  end
  if state == "syncing" then
    if snapshot.totals.needItems > 0 then
      return tr("summary.syncing-items", { count = snapshot.totals.needItems })
    end
    return tr("summary.syncing-folders", { count = math.max(snapshot.totals.syncingFolders, 1) })
  end
  return tr(`summary.{state}`)
end

local function allFoldersPaused()
  return snapshot ~= nil
    and snapshot.totals.monitoredFolders > 0
    and snapshot.totals.pausedFolders >= snapshot.totals.monitoredFolders
end

local function allDevicesPaused()
  return snapshot ~= nil
    and snapshot.devices.configured > 0
    and snapshot.devices.paused >= snapshot.devices.configured
end

local function bulkPauseKind()
  return (view == "folders" or view == "folder") and "folders" or "devices"
end

local function bulkPaused()
  return bulkPauseKind() == "folders" and allFoldersPaused() or allDevicesPaused()
end

local function bulkPauseLabel(paused)
  local kind = bulkPauseKind()
  return tr(paused and `panel.resume-all-{kind}` or `panel.pause-all-{kind}`)
end

-- Forward declaration: the detail-aware header uses the same folder state
-- wording as the rows below.
local folderStateText
local deviceStateText

-- ── Per-row actions ──────────────────────────────────────────────────────────

local function togglePaused(kind, id, paused)
  local verb = paused and "resume" or "pause"
  sendCmd(`{kind}_{verb}`, id)
end

local function openFolderDetails(folder)
  selectedFolderId = folder.id
  selectedDeviceId = nil
  view = "folder"
  folderDetail = nil
  folderDetailLoading = true
  render()
  sendCmd("folder_details", folder.id)
end

local function openDeviceDetails(device)
  selectedDeviceId = device.id
  selectedFolderId = nil
  view = "device"
  deviceQr = nil
  deviceQrLoading = true
  render()
  sendCmd("device_qr", nil, device.id)
end

local function copyDeviceId(device)
  if noctalia.copyToClipboard(device.id, "text/plain") then
    noctalia.notify(tr("toast.title"), tr("panel.device-id-copied"))
  else
    noctalia.notifyError(tr("toast.title"), tr("panel.device-id-copy-failed"))
  end
end

-- ── Sections ─────────────────────────────────────────────────────────────────

local function header()
  local folder = selectedFolder()
  local device = selectedDevice()
  local selected = folder or device
  local state = snapshot and snapshot.state or "unconfigured"
  -- The header's pause toggle targets whatever is on screen: the single
  -- selected folder/device in a detail view (mirroring its own row's
  -- pause/resume action), or a bulk pause-all/resume-all while browsing the
  -- list, same as before.
  local pauseGlyph, pauseTooltip, pauseOnClick
  local pauseVisible = true
  if folder then
    pauseGlyph = folder.paused and "player-play" or "player-pause"
    pauseTooltip = folder.paused and tr("panel.folder-resume") or tr("panel.folder-pause")
    pauseOnClick = function()
      togglePaused("folder", folder.id, folder.paused)
    end
  elseif device then
    -- You cannot pause yourself -- Syncthing's own web GUI has no such
    -- control on "This Device" either.
    pauseVisible = not device.isSelf
    pauseGlyph = device.paused and "player-play" or "player-pause"
    pauseTooltip = device.paused and tr("panel.device-resume") or tr("panel.device-pause")
    pauseOnClick = function()
      togglePaused("device", device.id, device.paused)
    end
  else
    local paused = bulkPaused()
    pauseGlyph = paused and "player-play" or "player-pause"
    pauseTooltip = bulkPauseLabel(paused)
    pauseOnClick = paused and onResumeAll or onPauseAll
  end
  -- Same idea as the pause toggle: the header's primary link button opens
  -- this folder in the file manager while its detail view is open, since
  -- that action lives nowhere else once the row's own copy moved here, and
  -- falls back to the app-wide "open web GUI" action on the list views. The
  -- device detail view has no equivalent per-device action, so it hides
  -- entirely there instead of showing the unrelated app-wide GUI link.
  local primaryGlyph, primaryTooltip, primaryVisible, primaryOnClick
  if folder then
    primaryGlyph = "folder"
    primaryTooltip = tr("panel.open-folder")
    primaryVisible = true
    primaryOnClick = function()
      sendCmd("open_folder", folder.id)
    end
  elseif device then
    primaryGlyph = "external-link"
    primaryTooltip = tr("panel.open-gui")
    primaryVisible = false
    primaryOnClick = onOpenGui
  else
    primaryGlyph = "external-link"
    primaryTooltip = tr("panel.open-gui")
    primaryVisible = snapshot ~= nil and snapshot.sources.resolvedUrl ~= ""
    primaryOnClick = onOpenGui
  end
  local title = folder and folder.label or device and device.name or tr("panel.title")
  local subtitle = folder and folderStateText(folder)
    or device and (device.isSelf and tr("device.this-device") or deviceStateText(device))
    or tr(`state.{state}`)
  local leading = selected and ui.button({
    glyph = "chevron-left",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.back"),
    onClick = "onBack",
  }) or ui.image({
    path = statusIcon.path(state),
    width = 34,
    height = 34,
    fit = "contain",
  })
  return ui.row({ gap = 8, align = "center" }, {
    leading,
    folder and ui.glyph({
      name = "folder",
      size = 34,
      color = stateColors.get(folder.state),
    }) or device and ui.glyph({
      name = "devices-pc",
      size = 34,
      color = rowIcons.deviceColor(device, stateColors.get(device.connected and "idle" or "error")),
    }) or ui.box({ width = 0, height = 0 }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 16, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = subtitle, fontSize = 12, color = stateColors.get(selected and selected.state or state), maxLines = 1 }),
    }),
    ui.button({
      glyph = primaryGlyph,
      variant = "ghost",
      controlSize = "sm",
      enabled = true,
      tooltip = primaryTooltip,
      visible = primaryVisible,
      onClick = primaryOnClick,
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      enabled = folder ~= nil and not folder.paused,
      tooltip = tr("panel.folder-rescan"),
      visible = folder ~= nil,
      onClick = function()
        sendCmd("folder_rescan_details", folder.id)
      end,
    }),
    ui.button({
      glyph = pauseGlyph,
      variant = "ghost",
      controlSize = "sm",
      enabled = true,
      tooltip = pauseTooltip,
      visible = pauseVisible,
      onClick = pauseOnClick,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      enabled = true,
      tooltip = tr("panel.open-settings"),
      visible = not selected,
      onClick = "onSettings",
    }),
  })
end

local function formatRate(bytesPerSec)
  if bytesPerSec < 1024 then
    return nil
  end
  return `{formatBytes(bytesPerSec)}/s`
end

local function ratesLabel()
  -- Always returns a node (an invisible one when idle): a nil in the middle of
  -- a children array literal would truncate the siblings after it.
  local down = snapshot and formatRate(snapshot.rateIn or 0) or nil
  local up = snapshot and formatRate(snapshot.rateOut or 0) or nil
  return ui.label({
    text = `↓ {down or "0 B/s"} · ↑ {up or "0 B/s"}`,
    fontSize = 11,
    color = "secondary",
    visible = (down or up) ~= nil,
  })
end

-- Syncthing's raw states that say more than the coarse "syncing" they all map
-- to, and that the row's glyph already distinguishes (magnifier for a scan,
-- hourglass while preparing, and so on). Keeping the wording in step with the
-- glyph is what stops a scanning folder from reading "Syncing" next to a
-- magnifier.
local RAW_STATE_LABELS = {
  ["scanning"] = "state.scanning",
  ["sync-preparing"] = "state.sync-preparing",
  ["sync-waiting"] = "state.waiting",
  ["scan-waiting"] = "state.waiting",
  ["clean-waiting"] = "state.waiting",
  ["cleaning"] = "state.cleaning",
}

folderStateText = function(folder)
  local progress = folder.state ~= "idle" and folder.completion >= 0 and ` {folder.completion}%` or ""
  local rawKey = folder.state ~= "paused" and folder.state ~= "error" and RAW_STATE_LABELS[folder.rawState] or nil
  local base = `{tr(rawKey or `state.{folder.state}`)}{progress}`
  if folder.state == "syncing" then
    if folder.needItems > 0 then
      base = tr("panel.folder-state", { state = base, count = folder.needItems })
    end
    return base
  end
  if folder.state == "error" and folder.detail ~= "" then
    return `{base} — {folder.detail}`
  end
  return base
end

local function tabs()
  local folderCount = snapshot and snapshot.totals.monitoredFolders or 0
  local connected = snapshot and snapshot.devices.connected or 0
  local configured = snapshot and snapshot.devices.configured or 0
  return ui.row({ gap = 6 }, {
    ui.button({
      text = `{tr("panel.tab-folders")} ({folderCount})`,
      glyph = "folder",
      variant = view == "folders" and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = "onTabFolders",
    }),
    ui.button({
      text = `{tr("panel.tab-devices")} ({connected}/{configured})`,
      glyph = "devices-pc",
      variant = view == "devices" and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = "onTabDevices",
    }),
  })
end

local function folderRow(folder)
  local color = stateColors.get(folder.state)
  return ui.row({
    key = `folder-{folder.id}`,
    gap = 8,
    padding = 8,
    align = "center",
    fill = "surface_variant/0.5",
    radius = 8,
    onClick = function()
      openFolderDetails(folder)
    end,
  }, {
    ui.glyph({ name = "folder", size = 20, color = "on_surface/0.5" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = folder.label, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
      -- The status glyph is a tooltip-carrying button and so has no color of
      -- its own; the state line carries the state color instead.
      ui.label({
        text = folderStateText(folder),
        fontSize = 10,
        color = folder.state == "idle" and "on_surface/0.65" or color,
        maxLines = 1,
      }),
      ui.progress({
        progress = folder.completion / 100,
        height = 3,
        fill = "secondary",
        visible = folder.state == "syncing",
      }),
    }),
    -- Status indicator on the right, where Syncthing's web GUI puts it. Only
    -- ui.button carries a tooltip, so the indicator is a click-less ghost
    -- button rather than a bare ui.glyph.
    ui.button({
      glyph = rowIcons.folder(folder),
      variant = "ghost",
      glyphSize = 18,
      width = 26,
      height = 26,
      color = folder.state == "idle" and rowIcons.CHECK_COLOR or color,
      tooltip = folderStateText(folder),
      -- A button with no callback at all keeps its input area disabled, and a
      -- disabled input area never hovers — so the tooltip would never show.
      onHover = noop,
    }),
  })
end

-- Plain-language device state, used both by the row subtitle and as the
-- hover text on its status glyph.
deviceStateText = function(device)
  if device.paused then
    return tr("device.paused")
  end
  return device.connected and tr("device.connected") or tr("device.disconnected")
end

local function folderHasDevice(folder, deviceId)
  for _, id in (folder.deviceIds or {}) do
    if id == deviceId then
      return true
    end
  end
  return false
end

-- Hover text for the device row's status glyph specifically: unlike the row
-- subtitle (plain connected/disconnected/paused), the glyph also distinguishes
-- "Up to Date" from "Syncing" once connected.
local function deviceSyncStatusText(device, syncing)
  if device.paused then
    return tr("device.paused")
  end
  if not device.connected then
    return tr("device.disconnected")
  end
  return syncing and tr("device.syncing") or tr("device.up-to-date")
end

local function deviceRow(device)
  -- device.completion/needItems come from the service's per-device
  -- /rest/db/completion poll (see fetchDeviceCompletions in service.luau) —
  -- real per-device state, not a proxy off this host's own folder status.
  local syncing = device.connected and not device.paused and (device.completion or 100) < 100
  -- A device that is simply not connected reads as a problem, so it takes the
  -- error color (the `on_error` role is the ink for an error-*filled* surface —
  -- near-black in a dark palette — and would be unreadable here).
  local color = device.paused and stateColors.get("paused")
    or (device.connected and stateColors.get(syncing and "syncing" or "idle") or stateColors.get("error"))
  local subtitle = deviceStateText(device)
  if device.connected and not device.paused and device.address ~= "" then
    subtitle = device.address
  end
  if device.isSelf then
    subtitle = tr("device.this-device")
  end
  return ui.row({
    key = `device-{device.shortId}`,
    gap = 8,
    padding = 8,
    align = "center",
    fill = "surface_variant/0.5",
    radius = 8,
    opacity = device.connected and 1 or 0.7,
    onClick = function()
      openDeviceDetails(device)
    end,
  }, {
    ui.glyph({ name = "devices-pc", size = 20, color = "on_surface/0.5" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = device.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
        ui.label({
          text = device.version,
          fontSize = 10,
          color = "on_surface/0.5",
          maxLines = 1,
          visible = device.connected and not device.paused and device.version ~= "",
        }),
      }),
      ui.label({
        text = subtitle,
        fontSize = 11,
        color = (device.connected and not device.paused) and "on_surface/0.65" or color,
        maxLines = 1,
      }),
    }),
    -- State glyph plus connection-type meter, the same pair (and order) the
    -- web GUI shows at the right edge of a device row.
    ui.row({ gap = 0, align = "center" }, {
      ui.button({
        glyph = rowIcons.device(device, syncing),
        variant = "ghost",
        glyphSize = 18,
        width = 26,
        height = 26,
        color = rowIcons.deviceColor(device, color, syncing),
        tooltip = deviceSyncStatusText(device, syncing),
        -- See folderRow: no callback means no hover means no tooltip.
        onHover = noop,
      }),
      ui.button({
        -- No connection-type meter for yourself: connType is always empty,
        -- and rowIcons.signal()/connKind() would otherwise fall back to a
        -- misleading "3-bar WAN" default. A "home" glyph in its place keeps
        -- this button's slot (and so the row's icon alignment) the same
        -- across every device row instead of just hiding it.
        glyph = device.isSelf and "home" or rowIcons.signal(device),
        variant = "ghost",
        glyphSize = 18,
        width = 26,
        height = 26,
        -- Same color a connected remote's meter would use -- "This device"
        -- is trivially always connected, so it takes the same branch.
        color = (device.connected and not device.paused) and color or "on_surface/0.35",
        tooltip = device.isSelf and tr("device.this-device") or tr(`device.conn-{rowIcons.connKind(device)}`),
        onHover = noop,
      }),
    }),
  })
end

local function infoStat(value, label)
  return ui.column({ gap = 1, align = "center", flexGrow = 1 }, {
    ui.label({ text = tostring(value), fontSize = 14, fontWeight = "bold", maxLines = 1 }),
    ui.label({ text = label, fontSize = 10, color = "on_surface/0.6", maxLines = 1 }),
  })
end

-- Empty-state hints ("No folder errors.", "No shared folders.", ...) lean on
-- an italic face to read as an aside rather than a data row. Noctalia's
-- ui.label has no italic style of its own, so italic_font_family (a
-- fontconfig alias that pins slant=italic, same trick as the timewarrior
-- plugin) is what actually slants it; empty keeps the shell font.
local function hintLabel(text)
  local label = { text = text, fontSize = 11, color = "on_surface/0.6" }
  local family = noctalia.getConfig("italic_font_family")
  if family ~= nil and family ~= "" then
    label.fontFamily = family
  end
  return ui.label(label)
end

local function detailSection(title, rows, emptyText, glyph)
  local titleNode = glyph and ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = 14, color = "on_surface/0.6" }),
    ui.label({ text = title, fontSize = 12, fontWeight = "bold" }),
  }) or ui.label({ text = title, fontSize = 12, fontWeight = "bold" })
  local children = { titleNode }
  if #rows == 0 and emptyText then
    table.insert(children, hintLabel(emptyText))
  else
    for _, row in rows do
      table.insert(children, row)
    end
  end
  return ui.column({ gap = 5, padding = 8, fill = "surface_variant/0.5", radius = 8 }, children)
end

local function detailFileRow(name, subtitle, color)
  return ui.column({ gap = 1, padding = 6, fill = "surface/0.35", radius = 6 }, {
    ui.label({ text = name, fontSize = 11, maxLines = 2, color = color }),
    ui.label({ text = subtitle, fontSize = 10, color = "on_surface/0.6", maxLines = 2, visible = subtitle ~= "" }),
  })
end

local function changeColor(action)
  local normalized = string.lower(action or "")
  if normalized == "deleted" or normalized == "delete" or normalized == "removed" or normalized == "remove" then
    return "error"
  end
  if normalized == "created" or normalized == "create" or normalized == "added" or normalized == "add" then
    return stateColors.get("idle")
  end
  if normalized == "modified" or normalized == "modify" or normalized == "updated" or normalized == "update" then
    return "secondary"
  end
  if normalized == "renamed" or normalized == "rename" then
    return "tertiary"
  end
  return "on_surface_variant"
end

local function changeGlyph(action)
  local normalized = string.lower(action or "")
  if normalized == "deleted" or normalized == "delete" or normalized == "removed" or normalized == "remove" then
    return "file-minus"
  end
  if normalized == "created" or normalized == "create" or normalized == "added" or normalized == "add" then
    return "file-plus"
  end
  if normalized == "modified" or normalized == "modify" or normalized == "updated" or normalized == "update" then
    return "pencil"
  end
  if normalized == "renamed" or normalized == "rename" then
    return "arrow-right"
  end
  return "file"
end

-- Matches the ha plugin's activityCard day grouping (panel.luau there), not
-- localized there either -- keeping parity rather than half-translating it.
local function changeDayLabel(date)
  if not date then
    return ""
  end
  local today = os.date("%Y-%m-%d")
  if date == today then
    return "Today"
  end
  local yesterday = os.date("%Y-%m-%d", os.time() - 24 * 60 * 60)
  if date == yesterday then
    return "Yesterday"
  end
  return date
end

-- "remote" reads as the more notable case (someone/something else touched
-- this folder); "local" stays the same muted gray as the separator dot,
-- since it's the unremarkable default. A fixed cyan rather than a theme role
-- — "secondary" is already the action color for "modified" (changeColor
-- above), and a remote-modified row would otherwise show the same color
-- twice for two unrelated facts. Palette-independent on purpose, same as
-- row_icons.luau's CHECK_COLOR/POWER_COLOR.
local function sourceColor(source)
  return source == "remote" and "#22D3EE" or "on_surface/0.6"
end

-- One timeline row: an icon-in-rail on the left (connected to the next row by
-- a vertical line, same construction as the ha plugin's activityEntry), path
-- + action/source in the middle, time on the right. Returns the row's date
-- too so the caller can group consecutive same-day entries under one label.
local function changeEntry(item, isLast)
  local date, time = splitTimestamp(item.time)
  local action = item.action ~= "" and item.action or item.source
  local color = changeColor(action)
  local rail = {
    ui.row({ width = 14, height = 18, align = "center", justify = "center" }, {
      ui.glyph({ name = changeGlyph(action), size = 14, color = color }),
    }),
  }
  if not isLast then
    table.insert(rail, ui.box({ width = 2, height = 10, flexGrow = 1, fill = "outline/0.55" }))
  end
  return {
    date = date,
    row = ui.row({ align = "stretch", gap = 8 }, {
      ui.column({ width = 14, align = "center", gap = 4, paddingV = 3 }, rail),
      ui.column({ flexGrow = 1, gap = 1, paddingV = 3 }, {
        ui.row({ align = "start", gap = 8 }, {
          ui.column({ flexGrow = 1, gap = 1 }, {
            ui.label({ text = item.path, fontSize = 11, maxLines = 2 }),
            ui.row({ gap = 3, align = "center" }, {
              ui.label({ text = action, fontSize = 10, color = color, maxLines = 1 }),
              ui.label({ text = "·", fontSize = 10, color = "on_surface/0.5", maxLines = 1 }),
              ui.label({ text = item.source, fontSize = 10, color = sourceColor(item.source), maxLines = 1 }),
            }),
          }),
          ui.label({ text = time or "", width = 40, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
        }),
      }),
    }),
  }
end

local function folderDetailsView()
  local folder = selectedFolder()
  if not folder then
    return ui.label({ text = tr("panel.no-folders"), fontSize = 12, color = "on_surface/0.6" })
  end

  local children = {
    ui.column({ gap = 2, padding = 8, fill = "surface_variant/0.5", radius = 8 }, {
      ui.label({ text = tr("panel.folder-path"), fontSize = 10, color = "on_surface/0.6" }),
      ui.label({
        text = folder.path ~= "" and folder.path or tr("panel.folder-no-path"),
        fontSize = 11,
        maxLines = 2,
      }),
    }),
    ui.row({ gap = 6 }, {
      infoStat(folder.globalFiles, tr("panel.folder-files")),
      infoStat(formatBytes(folder.globalBytes), tr("panel.folder-size")),
      infoStat(folder.needItems, tr("panel.folder-pending")),
      infoStat(folder.deviceCount, tr("panel.folder-devices")),
    }),
  }

  if folder.detail ~= "" then
    table.insert(children, ui.label({ text = folder.detail, fontSize = 11, color = stateColors.get("error"), maxLines = 3 }))
  end
  if folderDetailLoading then
    table.insert(children, ui.label({ text = tr("panel.folder-loading"), fontSize = 11, color = "on_surface/0.6" }))
  elseif not folderDetail then
    table.insert(children, ui.label({ text = tr("panel.folder-loading"), fontSize = 11, color = "on_surface/0.6" }))
  else
    if folderDetail.error ~= "" then
      table.insert(children, ui.label({ text = folderDetail.error, fontSize = 11, color = stateColors.get("error"), maxLines = 3 }))
    end

    local errors = {}
    for _, item in (folderDetail.errors or {}) do
      table.insert(errors, detailFileRow(item.path, item.message, "error/0.9"))
    end
    table.insert(children, detailSection(tr("panel.folder-errors"), errors, tr("panel.folder-no-errors"), "alert-triangle"))

    local conflicts = {}
    for _, path in (folderDetail.conflicts or {}) do
      table.insert(conflicts, detailFileRow(path, tr("panel.folder-conflict"), "error/0.9"))
    end
    if #conflicts > 0 then
      table.insert(children, detailSection(tr("panel.folder-conflicts"), conflicts, nil, "alert-circle"))
    end

    local pending = {}
    for _, item in (folderDetail.pending or {}) do
      local subtitle = `{item.queue} · {formatBytes(item.size)}`
      if item.modified ~= "" then
        subtitle = `{subtitle} · {shortTimestamp(item.modified)}`
      end
      table.insert(pending, detailFileRow(item.name, subtitle, "secondary"))
    end
    table.insert(children, detailSection(tr("panel.folder-pending-files"), pending, tr("panel.folder-no-pending"), "download"))

    local changes = {}
    local changeItems = folderDetail.changes or {}
    local previousDate = nil
    for index, item in changeItems do
      local entry = changeEntry(item, index == #changeItems)
      if entry.date ~= previousDate then
        table.insert(changes, ui.label({
          text = changeDayLabel(entry.date),
          fontSize = 11,
          fontWeight = "semibold",
          color = "on_surface_variant",
        }))
        previousDate = entry.date
      end
      table.insert(changes, entry.row)
    end
    table.insert(children, detailSection(tr("panel.folder-recent-changes"), changes, tr("panel.folder-no-recent-changes"), "history"))
  end
  return ui.scroll({ gap = 8, flexGrow = 1 }, children)
end

local function deviceDetailsView()
  local device = selectedDevice()
  if not device then
    return ui.label({ text = tr("panel.no-devices"), fontSize = 12, color = "on_surface/0.6" })
  end

  local connection = tr(`device.conn-{rowIcons.connKind(device)}`)
  local children = {
    ui.column({ gap = 4, padding = 8, fill = "surface_variant/0.5", radius = 8 }, {
      ui.label({ text = tr("panel.device-id"), fontSize = 10, color = "on_surface/0.6" }),
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = device.id, fontSize = 11, flexGrow = 1, maxLines = 2 }),
        ui.button({
          text = tr("panel.copy-device-id"),
          glyph = "copy",
          variant = "outline",
          controlSize = "sm",
          onClick = function()
            copyDeviceId(device)
          end,
        }),
      }),
    }),
    detailSection(tr("panel.device-connection"), {
      ui.label({
        text = device.isSelf and tr("device.this-device") or deviceStateText(device),
        fontSize = 11,
        color = stateColors.get(device.paused and "paused" or (device.connected and "idle" or "error")),
      }),
      -- Connection type ("Direct connection", "Relayed", ...) is meaningless
      -- for yourself -- connType is always empty, so this would otherwise
      -- just repeat the "This device"/"Connected" line above via the
      -- "unknown" fallback in rowIcons.connKind().
      ui.label({ text = connection, fontSize = 11, color = "on_surface/0.7", visible = not device.isSelf }),
      ui.label({ text = device.address ~= "" and device.address or tr("panel.device-no-address"), fontSize = 11, color = "on_surface/0.7" }),
      ui.label({ text = device.version ~= "" and device.version or tr("panel.device-no-version"), fontSize = 11, color = "on_surface/0.7" }),
    }, nil, "plug-connected"),
  }

  local folders = {}
  for _, folder in snapshot.folders do
    if folderHasDevice(folder, device.id) then
      table.insert(folders, ui.button({
        text = folder.label,
        glyph = rowIcons.folder(folder),
        variant = "ghost",
        contentAlign = "start",
        tooltip = tr("panel.folder-details"),
        onClick = function()
          openFolderDetails(folder)
        end,
      }))
    end
  end
  if #folders == 0 then
    table.insert(folders, hintLabel(tr("panel.device-no-folders")))
  end
  table.insert(children, detailSection(tr("panel.device-folders"), folders, nil, "folder"))
  if deviceQrLoading then
    table.insert(children, ui.label({ text = tr("panel.device-qr-loading"), fontSize = 11, color = "on_surface/0.6" }))
  elseif deviceQr and deviceQr.path then
    table.insert(children, ui.column({ gap = 5, align = "center", padding = 8, fill = "surface_variant/0.5", radius = 8 }, {
      ui.label({ text = tr("panel.device-qr"), fontSize = 12, fontWeight = "bold" }),
      ui.image({ path = deviceQr.path, width = 180, height = 180, fit = "contain" }),
    }))
  elseif deviceQr and deviceQr.error then
    table.insert(children, ui.label({ text = deviceQr.error, fontSize = 11, color = stateColors.get("error"), maxLines = 3 }))
  end
  return ui.scroll({ gap = 8, flexGrow = 1 }, children)
end

local function folderList()
  local rows = {}
  if snapshot then
    if view == "devices" then
      for _, device in snapshot.devicesList do
        table.insert(rows, deviceRow(device))
      end
    else
      for _, folder in snapshot.folders do
        table.insert(rows, folderRow(folder))
      end
    end
  end
  if #rows == 0 then
    local emptyKey = view == "devices" and "panel.no-devices" or "panel.no-folders"
    table.insert(rows, ui.label({ text = tr(emptyKey), fontSize = 12, color = "on_surface/0.6" }))
  end
  return ui.scroll({ gap = 6, flexGrow = 1 }, rows)
end

render = function()
  if not isOpen then
    return
  end
  -- height pins the root to the [[panel]] size so the folder list scrolls
  -- instead of growing past the panel background; keep PANEL_HEIGHT and the
  -- manifest's height = … in sync, the root wins over the manifest value.
  local children = { header() }
  if view == "folder" then
    table.insert(children, folderDetailsView())
  elseif view == "device" then
    table.insert(children, deviceDetailsView())
  else
    table.insert(children, ui.label({
      text = statusSummary(),
      fontSize = 12,
      color = "on_surface/0.8",
      -- Pure repetition while idle: the header already names the state and the
      -- tiles already show the device count. Every other state says something
      -- the rest of the panel does not.
      visible = not snapshot or snapshot.state ~= "idle",
    }))
    table.insert(children, tabs())
    table.insert(children, folderList())
  end
  table.insert(children, ratesLabel())
  panel.render(ui.column({ gap = 10, padding = PANEL_PADDING, height = PANEL_HEIGHT - PANEL_PADDING * 2 }, children))
end

-- ── Lifecycle & callbacks ────────────────────────────────────────────────────

noctalia.state.watch("st.snapshot", function(encoded)
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
end)

noctalia.state.watch("st.folder-detail", function(encoded)
  local detail = encoded and noctalia.json.decode(encoded) or nil
  if detail and detail.folderId == selectedFolderId then
    folderDetail = detail
    folderDetailLoading = false
    render()
  end
end)

noctalia.state.watch("st.device-qr", function(encoded)
  local qr = encoded and noctalia.json.decode(encoded) or nil
  if qr and qr.deviceId == selectedDeviceId then
    deviceQr = qr
    deviceQrLoading = false
    render()
  end
end)

function onOpen(_context)
  isOpen = true
  local encoded = noctalia.state.get("st.snapshot")
  snapshot = encoded and noctalia.json.decode(encoded) or nil
  render()
  sendCmd("refresh")
end

function onClose()
  isOpen = false
  view = "folders"
  selectedFolderId = nil
  selectedDeviceId = nil
  folderDetail = nil
  folderDetailLoading = false
  deviceQr = nil
  deviceQrLoading = false
end

function onRefresh()
  sendCmd("refresh")
end

function onOpenGui()
  sendCmd("open_gui")
end

function onSettings()
  noctalia.openSettings()
end

function onPauseAll()
  sendCmd(bulkPauseKind() == "folders" and "pause_all_folders" or "pause_all_devices")
end

function onResumeAll()
  sendCmd(bulkPauseKind() == "folders" and "resume_all_folders" or "resume_all_devices")
end

function onTabFolders()
  view = "folders"
  selectedFolderId = nil
  selectedDeviceId = nil
  deviceQr = nil
  deviceQrLoading = false
  render()
end

function onTabDevices()
  view = "devices"
  selectedFolderId = nil
  selectedDeviceId = nil
  deviceQr = nil
  deviceQrLoading = false
  render()
end

function onBack()
  view = selectedDeviceId and "devices" or "folders"
  selectedFolderId = nil
  selectedDeviceId = nil
  folderDetail = nil
  folderDetailLoading = false
  deviceQr = nil
  deviceQrLoading = false
  render()
end
