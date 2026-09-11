--!nonstrict

-- A deliberately small YAML subset for the user-facing HA layout file.
-- The file is meant to be easy to maintain by hand, not to be a general YAML
-- implementation: entities, sections, booleans, labels, conditions, per-media
-- player remotes, and small display-state overrides/templates are all we need.

local M = {}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function scalar(value)
  value = trim(value)
  if value:sub(1, 1) == "[" and value:sub(-1) == "]" then
    local values = {}
    for item in value:sub(2, -2):gmatch("[^,]+") do values[#values + 1] = scalar(item) end
    return values
  end
  if value == "true" then return true end
  if value == "false" then return false end
  if value == "null" or value == "~" then return nil end

  if value:sub(1, 1) == '"' then
    local decoded = noctalia.json.decode(value)
    if type(decoded) == "string" then return decoded end
  elseif value:sub(1, 1) == "'" and value:sub(-1) == "'" then
    return value:sub(2, -2):gsub("''", "'")
  end
  return value
end

local function addUnique(list, value)
  if type(value) ~= "string" or value == "" then return end
  for _, existing in ipairs(list) do
    if existing == value then return end
  end
  list[#list + 1] = value
end

local function setField(object, key, value)
  if key == "name" or key == "title" then
    if type(value) == "string" then object.name = value end
  elseif key == "collapsed" then
    object.collapsed = value == true
  elseif key == "entity" then
    addUnique(object.entities, value)
  elseif key == "state_attr" then
    if type(value) == "string" and value ~= "" then object.state_attr = value end
  elseif key == "remote" then
    if type(value) == "string" and value ~= "" then object.remote = value end
  end
end

function M.parse(text)
  local result = { entities = {}, entity_conditions = {}, entity_remotes = {}, sections = {}, labels = {}, icons = {}, state_attributes = {}, state_templates = {} }
  local mode = nil
  local section = nil
  local subsection = nil
  local entityEntry = nil
  local sectionEntityEntry = nil
  local labelEntity = nil

  for rawLine in tostring(text or ""):gmatch("[^\n]+") do
    rawLine = rawLine:gsub("\r$", "")
    local content = rawLine:gsub("^ +", "")
    if content ~= "" and content:sub(1, 1) ~= "#" then
      local indent = #rawLine - #content

      if indent == 0 then
        local key, inline = content:match("^([%w_]+):%s*(.*)$")
        mode = key
        subsection = nil
        entityEntry = nil
        sectionEntityEntry = nil
        labelEntity = nil
        if key == "entities" then
          if inline ~= "" then addUnique(result.entities, scalar(inline)) end
        elseif key == "sections" then
          -- The sequence follows on subsequent indented lines.
        elseif key == "labels" then
          -- Labels are parsed as an indented key/value mapping below.
        end
      elseif mode == "entities" and indent == 2 then
        local value = content:match("^%-%s+(.+)$")
        local id = value and (value:match("^entity_id:%s*(.+)$") or value:match("^id:%s*(.+)$"))
        if id then
          id = scalar(id)
          addUnique(result.entities, id)
          entityEntry = { id = id, when = {} }
          result.entity_conditions[id] = entityEntry.when
          subsection = nil
        else
          entityEntry = nil
          addUnique(result.entities, value and scalar(value) or nil)
        end
      elseif mode == "entities" and entityEntry and indent == 4 then
        local key, value = content:match("^([%w_]+):%s*(.*)$")
        if key == "conditions" or key == "if" then
          subsection = "entity_when"
        elseif key == "entity_id" or key == "id" then
          -- The entity id is normally on the sequence item (`- entity_id: ...`).
          entityEntry.id = scalar(value)
        elseif key == "state_attr" then
          local attr = scalar(value)
          if type(attr) == "string" and attr ~= "" then result.state_attributes[entityEntry.id] = attr end
        elseif key == "state_template" then
          local template = scalar(value)
          if type(template) == "string" and template ~= "" then result.state_templates[entityEntry.id] = template end
        elseif key == "remote" then
          local remote = scalar(value)
          if type(remote) == "string" and remote ~= "" then result.entity_remotes[entityEntry.id] = remote end
        end
      elseif mode == "entities" and entityEntry and subsection == "entity_when" and indent == 6 then
        local key, value = content:match("^([%w_]+):%s*(.*)$")
        if key == "entity" or key == "state" or key == "not" or key == "for" then
          entityEntry.when[key] = scalar(value)
        end
      elseif mode == "sections" and indent == 2 then
        local inline = content:match("^%-%s*(.*)$")
        section = { name = "", collapsed = false, entities = {} }
        sectionEntityEntry = nil
        result.sections[#result.sections + 1] = section
        subsection = nil
        if inline and inline ~= "" then
          local key, value = inline:match("^([%w_]+):%s*(.*)$")
          if key then setField(section, key, scalar(value)) end
        end
      elseif mode == "sections" and section and indent == 4 then
        local key, value = content:match("^([%w_]+):%s*(.*)$")
        if key == "entities" then
          subsection = "entities"
        elseif key == "conditions" or key == "if" then
          subsection = "section_when"
        elseif key then
          subsection = nil
          setField(section, key, scalar(value))
        end
      elseif mode == "sections" and section and subsection == "entities" and indent == 6 then
        local value = content:match("^%-%s+(.+)$")
        local id = value and (value:match("^entity_id:%s*(.+)$") or value:match("^id:%s*(.+)$"))
        if id then
          id = scalar(id)
          addUnique(section.entities, id)
          sectionEntityEntry = { id = id }
          -- Keep the sequence subsection active so the next `- ...` item is
          -- still recognized after this mapping's extra fields.
          subsection = "entities"
        else
          sectionEntityEntry = nil
          addUnique(section.entities, value and scalar(value) or nil)
        end
      elseif mode == "sections" and section and sectionEntityEntry and subsection == "entities" and indent == 8 then
        local key, value = content:match("^([%w_]+):%s*(.*)$")
        if key == "remote" then
          local remote = scalar(value)
          if type(remote) == "string" and remote ~= "" then result.entity_remotes[sectionEntityEntry.id] = remote end
        end
      elseif mode == "sections" and section and subsection == "section_when" and indent == 6 then
        local key, value = content:match("^([%w_]+):%s*(.*)$")
        if key == "entity" or key == "state" or key == "not" or key == "for" then
          section.when = section.when or {}
          section.when[key] = scalar(value)
        end
      elseif mode == "labels" and indent == 2 then
        local key, value = content:match("^([^:]+):%s*(.*)$")
        if key and value ~= "" then
          local label = scalar(value)
          if type(label) == "string" and label ~= "" then result.labels[trim(key)] = label end
        end
      elseif mode == "homeassistant" and indent == 2 then
        local key = content:match("^([%w_]+):%s*$")
        if key == "customize" then subsection = "customize" end
      elseif mode == "homeassistant" and subsection == "customize" and indent == 4 then
        local key, value = content:match("^([^:]+):%s*(.*)$")
        if key then
          labelEntity = trim(key)
          if value ~= "" then
            local label = scalar(value)
            if key == "friendly_name" then
              if type(label) == "string" and label ~= "" then result.labels[labelEntity] = label end
            elseif key == "icon" then
              if type(label) == "string" and label ~= "" then result.icons[labelEntity] = label end
            end
          end
        end
      elseif mode == "homeassistant" and subsection == "customize" and labelEntity and indent == 6 then
        local key, value = content:match("^([%w_]+):%s*(.*)$")
        if key == "friendly_name" or key == "icon" then
          local label = scalar(value)
          if type(label) == "string" and label ~= "" then
            if key == "friendly_name" then result.labels[labelEntity] = label else result.icons[labelEntity] = label end
          end
        end
      end
    end
  end

  local validSections = {}
  for _, candidate in ipairs(result.sections) do
    -- Keep empty named sections: the editor can create a category before
    -- moving entities into it, and the state overlay must preserve that.
    if candidate.name ~= "" then
      validSections[#validSections + 1] = candidate
      for _, entityId in ipairs(candidate.entities) do addUnique(result.entities, entityId) end
    end
  end
  result.sections = validSections
  for entityId, condition in pairs(result.entity_conditions) do
    if type(condition) ~= "table" or condition.entity == nil or condition.state == nil then
      result.entity_conditions[entityId] = nil
    end
  end
  return result
end

local function quote(value)
  if type(value) == "table" then
    local values = {}
    for _, item in ipairs(value) do values[#values + 1] = quote(item) end
    return "[" .. table.concat(values, ", ") .. "]"
  end
  return noctalia.json.encode(tostring(value or ""))
end

function M.serialize(layout)
  local lines = {
    "# Home Assistant entities and panel layout.",
    "# This file is the writable Noctalia state overlay; edit the declarative",
    "# base at ~/.config/noctalia/ha.yaml instead when using Home Manager.",
    "entities:",
  }
  for _, entityId in ipairs(layout.entities or {}) do
    local condition = layout.entity_conditions and layout.entity_conditions[entityId]
    local stateAttr = layout.state_attributes and layout.state_attributes[entityId]
    local stateTemplate = layout.state_templates and layout.state_templates[entityId]
    local remote = layout.entity_remotes and layout.entity_remotes[entityId]
    if (condition and condition.entity and condition.state ~= nil) or stateAttr or stateTemplate or remote then
      lines[#lines + 1] = "  - entity_id: " .. quote(entityId)
      if stateAttr then lines[#lines + 1] = "    state_attr: " .. quote(stateAttr) end
      if stateTemplate then lines[#lines + 1] = "    state_template: " .. quote(stateTemplate) end
      if remote then lines[#lines + 1] = "    remote: " .. quote(remote) end
    end
    if condition and condition.entity and condition.state ~= nil then
      lines[#lines + 1] = "    conditions:"
      lines[#lines + 1] = "      entity: " .. quote(condition.entity)
      lines[#lines + 1] = "      state: " .. quote(condition.state)
      if condition["not"] == true then lines[#lines + 1] = "      not: true" end
      if condition["for"] ~= nil then lines[#lines + 1] = "      for: " .. quote(condition["for"]) end
    elseif not stateAttr and not stateTemplate and not remote then
      lines[#lines + 1] = "  - " .. quote(entityId)
    end
  end

  lines[#lines + 1] = "sections:"
  for _, section in ipairs(layout.sections or {}) do
    lines[#lines + 1] = "  - name: " .. quote(section.name)
    lines[#lines + 1] = "    collapsed: " .. (section.collapsed == true and "true" or "false")
    if section.when and section.when.entity and section.when.state ~= nil then
      lines[#lines + 1] = "    conditions:"
      lines[#lines + 1] = "      entity: " .. quote(section.when.entity)
      lines[#lines + 1] = "      state: " .. quote(section.when.state)
      if section.when["not"] == true then lines[#lines + 1] = "      not: true" end
      if section.when["for"] ~= nil then lines[#lines + 1] = "      for: " .. quote(section.when["for"]) end
    end
    lines[#lines + 1] = "    entities:"
    for _, entityId in ipairs(section.entities or {}) do
      local remote = layout.entity_remotes and layout.entity_remotes[entityId]
      if remote then
        lines[#lines + 1] = "      - entity_id: " .. quote(entityId)
        lines[#lines + 1] = "        remote: " .. quote(remote)
      else
        lines[#lines + 1] = "      - " .. quote(entityId)
      end
    end
  end

  local customizeKeys = {}
  for entityId in pairs(layout.labels or {}) do customizeKeys[entityId] = true end
  for entityId in pairs(layout.icons or {}) do customizeKeys[entityId] = true end
  local customizeIds = {}
  for entityId in pairs(customizeKeys) do customizeIds[#customizeIds + 1] = entityId end
  table.sort(customizeIds)
  if #customizeIds > 0 then
    lines[#lines + 1] = "homeassistant:"
    lines[#lines + 1] = "  customize:"
    for _, entityId in ipairs(customizeIds) do
      lines[#lines + 1] = "    " .. entityId .. ":"
      if layout.labels and layout.labels[entityId] then
        lines[#lines + 1] = "      friendly_name: " .. quote(layout.labels[entityId])
      end
      if layout.icons and layout.icons[entityId] then
        lines[#lines + 1] = "      icon: " .. quote(layout.icons[entityId])
      end
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
