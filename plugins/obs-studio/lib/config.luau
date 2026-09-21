--!nonstrict
-- A deliberately small YAML subset for the user-facing custom-buttons file,
-- the same "read this by hand, not with a general YAML parser" approach
-- pschmitt/ha's layout.luau takes for ha.yaml. Only one shape is supported:
-- a top-level `buttons:` list of flat mappings (string/quoted-string/flow-
-- list values, no nesting), because that's all a button needs.

local M = {}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unquote(value)
  value = trim(value)
  if value == "" then return "" end
  if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
    return (value:sub(2, -2):gsub('\\"', '"'))
  end
  if value:sub(1, 1) == "'" and value:sub(-1) == "'" then
    return (value:sub(2, -2):gsub("''", "'"))
  end
  return value
end

-- "[a, \"b c\", d]" -> { "a", "b c", "d" }. Kept flat on purpose: every flow
-- item here is a plain argv token, never a nested structure.
local function flowList(value)
  value = trim(value)
  if value:sub(1, 1) ~= "[" or value:sub(-1) ~= "]" then return nil end
  local inner = value:sub(2, -2)
  local items = {}
  if trim(inner) == "" then return items end
  for item in (inner .. ","):gmatch("([^,]*),") do
    table.insert(items, unquote(item))
  end
  return items
end

local function scalarOrList(value)
  local list = flowList(value)
  if list then return list end
  return unquote(value)
end

-- Parses the file's text into { buttons = { { label = ..., icon = ...,
-- obs_cli = {...} | command = {...}, color = ... },
-- ... } }. Any line outside a recognized `buttons:` list item is ignored,
-- so unrelated top-level keys (reserved for future use) don't error out.
function M.parse(text)
  local buttons = {}
  local current = nil
  local inButtons = false

  for line in (text or ""):gmatch("[^\r\n]+") do
    if trim(line) == "" or trim(line):sub(1, 1) == "#" then
      -- blank/comment
    elseif line:match("^buttons:%s*$") then
      inButtons = true
    elseif not line:match("^%s") then
      -- a new, unindented top-level key ends the buttons list.
      inButtons = false
      current = nil
    elseif inButtons then
      local dashRest = line:match("^%s*-%s*(.*)$")
      if dashRest ~= nil then
        current = {}
        table.insert(buttons, current)
        if trim(dashRest) ~= "" then
          local key, value = dashRest:match("^([%w_]+):%s*(.-)%s*$")
          if key then
            current[key] = scalarOrList(value)
          end
        end
      elseif current then
        local key, value = line:match("^%s+([%w_]+):%s*(.-)%s*$")
        if key then
          current[key] = scalarOrList(value)
        end
      end
    end
  end

  return { buttons = buttons }
end

return M
