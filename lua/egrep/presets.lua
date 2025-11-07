-- Preset management for enhanced grep
local M = {}

-- Built-in presets
M.builtin = {
  all = {
    name = "All Files",
    description = "Search all files",
    include = {},
    exclude = {},
  },

  ruby = {
    name = "Ruby",
    description = "Ruby source files",
    include = {"*.rb", "*.rake", "Gemfile", "Rakefile", "*.gemspec"},
    exclude = {"*_test.rb", "*_spec.rb", "/test/*", "/spec/*", "/vendor/*"},
  },

  python = {
    name = "Python",
    description = "Python source files",
    include = {"*.py", "*.pyi", "requirements.txt", "setup.py", "pyproject.toml"},
    exclude = {"test_*.py", "*_test.py", "/tests/*", "__pycache__/*", "*.pyc", "/venv/*", "/.venv/*"},
  },

  javascript = {
    name = "JavaScript/TypeScript",
    description = "JavaScript and TypeScript files",
    include = {"*.js", "*.jsx", "*.ts", "*.tsx", "*.mjs", "*.cjs", "package.json"},
    exclude = {"*.min.js", "*.min.ts", "/node_modules/*", "/dist/*", "/build/*", "/.next/*"},
  },

  go = {
    name = "Go",
    description = "Go source files",
    include = {"*.go", "go.mod", "go.sum"},
    exclude = {"*_test.go", "/vendor/*", "/testdata/*"},
  },

  lua = {
    name = "Lua",
    description = "Lua files",
    include = {"*.lua"},
    exclude = {"/plugin/*", "/.deps/*"},
  },

  rust = {
    name = "Rust",
    description = "Rust source files",
    include = {"*.rs", "Cargo.toml", "Cargo.lock"},
    exclude = {"/target/*", "*.rlib"},
  },

  c_cpp = {
    name = "C/C++",
    description = "C and C++ files",
    include = {"*.c", "*.cpp", "*.cc", "*.cxx", "*.h", "*.hpp", "*.hxx"},
    exclude = {"*.o", "*.obj", "/build/*", "/bin/*"},
  },

  no_tests = {
    name = "No Tests",
    description = "Exclude all test files",
    include = {},
    exclude = {
      "/test/*",
      "/tests/*",
      "/spec/*",
      "/__tests__/*",
      "*_test.*",
      "*_spec.*",
      "test_*.*",
      "*.test.*",
      "*.spec.*",
    },
  },

  no_vendor = {
    name = "No Dependencies",
    description = "Exclude vendor and dependency directories",
    include = {},
    exclude = {
      "/vendor/*",
      "/node_modules/*",
      "/deps/*",
      "/.deps/*",
      "/target/*",
      "/venv/*",
      "/.venv/*",
      "/build/*",
      "/dist/*",
    },
  },
}

-- User custom presets
local custom_presets = {}

--- Get preset file path
--- @return string Path to presets file
local function get_presets_file()
  local data_dir = vim.fn.stdpath("data")
  return data_dir .. "/egrep-presets.json"
end

--- Load custom presets from disk
function M.load_custom()
  local presets_file = get_presets_file()
  local file = io.open(presets_file, "r")

  if not file then
    return
  end

  local content = file:read("*all")
  file:close()

  local ok, loaded = pcall(vim.json.decode, content)
  if ok and loaded then
    custom_presets = loaded
  end
end

--- Save custom presets to disk
function M.save_custom()
  local presets_file = get_presets_file()
  local file = io.open(presets_file, "w")

  if not file then
    vim.notify("Failed to save custom presets", vim.log.levels.WARN)
    return
  end

  local ok, json = pcall(vim.json.encode, custom_presets)
  if ok then
    file:write(json)
  end
  file:close()
end

--- Get a preset by key
--- @param key string Preset key
--- @return table|nil Preset data
function M.get(key)
  -- Check custom presets first
  if custom_presets[key] then
    return custom_presets[key]
  end

  -- Then check built-in
  return M.builtin[key]
end

--- Get all presets
--- @return table All presets (builtin and custom)
function M.get_all()
  local all = {}

  -- Add built-in presets
  for key, preset in pairs(M.builtin) do
    all[key] = vim.tbl_extend("force", preset, {
      key = key,
      builtin = true,
    })
  end

  -- Add custom presets
  for key, preset in pairs(custom_presets) do
    all[key] = vim.tbl_extend("force", preset, {
      key = key,
      builtin = false,
    })
  end

  return all
end

--- Get preset keys in a specific order
--- @return table List of preset keys
function M.get_ordered_keys()
  local keys = {
    "all",
    "no_tests",
    "ruby",
    "python",
    "javascript",
    "go",
    "lua",
    "rust",
    "c_cpp",
    "no_vendor",
  }

  -- Add custom preset keys
  for key in pairs(custom_presets) do
    table.insert(keys, key)
  end

  return keys
end

--- Add or update a custom preset
--- @param key string Preset key
--- @param preset table Preset data
function M.save_preset(key, preset)
  custom_presets[key] = {
    name = preset.name,
    description = preset.description or "",
    include = preset.include or {},
    exclude = preset.exclude or {},
  }
  M.save_custom()
end

--- Delete a custom preset
--- @param key string Preset key
--- @return boolean Success
function M.delete_preset(key)
  if custom_presets[key] then
    custom_presets[key] = nil
    M.save_custom()
    return true
  end
  return false
end

--- Apply a preset to current options
--- @param key string Preset key
--- @param current_opts table Current options
--- @return table Updated options
function M.apply(key, current_opts)
  local preset = M.get(key)
  if not preset then
    vim.notify("Preset not found: " .. key, vim.log.levels.WARN)
    return current_opts
  end

  return vim.tbl_extend("force", current_opts, {
    include_patterns = vim.deepcopy(preset.include),
    exclude_patterns = vim.deepcopy(preset.exclude),
  })
end

--- Merge a preset with current options (additive)
--- @param key string Preset key
--- @param current_opts table Current options
--- @return table Updated options
function M.merge(key, current_opts)
  local preset = M.get(key)
  if not preset then
    vim.notify("Preset not found: " .. key, vim.log.levels.WARN)
    return current_opts
  end

  local new_opts = vim.deepcopy(current_opts)

  -- Merge include patterns
  if not new_opts.include_patterns then
    new_opts.include_patterns = {}
  end
  for _, pattern in ipairs(preset.include) do
    if not vim.tbl_contains(new_opts.include_patterns, pattern) then
      table.insert(new_opts.include_patterns, pattern)
    end
  end

  -- Merge exclude patterns
  if not new_opts.exclude_patterns then
    new_opts.exclude_patterns = {}
  end
  for _, pattern in ipairs(preset.exclude) do
    if not vim.tbl_contains(new_opts.exclude_patterns, pattern) then
      table.insert(new_opts.exclude_patterns, pattern)
    end
  end

  return new_opts
end

-- Load custom presets on module load
M.load_custom()

return M
