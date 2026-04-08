-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Enable list mode
vim.opt.list = true
-- Customize specific characters (Removed 'space' to reduce noise)
vim.opt.listchars = {
  tab = "» ", -- Tabs show as a double arrow
  trail = "█", -- Trailing spaces show as a block
  extends = "…", -- Overflow right
  precedes = "…", -- Overflow left
  nbsp = "␣", -- Non-breaking space
}

vim.opt.ignorecase = true -- Case-insensitive search by default
vim.opt.smartcase = true -- ...unless the query contains uppercase
vim.opt.gdefault = true -- Substitute all matches on a line by default (:s///g)
vim.opt.cursorline = false -- Don't highlight the current line
vim.opt.colorcolumn = "120" -- Visual line at 120 characters
vim.opt.textwidth = 120 -- Hard-wrap at 120 columns
vim.opt.wrap = true -- Soft-wrap long lines visually
vim.opt.linebreak = true -- Wrap at word boundaries, not mid-word
vim.opt.background = "dark" -- Force Neovim to always use Dark Mode

-- Normal Line Numbers
vim.opt.number = true
vim.opt.relativenumber = false

-- Default Indentation (Fallback settings)
-- These are used if the auto-detection plugin (below) finds nothing
vim.opt.expandtab = true -- Use spaces instead of tabs
vim.opt.shiftwidth = 2 -- Size of an indent
vim.opt.tabstop = 2 -- Number of spaces tabs count for

-- Disable animations for a faster feel
vim.g.snacks_animate = false

-- Disable autoformat by default
vim.g.autoformat = false

-- Disable "unnamedplus"
-- This overrides LazyVim's default. Now 'y'/'p' stay internal.
-- Alt+c / Alt+v bindings for the system clipboard live in keymaps.lua.
vim.opt.clipboard = ""

if vim.g.neovide then
  vim.o.guifont = "DroidSansM Nerd Font:h14"
  vim.g.neovide_scale_factor = 1.0

  vim.g.neovide_position_animation_length = 0
  vim.g.neovide_scroll_animation_far_lines = 0
  vim.g.neovide_scroll_animation_length = 0.00

  -- This tells neovide on macOS to interpret alt+something as actually alt+something, and not some special character.
  vim.g.neovide_input_macos_option_key_is_meta = 'both'
end
