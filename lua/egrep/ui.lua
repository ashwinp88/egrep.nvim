-- Redesigned unified picker UI for enhanced grep with preview pane
local state = require("egrep.state")
local patterns = require("egrep.patterns")
local tree_module = require("egrep.tree")

local M = {}


-- UI state
local ui_state = {
  -- Main results window
  main_buf = nil,
  main_win = nil,
  -- Three input windows
  input_buf = nil,
  input_win = nil,
  include_buf = nil,
  include_win = nil,
  exclude_buf = nil,
  exclude_win = nil,
  -- Options and preview windows
  options_buf = nil,
  options_win = nil,
  preview_buf = nil,
  preview_win = nil,
  -- State tracking
  results = {},
  tree = nil,  -- NuiTree instance
  folder_state = {},  -- Track folder expand/collapse
  search_timer = nil,
  focus_timer = nil,
  current_search = "",
  current_include = "",
  current_exclude = "",
  include_patterns = {},
  exclude_patterns = {},
  on_search_callback = nil,
  current_preview_file = nil,
  current_focused_input = nil,
  search_config = nil,
  -- Options state
  ruby_only = false,
  show_hidden = false,
}

-- Icons
local icons = {
  expanded = "▼",
  collapsed = "▶",
  match = "  ",
  checked = "[✓]",
  unchecked = "[ ]",
  folder_open = "",
  folder_closed = "",
}

-- Try to load devicons
local has_devicons, devicons = pcall(require, "nvim-web-devicons")
if not has_devicons then
  devicons = nil
end

-- Highlight groups
local function setup_highlights()
  vim.api.nvim_set_hl(0, "EgrepFile", {link = "Directory", default = true})
  vim.api.nvim_set_hl(0, "EgrepMatch", {link = "String", default = true})
  vim.api.nvim_set_hl(0, "EgrepLineNr", {link = "LineNr", default = true})
  vim.api.nvim_set_hl(0, "EgrepIcon", {link = "Special", default = true})
  vim.api.nvim_set_hl(0, "EgrepCount", {link = "Number", default = true})
  vim.api.nvim_set_hl(0, "EgrepPrompt", {link = "Title", default = true})
  vim.api.nvim_set_hl(0, "EgrepBorder", {link = "FloatBorder", default = true})
  vim.api.nvim_set_hl(0, "EgrepPreviewHighlight", {link = "CursorLine", default = true})
  vim.api.nvim_set_hl(0, "EgrepActiveInput", {link = "CursorLine", default = true})
  vim.api.nvim_set_hl(0, "EgrepInactiveInput", {link = "Normal", default = true})
  vim.api.nvim_set_hl(0, "EgrepSeparator", {link = "Comment", default = true})
end

-- Forward declarations
local trigger_search
local render_options

--- Close the picker
function M.close()
  if ui_state.search_timer then
    vim.fn.timer_stop(ui_state.search_timer)
    ui_state.search_timer = nil
  end

  if ui_state.focus_timer then
    vim.fn.timer_stop(ui_state.focus_timer)
    ui_state.focus_timer = nil
  end

  -- Clean up autocmd group
  pcall(vim.api.nvim_del_augroup_by_name, "EgrepFocus")

  -- Close all windows
  local windows = {
    ui_state.input_win,
    ui_state.include_win,
    ui_state.exclude_win,
    ui_state.options_win,
    ui_state.main_win,
    ui_state.preview_win,
  }

  for _, win in ipairs(windows) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Reset state
  ui_state = {
    main_buf = nil,
    main_win = nil,
    input_buf = nil,
    input_win = nil,
    include_buf = nil,
    include_win = nil,
    exclude_buf = nil,
    exclude_win = nil,
    options_buf = nil,
    options_win = nil,
    preview_buf = nil,
    preview_win = nil,
    results = {},
    tree = nil,
    folder_state = {},
    search_timer = nil,
    focus_timer = nil,
    current_search = "",
    current_include = "",
    current_exclude = "",
    include_patterns = {},
    exclude_patterns = {},
    on_search_callback = nil,
    current_preview_file = nil,
    current_focused_input = nil,
    search_config = nil,
    ruby_only = false,
    show_hidden = false,
  }
end

--- Update preview pane with file content
--- @param file string|nil File path
--- @param line_number number|nil Line to highlight
local function update_preview(file, line_number)
  if not ui_state.preview_buf or not vim.api.nvim_buf_is_valid(ui_state.preview_buf) then
    return
  end

  if not file or file == "" then
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(ui_state.preview_buf, 0, -1, false, {"No preview available"})
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", false)
    return
  end

  ui_state.current_preview_file = file

  -- Read file contents
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok or not lines then
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(ui_state.preview_buf, 0, -1, false, {"Error reading file: " .. file})
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", false)
    return
  end

  -- Set file contents
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.preview_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", false)

  -- Set filetype for syntax highlighting
  local ft = vim.filetype.match({filename = file})
  if ft then
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "filetype", ft)
  end

  -- Highlight and scroll to line
  if line_number and ui_state.preview_win and vim.api.nvim_win_is_valid(ui_state.preview_win) then
    -- Center on the line
    pcall(vim.api.nvim_win_set_cursor, ui_state.preview_win, {line_number, 0})
    vim.api.nvim_win_call(ui_state.preview_win, function()
      vim.cmd("normal! zz")
    end)

    -- Add highlight for the line
    local ns_id = vim.api.nvim_create_namespace("egrep_preview")
    vim.api.nvim_buf_clear_namespace(ui_state.preview_buf, ns_id, 0, -1)
    vim.api.nvim_buf_add_highlight(ui_state.preview_buf, ns_id, "EgrepPreviewHighlight", line_number - 1, 0, -1)
  end
end

--- Update preview based on cursor position
function M.update_preview_from_cursor()
  if not ui_state.main_buf or not ui_state.main_win or not ui_state.tree then
    return
  end

  -- Validate window is still valid
  if not vim.api.nvim_win_is_valid(ui_state.main_win) then
    return
  end

  -- Get current node from tree
  local line_num = vim.api.nvim_win_get_cursor(ui_state.main_win)[1]
  local node = ui_state.tree:get_node(line_num)

  if not node then
    return
  end

  -- Check node type and update preview accordingly
  if node.type == "match" then
    update_preview(node.file, node.line_number)
  elseif node.type == "file" then
    update_preview(node.path, nil)
  elseif node.type == "folder" then
    -- Don't preview folders
    return
  end
end

--- Render results in main buffer with folder hierarchy using NuiTree
function M.render_results(results)
  if not ui_state.main_buf or not vim.api.nvim_buf_is_valid(ui_state.main_buf) then
    return
  end

  -- Save cursor position and current node path before re-render
  local saved_cursor_line = nil
  local saved_node_path = nil
  local saved_node_type = nil

  if ui_state.main_win and vim.api.nvim_win_is_valid(ui_state.main_win) and ui_state.tree then
    saved_cursor_line = vim.api.nvim_win_get_cursor(ui_state.main_win)[1]

    -- Get node at current cursor line
    local current_node = ui_state.tree:get_node(saved_cursor_line)

    if current_node then
      saved_node_path = current_node.path or current_node.file
      saved_node_type = current_node.type

      local logfile = io.open("/tmp/egrep_restore.log", "a")
      if logfile then
        logfile:write(string.format("[SAVE] Line %d: path='%s' type='%s'\n",
          saved_cursor_line, saved_node_path, saved_node_type))
        logfile:close()
      end
    end
  end

  ui_state.results = results or {}

  -- Calculate totals
  local total_files = #ui_state.results
  local total_matches = 0
  for _, file_data in ipairs(ui_state.results) do
    total_matches = total_matches + #file_data.matches
  end

  if total_files == 0 then
    -- No results
    vim.api.nvim_buf_set_option(ui_state.main_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(ui_state.main_buf, 0, -1, false, {
      "No results found",
      "",
      "Try adjusting your search pattern or filters"
    })
    vim.api.nvim_buf_set_option(ui_state.main_buf, "modifiable", false)
    ui_state.tree = nil
  else
    -- Create NuiTree instance and render
    if ui_state.main_win and vim.api.nvim_win_is_valid(ui_state.main_win) then
      -- Clear buffer and prepare for new render
      vim.api.nvim_buf_set_option(ui_state.main_buf, "modifiable", true)
      vim.api.nvim_buf_set_lines(ui_state.main_buf, 0, -1, false, {})

      -- Create and render tree
      ui_state.tree = tree_module.create_tree(ui_state.results, ui_state.main_win, ui_state.folder_state)
      ui_state.tree:render()

      -- Lock buffer but keep it non-readonly (to allow programmatic changes)
      vim.api.nvim_buf_set_option(ui_state.main_buf, "modifiable", false)
      vim.api.nvim_buf_set_option(ui_state.main_buf, "readonly", false)

      -- Restore cursor position after re-render
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(ui_state.main_win) then
          return
        end

        if saved_node_path and ui_state.tree then
          local logfile = io.open("/tmp/egrep_restore.log", "a")
          if logfile then
            logfile:write(string.format("\n[RESTORE] Looking for: path='%s' type='%s'\n", saved_node_path, saved_node_type))
          end

          -- Try to find the same node and position cursor there
          local found = false
          local max_line = vim.api.nvim_buf_line_count(ui_state.main_buf)
          if logfile then
            logfile:write(string.format("[RESTORE] Max lines: %d\n", max_line))
          end

          -- Search all lines for matching node
          for line_num = 1, max_line do
            -- Get node at this line
            local node = ui_state.tree:get_node(line_num)

            -- Check if this is the node we're looking for
            if node then
              local node_path = node.path or node.file
              if logfile then
                logfile:write(string.format("[RESTORE] Line %d: path='%s' type='%s' | Match: %s\n",
                  line_num, node_path or "nil", node.type,
                  tostring(node_path == saved_node_path and node.type == saved_node_type)))
              end

              if node_path == saved_node_path and node.type == saved_node_type then
                -- Found it! Set cursor to this line
                vim.api.nvim_win_set_cursor(ui_state.main_win, {line_num, 0})
                if logfile then
                  logfile:write(string.format("[RESTORE] MATCH at line %d\n", line_num))
                end
                found = true
                break
              end
            else
              if logfile then
                logfile:write(string.format("[RESTORE] Line %d: NO NODE\n", line_num))
              end
            end
          end

          if not found then
            if logfile then
              logfile:write("[RESTORE] NOT FOUND - using fallback\n")
            end
          end

          -- If node not found, try to restore approximate line position
          if not found and saved_cursor_line then
            local target_line = math.max(saved_cursor_line, 1)
            target_line = math.min(target_line, max_line)
            if logfile then
              logfile:write(string.format("[RESTORE] Fallback to line %d\n", target_line))
            end
            vim.api.nvim_win_set_cursor(ui_state.main_win, {target_line, 0})
          end

          if logfile then
            logfile:close()
          end
        elseif saved_cursor_line then
          -- No saved node path, just restore approximate line
          local max_line = vim.api.nvim_buf_line_count(ui_state.main_buf)
          local target_line = math.max(saved_cursor_line, 1)
          target_line = math.min(target_line, max_line)
          vim.api.nvim_win_set_cursor(ui_state.main_win, {target_line, 0})
        else
          -- No saved position, put cursor on first line
          vim.api.nvim_win_set_cursor(ui_state.main_win, {1, 0})
        end

        -- Force update preview after cursor restore
        M.update_preview_from_cursor()
      end)
    end
  end
end

--- Right arrow: expand if collapsed, move to first child if expanded
function M.toggle_fold()
  if not ui_state.tree then
    return
  end

  local line_num = vim.api.nvim_win_get_cursor(ui_state.main_win)[1]
  local node = ui_state.tree:get_node(line_num)

  if not node then
    return
  end

  -- Handle based on node type and expansion state
  if node.type == "folder" or node.type == "file" then
    if node:is_expanded() then
      -- Already expanded, move to first child
      local child_ids = node:get_child_ids()
      if child_ids and #child_ids > 0 then
        -- Get current cursor position
        local cursor = vim.api.nvim_win_get_cursor(ui_state.main_win)
        local current_line = cursor[1]

        -- Move cursor down one line (to first child)
        vim.api.nvim_win_set_cursor(ui_state.main_win, {current_line + 1, 0})
        M.update_preview_from_cursor()
      end
    else
      -- Collapsed, expand it
      if node.type == "folder" then
        -- Just update state - don't call node:expand()
        -- Let render_results() rebuild the tree with proper expansion
        ui_state.folder_state[node.path] = true
      else -- file
        state.set_fold_state(node.path, true)
      end
      M.render_results(ui_state.results)
    end
  end
end

--- Left arrow: collapse and move to parent based on node type
function M.collapse_parent()
  if not ui_state.tree then
    return
  end

  local line_num = vim.api.nvim_win_get_cursor(ui_state.main_win)[1]
  local node = ui_state.tree:get_node(line_num)

  if not node then
    return
  end

  -- Helper function to move cursor to parent node
  local function move_to_parent()
    local parent_id = node:get_parent_id()
    if not parent_id then
      return false
    end

    local parent_node = ui_state.tree:get_node(parent_id)
    if not parent_node then
      return false
    end

    -- Find the line number of the parent node
    local lines = vim.api.nvim_buf_get_lines(ui_state.main_buf, 0, -1, false)
    for line_num = 1, #lines do
      local line_node = ui_state.tree:get_node(line_num)
      if line_node and line_node:get_id() == parent_id then
        vim.api.nvim_win_set_cursor(ui_state.main_win, {line_num, 0})
        M.update_preview_from_cursor()
        return true
      end
    end
    return false
  end

  -- Match node: collapse parent file and move to it
  if node.type == "match" then
    local parent_id = node:get_parent_id()
    if parent_id then
      local parent_node = ui_state.tree:get_node(parent_id)
      if parent_node and parent_node.type == "file" then
        -- Collapse the file
        state.set_fold_state(parent_node.path, false)
        M.render_results(ui_state.results)
        -- Move to the file after re-render
        vim.schedule(function()
          move_to_parent()
        end)
      end
    end
    return
  end

  -- File or Folder node
  if node.type == "folder" or node.type == "file" then
    -- If expanded: collapse it
    if node:is_expanded() then
      if node.type == "folder" then
        -- Just update state - don't call node:collapse()
        ui_state.folder_state[node.path] = false
      else -- file
        state.set_fold_state(node.path, false)
      end
      M.render_results(ui_state.results)
    else
      -- If collapsed: collapse parent and move to it
      local parent_id = node:get_parent_id()
      if parent_id then
        local parent_node = ui_state.tree:get_node(parent_id)
        if parent_node then
          -- Collapse parent - just update state
          if parent_node.type == "folder" then
            ui_state.folder_state[parent_node.path] = false
          elseif parent_node.type == "file" then
            state.set_fold_state(parent_node.path, false)
          end
          M.render_results(ui_state.results)
          -- Move to parent after re-render
          vim.schedule(function()
            move_to_parent()
          end)
        end
      end
    end
  end
end

--- Jump to match or file under cursor, or toggle folder
function M.jump_to_match()
  if not ui_state.tree then
    return
  end

  local line_num = vim.api.nvim_win_get_cursor(ui_state.main_win)[1]
  local node = ui_state.tree:get_node(line_num)

  if not node then
    return
  end

  -- Check if it's a folder - toggle expand/collapse
  if node.type == "folder" then
    -- Just update state - don't call node methods
    if node:is_expanded() then
      ui_state.folder_state[node.path] = false
    else
      ui_state.folder_state[node.path] = true
    end
    M.render_results(ui_state.results)
    return
  end

  -- Check if it's a match
  if node.type == "match" then
    M.close()
    vim.cmd("edit " .. vim.fn.fnameescape(node.file))
    vim.api.nvim_win_set_cursor(0, {node.line_number, node.column})
    vim.cmd("normal! zz")
    return
  end

  -- Check if it's a file
  if node.type == "file" then
    M.close()
    vim.cmd("edit " .. vim.fn.fnameescape(node.path))
    return
  end
end

--- Expand all folds
function M.expand_all()
  for _, file_data in ipairs(ui_state.results) do
    state.set_fold_state(file_data.path, true)
  end
  M.render_results(ui_state.results)
end

--- Collapse all folds
function M.collapse_all()
  for _, file_data in ipairs(ui_state.results) do
    state.set_fold_state(file_data.path, false)
  end
  M.render_results(ui_state.results)
end

--- Export to quickfix
function M.to_quickfix()
  local qf_list = {}

  for _, file_data in ipairs(ui_state.results) do
    for _, match in ipairs(file_data.matches) do
      table.insert(qf_list, {
        filename = file_data.path,
        lnum = match.line_number,
        col = match.column + 1,
        text = match.text,
      })
    end
  end

  vim.fn.setqflist(qf_list, "r")
  M.close()
  vim.cmd("copen")
  vim.notify(string.format("Exported %d matches to quickfix", #qf_list), vim.log.levels.INFO)
end

--- Update input field highlights based on focus
local function update_input_highlights()
  local current_win = vim.api.nvim_get_current_win()

  -- Update window highlights based on focus
  if ui_state.input_win and vim.api.nvim_win_is_valid(ui_state.input_win) then
    local hl = current_win == ui_state.input_win and "EgrepActiveInput" or "EgrepInactiveInput"
    -- Include FloatBorder and FloatTitle to preserve title rendering
    vim.api.nvim_win_set_option(ui_state.input_win, "winhl",
      "Normal:" .. hl .. ",FloatBorder:FloatBorder,FloatTitle:FloatTitle")
  end

  if ui_state.include_win and vim.api.nvim_win_is_valid(ui_state.include_win) then
    local hl = current_win == ui_state.include_win and "EgrepActiveInput" or "EgrepInactiveInput"
    vim.api.nvim_win_set_option(ui_state.include_win, "winhl",
      "Normal:" .. hl .. ",FloatBorder:FloatBorder,FloatTitle:FloatTitle")
  end

  if ui_state.exclude_win and vim.api.nvim_win_is_valid(ui_state.exclude_win) then
    local hl = current_win == ui_state.exclude_win and "EgrepActiveInput" or "EgrepInactiveInput"
    vim.api.nvim_win_set_option(ui_state.exclude_win, "winhl",
      "Normal:" .. hl .. ",FloatBorder:FloatBorder,FloatTitle:FloatTitle")
  end
end

--- Move to next input field
function M.next_input()
  local current_win = vim.api.nvim_get_current_win()

  if current_win == ui_state.input_win then
    vim.api.nvim_set_current_win(ui_state.include_win)
    vim.cmd("startinsert!")
  elseif current_win == ui_state.include_win then
    vim.api.nvim_set_current_win(ui_state.exclude_win)
    vim.cmd("startinsert!")
  elseif current_win == ui_state.exclude_win then
    vim.cmd("stopinsert")  -- Exit insert mode before moving to results
    vim.api.nvim_set_current_win(ui_state.main_win)
  else
    vim.api.nvim_set_current_win(ui_state.input_win)
    vim.cmd("startinsert!")
  end

  update_input_highlights()
  vim.schedule(function() vim.cmd("redraw") end)
end

--- Move to previous input field
function M.prev_input()
  local current_win = vim.api.nvim_get_current_win()

  if current_win == ui_state.exclude_win then
    vim.api.nvim_set_current_win(ui_state.include_win)
    vim.cmd("startinsert!")
  elseif current_win == ui_state.include_win then
    vim.api.nvim_set_current_win(ui_state.input_win)
    vim.cmd("startinsert!")
  elseif current_win == ui_state.input_win then
    vim.api.nvim_set_current_win(ui_state.exclude_win)
    vim.cmd("startinsert!")
  elseif current_win == ui_state.main_win then
    -- Going back from results to input
    vim.api.nvim_set_current_win(ui_state.exclude_win)
    vim.cmd("startinsert!")
  else
    vim.api.nvim_set_current_win(ui_state.input_win)
    vim.cmd("startinsert!")
  end

  update_input_highlights()
  vim.schedule(function() vim.cmd("redraw") end)
end

--- Toggle "No Tests" filter
function M.toggle_no_tests()
  local current = state.get()
  local new_value = not current.ignore_tests
  state.update({ignore_tests = new_value})

  -- Don't modify the exclude input buffer - the toggle works behind the scenes
  -- The test patterns will be added during ripgrep command building

  render_options()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Toggle Ruby only filter
function M.toggle_ruby_only()
  ui_state.ruby_only = not ui_state.ruby_only

  -- Don't modify the include input buffer - the toggle works behind the scenes
  -- The Ruby pattern will be added during ripgrep command building

  render_options()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Toggle case sensitivity
function M.toggle_case_sensitive()
  local current = state.get()
  state.update({case_sensitive = not current.case_sensitive})
  render_options()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Toggle show hidden files
function M.toggle_show_hidden()
  ui_state.show_hidden = not ui_state.show_hidden
  render_options()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Render options line
render_options = function()
  if not ui_state.options_buf or not vim.api.nvim_buf_is_valid(ui_state.options_buf) then
    return
  end

  local current = state.get()
  local no_tests_icon = current.ignore_tests and icons.checked or icons.unchecked
  local ruby_only_icon = ui_state.ruby_only and icons.checked or icons.unchecked
  local case_icon = current.case_sensitive and icons.checked or icons.unchecked
  local hidden_icon = ui_state.show_hidden and icons.checked or icons.unchecked

  local line = string.format(
    " %s No Tests (F1)   %s Ruby Only (F2)   %s Case Sensitive (F3)   %s Show Hidden (F4)   Help (?)",
    no_tests_icon,
    ruby_only_icon,
    case_icon,
    hidden_icon
  )

  vim.api.nvim_buf_set_option(ui_state.options_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.options_buf, 0, -1, false, {line})
  vim.api.nvim_buf_set_option(ui_state.options_buf, "modifiable", false)
end

--- Show help
function M.show_help()
  local help_text = {
    "Enhanced Grep Keybindings:",
    "",
    "Input Navigation:",
    "  <Tab>/<C-n>    - Next input field",
    "  <S-Tab>/<C-p>  - Previous input field",
    "  <CR>           - Execute search and focus results",
    "",
    "Results Navigation:",
    "  <CR>           - Jump to match/file or toggle folder",
    "  <Double-Click> - Jump to match/file or toggle folder",
    "  <Right>        - Expand (if collapsed) or move to first child",
    "  <Left>         - Collapse (if expanded) or move to parent",
    "  za             - Toggle fold",
    "  zR             - Expand all folds",
    "  zM             - Collapse all folds",
    "  i              - Return to search input",
    "",
    "Quick Options:",
    "  F1             - Toggle 'No Tests' filter",
    "  F2             - Toggle 'Ruby Only' filter",
    "  F3             - Toggle case sensitivity",
    "  F4             - Toggle show hidden/git-ignored files",
    "",
    "Actions:",
    "  <C-q>          - Send to quickfix list",
    "  q/<Esc>        - Close picker",
    "  ?              - Show this help",
    "",
    "Tips:",
    "  - All inputs support live search (300ms delay)",
    "  - Use wildcards: *.rb, /test/*, **/*.lua",
    "  - Preview updates as you navigate results",
    "  - Files are collapsed by default (press Right arrow to expand)",
    "  - F1-F3 work in both insert and normal mode",
  }

  vim.notify(table.concat(help_text, "\n"), vim.log.levels.INFO, {title = "Enhanced Grep Help"})
end

--- Trigger search from inputs
--- @param force boolean|nil Force search even if inputs haven't changed
trigger_search = function(force)
  if not ui_state.input_buf or not vim.api.nvim_buf_is_valid(ui_state.input_buf) then
    return
  end

  -- Save previous values for comparison
  local prev_search = ui_state.current_search
  local prev_include = ui_state.current_include
  local prev_exclude = ui_state.current_exclude

  -- Get search pattern (from line 2, index 1)
  local pattern_lines = vim.api.nvim_buf_get_lines(ui_state.input_buf, 1, 2, false)
  local pattern = (pattern_lines[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")

  -- Get include patterns (from line 2, index 1)
  local include_str = ""
  if ui_state.include_buf and vim.api.nvim_buf_is_valid(ui_state.include_buf) then
    local include_lines = vim.api.nvim_buf_get_lines(ui_state.include_buf, 1, 2, false)
    include_str = (include_lines[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  -- Get exclude patterns (from line 2, index 1)
  local exclude_str = ""
  if ui_state.exclude_buf and vim.api.nvim_buf_is_valid(ui_state.exclude_buf) then
    local exclude_lines = vim.api.nvim_buf_get_lines(ui_state.exclude_buf, 1, 2, false)
    exclude_str = (exclude_lines[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  -- Check if anything changed (unless force is true)
  if not force and pattern == prev_search and include_str == prev_include and exclude_str == prev_exclude then
    return
  end

  -- Update state with new values
  ui_state.current_search = pattern
  ui_state.current_include = include_str
  ui_state.current_exclude = exclude_str
  ui_state.include_patterns = patterns.parse_patterns(include_str)
  ui_state.exclude_patterns = patterns.parse_patterns(exclude_str)

  if pattern == "" then
    M.render_results({})
    return
  end

  -- Call the search callback
  if ui_state.on_search_callback then
    -- Merge toggle patterns with user-typed patterns
    local final_include = vim.deepcopy(ui_state.include_patterns)
    local final_exclude = vim.deepcopy(ui_state.exclude_patterns)

    -- Add test patterns if "no tests" is enabled
    local current = state.get()
    if current.ignore_tests then
      local test_patterns = {
        "/test/*", "/tests/*", "/spec/*", "/__tests__/*",
        "*_test.*", "*_spec.*", "test_*.*", "*.test.*", "*.spec.*"
      }
      for _, test_pattern in ipairs(test_patterns) do
        if not vim.tbl_contains(final_exclude, test_pattern) then
          table.insert(final_exclude, test_pattern)
        end
      end
    end

    -- Add *.rb pattern if "ruby only" is enabled
    if ui_state.ruby_only then
      if not vim.tbl_contains(final_include, "*.rb") then
        table.insert(final_include, "*.rb")
      end
    end

    ui_state.on_search_callback(pattern, {
      include_patterns = final_include,
      exclude_patterns = final_exclude,
      show_hidden = ui_state.show_hidden,
    })
  end
end

--- Auto-focus results window
local function auto_focus_results()
  if ui_state.main_win and vim.api.nvim_win_is_valid(ui_state.main_win) then
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(ui_state.main_win)
    update_input_highlights()
  end
end

--- Debounced search trigger with min chars check
local function trigger_search_debounced()
  -- Stop existing timers
  if ui_state.search_timer then
    vim.fn.timer_stop(ui_state.search_timer)
    ui_state.search_timer = nil
  end
  if ui_state.focus_timer then
    vim.fn.timer_stop(ui_state.focus_timer)
    ui_state.focus_timer = nil
  end

  -- Get current search pattern to check length
  if not ui_state.input_buf or not vim.api.nvim_buf_is_valid(ui_state.input_buf) then
    return
  end

  local pattern_lines = vim.api.nvim_buf_get_lines(ui_state.input_buf, 1, 2, false)
  local pattern = (pattern_lines[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")

  local min_chars = ui_state.search_config and ui_state.search_config.min_chars or 3
  local debounce_ms = ui_state.search_config and ui_state.search_config.debounce_ms or 350
  local auto_focus_delay_ms = ui_state.search_config and ui_state.search_config.auto_focus_delay_ms or 500

  -- Only trigger search if we have minimum characters
  if #pattern >= min_chars then
    -- Schedule search after debounce delay
    ui_state.search_timer = vim.fn.timer_start(debounce_ms, function()
      vim.schedule(trigger_search)
    end)

    -- Schedule auto-focus after longer delay
    ui_state.focus_timer = vim.fn.timer_start(auto_focus_delay_ms, function()
      vim.schedule(auto_focus_results)
    end)
  elseif #pattern == 0 then
    -- Clear results immediately if pattern is empty
    vim.schedule(function()
      M.render_results({})
    end)
  end
end

--- Trigger search and focus immediately (for Enter key)
local function trigger_search_and_focus()
  -- Stop existing timers
  if ui_state.search_timer then
    vim.fn.timer_stop(ui_state.search_timer)
    ui_state.search_timer = nil
  end
  if ui_state.focus_timer then
    vim.fn.timer_stop(ui_state.focus_timer)
    ui_state.focus_timer = nil
  end

  -- Trigger search immediately
  trigger_search()

  -- Focus results immediately
  auto_focus_results()
end

--- Set up keymaps for input buffers
local function setup_input_keymaps(buf)
  local keymaps = {
    {"i", "<Tab>", M.next_input, {desc = "Next input"}},
    {"i", "<S-Tab>", M.prev_input, {desc = "Previous input"}},
    {"i", "<C-n>", M.next_input, {desc = "Next input"}},
    {"i", "<C-p>", M.prev_input, {desc = "Previous input"}},
    {"i", "<CR>", trigger_search_and_focus, {desc = "Search and focus results"}},
    {"i", "<Esc>", function()
      M.close()
    end, {desc = "Close"}},
    {"i", "<C-c>", function()
      M.close()
    end, {desc = "Close"}},
    {"n", "<Esc>", function()
      M.close()
    end, {desc = "Close"}},
    {"n", "q", function()
      M.close()
    end, {desc = "Close"}},
    {"n", "?", M.show_help, {desc = "Show help"}},
    {"n", "<F1>", M.toggle_no_tests, {desc = "Toggle no tests"}},
    {"i", "<F1>", M.toggle_no_tests, {desc = "Toggle no tests"}},
    {"n", "<F2>", M.toggle_ruby_only, {desc = "Toggle Ruby only"}},
    {"i", "<F2>", M.toggle_ruby_only, {desc = "Toggle Ruby only"}},
    {"n", "<F3>", M.toggle_case_sensitive, {desc = "Toggle case sensitive"}},
    {"i", "<F3>", M.toggle_case_sensitive, {desc = "Toggle case sensitive"}},
    {"n", "<F4>", M.toggle_show_hidden, {desc = "Toggle show hidden"}},
    {"i", "<F4>", M.toggle_show_hidden, {desc = "Toggle show hidden"}},
  }

  for _, keymap in ipairs(keymaps) do
    vim.keymap.set(keymap[1], keymap[2], keymap[3],
      vim.tbl_extend("force", keymap[4], {buffer = buf, nowait = true}))
  end
end

--- Create the unified picker UI with preview pane
function M.create_picker(opts)
  opts = opts or {}

  -- Load saved state
  local saved_state = state.get()
  ui_state.include_patterns = opts.include_patterns or saved_state.last_include or {}
  ui_state.exclude_patterns = opts.exclude_patterns or saved_state.last_exclude or {}
  ui_state.on_search_callback = opts.on_search
  ui_state.search_config = opts.search_config

  -- Calculate dimensions
  local total_width = opts.width or math.floor(vim.o.columns * 0.9)
  local total_height = opts.height or math.floor(vim.o.lines * 0.9)
  local row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - total_width) / 2)

  -- Layout calculations
  local input_section_height = 11  -- 3 input windows (2 lines + border) + 1 options window = 11
  local results_height = total_height - input_section_height
  local results_width = math.floor(total_width * 0.5)
  local preview_width = total_width - results_width - 4  -- -4 for both sets of borders (2 each)

  -- Create search pattern buffer with label line
  ui_state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.input_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.input_buf, "buftype", "")
  vim.api.nvim_buf_set_option(ui_state.input_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.input_buf, 0, -1, false, {"Search Pattern:", opts.default_pattern or ""})
  vim.api.nvim_buf_call(ui_state.input_buf, function()
    vim.fn.matchadd("Comment", "\\%1l")  -- Highlight first line as comment
  end)

  -- Create include pattern buffer with label line
  ui_state.include_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.include_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.include_buf, "buftype", "")
  vim.api.nvim_buf_set_option(ui_state.include_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.include_buf, 0, -1, false, {"Include Patterns:", patterns.format_patterns(ui_state.include_patterns)})
  vim.api.nvim_buf_call(ui_state.include_buf, function()
    vim.fn.matchadd("Comment", "\\%1l")
  end)

  -- Create exclude pattern buffer with label line
  ui_state.exclude_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.exclude_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.exclude_buf, "buftype", "")
  vim.api.nvim_buf_set_option(ui_state.exclude_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.exclude_buf, 0, -1, false, {"Exclude Patterns:", patterns.format_patterns(ui_state.exclude_patterns)})
  vim.api.nvim_buf_call(ui_state.exclude_buf, function()
    vim.fn.matchadd("Comment", "\\%1l")
  end)

  -- Create options buffer
  ui_state.options_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.options_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.options_buf, "modifiable", false)

  -- Create main results buffer
  ui_state.main_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.main_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.main_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(ui_state.main_buf, "filetype", "egrep")
  vim.api.nvim_buf_set_option(ui_state.main_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(ui_state.main_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(ui_state.main_buf, "readonly", false)

  -- Create preview buffer
  ui_state.preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "swapfile", false)

  -- Create input windows with proper borders (now 2 lines high with labels)
  -- Search Pattern window
  ui_state.input_win = vim.api.nvim_open_win(ui_state.input_buf, true, {
    relative = "editor",
    width = total_width,
    height = 2,
    row = row,
    col = col,
    style = "minimal",
    border = {"╭", "─", "╮", "│", "╯", "─", "╰", "│"},
  })
  -- Position cursor on line 2 (the input line)
  vim.api.nvim_win_set_cursor(ui_state.input_win, {2, 0})

  -- Include pattern window
  ui_state.include_win = vim.api.nvim_open_win(ui_state.include_buf, false, {
    relative = "editor",
    width = total_width,
    height = 2,
    row = row + 3,  -- +3 for 2 lines + 1 border of previous window
    col = col,
    style = "minimal",
    border = {"╭", "─", "╮", "│", "╯", "─", "╰", "│"},
  })

  -- Exclude pattern window
  ui_state.exclude_win = vim.api.nvim_open_win(ui_state.exclude_buf, false, {
    relative = "editor",
    width = total_width,
    height = 2,
    row = row + 6,  -- +3 for each previous window (2 lines + border)
    col = col,
    style = "minimal",
    border = {"╭", "─", "╮", "│", "╯", "─", "╰", "│"},
  })

  -- Options window
  ui_state.options_win = vim.api.nvim_open_win(ui_state.options_buf, false, {
    relative = "editor",
    width = total_width,
    height = 1,
    row = row + 9,  -- +3 for each previous 2-line window with border
    col = col,
    style = "minimal",
    border = {"╭", "─", "╮", "│", "╯", "─", "╰", "│"},
  })

  -- Create results window (left side, below input section)
  ui_state.main_win = vim.api.nvim_open_win(ui_state.main_buf, false, {
    relative = "editor",
    width = results_width,
    height = results_height,
    row = row + input_section_height,
    col = col,
    style = "minimal",
    border = {"╭", "─", "╮", "│", "╰", "─", "╯", "│"},
    title = " Results ",
    title_pos = "center",
  })

  -- Create preview window (right side, below input section)
  ui_state.preview_win = vim.api.nvim_open_win(ui_state.preview_buf, false, {
    relative = "editor",
    width = preview_width,
    height = results_height,
    row = row + input_section_height,
    col = col + results_width + 2,  -- +2 for left border of results and spacing
    style = "minimal",
    border = {"╭", "─", "╮", "│", "╰", "─", "╯", "│"},
    title = " Preview ",
    title_pos = "center",
  })

  -- Set window options
  vim.api.nvim_win_set_option(ui_state.main_win, "wrap", false)
  vim.api.nvim_win_set_option(ui_state.main_win, "cursorline", true)
  vim.api.nvim_win_set_option(ui_state.preview_win, "wrap", false)
  vim.api.nvim_win_set_option(ui_state.preview_win, "number", true)

  -- Set initial highlight for active input (preserve border and title)
  vim.api.nvim_win_set_option(ui_state.input_win, "winhl",
    "Normal:EgrepActiveInput,FloatBorder:FloatBorder,FloatTitle:FloatTitle")
  vim.api.nvim_win_set_option(ui_state.include_win, "winhl",
    "Normal:EgrepInactiveInput,FloatBorder:FloatBorder,FloatTitle:FloatTitle")
  vim.api.nvim_win_set_option(ui_state.exclude_win, "winhl",
    "Normal:EgrepInactiveInput,FloatBorder:FloatBorder,FloatTitle:FloatTitle")

  -- Set up keymaps for all input buffers
  setup_input_keymaps(ui_state.input_buf)
  setup_input_keymaps(ui_state.include_buf)
  setup_input_keymaps(ui_state.exclude_buf)

  -- Protect label lines and position cursor on input buffers
  local function setup_label_protection(buf, label_text)
    vim.api.nvim_create_autocmd({"BufEnter", "WinEnter"}, {
      buffer = buf,
      callback = function()
        -- Ensure cursor starts on line 2 (the input line)
        local cursor = vim.api.nvim_win_get_cursor(0)
        if cursor[1] == 1 then
          vim.api.nvim_win_set_cursor(0, {2, cursor[2]})
        end
      end
    })

    vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
      buffer = buf,
      callback = function()
        -- Restore label line if deleted
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if #lines < 2 or lines[1] ~= label_text then
          local current_input = lines[#lines] or ""
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {label_text, current_input})
          -- Reposition cursor on line 2
          pcall(vim.api.nvim_win_set_cursor, 0, {2, #current_input})
        end
      end
    })
  end

  setup_label_protection(ui_state.input_buf, "Search Pattern:")
  setup_label_protection(ui_state.include_buf, "Include Patterns:")
  setup_label_protection(ui_state.exclude_buf, "Exclude Patterns:")

  -- Enable mouse support in results window
  vim.api.nvim_win_set_option(ui_state.main_win, "mouse", "a")

  -- Set up main buffer keymaps
  local main_keymaps = {
    {"n", "<CR>", M.jump_to_match, {desc = "Jump to match/file or toggle folder"}},
    {"n", "i", function()
      vim.api.nvim_set_current_win(ui_state.input_win)
      vim.cmd("startinsert!")
      update_input_highlights()
      vim.schedule(function() vim.cmd("redraw") end)
    end, {desc = "Edit search"}},
    {"n", "a", function() end, {desc = "Disabled"}},
    {"n", "A", function() end, {desc = "Disabled"}},
    {"n", "I", function() end, {desc = "Disabled"}},
    {"n", "o", function() end, {desc = "Disabled"}},
    {"n", "O", function() end, {desc = "Disabled"}},
    {"n", "<2-LeftMouse>", function()
      -- Exit insert mode if in input fields
      vim.cmd("stopinsert")

      local mouse_pos = vim.fn.getmousepos()
      if mouse_pos.winid == ui_state.main_win then
        -- Set focus to results window
        vim.api.nvim_set_current_win(ui_state.main_win)
        vim.api.nvim_win_set_cursor(ui_state.main_win, {mouse_pos.line, mouse_pos.column - 1})
        update_input_highlights()

        if not ui_state.tree then
          return
        end

        local node = ui_state.tree:get_node(mouse_pos.line)

        if not node then
          return
        end

        -- Double-click on match: preview it
        if node.type == "match" then
          update_preview(node.file, node.line_number)
        -- Double-click on file/folder: toggle expand
        elseif node.type == "file" or node.type == "folder" then
          M.toggle_fold()
        end
      end
    end, {desc = "Double-click to toggle or preview"}},
    {"n", "<LeftMouse>", function()
      -- Exit insert mode if in input fields
      vim.cmd("stopinsert")

      local mouse_pos = vim.fn.getmousepos()
      if mouse_pos.winid == ui_state.main_win then
        -- Set focus to results window
        vim.api.nvim_set_current_win(ui_state.main_win)
        vim.api.nvim_win_set_cursor(ui_state.main_win, {mouse_pos.line, mouse_pos.column - 1})
        update_input_highlights()

        if not ui_state.tree then
          return
        end

        local node = ui_state.tree:get_node(mouse_pos.line)

        if not node then
          return
        end

        -- Single click on file/folder: expand it
        if node.type == "file" or node.type == "folder" then
          M.toggle_fold()
        end
      end
    end, {desc = "Click to navigate and expand"}},
    {"n", "<Right>", M.toggle_fold, {desc = "Expand folder/file"}},
    {"n", "<Left>", M.collapse_parent, {desc = "Collapse parent"}},
    {"n", "za", M.toggle_fold, {desc = "Toggle fold"}},
    {"n", "zR", M.expand_all, {desc = "Expand all"}},
    {"n", "zM", M.collapse_all, {desc = "Collapse all"}},
    {"n", "<F1>", M.toggle_no_tests, {desc = "Toggle no tests filter"}},
    {"n", "<F2>", M.toggle_ruby_only, {desc = "Toggle Ruby only"}},
    {"n", "<F3>", M.toggle_case_sensitive, {desc = "Toggle case sensitive"}},
    {"n", "<F4>", M.toggle_show_hidden, {desc = "Toggle show hidden"}},
    {"n", "?", M.show_help, {desc = "Show help"}},
    {"n", "q", M.close, {desc = "Close"}},
    {"n", "<Esc>", M.close, {desc = "Close"}},
    {"n", "<C-q>", M.to_quickfix, {desc = "Send to quickfix"}},
  }

  for _, keymap in ipairs(main_keymaps) do
    vim.keymap.set(keymap[1], keymap[2], keymap[3],
      vim.tbl_extend("force", keymap[4], {buffer = ui_state.main_buf, nowait = true}))
  end

  -- Set up autocmd for live search
  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
    buffer = ui_state.input_buf,
    callback = trigger_search_debounced,
  })

  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
    buffer = ui_state.include_buf,
    callback = trigger_search_debounced,
  })

  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
    buffer = ui_state.exclude_buf,
    callback = trigger_search_debounced,
  })

  -- Set up autocmd for preview updates
  vim.api.nvim_create_autocmd({"CursorMoved"}, {
    buffer = ui_state.main_buf,
    callback = function()
      vim.schedule(M.update_preview_from_cursor)
    end,
  })

  -- Set up autocmd for focus changes to update highlights
  local focus_group = vim.api.nvim_create_augroup("EgrepFocus", { clear = true })
  vim.api.nvim_create_autocmd({"WinEnter", "BufEnter"}, {
    group = focus_group,
    callback = function()
      if ui_state.input_win then
        update_input_highlights()
      end
    end,
  })

  -- Render initial state
  render_options()
  M.render_results({})
  update_preview(nil, nil)
  update_input_highlights()

  -- Start in insert mode
  vim.cmd("startinsert!")

  return ui_state.input_buf, ui_state.main_buf
end

-- Setup highlights on load
setup_highlights()

return M