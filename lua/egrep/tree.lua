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
        local display_limit = 160
        for _, match in ipairs(node.matches) do
          local raw_line = (match.text or ""):gsub("\n$", "")
          local leading = raw_line:match("^%s*") or ""
          local leading_len = #leading
          local trimmed_line = raw_line:gsub("^%s+", "")
          local display_line = trimmed_line
          local truncated = false
          if #display_line > display_limit then
            display_line = display_line:sub(1, display_limit - 3)
            truncated = true
          end

          local adjusted_submatches = {}
          for _, sub in ipairs(match.submatches or {}) do
            if sub.start and sub["end"] then
              local start_idx = sub.start - leading_len
              local end_idx = sub["end"] - leading_len
              if start_idx < display_limit then
                start_idx = math.max(start_idx, 0)
                local limit = truncated and (display_limit - 3) or #display_line
                local finish_idx = math.min(end_idx, limit)
                if finish_idx > start_idx then
                  table.insert(adjusted_submatches, {
                    start = start_idx,
                    finish = finish_idx,
                  })
                end
              end
            end
          end

          if truncated then
            display_line = display_line .. "..."
          end

          local match_node = NuiTree.Node({
            text = string.format("L%d: %s", match.line_number, display_line),
            type = "match",
            file = node.path,
            line_number = match.line_number,
            column = match.column,
            submatches = adjusted_submatches,
            match_text = display_line,
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

    line:append(indent, "EgrepGuide")

    if node.type == "folder" then
      -- Render folder
      local fold_icon = node:is_expanded() and icons.folder_open or icons.folder_closed
      line:append(fold_icon .. " ", "EgrepGuide")
      line:append(node.text, "EgrepFile")

    elseif node.type == "file" then
      -- Render file
      local fold_icon = node:is_expanded() and icons.file_expanded or icons.file_collapsed
      local file_icon = get_file_icon(node.filename or node.text)

      line:append(fold_icon .. " ", "EgrepGuide")
      if file_icon ~= "" then
        line:append(file_icon .. " ", "EgrepIcon")
      end
      line:append(node.text, "EgrepFile")

    elseif node.type == "match" then
      -- Render match line
      line:append(icons.match, "EgrepGuide")

      -- Split text into line number and match content
      local line_nr, match_text = node.text:match("^(L%d+:)%s*(.*)$")
      if line_nr then
        line:append(line_nr .. " ", "EgrepGuide")
        local submatches = node.submatches or {}
        if #submatches == 0 then
          line:append(match_text, "EgrepMatchText")
        else
          local last_index = 1
          for _, sub in ipairs(submatches) do
            local start_col = sub.start + 1
            local end_col = sub.finish
            if start_col > #match_text then
              break
            end
            if start_col > last_index then
              line:append(match_text:sub(last_index, start_col - 1), "EgrepMatchText")
            end
            if end_col >= start_col then
              if end_col > #match_text then
                end_col = #match_text
              end
              line:append(match_text:sub(start_col, end_col), "EgrepMatchHighlight")
              last_index = end_col + 1
            end
          end
          if last_index <= #match_text then
            line:append(match_text:sub(last_index), "EgrepMatchText")
          end
        end
      else
        line:append(node.text, "EgrepMatchText")
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
