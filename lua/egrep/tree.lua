-- Tree adapter for nui.nvim integration
-- Converts egrep results to NuiTree structure

local state = require("egrep.state")

local M = {}

-- Try to load nui components
local ok_tree, NuiTree = pcall(require, "nui.tree")
local ok_line, NuiLine = pcall(require, "nui.line")

if not ok_tree or not ok_line then
  error("nui.nvim is required but not installed. Please install MunifTanjim/nui.nvim")
end

-- Icons for tree nodes
local icons = {
  folder_open = "▼ 📂",
  folder_closed = "▶ 📁",
  file_expanded = "▼",
  file_collapsed = "▶",
  match = "  ",
}

-- Try to load devicons
local has_devicons, devicons = pcall(require, "nvim-web-devicons")
if not has_devicons then
  devicons = nil
end

--- Get icon for file using devicons
--- @param filename string File name
--- @return string Icon
local function get_file_icon(filename)
  if devicons then
    local icon, _ = devicons.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), {default = true})
    return icon or ""
  end
  return ""
end

--- Build hierarchical tree structure from flat file list
--- @param results table Flat list of file results from ripgrep
--- @param folder_state table Current folder expand/collapse state
--- @return table NuiTree nodes array
function M.build_nodes(results, folder_state)
  folder_state = folder_state or {}

  -- Build folder hierarchy first
  local tree = {}

  for _, file_data in ipairs(results) do
    local path = file_data.path
    local parts = vim.split(path, "/")

    local current = tree
    local path_so_far = ""

    -- Build folder hierarchy
    for i = 1, #parts - 1 do
      local folder = parts[i]
      path_so_far = path_so_far == "" and folder or (path_so_far .. "/" .. folder)

      if not current[folder] then
        current[folder] = {
          type = "folder",
          name = folder,
          path = path_so_far,
          children = {},
        }
      end
      current = current[folder].children
    end

    -- Add file as leaf
    local filename = parts[#parts]
    current[filename] = {
      type = "file",
      name = filename,
      path = path,
      matches = file_data.matches,
    }
  end

  -- Convert tree structure to NuiTree nodes
  local nodes = {}

  --- Recursively build NuiTree nodes from tree structure
  --- @param node table Tree node
  --- @param parent_id string|nil Parent node ID
  local function build_nui_node(node, parent_id)
    if node.type == "folder" then
      local is_expanded = folder_state[node.path] ~= false -- Default true

      -- Sort children: folders first, then files
      local children = {}
      for name, child in pairs(node.children) do
        table.insert(children, {name = name, node = child})
      end
      table.sort(children, function(a, b)
        if a.node.type == b.node.type then
          return a.name < b.name
        end
        return a.node.type == "folder"
      end)

      -- Build child nodes if expanded
      local child_nodes = {}
      if is_expanded then
        for _, child in ipairs(children) do
          local child_nui_node = build_nui_node(child.node, nil)
          if child_nui_node then
            table.insert(child_nodes, child_nui_node)
          end
        end
      end

      -- Create and return folder node with children
      return NuiTree.Node({
        text = node.name .. "/",
        type = "folder",
        path = node.path,
        _is_expanded = is_expanded,
      }, child_nodes)

    elseif node.type == "file" then
      local saved_fold_state = state.get_fold_state(node.path)
      local is_expanded = saved_fold_state == true -- Default false for files

      -- Create file node
      local match_count = #node.matches
      local file_text = string.format("%s (%d)", node.name, match_count)

      -- Build match nodes if expanded
      local match_nodes = {}
      if is_expanded then
        for _, match in ipairs(node.matches) do
          local match_text = string.format("L%d: %s",
            match.line_number,
            match.text:gsub("^%s+", ""):gsub("%s+$", "")
          )

          -- Truncate long lines
          if #match_text > 80 then
            match_text = match_text:sub(1, 77) .. "..."
          end

          local match_node = NuiTree.Node({
            text = match_text,
            type = "match",
            file = node.path,
            line_number = match.line_number,
            column = match.column,
          })

          table.insert(match_nodes, match_node)
        end
      end

      return NuiTree.Node({
        text = file_text,
        type = "file",
        path = node.path,
        filename = node.name,
        match_count = match_count,
        _is_expanded = is_expanded,
      }, match_nodes)
    end
  end

  -- Sort root level nodes
  local root_nodes = {}
  for name, node in pairs(tree) do
    table.insert(root_nodes, {name = name, node = node})
  end
  table.sort(root_nodes, function(a, b)
    if a.node.type == b.node.type then
      return a.name < b.name
    end
    return a.node.type == "folder"
  end)

  -- Build NuiTree nodes for root level
  for _, item in ipairs(root_nodes) do
    local nui_node = build_nui_node(item.node, nil)
    if nui_node then
      table.insert(nodes, nui_node)
    end
  end

  return nodes
end

--- Create a prepare_node function for NuiTree rendering
--- @return function prepare_node function for NuiTree
function M.create_prepare_node()
  return function(node)
    local line = NuiLine()
    local indent = string.rep("  ", node:get_depth() - 1)

    line:append(indent)

    if node.type == "folder" then
      -- Render folder
      local fold_icon = node:is_expanded() and icons.folder_open or icons.folder_closed
      line:append(fold_icon .. " ", "EgrepIcon")
      line:append(node.text, "EgrepFile")

    elseif node.type == "file" then
      -- Render file
      local fold_icon = node:is_expanded() and icons.file_expanded or icons.file_collapsed
      local file_icon = get_file_icon(node.filename or node.text)

      line:append(fold_icon .. " ", "Special")
      if file_icon ~= "" then
        line:append(file_icon .. " ", "EgrepIcon")
      end
      line:append(node.text, "EgrepFile")

    elseif node.type == "match" then
      -- Render match line
      line:append(icons.match, "Comment")

      -- Split text into line number and match content
      local line_nr, match_text = node.text:match("^(L%d+:)%s*(.*)$")
      if line_nr then
        line:append(line_nr .. " ", "EgrepLineNr")
        line:append(match_text, "EgrepMatch")
      else
        line:append(node.text, "EgrepMatch")
      end
    end

    return line
  end
end

--- Create a NuiTree instance with egrep results
--- @param results table Flat list of file results
--- @param winid number Window ID to render tree in
--- @param folder_state table Current folder expand/collapse state
--- @return table NuiTree instance
function M.create_tree(results, winid, folder_state)
  local nodes = M.build_nodes(results, folder_state)

  local tree = NuiTree({
    winid = winid,
    nodes = nodes,
    prepare_node = M.create_prepare_node(),
  })

  -- Store folder_state for later use
  tree._folder_state = folder_state

  -- After tree is created, expand nodes based on folder_state
  -- We need to walk ALL nodes in the tree, not just root nodes
  local function expand_all_nodes(node_id)
    local node = tree:get_node(node_id)
    if not node then
      return
    end

    -- Check if this node should be expanded
    if node.type == "folder" and folder_state[node.path] == true then
      -- Only expand if explicitly set to true (default false for folders)
      node:expand()
    elseif node.type == "file" then
      -- For files, check saved fold state (default false)
      local saved_fold_state = state.get_fold_state(node.path)
      if saved_fold_state == true then
        node:expand()
      end
    end

    -- Recursively process children
    local child_ids = node:get_child_ids()
    for _, child_id in ipairs(child_ids or {}) do
      expand_all_nodes(child_id)
    end
  end

  -- Start from root nodes
  for _, node in ipairs(nodes) do
    expand_all_nodes(node:get_id())
  end

  return tree
end

return M
