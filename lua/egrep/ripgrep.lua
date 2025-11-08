-- Ripgrep wrapper and execution
local patterns = require("egrep.patterns")
local M = {}

--- Build ripgrep command with options
--- @param search_pattern string Pattern to search for
--- @param opts table Options for ripgrep
--- @return table Command array
function M.build_command(search_pattern, opts)
  local cmd = {"rg"}

  -- Output format
  table.insert(cmd, "--json")
  table.insert(cmd, "--with-filename")
  table.insert(cmd, "--line-number")
  table.insert(cmd, "--column")

  -- Case sensitivity
  if not opts.case_sensitive then
    table.insert(cmd, "--ignore-case")
  end

  -- Show hidden files and ignore .gitignore
  if opts.show_hidden then
    table.insert(cmd, "--hidden")     -- Show hidden files (dotfiles)
    table.insert(cmd, "--no-ignore")  -- Ignore .gitignore
  end
  -- By default, respects .gitignore and hides dotfiles

  -- Follow symlinks
  table.insert(cmd, "--follow")

  -- Context lines
  if opts.context_before and opts.context_before > 0 then
    table.insert(cmd, "-B")
    table.insert(cmd, tostring(opts.context_before))
  end
  if opts.context_after and opts.context_after > 0 then
    table.insert(cmd, "-A")
    table.insert(cmd, tostring(opts.context_after))
  end

  -- Add include/exclude patterns
  local pattern_args = patterns.to_ripgrep_args(
    opts.include_patterns,
    opts.exclude_patterns
  )
  vim.list_extend(cmd, pattern_args)

  -- Add the search pattern
  table.insert(cmd, search_pattern)

  -- Add search path
  table.insert(cmd, opts.search_path or ".")

  return cmd
end

--- Parse ripgrep JSON output
--- @param line string Single line of JSON output
--- @return table|nil Parsed match data
local function parse_json_line(line)
  local ok, data = pcall(vim.json.decode, line)
  if not ok then
    return nil
  end
  return data
end

--- Group matches by file
--- @param raw_results table Raw ripgrep results
--- @return table Results grouped by file
local function group_by_file(raw_results)
  local grouped = {}
  local file_order = {}

  for _, result in ipairs(raw_results) do
    if result.type == "match" then
      local file = result.data.path.text

      -- Strip leading "./" from paths
      file = file:gsub("^%./", "")

      if not grouped[file] then
        grouped[file] = {
          path = file,
          matches = {},
        }
        table.insert(file_order, file)
      end

      table.insert(grouped[file].matches, {
        line_number = result.data.line_number,
        column = result.data.submatches[1] and result.data.submatches[1].start or 0,
        text = result.data.lines.text,
        submatches = result.data.submatches,
      })
    end
  end

  -- Convert to ordered array
  local ordered = {}
  for _, file in ipairs(file_order) do
    table.insert(ordered, grouped[file])
  end

  return ordered
end

--- Execute ripgrep asynchronously using vim.system
--- @param search_pattern string Pattern to search for
--- @param opts table Search options
--- @param callback function Callback with results
function M.search(search_pattern, opts, callback)
  local cmd = M.build_command(search_pattern, opts)

  -- Use vim.system for async execution (Neovim 0.10+)
  if vim.system then
    vim.system(cmd, {
      text = true,
    }, function(result)
      vim.schedule(function()
        if result.code ~= 0 and result.code ~= 1 then
          callback({
            success = false,
            error = result.stderr or "Unknown error",
            code = result.code,
          })
          return
        end

        -- Parse JSON output
        local raw_results = {}
        for line in result.stdout:gmatch("[^\r\n]+") do
          local parsed = parse_json_line(line)
          if parsed then
            table.insert(raw_results, parsed)
          end
        end

        local grouped = group_by_file(raw_results)
        callback({
          success = true,
          results = grouped,
          total_files = #grouped,
          total_matches = #raw_results,
        })
      end)
    end)
  else
    -- Fallback to synchronous execution for older Neovim
    vim.schedule(function()
      local result = M.search_sync(search_pattern, opts)
      callback(result)
    end)
  end
end

--- Execute ripgrep synchronously
--- @param search_pattern string Pattern to search for
--- @param opts table Search options
--- @return table Results
function M.search_sync(search_pattern, opts)
  local cmd = M.build_command(search_pattern, opts)
  local cmd_string = table.concat(vim.tbl_map(function(arg)
    if arg:match(" ") then
      return string.format('"%s"', arg)
    end
    return arg
  end, cmd), " ")

  local output = vim.fn.system(cmd_string)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 and exit_code ~= 1 then
    return {
      success = false,
      error = output,
      code = exit_code,
    }
  end

  -- Parse JSON output
  local raw_results = {}
  for line in output:gmatch("[^\r\n]+") do
    local parsed = parse_json_line(line)
    if parsed then
      table.insert(raw_results, parsed)
    end
  end

  local grouped = group_by_file(raw_results)
  return {
    success = true,
    results = grouped,
    total_files = #grouped,
    total_matches = #raw_results,
  }
end

return M
