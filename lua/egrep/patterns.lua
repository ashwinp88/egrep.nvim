-- Pattern parsing and ripgrep glob conversion
local M = {}

--- Parse a space-separated string of patterns into a table
--- @param pattern_string string Space-separated patterns
--- @return table List of patterns
function M.parse_patterns(pattern_string)
  if not pattern_string or pattern_string == "" then
    return {}
  end

  local patterns = {}
  -- Split by whitespace
  for pattern in pattern_string:gmatch("%S+") do
    table.insert(patterns, pattern)
  end
  return patterns
end

--- Convert include/exclude patterns to ripgrep glob arguments
--- @param include_patterns table|nil List of include patterns
--- @param exclude_patterns table|nil List of exclude patterns
--- @return table List of ripgrep arguments
function M.to_ripgrep_args(include_patterns, exclude_patterns)
  local args = {}

  -- Add include patterns as --glob arguments
  -- If no include patterns specified or contains "*", don't add any (search all)
  if include_patterns and #include_patterns > 0 then
    local has_wildcard_all = false
    for _, pattern in ipairs(include_patterns) do
      if pattern == "*" then
        has_wildcard_all = true
        break
      end
    end

    if not has_wildcard_all then
      for _, pattern in ipairs(include_patterns) do
        table.insert(args, "--glob=" .. pattern)
      end
    end
  end

  -- Add exclude patterns as negative globs
  if exclude_patterns and #exclude_patterns > 0 then
    for _, pattern in ipairs(exclude_patterns) do
      table.insert(args, "--glob=!" .. pattern)
    end
  end

  return args
end

--- Validate a pattern string
--- @param pattern string Pattern to validate
--- @return boolean, string|nil Valid, error message
function M.validate_pattern(pattern)
  if not pattern or pattern == "" then
    return false, "Pattern cannot be empty"
  end

  -- Basic validation - just check for problematic characters
  if pattern:match("[%c]") then
    return false, "Pattern contains control characters"
  end

  return true
end

--- Format patterns for display
--- @param patterns table List of patterns
--- @return string Space-separated patterns
function M.format_patterns(patterns)
  if not patterns or #patterns == 0 then
    return ""
  end
  return table.concat(patterns, " ")
end

--- Get pattern examples for help text
--- @return table List of example patterns with descriptions
function M.get_examples()
  return {
    {pattern = "*.rb", description = "All Ruby files"},
    {pattern = "*.{js,ts}", description = "JavaScript and TypeScript files"},
    {pattern = "/test/*", description = "All files in test directory"},
    {pattern = "*_test.*", description = "All test files"},
    {pattern = "lib/**/*.py", description = "All Python files in lib/ recursively"},
    {pattern = "!*.min.js", description = "Exclude minified JavaScript"},
  }
end

return M
