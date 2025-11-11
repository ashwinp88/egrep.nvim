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
  -- Status and preview windows
  status_buf = nil,
  status_win = nil,
  preview_buf = nil,
  preview_win = nil,
  help_buf = nil,
  help_win = nil,
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
  include_visible = false,
  exclude_visible = false,
  layout = nil,
  spacer_buf = nil,
  spacer_win = nil,
  manual_input_focus = false,
  origin_win = nil,
  is_closing = false,
  suppress_close_watch = false,
  input_prefixes = {},
  backend_command = nil,
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

local DEFAULT_UI_CONFIG = {
  enable_default_keymaps = true,  -- Set to false to disable all default keybindings
  keymaps = {
    focus_search = "<F1>",
    toggle_include = "<F2>",
    toggle_exclude = "<F3>",
    toggle_no_tests = "<F4>",
    toggle_ruby_only = "<F5>",
    toggle_case_sensitive = "<F6>",
    toggle_show_hidden = "<F7>",
    show_help = "?",
  },
  layout = {
    results_ratio = 0.5,
    horizontal_gap = 1,
    vertical_gap = 0,
    min_results_height = 10,
  },
}

local ui_config = vim.deepcopy(DEFAULT_UI_CONFIG)

function M.setup_ui(user_config)
  ui_config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_UI_CONFIG), user_config or {})
end

local function get_keymap(name)
  local keymaps = ui_config.keymaps or {}
  return keymaps[name] or DEFAULT_UI_CONFIG.keymaps[name]
end

local function display_key(name, fallback)
  local key = get_keymap(name) or fallback or ""
  if key:match("^<.+>$") then
    key = key:sub(2, -2)
  end
  return key
end

local FLOAT_BORDER = {"╭", "─", "╮", "│", "╯", "─", "╰", "│"}

local function str_width(text)
  if not text or text == "" then
    return 0
  end
  return vim.fn.strdisplaywidth(text)
end

local function shorten_text(text, max_width)
  if not text or text == "" then
    return ""
  end
  if not max_width or max_width <= 0 then
    return ""
  end
  if str_width(text) <= max_width then
    return text
  end
  if max_width <= 3 then
    return text:sub(1, max_width)
  end
  return text:sub(1, max_width - 3) .. "..."
end

local function format_input_prefix(label)
  return string.format("  %-8s┃ ", label)
end

local function set_input_buffer_content(buf, label, value)
  local prefix = format_input_prefix(label)
  ui_state.input_prefixes[buf] = {label = label, prefix = prefix}
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {prefix .. value})
end

local function ensure_input_prefix(buf)
  local info = ui_state.input_prefixes[buf]
  if not info or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local prefix = info.prefix
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  if line:sub(1, #prefix) ~= prefix then
    local suffix
    local idx = line:find(prefix, 1, true)
    if idx then
      suffix = line:sub(idx + #prefix)
    else
      suffix = line:gsub("^%s+", "")
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {prefix .. suffix})
  end
end

local function clamp_input_cursor(buf)
  local info = ui_state.input_prefixes[buf]
  if not info then return end
  local prefix_len = #info.prefix
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      local pos = vim.api.nvim_win_get_cursor(win)
      if pos[1] == 1 and pos[2] < prefix_len then
        vim.api.nvim_win_set_cursor(win, {1, prefix_len})
      end
    end
  end
end

local function attach_input_behavior(buf)
  local info = ui_state.input_prefixes[buf]
  if not info then return end
  local group = vim.api.nvim_create_augroup("EgrepInput" .. buf, {clear = true})

  vim.api.nvim_create_autocmd({"BufEnter", "WinEnter"}, {
    group = group,
    buffer = buf,
    callback = function()
      clamp_input_cursor(buf)
    end,
  })

  vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
    group = group,
    buffer = buf,
    callback = function()
      clamp_input_cursor(buf)
    end,
  })

  vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
    group = group,
    buffer = buf,
    callback = function()
      ensure_input_prefix(buf)
      clamp_input_cursor(buf)
    end,
  })
end

local function get_input_value(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return ""
  end
  local info = ui_state.input_prefixes[buf]
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  local prefix = info and info.prefix or ""
  local value = line
  if prefix ~= "" and line:sub(1, #prefix) == prefix then
    value = line:sub(#prefix + 1)
  end
  return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function move_input_cursor_to_end(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, {1, #line})
  end
end

-- Try to load devicons
local has_devicons, devicons = pcall(require, "nvim-web-devicons")
if not has_devicons then
  devicons = nil
end

-- Highlight groups
local function setup_highlights()
  vim.api.nvim_set_hl(0, "EgrepFile", {link = "Directory", default = true})
  vim.api.nvim_set_hl(0, "EgrepMatch", {link = "String", default = true})
  vim.api.nvim_set_hl(0, "EgrepLineNr", {link = "Comment", default = true})
  vim.api.nvim_set_hl(0, "EgrepIcon", {link = "Special", default = true})
  vim.api.nvim_set_hl(0, "EgrepCount", {link = "Number", default = true})
  vim.api.nvim_set_hl(0, "EgrepPrompt", {link = "Title", default = true})
  vim.api.nvim_set_hl(0, "EgrepBorder", {link = "FloatBorder", default = true})
  vim.api.nvim_set_hl(0, "EgrepPreviewHighlight", {link = "CursorLine", default = true})
  vim.api.nvim_set_hl(0, "EgrepActiveInput", {link = "NormalFloat", default = true})
  vim.api.nvim_set_hl(0, "EgrepInactiveInput", {link = "NormalFloat", default = true})
  vim.api.nvim_set_hl(0, "EgrepSeparator", {link = "Comment", default = true})
  vim.api.nvim_set_hl(0, "EgrepCursorLine", {link = "Visual", default = false})
  vim.api.nvim_set_hl(0, "EgrepStatus", {link = "StatusLine", default = true})
  vim.api.nvim_set_hl(0, "EgrepGuide", {link = "Comment", default = true})
  vim.api.nvim_set_hl(0, "EgrepMatchText", {link = "Normal", default = true})
  vim.api.nvim_set_hl(0, "EgrepMatchHighlight", {link = "Search", default = true})
  vim.api.nvim_set_hl(0, "EgrepSpacer", {link = "NormalFloat", default = true})
end

local trigger_search
local render_status_line
local close_help_window

--- Close the picker
local function close_help_window()
  if ui_state.help_win and vim.api.nvim_win_is_valid(ui_state.help_win) then
    pcall(vim.api.nvim_win_close, ui_state.help_win, true)
  end
  if ui_state.help_buf and vim.api.nvim_buf_is_valid(ui_state.help_buf) then
    pcall(vim.api.nvim_buf_delete, ui_state.help_buf, {force = true})
  end
  ui_state.help_buf = nil
  ui_state.help_win = nil
end

function M.close()
  ui_state.is_closing = true

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
  pcall(vim.api.nvim_del_augroup_by_name, "EgrepWindowWatch")

  if ui_state.origin_win and vim.api.nvim_win_is_valid(ui_state.origin_win) then
    pcall(vim.api.nvim_set_current_win, ui_state.origin_win)
  end

  -- Close all windows
  local windows = {
    ui_state.input_win,
    ui_state.include_win,
    ui_state.exclude_win,
    ui_state.status_win,
    ui_state.main_win,
    ui_state.preview_win,
    ui_state.spacer_win,
  }

  for _, win in ipairs(windows) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  close_help_window()

  if ui_state.spacer_buf and vim.api.nvim_buf_is_valid(ui_state.spacer_buf) then
    pcall(vim.api.nvim_buf_delete, ui_state.spacer_buf, {force = true})
  end

  local buffers = {
    ui_state.input_buf,
    ui_state.include_buf,
    ui_state.exclude_buf,
    ui_state.status_buf,
    ui_state.main_buf,
    ui_state.preview_buf,
    ui_state.help_buf,
  }

  for _, buf in ipairs(buffers) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, {force = true})
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
    status_buf = nil,
    status_win = nil,
    preview_buf = nil,
    preview_win = nil,
    help_buf = nil,
    help_win = nil,
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
    include_visible = false,
    exclude_visible = false,
    layout = nil,
    spacer_buf = nil,
    spacer_win = nil,
    manual_input_focus = false,
    origin_win = nil,
    is_closing = false,
    suppress_close_watch = false,
    input_prefixes = {},
    backend_command = nil,
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
    vim.api.nvim_buf_set_lines(ui_state.preview_buf, 0, -1, false, {"Select a match to preview the file context here."})
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", false)
    if ui_state.preview_win and vim.api.nvim_win_is_valid(ui_state.preview_win) then
      local cfg = vim.api.nvim_win_get_config(ui_state.preview_win)
      cfg.title = " Preview "
      cfg.title_pos = "left"
      vim.api.nvim_win_set_config(ui_state.preview_win, cfg)
    end
    return
  end

  ui_state.current_preview_file = file

  -- Read file contents
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok or not lines then
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(ui_state.preview_buf, 0, -1, false, {"Error reading file: " .. file})
    vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", false)
    if ui_state.preview_win and vim.api.nvim_win_is_valid(ui_state.preview_win) then
      local cfg = vim.api.nvim_win_get_config(ui_state.preview_win)
      cfg.title = string.format(" Preview ─ %s ─", vim.fn.fnamemodify(file, ":~"))
      cfg.title_pos = "left"
      vim.api.nvim_win_set_config(ui_state.preview_win, cfg)
    end
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
  elseif ui_state.preview_win and vim.api.nvim_win_is_valid(ui_state.preview_win) then
    local ns_id = vim.api.nvim_create_namespace("egrep_preview")
    vim.api.nvim_buf_clear_namespace(ui_state.preview_buf, ns_id, 0, -1)
  end

  if ui_state.preview_win and vim.api.nvim_win_is_valid(ui_state.preview_win) then
    local cfg = vim.api.nvim_win_get_config(ui_state.preview_win)
    local path = vim.fn.fnamemodify(file, ":~")
    if line_number then
      cfg.title = string.format(" Preview ─ %s:%d ─", path, line_number)
    else
      cfg.title = string.format(" Preview ─ %s ─", path)
    end
    cfg.title_pos = "left"
    vim.api.nvim_win_set_config(ui_state.preview_win, cfg)
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
          local found = false
          local max_line = vim.api.nvim_buf_line_count(ui_state.main_buf)

          for line_num = 1, max_line do
            local node = ui_state.tree:get_node(line_num)
            if node then
              local node_path = node.path or node.file
              if node_path == saved_node_path and node.type == saved_node_type then
                vim.api.nvim_win_set_cursor(ui_state.main_win, {line_num, 0})
                found = true
                break
              end
            end
          end

          if not found and saved_cursor_line then
            local target_line = math.max(saved_cursor_line, 1)
            target_line = math.min(target_line, max_line)
            vim.api.nvim_win_set_cursor(ui_state.main_win, {target_line, 0})
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

  -- Store targets before closing UI to avoid race conditions
  if node.type == "match" then
    local file = node.file
    local line = node.line_number or 1
    local col = node.column or 0
    local target_win = ui_state.origin_win
    M.close()
    vim.schedule(function()
      if target_win and vim.api.nvim_win_is_valid(target_win) then
        pcall(vim.api.nvim_set_current_win, target_win)
      end
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      pcall(vim.api.nvim_win_set_cursor, 0, {line, col})
      vim.cmd("normal! zz")
    end)
    return
  end

  if node.type == "file" then
    local path = node.path
    local target_win = ui_state.origin_win
    M.close()
    vim.schedule(function()
      if target_win and vim.api.nvim_win_is_valid(target_win) then
        pcall(vim.api.nvim_set_current_win, target_win)
      end
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    end)
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
    vim.api.nvim_win_set_option(ui_state.input_win, "winhl", "Normal:" .. hl)
  end

  if ui_state.include_win and vim.api.nvim_win_is_valid(ui_state.include_win) then
    local hl = current_win == ui_state.include_win and "EgrepActiveInput" or "EgrepInactiveInput"
    vim.api.nvim_win_set_option(ui_state.include_win, "winhl", "Normal:" .. hl)
  end

  if ui_state.exclude_win and vim.api.nvim_win_is_valid(ui_state.exclude_win) then
    local hl = current_win == ui_state.exclude_win and "EgrepActiveInput" or "EgrepInactiveInput"
    vim.api.nvim_win_set_option(ui_state.exclude_win, "winhl", "Normal:" .. hl)
  end
end

local function cancel_focus_timer()
  if ui_state.focus_timer then
    vim.fn.timer_stop(ui_state.focus_timer)
    ui_state.focus_timer = nil
  end
end

local function focus_search_input()
  cancel_focus_timer()
  if ui_state.input_win and vim.api.nvim_win_is_valid(ui_state.input_win) then
    ui_state.manual_input_focus = false
    vim.api.nvim_set_current_win(ui_state.input_win)
    vim.cmd("startinsert!")
    move_input_cursor_to_end(ui_state.input_buf, ui_state.input_win)
    update_input_highlights()
  end
end

local function auto_focus_results()
  if ui_state.main_win and vim.api.nvim_win_is_valid(ui_state.main_win) then
    ui_state.manual_input_focus = false
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(ui_state.main_win)
    update_input_highlights()
  end
end

local function map_config_key(modes, key_name, handler, opts)
  local key = get_keymap(key_name)
  -- Support false or "" to disable specific keybinding
  if not key or key == "" or key == false then return end
  local mode_list = type(modes) == "table" and modes or {modes}
  opts = opts or {}
  for _, mode in ipairs(mode_list) do
    vim.keymap.set(mode, key, handler, opts)
  end
end

local function compute_layout_sections()
  local layout = ui_state.layout
  if not layout then return nil end

  local sections = {}
  local gap = layout.vertical_gap or 0
  local row = layout.row
  local col = layout.col
  local width = layout.width

  local function assign_section(name)
    sections[name] = {
      row = row,
      col = col,
      width = width,
      height = 1,
    }
    row = row + 1 + gap
  end

  assign_section('search')

  if ui_state.include_visible then
    assign_section('include')
  end

  if ui_state.exclude_visible then
    assign_section('exclude')
  end

  local status_height = 1
  local status_row = layout.row + layout.height - status_height
  if status_row <= row then
    status_row = row + status_height + gap
  end

  sections.status = {
    row = status_row,
    col = col,
    width = width,
    height = status_height,
  }

  local available = status_row - row - gap
  if available < 5 then
    available = 5
  end

  local results_height = available - 2 -- account for border
  local min_results_height = layout.min_results_height or 10
  if results_height < min_results_height then
    results_height = math.max(min_results_height, available - 2)
  end
  if results_height < 3 then
    results_height = 3
  end

  local gap_x = layout.horizontal_gap or 0
  local content_width = width - gap_x - 4  -- Account for borders on both results and preview panes (2+2)
  if content_width < 2 then content_width = 2 end

  local results_ratio = layout.results_ratio or 0.5
  if results_ratio <= 0 then results_ratio = 0.5 end
  if results_ratio >= 1 then results_ratio = 0.9 end

  local results_width = math.floor(content_width * results_ratio)
  if results_width < 1 then results_width = 1 end
  local preview_width = content_width - results_width
  if preview_width < 1 then
    preview_width = 1
    results_width = content_width - preview_width
    if results_width < 1 then results_width = 1 end
  end

  sections.results = {
    row = row,
    col = col,
    width = results_width,
    height = results_height,
  }

  sections.preview = {
    row = row,
    col = col + results_width + 2 + gap_x,
    width = preview_width,
    height = results_height,
  }

  if gap_x > 0 then
    local spacer_row = row - 1
    if spacer_row < 0 then spacer_row = 0 end
    sections.spacer = {
      row = spacer_row,
      col = col + results_width + 2,
      width = gap_x,
      height = results_height + 3,  -- +3 because spacer starts 1 row above + 2 borders
    }
  end

  return sections
end

local function ensure_window(win_field, buf_field, section, opts)
  opts = opts or {}
  local buf = ui_state[buf_field]
  local win = ui_state[win_field]

  if not section then
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    ui_state[win_field] = nil
    return
  end

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local config = {
    relative = "editor",
    row = section.row,
    col = section.col,
    width = section.width,
    height = section.height,
    style = "minimal",
    border = opts.border or FLOAT_BORDER,
  }

  if opts.title then
    config.title = opts.title
    config.title_pos = opts.title_pos or "center"
  end

  if opts.focusable ~= nil then
    config.focusable = opts.focusable
  end

  if opts.zindex then
    config.zindex = opts.zindex
  end

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, config)
  else
    win = vim.api.nvim_open_win(buf, opts.enter_on_create or false, config)
    ui_state[win_field] = win
  end

  if opts.winhl then
    vim.api.nvim_win_set_option(win, "winhl", opts.winhl)
  end

  if opts.options then
    for name, value in pairs(opts.options) do
      vim.api.nvim_win_set_option(win, name, value)
    end
  end
end

local function ensure_spacer(section, max_height)
  if not section or section.width <= 0 then
    if ui_state.spacer_win and vim.api.nvim_win_is_valid(ui_state.spacer_win) then
      pcall(vim.api.nvim_win_close, ui_state.spacer_win, true)
    end
    ui_state.spacer_win = nil
    if ui_state.spacer_buf and vim.api.nvim_buf_is_valid(ui_state.spacer_buf) then
      pcall(vim.api.nvim_buf_delete, ui_state.spacer_buf, {force = true})
    end
    ui_state.spacer_buf = nil
    return
  end

  if not ui_state.spacer_buf or not vim.api.nvim_buf_is_valid(ui_state.spacer_buf) then
    ui_state.spacer_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(ui_state.spacer_buf, "bufhidden", "wipe")
  end

  local height = section.height
  if max_height and max_height > 0 then
    height = math.min(height, max_height)
  end
  if height < 1 then
    height = 1
  end

  local filler = string.rep(" ", section.width)
  local lines = {}
  for _ = 1, height do
    table.insert(lines, filler)
  end
  vim.api.nvim_buf_set_option(ui_state.spacer_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.spacer_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(ui_state.spacer_buf, "modifiable", false)

  local config = {
    relative = "editor",
    row = section.row,
    col = section.col,
    width = section.width,
    height = height,
    style = "minimal",
    border = "none",
  }

  if ui_state.spacer_win and vim.api.nvim_win_is_valid(ui_state.spacer_win) then
    vim.api.nvim_win_set_config(ui_state.spacer_win, config)
  else
    ui_state.spacer_win = vim.api.nvim_open_win(ui_state.spacer_buf, false, config)
  end

  vim.api.nvim_win_set_option(ui_state.spacer_win, "winhl", "Normal:EgrepSpacer")
  vim.api.nvim_win_set_option(ui_state.spacer_win, "winblend", 0)
end

local function apply_layout()
  local layout = ui_state.layout
  if not layout then return end

  local sections = compute_layout_sections()
  if not sections then return end

  ensure_window('input_win', 'input_buf', sections.search, {
    enter_on_create = not (ui_state.input_win and vim.api.nvim_win_is_valid(ui_state.input_win)),
    border = "none",
    winhl = "Normal:EgrepActiveInput,EndOfBuffer:EgrepActiveInput",
    options = {
      wrap = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
    },
  })

  ensure_window('include_win', 'include_buf', sections.include, {
    border = "none",
    winhl = "Normal:EgrepInactiveInput,EndOfBuffer:EgrepInactiveInput",
    options = {
      wrap = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
    },
  })

  ensure_window('exclude_win', 'exclude_buf', sections.exclude, {
    border = "none",
    winhl = "Normal:EgrepInactiveInput,EndOfBuffer:EgrepInactiveInput",
    options = {
      wrap = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
    },
  })

  ensure_window('status_win', 'status_buf', sections.status, {
    border = "none",
    winhl = "Normal:EgrepStatus",
    options = {
      wrap = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
    },
  })

  ensure_window('main_win', 'main_buf', sections.results, {
    title = " Results ",
    title_pos = "left",
    winhl = "Normal:NormalFloat,FloatBorder:EgrepBorder",
    options = {
      wrap = false,
      cursorline = true,
    },
  })

  ensure_window('preview_win', 'preview_buf', sections.preview, {
    title = " Preview ",
    title_pos = "left",
    winhl = "Normal:NormalFloat,FloatBorder:EgrepBorder",
    options = {
      wrap = false,
      number = true,
    },
  })

  local spacer_height_limit
  if sections.results and sections.spacer then
    spacer_height_limit = sections.results.height + 3
  end
  local status_row = sections.status and sections.status.row or nil
  if status_row and sections.spacer then
    local to_status = status_row - sections.spacer.row
    if to_status >= 1 then
      if spacer_height_limit then
        spacer_height_limit = math.min(spacer_height_limit, to_status)
      else
        spacer_height_limit = to_status
      end
    end
  end
  ensure_spacer(sections.spacer, spacer_height_limit)

  if ui_state.main_win and vim.api.nvim_win_is_valid(ui_state.main_win) then
    pcall(vim.api.nvim_win_set_option, ui_state.main_win, "winhighlight", "CursorLine:EgrepCursorLine")
  end

  render_status_line()
  update_input_highlights()
end

--- Move to next input field
function M.next_input()
  cancel_focus_timer()
  local windows = {}
  if ui_state.input_win and vim.api.nvim_win_is_valid(ui_state.input_win) then
    table.insert(windows, ui_state.input_win)
  end
  if ui_state.include_visible and ui_state.include_win and vim.api.nvim_win_is_valid(ui_state.include_win) then
    table.insert(windows, ui_state.include_win)
  end
  if ui_state.exclude_visible and ui_state.exclude_win and vim.api.nvim_win_is_valid(ui_state.exclude_win) then
    table.insert(windows, ui_state.exclude_win)
  end

  if #windows == 0 then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local target

  for index, win in ipairs(windows) do
    if win == current_win then
      target = windows[(index % #windows) + 1]
      break
    end
  end

  if not target then
    target = windows[1]
  end

  if target and vim.api.nvim_win_is_valid(target) then
    if target == ui_state.include_win or target == ui_state.exclude_win then
      ui_state.manual_input_focus = true
    else
      ui_state.manual_input_focus = false
    end
    vim.api.nvim_set_current_win(target)
    vim.cmd("startinsert!")
    local target_buf = vim.api.nvim_win_get_buf(target)
    move_input_cursor_to_end(target_buf, target)
  end

  update_input_highlights()
  vim.schedule(function() vim.cmd("redraw") end)
end

function M.prev_input()
  cancel_focus_timer()
  local windows = {}
  if ui_state.input_win and vim.api.nvim_win_is_valid(ui_state.input_win) then
    table.insert(windows, ui_state.input_win)
  end
  if ui_state.include_visible and ui_state.include_win and vim.api.nvim_win_is_valid(ui_state.include_win) then
    table.insert(windows, ui_state.include_win)
  end
  if ui_state.exclude_visible and ui_state.exclude_win and vim.api.nvim_win_is_valid(ui_state.exclude_win) then
    table.insert(windows, ui_state.exclude_win)
  end

  if #windows == 0 then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local target

  for index, win in ipairs(windows) do
    if win == current_win then
      local new_index = index - 1
      if new_index < 1 then
        new_index = #windows
      end
      target = windows[new_index]
      break
    end
  end

  if not target then
    target = windows[#windows]
  end

  if target and vim.api.nvim_win_is_valid(target) then
    if target == ui_state.include_win or target == ui_state.exclude_win then
      ui_state.manual_input_focus = true
    else
      ui_state.manual_input_focus = false
    end
    vim.api.nvim_set_current_win(target)
    vim.cmd("startinsert!")
    local target_buf = vim.api.nvim_win_get_buf(target)
    move_input_cursor_to_end(target_buf, target)
  end

  update_input_highlights()
  vim.schedule(function() vim.cmd("redraw") end)
end

function M.toggle_include()
  cancel_focus_timer()
  ui_state.suppress_close_watch = true
  ui_state.include_visible = not ui_state.include_visible
  apply_layout()
  ui_state.suppress_close_watch = false
  render_status_line()

  if ui_state.include_visible and ui_state.include_win and vim.api.nvim_win_is_valid(ui_state.include_win) then
    ui_state.manual_input_focus = true
    vim.api.nvim_set_current_win(ui_state.include_win)
    vim.cmd("startinsert!")
    move_input_cursor_to_end(ui_state.include_buf, ui_state.include_win)
    update_input_highlights()
  else
    focus_search_input()
  end
end

function M.toggle_exclude()
  cancel_focus_timer()
  ui_state.suppress_close_watch = true
  ui_state.exclude_visible = not ui_state.exclude_visible
  apply_layout()
  ui_state.suppress_close_watch = false
  render_status_line()

  if ui_state.exclude_visible and ui_state.exclude_win and vim.api.nvim_win_is_valid(ui_state.exclude_win) then
    ui_state.manual_input_focus = true
    vim.api.nvim_set_current_win(ui_state.exclude_win)
    vim.cmd("startinsert!")
    move_input_cursor_to_end(ui_state.exclude_buf, ui_state.exclude_win)
    update_input_highlights()
  else
    focus_search_input()
  end
end

--- Toggle "No Tests" filter
function M.toggle_no_tests()
  local current = state.get()
  local new_value = not current.ignore_tests
  state.update({ignore_tests = new_value})

  -- Don't modify the exclude input buffer - the toggle works behind the scenes
  -- The test patterns will be added during ripgrep command building

  render_status_line()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Toggle Ruby only filter
function M.toggle_ruby_only()
  ui_state.ruby_only = not ui_state.ruby_only

  -- Don't modify the include input buffer - the toggle works behind the scenes
  -- The Ruby pattern will be added during ripgrep command building

  render_status_line()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Toggle case sensitivity
function M.toggle_case_sensitive()
  local current = state.get()
  state.update({case_sensitive = not current.case_sensitive})
  render_status_line()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Toggle show hidden files
function M.toggle_show_hidden()
  ui_state.show_hidden = not ui_state.show_hidden
  render_status_line()
  if ui_state.current_search ~= "" then
    trigger_search(true)  -- Force search since toggles changed
  end
end

--- Render options line
render_status_line = function()
  if not ui_state.status_buf or not vim.api.nvim_buf_is_valid(ui_state.status_buf) then
    return
  end

  local current = state.get()

  local segments = {}

  local function add_segment(text)
    if text and text ~= "" then
      table.insert(segments, text)
    end
  end

  local entries = {}

  local function add_entry(text)
    if text and text ~= "" then
      table.insert(entries, text)
    end
  end

  local function add_toggle_entry(active, label, key_name, always_visible)
    local key = display_key(key_name, key_name)
    if key == "" then
      return
    end
    if not always_visible and not active then
      return
    end
    local marker = active and "x" or " "
    add_entry(string.format("[%s] %s(%s)", marker, label, key))
  end

  local help_key = display_key('show_help', '?')
  if help_key ~= "" then
    add_entry(string.format("%s Help", help_key))
  end

  local focus_key = display_key('focus_search', 'F1')
  if focus_key ~= "" then
    add_entry(string.format("Focus Search (%s)", focus_key))
  end

  add_toggle_entry(ui_state.include_visible, "Include Pattern", 'toggle_include', true)
  add_toggle_entry(ui_state.exclude_visible, "Exclude Pattern", 'toggle_exclude', true)
  add_toggle_entry(current.ignore_tests, "NoTests", 'toggle_no_tests', false)
  add_toggle_entry(ui_state.ruby_only, "Ruby Only", 'toggle_ruby_only', false)
  add_toggle_entry(current.case_sensitive, "Case Sensitive", 'toggle_case_sensitive', false)
  add_toggle_entry(ui_state.show_hidden, "Hidden Files", 'toggle_show_hidden', false)

  local total_width = ui_state.layout and ui_state.layout.width or nil
  local separator = " │ "
  local separator_width = str_width(separator)
  local line = ""

  for _, entry in ipairs(entries) do
    local part = entry
    local part_width = str_width(part)
    local extra = (line ~= "") and separator_width or 0
    if total_width and str_width(line) + extra + part_width > total_width then
      if str_width(line) == 0 then
        part = shorten_text(part, total_width)
        line = part
      end
      break
    end
    if line ~= "" then
      line = line .. separator
    end
    line = line .. part
  end

  if total_width then
    local current_width = str_width(line)
    if current_width < total_width then
      line = line .. string.rep(" ", total_width - current_width)
    elseif current_width == 0 then
      line = string.rep(" ", total_width)
    end
  elseif line == "" then
    line = " "
  end

  vim.api.nvim_buf_set_option(ui_state.status_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.status_buf, 0, -1, false, {line})
  vim.api.nvim_buf_set_option(ui_state.status_buf, "modifiable", false)
end

--- Show help
function M.show_help()
  if ui_state.help_win and vim.api.nvim_win_is_valid(ui_state.help_win) then
    close_help_window()
    return
  end

  local help_text = {
    "Enhanced Grep Keybindings:",
    "",
  }

  if ui_state.backend_command and ui_state.backend_command ~= "" then
    table.insert(help_text, 2, string.format("Backend command: %s", ui_state.backend_command))
    table.insert(help_text, 3, "")
  end

  vim.list_extend(help_text, {
    "Input Navigation:",
    "  <Tab>/<C-n>    - Next input field",
    "  <S-Tab>/<C-p>  - Previous input field",
    "  <CR>           - Execute search and focus results",
    string.format("  %-14s - Focus search input", display_key('focus_search', 'F1')),
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
    string.format("  %-14s - Toggle 'No Tests' filter", display_key('toggle_no_tests', 'F4')),
    string.format("  %-14s - Toggle 'Ruby Only' filter", display_key('toggle_ruby_only', 'F5')),
    string.format("  %-14s - Toggle case sensitivity", display_key('toggle_case_sensitive', 'F6')),
    string.format("  %-14s - Toggle show hidden/git-ignored files", display_key('toggle_show_hidden', 'F7')),
    string.format("  %-14s - Toggle include filters pane", display_key('toggle_include', 'F2')),
    string.format("  %-14s - Toggle exclude filters pane", display_key('toggle_exclude', 'F3')),
    "",
    "Actions:",
    "  <C-q>          - Send to quickfix list",
    "  q/<Esc>        - Close picker",
    string.format("  %-14s - Show this help", display_key('show_help', '?')),
    "",
    "Tips:",
    "  - Press <CR> in any input to run the search",
    "  - Use wildcards: *.rb, /test/*, **/*.lua",
    "  - Preview updates as you navigate results",
    "  - Files are collapsed by default (press Right arrow to expand)",
    "  - Quick option toggles work in both insert and normal mode",
  })

  local longest = 0
  for _, line in ipairs(help_text) do
    longest = math.max(longest, str_width(line))
  end

  local padding = 4
  local desired_width = math.max(40, math.min(longest, vim.o.columns - 10))
  local win_width = math.min(desired_width + padding, vim.o.columns - 4)
  local desired_height = #help_text
  local win_height = math.min(desired_height + 2, vim.o.lines - 4)

  if not ui_state.help_buf or not vim.api.nvim_buf_is_valid(ui_state.help_buf) then
    ui_state.help_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(ui_state.help_buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(ui_state.help_buf, "filetype", "egrephelp")
  end

  vim.api.nvim_buf_set_option(ui_state.help_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ui_state.help_buf, 0, -1, false, help_text)
  vim.api.nvim_buf_set_option(ui_state.help_buf, "modifiable", false)

  local row = math.max(math.floor((vim.o.lines - win_height) / 2), 0)
  local col = math.max(math.floor((vim.o.columns - win_width) / 2), 0)

  ui_state.help_win = vim.api.nvim_open_win(ui_state.help_buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = win_width,
    height = win_height,
    style = "minimal",
    border = FLOAT_BORDER,
    focusable = true,
    zindex = 150,
  })

  vim.api.nvim_win_set_option(ui_state.help_win, "wrap", true)
  vim.api.nvim_win_set_option(ui_state.help_win, "winhl", "NormalFloat:NormalFloat,FloatBorder:EgrepBorder")

  vim.keymap.set({'n', 'i'}, '<Esc>', close_help_window, {buffer = ui_state.help_buf, nowait = true})
  vim.keymap.set({'n', 'i'}, 'q', close_help_window, {buffer = ui_state.help_buf, nowait = true})
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

  local pattern = get_input_value(ui_state.input_buf)
  local include_str = get_input_value(ui_state.include_buf)
  local exclude_str = get_input_value(ui_state.exclude_buf)

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
  }

  for _, keymap in ipairs(keymaps) do
    vim.keymap.set(keymap[1], keymap[2], keymap[3],
      vim.tbl_extend("force", keymap[4], {buffer = buf, nowait = true}))
  end

  -- Only set up default keymaps if enabled
  if ui_config.enable_default_keymaps ~= false then
    local opts = {buffer = buf, nowait = true}
    map_config_key({'n', 'i'}, 'focus_search', focus_search_input,
      vim.tbl_extend("force", {desc = "Focus search input"}, opts))
    map_config_key({'n', 'i'}, 'toggle_include', M.toggle_include,
      vim.tbl_extend("force", {desc = "Toggle include filters"}, opts))
    map_config_key({'n', 'i'}, 'toggle_exclude', M.toggle_exclude,
      vim.tbl_extend("force", {desc = "Toggle exclude filters"}, opts))
    map_config_key({'n', 'i'}, 'toggle_no_tests', M.toggle_no_tests,
      vim.tbl_extend("force", {desc = "Toggle no tests filter"}, opts))
    map_config_key({'n', 'i'}, 'toggle_ruby_only', M.toggle_ruby_only,
      vim.tbl_extend("force", {desc = "Toggle Ruby only filter"}, opts))
    map_config_key({'n', 'i'}, 'toggle_case_sensitive', M.toggle_case_sensitive,
      vim.tbl_extend("force", {desc = "Toggle case sensitive"}, opts))
    map_config_key({'n', 'i'}, 'toggle_show_hidden', M.toggle_show_hidden,
      vim.tbl_extend("force", {desc = "Toggle show hidden files"}, opts))
    map_config_key({'n', 'i'}, 'show_help', M.show_help,
      vim.tbl_extend("force", {desc = "Show help"}, opts))
  end
end

--- Create the unified picker UI with preview pane
function M.create_picker(opts)
  opts = opts or {}

  local saved_state = state.get()
  ui_state.include_patterns = opts.include_patterns or saved_state.last_include or {}
  ui_state.exclude_patterns = opts.exclude_patterns or saved_state.last_exclude or {}
  ui_state.on_search_callback = opts.on_search
  ui_state.search_config = opts.search_config
  ui_state.include_visible = false
  ui_state.exclude_visible = false
  ui_state.manual_input_focus = false
  ui_state.origin_win = vim.api.nvim_get_current_win()
  ui_state.input_prefixes = {}
  ui_state.backend_command = nil

  local default_pattern = opts.default_pattern or ""

  local total_width = opts.width or math.floor(vim.o.columns * 0.9)
  local total_height = opts.height or math.floor(vim.o.lines * 0.9)

  total_width = math.min(total_width, vim.o.columns - 2)
  total_height = math.min(total_height, vim.o.lines - 2)
  total_width = math.max(total_width, math.min(80, vim.o.columns - 2))
  total_height = math.max(total_height, math.min(24, vim.o.lines - 2))

  local row = math.max(0, math.floor((vim.o.lines - total_height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - total_width) / 2))

  -- Search input buffer
  ui_state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.input_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(ui_state.input_buf, "buftype", "")
  vim.api.nvim_buf_set_option(ui_state.input_buf, "modifiable", true)
  vim.api.nvim_buf_set_option(ui_state.input_buf, "swapfile", false)
  set_input_buffer_content(ui_state.input_buf, "Search", default_pattern or "")
  attach_input_behavior(ui_state.input_buf)

  -- Include patterns buffer
  local include_default = patterns.format_patterns(ui_state.include_patterns) or ""
  ui_state.include_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.include_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(ui_state.include_buf, "buftype", "")
  vim.api.nvim_buf_set_option(ui_state.include_buf, "modifiable", true)
  vim.api.nvim_buf_set_option(ui_state.include_buf, "swapfile", false)
  set_input_buffer_content(ui_state.include_buf, "Include", include_default)
  attach_input_behavior(ui_state.include_buf)

  -- Exclude patterns buffer
  local exclude_default = patterns.format_patterns(ui_state.exclude_patterns) or ""
  ui_state.exclude_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.exclude_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(ui_state.exclude_buf, "buftype", "")
  vim.api.nvim_buf_set_option(ui_state.exclude_buf, "modifiable", true)
  vim.api.nvim_buf_set_option(ui_state.exclude_buf, "swapfile", false)
  set_input_buffer_content(ui_state.exclude_buf, "Exclude", exclude_default)
  attach_input_behavior(ui_state.exclude_buf)

  -- Input frame buffer
  -- Status line buffer
  ui_state.status_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.status_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(ui_state.status_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(ui_state.status_buf, "swapfile", false)

  -- Results buffer
  ui_state.main_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.main_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.main_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(ui_state.main_buf, "filetype", "egrep")
  vim.api.nvim_buf_set_option(ui_state.main_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(ui_state.main_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(ui_state.main_buf, "readonly", false)

  -- Preview buffer
  ui_state.preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(ui_state.preview_buf, "swapfile", false)

  -- Input keymaps
  setup_input_keymaps(ui_state.input_buf)
  setup_input_keymaps(ui_state.include_buf)
  setup_input_keymaps(ui_state.exclude_buf)

  local layout_defaults = ui_config.layout or {}
  local layout_overrides = opts.layout or {}
  local min_results_height = layout_overrides.min_results_height
    or layout_defaults.min_results_height
    or math.max(math.floor(total_height * 0.45), 10)
  min_results_height = math.min(min_results_height, math.max(6, total_height - 6))

  ui_state.layout = {
    row = row,
    col = col,
    width = total_width,
    height = total_height,
    results_ratio = layout_overrides.results_ratio or layout_defaults.results_ratio or 0.5,
    horizontal_gap = layout_overrides.horizontal_gap or layout_defaults.horizontal_gap or 1,
    vertical_gap = layout_overrides.vertical_gap or layout_defaults.vertical_gap or 0,
    min_results_height = min_results_height,
  }

  apply_layout()

  if ui_state.input_win and vim.api.nvim_win_is_valid(ui_state.input_win) then
    move_input_cursor_to_end(ui_state.input_buf, ui_state.input_win)
  end

  if ui_state.main_win and vim.api.nvim_win_is_valid(ui_state.main_win) then
    vim.api.nvim_win_set_option(ui_state.main_win, "mouse", "a")
  end

  local function map_ui_keys_for_buffer(buf, modes)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    -- Only set up default keymaps if enabled
    if ui_config.enable_default_keymaps ~= false then
      local base_opts = {buffer = buf, nowait = true}
      map_config_key(modes, 'focus_search', focus_search_input, vim.tbl_extend("force", {desc = "Focus search input"}, base_opts))
      map_config_key(modes, 'toggle_include', M.toggle_include, vim.tbl_extend("force", {desc = "Toggle include filters"}, base_opts))
      map_config_key(modes, 'toggle_exclude', M.toggle_exclude, vim.tbl_extend("force", {desc = "Toggle exclude filters"}, base_opts))
      map_config_key(modes, 'toggle_no_tests', M.toggle_no_tests, vim.tbl_extend("force", {desc = "Toggle no tests filter"}, base_opts))
      map_config_key(modes, 'toggle_ruby_only', M.toggle_ruby_only, vim.tbl_extend("force", {desc = "Toggle Ruby only filter"}, base_opts))
      map_config_key(modes, 'toggle_case_sensitive', M.toggle_case_sensitive, vim.tbl_extend("force", {desc = "Toggle case sensitive search"}, base_opts))
      map_config_key(modes, 'toggle_show_hidden', M.toggle_show_hidden, vim.tbl_extend("force", {desc = "Toggle show hidden files"}, base_opts))
      map_config_key(modes, 'show_help', M.show_help, vim.tbl_extend("force", {desc = "Show help"}, base_opts))
    end
  end

  local main_keymaps = {
    {"n", "<CR>", M.jump_to_match, {desc = "Jump to match/file or toggle folder"}},
    {"n", "i", function()
      focus_search_input()
      update_input_highlights()
      vim.schedule(function() vim.cmd("redraw") end)
    end, {desc = "Edit search"}},
    {"n", "a", function() end, {desc = "Disabled"}},
    {"n", "A", function() end, {desc = "Disabled"}},
    {"n", "I", function() end, {desc = "Disabled"}},
    {"n", "o", function() end, {desc = "Disabled"}},
    {"n", "O", function() end, {desc = "Disabled"}},
    {"n", "<2-LeftMouse>", function()
      vim.cmd("stopinsert")
      local mouse_pos = vim.fn.getmousepos()
      if mouse_pos.winid == ui_state.main_win then
        vim.api.nvim_set_current_win(ui_state.main_win)
        vim.api.nvim_win_set_cursor(ui_state.main_win, {mouse_pos.line, math.max(mouse_pos.column - 1, 0)})
        update_input_highlights()
        if not ui_state.tree then
          return
        end
        local node = ui_state.tree:get_node(mouse_pos.line)
        if not node then
          return
        end
        if node.type == "match" then
          update_preview(node.file, node.line_number)
        elseif node.type == "file" or node.type == "folder" then
          M.toggle_fold()
        end
      end
    end, {desc = "Double-click to toggle or preview"}},
    {"n", "<LeftMouse>", function()
      vim.cmd("stopinsert")
      local mouse_pos = vim.fn.getmousepos()
      if mouse_pos.winid == ui_state.main_win then
        vim.api.nvim_set_current_win(ui_state.main_win)
        vim.api.nvim_win_set_cursor(ui_state.main_win, {mouse_pos.line, math.max(mouse_pos.column - 1, 0)})
        update_input_highlights()
        if not ui_state.tree then
          return
        end
        local node = ui_state.tree:get_node(mouse_pos.line)
        if not node then
          return
        end
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
    {"n", "q", M.close, {desc = "Close"}},
    {"n", "<Esc>", M.close, {desc = "Close"}},
    {"n", "<C-q>", M.to_quickfix, {desc = "Send to quickfix"}},
  }

  for _, keymap in ipairs(main_keymaps) do
    vim.keymap.set(keymap[1], keymap[2], keymap[3],
      vim.tbl_extend("force", keymap[4], {buffer = ui_state.main_buf, nowait = true}))
  end

  map_ui_keys_for_buffer(ui_state.main_buf, 'n')

  local watch_group = vim.api.nvim_create_augroup("EgrepWindowWatch", {clear = true})
  vim.api.nvim_create_autocmd("WinClosed", {
    group = watch_group,
    callback = function(args)
      if ui_state.is_closing or ui_state.suppress_close_watch then
        return
      end

      local closed_win = tonumber(args.match)
      if not closed_win then
        return
      end

      local managed = {
        ui_state.input_win,
        ui_state.include_win,
        ui_state.exclude_win,
        ui_state.status_win,
        ui_state.main_win,
        ui_state.preview_win,
        ui_state.spacer_win,
      }

      for _, win in ipairs(managed) do
        if win and win == closed_win then
          M.close()
          break
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd({"CursorMoved"}, {
    buffer = ui_state.main_buf,
    callback = function()
      vim.schedule(M.update_preview_from_cursor)
    end,
  })

  local focus_group = vim.api.nvim_create_augroup("EgrepFocus", {clear = true})
  vim.api.nvim_create_autocmd({"WinEnter", "BufEnter"}, {
    group = focus_group,
    callback = function()
      if not ui_state.input_win then
        return
      end

      local current_win = vim.api.nvim_get_current_win()
      if ui_state.input_win and vim.api.nvim_win_is_valid(ui_state.input_win) and current_win == ui_state.input_win then
        ui_state.manual_input_focus = false
      elseif ui_state.include_win and vim.api.nvim_win_is_valid(ui_state.include_win) and current_win == ui_state.include_win then
        ui_state.manual_input_focus = true
      elseif ui_state.exclude_win and vim.api.nvim_win_is_valid(ui_state.exclude_win) and current_win == ui_state.exclude_win then
        ui_state.manual_input_focus = true
      end

      update_input_highlights()
    end,
  })

  render_status_line()
  M.render_results({})
  update_preview(nil, nil)
  update_input_highlights()

  vim.cmd("startinsert!")

  return ui_state.input_buf, ui_state.main_buf
end

function M.set_backend_command(cmd)
  ui_state.backend_command = cmd
  render_status_line()
end

-- Setup highlights on load
setup_highlights()

return M
