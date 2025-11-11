-- Enhanced Grep - Main entry point
local ripgrep = require("egrep.ripgrep")
local ui = require("egrep.ui")
local state = require("egrep.state")
local presets = require("egrep.presets")
local patterns = require("egrep.patterns")

local M = {}

-- Plugin configuration
M.config = {
  defaults = {
    ignore_tests = true,
    use_gitignore = true,
    case_sensitive = false,
    fold_by_default = false,
    include = {},
    exclude = {"/test/*", "/spec/*", "*_test.*", "*_spec.*"},
  },
  window = {
    width = 0.8,
    height = 0.8,
  },
  search = {
    min_chars = 3,           -- Minimum characters before triggering search
    debounce_ms = 350,       -- Debounce delay for search
    auto_focus_delay_ms = 500, -- Delay before auto-focusing results
  },
  ui = {},
}

--- Setup plugin with user configuration
--- @param user_config table|nil User configuration
function M.setup(user_config)
  M.config = vim.tbl_deep_extend("force", M.config, user_config or {})

  ui.setup_ui(M.config.ui)

  -- Update default state with config
  local current_state = state.get()
  state.update(vim.tbl_extend("force", current_state, M.config.defaults))

  -- Create user commands
  vim.api.nvim_create_user_command("Egrep", function(opts)
    M.grep(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    desc = "Enhanced grep search",
  })

  vim.api.nvim_create_user_command("EgrepNoTests", function(opts)
    M.grep_no_tests(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    desc = "Enhanced grep search (exclude tests)",
  })

  vim.api.nvim_create_user_command("EgrepPreset", function(opts)
    M.grep_with_preset(opts.fargs[1], opts.fargs[2])
  end, {
    nargs = "+",
    desc = "Enhanced grep with preset",
    complete = function(arg_lead, cmdline, cursor_pos)
      local args = vim.split(cmdline, "%s+")
      if #args == 2 then
        local preset_keys = presets.get_ordered_keys()
        return vim.tbl_filter(function(key)
          return key:match("^" .. vim.pesc(arg_lead))
        end, preset_keys)
      end
      return {}
    end,
  })
end

--- Build search options from state
--- @param overrides table|nil Option overrides
--- @return table Search options
local function build_search_opts(overrides)
  local current = state.get()
  local opts = {
    case_sensitive = current.case_sensitive,
    use_gitignore = current.use_gitignore,
    include_patterns = current.last_include or {},
    exclude_patterns = current.last_exclude or {},
    search_path = current.search_path or ".",
    context_before = current.context_before or 0,
    context_after = current.context_after or 0,
    show_hidden = false,  -- Default to false
  }

  if overrides then
    opts = vim.tbl_extend("force", opts, overrides)
  end

  return opts
end

--- Execute search and update UI with results
--- @param pattern string Search pattern
--- @param opts table Search options
local function execute_search(pattern, opts)
  if not pattern or pattern == "" then
    return
  end

  -- Build search options
  local search_opts = build_search_opts(opts)

  local backend_cmd_table = ripgrep.build_command(pattern, search_opts)
  ui.set_backend_command(table.concat(backend_cmd_table, " "))

  -- Execute search
  ripgrep.search(pattern, search_opts, function(result)
    vim.schedule(function()
      if not result.success then
        vim.notify("Search failed: " .. (result.error or "Unknown error"), vim.log.levels.ERROR)
        ui.render_results({})
        return
      end

      if #result.results == 0 then
        ui.render_results({})
        return
      end

      -- Add to history
      state.add_to_history(pattern, search_opts.include_patterns, search_opts.exclude_patterns)

      -- Update UI with results
      ui.render_results(result.results)
    end)
  end)
end

--- Main grep function with unified picker UI
--- @param default_pattern string|nil Optional default pattern
--- @param opts table|nil Search options
function M.grep(default_pattern, opts)
  opts = opts or {}

  -- Create the picker with search callback
  ui.create_picker({
    default_pattern = default_pattern,
    width = math.floor(vim.o.columns * M.config.window.width),
    height = math.floor(vim.o.lines * M.config.window.height),
    include_patterns = opts.include_patterns,
    exclude_patterns = opts.exclude_patterns,
    search_config = M.config.search,
    layout = M.config.ui and M.config.ui.layout,
    on_search = function(pattern, search_opts)
      execute_search(pattern, search_opts)
    end,
  })
end

--- Grep excluding test files
--- @param default_pattern string|nil Optional default pattern
function M.grep_no_tests(default_pattern)
  local test_excludes = {
    "/test/*",
    "/tests/*",
    "/spec/*",
    "/__tests__/*",
    "*_test.*",
    "*_spec.*",
    "test_*.*",
    "*.test.*",
    "*.spec.*",
  }

  M.grep(default_pattern, {
    exclude_patterns = test_excludes,
  })
end

--- Grep with a preset
--- @param preset_key string Preset key
--- @param default_pattern string|nil Optional default pattern
function M.grep_with_preset(preset_key, default_pattern)
  local preset = presets.get(preset_key)
  if not preset then
    vim.notify("Preset not found: " .. preset_key, vim.log.levels.ERROR)
    return
  end

  M.grep(default_pattern, {
    include_patterns = preset.include,
    exclude_patterns = preset.exclude,
  })
end

--- Grep for word under cursor
function M.grep_word()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    vim.notify("No word under cursor", vim.log.levels.WARN)
    return
  end

  M.grep(word)
end

--- Grep for word under cursor (no tests)
function M.grep_word_no_tests()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    vim.notify("No word under cursor", vim.log.levels.WARN)
    return
  end

  M.grep_no_tests(word)
end

--- Repeat last search
function M.repeat_last()
  local saved = state.get()
  local last = saved.last_search
  if not last or last == "" then
    vim.notify("No previous search", vim.log.levels.WARN)
    return
  end

  M.grep(last, {
    include_patterns = saved.last_include,
    exclude_patterns = saved.last_exclude,
  })
end

--- Select from preset list
function M.select_preset()
  local all_presets = presets.get_all()
  local preset_keys = presets.get_ordered_keys()

  local items = {}
  for _, key in ipairs(preset_keys) do
    local preset = all_presets[key]
    if preset then
      table.insert(items, {
        key = key,
        display = string.format("%s - %s", preset.name, preset.description or ""),
      })
    end
  end

  vim.ui.select(items, {
    prompt = "Select preset:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then
      M.grep_with_preset(choice.key)
    end
  end)
end

--- Expose UI toggle functions for programmatic use

--- Toggle include filter input visibility
function M.toggle_include()
  require("egrep.ui").toggle_include()
end

--- Toggle exclude filter input visibility
function M.toggle_exclude()
  require("egrep.ui").toggle_exclude()
end

--- Toggle test file exclusion
function M.toggle_no_tests()
  require("egrep.ui").toggle_no_tests()
end

--- Toggle Ruby-only filter
function M.toggle_ruby_only()
  require("egrep.ui").toggle_ruby_only()
end

--- Toggle case-sensitive search
function M.toggle_case_sensitive()
  require("egrep.ui").toggle_case_sensitive()
end

--- Toggle show hidden files
function M.toggle_show_hidden()
  require("egrep.ui").toggle_show_hidden()
end

--- Show help window
function M.show_help()
  require("egrep.ui").show_help()
end

return M
