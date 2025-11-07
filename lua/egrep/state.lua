-- State management for enhanced grep
local M = {}

-- Default state
local default_state = {
  last_search = "",
  last_include = {},
  last_exclude = {},
  ignore_tests = true,
  case_sensitive = false,
  use_gitignore = true,
  fold_state = {}, -- file -> boolean (expanded/collapsed)
  search_history = {},
  context_before = 0,
  context_after = 0,
  search_path = ".",
}

-- Current state
local state = vim.deepcopy(default_state)

--- Get the state file path
--- @return string Path to state file
local function get_state_file()
  local data_dir = vim.fn.stdpath("data")
  return data_dir .. "/egrep-state.json"
end

--- Load state from disk
function M.load()
  local state_file = get_state_file()
  local file = io.open(state_file, "r")

  if not file then
    return
  end

  local content = file:read("*all")
  file:close()

  local ok, loaded_state = pcall(vim.json.decode, content)
  if ok and loaded_state then
    state = vim.tbl_deep_extend("force", default_state, loaded_state)
  end
end

--- Save state to disk
function M.save()
  local state_file = get_state_file()
  local file = io.open(state_file, "w")

  if not file then
    vim.notify("Failed to save egrep state", vim.log.levels.WARN)
    return
  end

  local ok, json = pcall(vim.json.encode, state)
  if ok then
    file:write(json)
  end
  file:close()
end

--- Get current state
--- @return table Current state
function M.get()
  return state
end

--- Update state
--- @param updates table Fields to update
function M.update(updates)
  state = vim.tbl_deep_extend("force", state, updates)
  M.save()
end

--- Reset state to defaults
function M.reset()
  state = vim.deepcopy(default_state)
  M.save()
end

--- Get fold state for a file
--- @param file string File path
--- @return boolean True if expanded, false if collapsed
function M.get_fold_state(file)
  return state.fold_state[file] or false
end

--- Set fold state for a file
--- @param file string File path
--- @param expanded boolean True if expanded, false if collapsed
function M.set_fold_state(file, expanded)
  state.fold_state[file] = expanded
  M.save()
end

--- Toggle fold state for a file
--- @param file string File path
--- @return boolean New fold state
function M.toggle_fold_state(file)
  local new_state = not M.get_fold_state(file)
  M.set_fold_state(file, new_state)
  return new_state
end

--- Add search to history
--- @param search_pattern string Search pattern
--- @param include_patterns table Include patterns
--- @param exclude_patterns table Exclude patterns
function M.add_to_history(search_pattern, include_patterns, exclude_patterns)
  -- Remove duplicate if exists
  for i, entry in ipairs(state.search_history) do
    if entry.pattern == search_pattern then
      table.remove(state.search_history, i)
      break
    end
  end

  -- Add to beginning
  table.insert(state.search_history, 1, {
    pattern = search_pattern,
    include = include_patterns,
    exclude = exclude_patterns,
    timestamp = os.time(),
  })

  -- Keep only last 50 searches
  if #state.search_history > 50 then
    for i = #state.search_history, 51, -1 do
      table.remove(state.search_history, i)
    end
  end

  M.save()
end

--- Get search history
--- @param limit number|nil Maximum number of entries to return
--- @return table Search history
function M.get_history(limit)
  limit = limit or #state.search_history
  local history = {}
  for i = 1, math.min(limit, #state.search_history) do
    table.insert(history, state.search_history[i])
  end
  return history
end

--- Clear fold states
function M.clear_fold_states()
  state.fold_state = {}
  M.save()
end

-- Load state on module load
M.load()

return M
