# egrep.nvim

A beautiful, fast, and feature-rich grep interface for Neovim with folder hierarchy, live preview, and smart filtering.

## ✨ Features

### 🌳 Hierarchical Tree View
- **Folder hierarchy** - Files organized by directory structure
- **Smart collapse/expand** - Right arrow expands, left arrow collapses parent
- **File icons** - Beautiful devicons integration for files and folders
- **Nested indentation** - Clear visual hierarchy

### 🖱️ Mouse Support
- **Click to navigate** - Single click moves cursor
- **Double-click to open** - Quick file access
- **Scroll with mouse wheel** - Natural navigation

### ⚡ Live Search
- **Real-time results** - See matches as you type (300ms debounce)
- **Pattern support** - Include/exclude glob patterns (*.rb, /test/*, etc.)
- **Quick toggles** - F1/F2/F3 for instant filtering
- **Persistent state** - Remembers your preferences and fold states

### 🎯 Smart Filtering
- **No Tests** (F1) - Automatically excludes test files
- **Ruby Only** (F2) - Filter to Ruby files only
- **Case Sensitive** (F3) - Toggle case sensitivity
- **Custom patterns** - Full glob pattern support

### 👁️ Live Preview
- **Side-by-side view** - Results on left, preview on right
- **Syntax highlighting** - Proper filetype detection
- **Auto-update** - Preview follows cursor

### ⌨️ Intuitive Keybindings
- **Arrow keys** - Natural tree navigation (like neotree)
- **Enter** - Open file or jump to match
- **F1/F2/F3** - Quick filters (work in insert and normal mode)
- **Mouse support** - Click, double-click, scroll
- **Standard vim** - za, zR, zM for folding

## 📦 Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "ashwinp88/egrep.nvim",
  lazy = false,

  config = function()
    require("egrep").setup({
      defaults = {
        ignore_tests = true,
        use_gitignore = true,
        case_sensitive = false,
        fold_by_default = false,
        include = {},
        exclude = {"/test/*", "/spec/*", "*_test.*", "*_spec.*"},
      },
      window = {
        width = 0.8,  -- 80% of screen width
        height = 0.8, -- 80% of screen height
      },
    })
  end,

  keys = {
    { "<leader>sE", function() require("egrep").grep() end, desc = "Enhanced Grep" },
    { "<leader>sT", function() require("egrep").grep_no_tests() end, desc = "Enhanced Grep (No Tests)" },
    { "<leader>sW", function() require("egrep").grep_word() end, desc = "Enhanced Grep Word" },
    { "<leader>s<leader>", function() require("egrep").repeat_last() end, desc = "Repeat Last Search" },
  },
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "ashwinp88/egrep.nvim",
  config = function()
    require("egrep").setup()
  end
}

-- Add keybindings
vim.keymap.set("n", "<leader>sE", function() require("egrep").grep() end, { desc = "Enhanced Grep" })
vim.keymap.set("n", "<leader>sW", function() require("egrep").grep_word() end, { desc = "Enhanced Grep Word" })
```

### Dependencies

- Neovim >= 0.9.0
- [ripgrep](https://github.com/BurntSushi/ripgrep) (rg command)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) (optional, for file icons)

## 🚀 Usage

### Basic Search

Press `<leader>sE` to open the grep interface and start typing your search pattern.

### Input Fields

The interface has three input fields:

1. **Search Pattern** - Your search query (regex supported)
2. **Include Patterns** - Glob patterns to include (e.g., `*.rb`, `src/**/*.lua`)
3. **Exclude Patterns** - Glob patterns to exclude (e.g., `/test/*`, `*.min.js`)

Navigate between fields with `<Tab>` (forward) and `<S-Tab>` (backward).

### Quick Options

Toggle filters with function keys (works in insert and normal mode):

- **F1** - No Tests: Excludes `/test/*`, `/spec/*`, `*_test.*`, `*_spec.*`
- **F2** - Ruby Only: Filter to `*.rb` files only
- **F3** - Case Sensitive: Toggle case sensitivity

### Tree Navigation

#### Keyboard
- **Right Arrow** - Expand folder/file
- **Left Arrow** - Collapse parent (smart: collapses file from match, folder from file)
- **Enter** - Open file or jump to match
- **za** - Toggle fold
- **zR** - Expand all
- **zM** - Collapse all

#### Mouse
- **Single Click** - Move cursor
- **Double Click** - Open file/jump to match
- **Scroll Wheel** - Navigate results

### Results Window

- **i** - Return to search input
- **q** or **Esc** - Close grep window
- **Ctrl-q** - Send results to quickfix list
- **?** - Show help

## ⚙️ Configuration

### Default Configuration

```lua
require("egrep").setup({
  defaults = {
    -- Ignore test files by default
    ignore_tests = true,

    -- Respect .gitignore
    use_gitignore = true,

    -- Case insensitive by default
    case_sensitive = false,

    -- Files collapsed by default
    fold_by_default = false,

    -- Default include patterns (empty = all files)
    include = {},

    -- Default exclude patterns
    exclude = {
      "/test/*",
      "/tests/*",
      "/spec/*",
      "/__tests__/*",
      "*_test.*",
      "*_spec.*",
      "test_*.*",
      "*.test.*",
      "*.spec.*"
    },
  },

  window = {
    -- Window size (0.0 to 1.0)
    width = 0.8,
    height = 0.8,
  },
})
```

### Available Functions

```lua
local egrep = require("egrep")

-- Basic grep
egrep.grep()

-- Grep with default pattern
egrep.grep("TODO")

-- Grep without test files
egrep.grep_no_tests()
egrep.grep_no_tests("FIXME")

-- Grep word under cursor
egrep.grep_word()

-- Grep word under cursor (no tests)
egrep.grep_word_no_tests()

-- Select from presets (if configured)
egrep.select_preset()

-- Repeat last search
egrep.repeat_last()
```

### Custom Presets

Create custom search presets for common workflows:

```lua
require("egrep").setup({
  presets = {
    ruby_controllers = {
      name = "Ruby Controllers",
      include = {"app/controllers/**/*.rb"},
      exclude = {"*_spec.rb"},
    },
    todos = {
      name = "TODOs",
      pattern = "TODO|FIXME|HACK",
      exclude = {"/test/*", "/spec/*"},
    },
    migrations = {
      name = "Migrations",
      include = {"db/migrate/*.rb"},
    },
  }
})
```

## 🎨 Highlights

Customize colors by overriding these highlight groups:

```lua
vim.api.nvim_set_hl(0, "EgrepFile", { link = "Directory" })
vim.api.nvim_set_hl(0, "EgrepMatch", { link = "String" })
vim.api.nvim_set_hl(0, "EgrepLineNr", { link = "LineNr" })
vim.api.nvim_set_hl(0, "EgrepIcon", { link = "Special" })
vim.api.nvim_set_hl(0, "EgrepCount", { link = "Number" })
vim.api.nvim_set_hl(0, "EgrepActiveInput", { link = "CursorLine" })
vim.api.nvim_set_hl(0, "EgrepInactiveInput", { link = "Normal" })
```

## 🔧 Advanced Usage

### Glob Pattern Examples

**Include Patterns:**
```
*.rb               - All Ruby files
src/**/*.lua       - Lua files in src/ and subdirectories
app/models/*.rb    - Ruby files in app/models/ only
**/*_controller.rb - All controller files
```

**Exclude Patterns:**
```
/test/*            - Exclude test directory
*.min.js           - Exclude minified JS
/vendor/*          - Exclude vendor directory
**/node_modules/*  - Exclude node_modules anywhere
```

### Search Tips

- **Regex supported** - Use ripgrep regex syntax
- **Word boundaries** - `\bword\b` for exact word matches
- **Case insensitive** - Default, toggle with F3
- **Multiple patterns** - Use `|` for OR (e.g., `TODO|FIXME`)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📝 License

MIT License - see LICENSE file for details

## 🙏 Credits

- Built with [ripgrep](https://github.com/BurntSushi/ripgrep)
- Icons from [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons)
- Inspired by telescope.nvim, fzf, and neotree

## 📸 Screenshots

<!-- TODO: Add screenshots here -->

---

**Made with ❤️ for Neovim**
