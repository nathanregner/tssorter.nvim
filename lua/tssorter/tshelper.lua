local logger = require('tssorter.logger')

local M = {}

---@alias NodeRange {s_line: number, s_col: number, e_row: number, e_col: number}

local function find_top_line(lines, curr_range)
  local curr_top_line = curr_range[1]

  local s_line_offset = 1
  while s_line_offset <= #lines do
    local s_col_offset = string.find(lines[s_line_offset], '%S')
    if s_col_offset ~= nil then
      break
    end
    s_line_offset = s_line_offset + 1
  end

  -- because lua is 1-based need to remove one to get actual offset
  -- Ex. if found on first line you want to return the line and not line + 1
  return curr_top_line + (s_line_offset - 1)
end

local function find_bottom_line(lines, curr_range)
  local curr_bottom_line = curr_range[3]
  local curr_end_col = curr_range[4]

  -- HACK: fix for when treesitter returns us an extra line with no text (col = 0)
  if curr_end_col == 0 then
    curr_bottom_line = curr_bottom_line - 1
  end

  local function get_line_ix()
    local line_ix = #lines
    while line_ix >= 1 do
      local line_text = lines[line_ix]

      for col_ix = #line_text, 1, -1 do
        -- FIX: what about tabs?????
        if line_text:sub(col_ix, col_ix) ~= ' ' then
          return line_ix
        end
      end

      line_ix = line_ix - 1
    end

    -- FIX: what happens when out of the loop and it's all spaces?
  end

  local line_ix = get_line_ix()
  local e_line_offset = #lines - line_ix

  return curr_bottom_line - e_line_offset
end

-- NOTE: line_ix being passed in is 0-indexed (treesitter), need to add 1 to get actual line number
local function get_line(line_ix)
  line_ix = line_ix + 1

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, line_ix - 1, line_ix, false)
  if not lines or type(lines) ~= 'table' then
    return nil
  end

  return lines[1]
end

local function get_char(line, ix)
  return line:sub(ix, ix)
end

local function find_first_char(line_ix, lines, curr_range)
  -- doesn't need to trim, return current position
  if get_char(lines[1], 1) ~= ' ' then
    logger.trace('Line does not need ltrim', { line = lines[1], initial_char = get_char(lines[1], 1) })
    return curr_range[2]
  end

  local line = get_line(line_ix)
  if not line then
    return nil
  end

  return string.find(line, '%S') - 1
end

local function find_last_char(line_ix, lines, curr_range)
  -- doesn't need to trim, return current position
  -- make sure to check end_col is not beginning of next line
  if curr_range[4] ~= 0 and get_char(lines[#lines], curr_range[4]) ~= ' ' then
    logger.trace(
      'Line does not need rtrim',
      { line = lines[1], curr_col = curr_range[2], char_at = get_char(lines[1], curr_range[4]) }
    )
    return curr_range[4]
  end

  local line = get_line(line_ix)
  if not line then
    return nil
  end

  for col_ix = #line, 1, -1 do
    -- FIX: what about tabs????? Should switch to pattern matching on space characters
    if get_char(line, col_ix) ~= ' ' then
      return col_ix
    end
  end
end

local function remove_whitespace(lines, curr_range)
  logger.trace('Removing whitespace', { lines = lines, curr_range = curr_range })

  local top_line = find_top_line(lines, curr_range)
  local bottom_line = find_bottom_line(lines, curr_range)
  local top_col = find_first_char(top_line, lines, curr_range)
  local bottom_col = find_last_char(bottom_line, lines, curr_range)

  local new_ranges = {
    top_line,
    top_col,
    bottom_line,
    bottom_col,
  }

  return new_ranges
end

--- Returns true if node matches the passed config
---@param node TSNode
---@param sortable_config SortableOpts
---@return boolean
local function node_matches_sortable(node, sortable_config)
  local possible_nodes = sortable_config.node
  if type(possible_nodes) ~= 'table' then
    possible_nodes = { possible_nodes }
  end

  logger.trace('Trying to match node type', {
    node_type = node:type(),
    possible_nodes = possible_nodes,
  })

  return vim.tbl_contains(possible_nodes, node:type())
end

---@param sortables SortableCfg
---@return string? sortable_name
---@return TSNode?
local function find_nearest_sortable(sortables)
  local node = vim.treesitter.get_node({ ignore_injections = false })

  while node do
    for name, sortable_config in pairs(sortables) do
      if node_matches_sortable(node, sortable_config) then
        logger.info('Matched node with sortable', {
          sortable_name = name,
          node_type = node:type(),
        })

        return name, node
      end
    end
    node = node:parent()
  end
end

--- Get the node positions without
---@param nodes TSNode[]
---@return NodeRange[] positions
M.get_positions = function(nodes)
  local bufnr = vim.api.nvim_get_current_buf()

  return vim
    .iter(nodes)
    :map(function(node)
      local lines_text = vim.treesitter.get_node_text(node, bufnr)
      local lines = vim.split(lines_text, '\n')
      return remove_whitespace(lines, { node:range() })
    end)
    :totable()
end

--- Returns the nodes text
---@param node TSNode
---@return string
M.get_text = function(node)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.treesitter.get_node_text(node, bufnr)

  return vim.trim(lines)
end

--- stolen from vim.treesitter._range
---@param a_row integer
---@param a_col integer
---@param b_row integer
---@param b_col integer
---@return integer
--- 1: a > b
--- 0: a == b
--- -1: a < b
local function cmp_pos(a_row, a_col, b_row, b_col)
  if a_row == b_row then
    if a_col > b_col then
      return 1
    elseif a_col < b_col then
      return -1
    else
      return 0
    end
  elseif a_row > b_row then
    return 1
  end

  return -1
end

--- stolen from vim.treesitter._range
---@param r Range
---@return integer, integer, integer, integer
local function unpack4(r)
  if #r == 2 then
    return r[1], 0, r[2], 0
  end
  local off_1 = #r == 6 and 1 or 0
  return r[1], r[2], r[3 + off_1], r[4 + off_1]
end

--- stolen from vim.treesitter._range
---@param r1 Range
---@param r2 Range
---@return boolean whether r1 contains r2
local function contains(r1, r2)
  local srow_1, scol_1, erow_1, ecol_1 = unpack4(r1)
  local srow_2, scol_2, erow_2, ecol_2 = unpack4(r2)

  -- start doesn't fit
  if cmp_pos(srow_1, scol_1, srow_2, scol_2) == 1 then
    return false
  end

  -- end doesn't fit
  if cmp_pos(erow_1, ecol_1, erow_2, ecol_2) == -1 then
    return false
  end

  return true
end

--- Look for the nearest sortable under the current node
---@param sortables SortableCfg
---@param range? Range
---@return string? sortable_name
---@return TSNode[]?
M.find_sortables = function(sortables, range)
  local name, sortable_node = find_nearest_sortable(sortables)

  if not sortable_node then
    logger.warn('No sortable node under the cursor')
    return
  end

  local in_range = function()
    return true
  end
  if range then
    ---@param node TSNode
    in_range = function(node)
      return contains(range, vim.treesitter.get_range(node))
    end
  end

  if not in_range(sortable_node) then
    logger.warn('Node out of range')
    return
  end

  local parent = sortable_node:parent()

  if not parent then
    logger.warn('Invalid orphan node, needs parent to iterate through sibling nodes')
    return
  end

  local sortable_nodes = {}
  local target_type = sortable_node:type()

  for possible_sortable in parent:iter_children() do
    if possible_sortable:type() == target_type and in_range(possible_sortable) then
      table.insert(sortable_nodes, possible_sortable)
    end
  end

  return name, sortable_nodes
end

--- Return the first nested child of this type
---@param node TSNode
---@param node_type string|string[]
---@return TSNode?
M.get_nested_child = function(node, node_type)
  if type(node_type) == 'string' then
    node_type = { node_type }
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local filetype = vim.bo[bufnr].filetype

  local log_context = {
    current_node = {
      node:type(),
      { node:range() },
    },
    ordinal_types = node_type,
  }

  logger.trace('Looking for ordinal in node', log_context)

  for _, type in ipairs(node_type) do
    local query_str = string.format('(%s) @ordinal', type)

    -- FIX: for parse() need to get language on current node (in case of injected_language) rather than current buffer filetype
    -- NOTE: this can potentially error out if there's an invalid node (not part of language tree) in the list, consider adding a pcall here?
    local query = vim.treesitter.query.parse(filetype, query_str)

    -- take first capture
    local _, child = query:iter_captures(node, bufnr)()

    if child then
      logger.info(
        'Found nested child',
        vim.tbl_extend('force', log_context, {
          found_type = child:type(),
        })
      )

      return child
    end
  end

  logger.info('None of the possible types were found under the current node', log_context)

  return nil
end

return M
