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

vim.opt.cursorline = false -- Don't highlight the current line
vim.opt.colorcolumn = "80" -- Visual line at 80 characters
vim.opt.background = "dark" -- Force Neovim to always use Dark Mode

-- Normal Line Numbers
vim.opt.number = true
vim.opt.relativenumber = false

-- Default Indentation (Fallback settings)
-- These are used if the auto-detection plugin (below) finds nothing
vim.opt.expandtab = true -- Use spaces instead of tabs
vim.opt.shiftwidth = 2 -- Size of an indent
vim.opt.tabstop = 2 -- Number of spaces tabs count for<

-- Disable animations for a faster feel
vim.g.snacks_animate = false

-- Disable autoformat by default
vim.g.autoformat = false

-- Disable "unnamedplus"
-- This overrides LazyVim's default. Now 'y'/'p' stay internal.
vim.opt.clipboard = ""

-- Clipboard keymappings
-- These interact explicitly with the '+' (system) register.
local map = vim.keymap.set

-- COPY (Alt+c)
-- Visual Mode: Copy selection to system clipboard
map("v", "<A-c>", '"+y', { desc = "Copy to System Clipboard" })
-- Normal Mode: Copy current line to system clipboard (Optional convenience)
map("n", "<A-c>", '"+yy', { desc = "Copy Line to System Clipboard" })

-- PASTE (Alt+v)
-- Normal Mode
map("n", "<A-v>", '"+p', { desc = "Paste from System Clipboard" })
-- Insert Mode
map("i", "<A-v>", '<C-r>+', { desc = "Paste from System Clipboard" })
-- Command Line Mode
map("c", "<A-v>", '<C-r>+', { desc = "Paste from System Clipboard" })

if vim.g.neovide then
  vim.o.guifont = "DroidSansM Nerd Font:h14"
  vim.g.neovide_scale_factor = 1.0

  vim.g.neovide_position_animation_length = 0
  vim.g.neovide_scroll_animation_far_lines = 0
  vim.g.neovide_scroll_animation_length = 0.00

  -- This tells neovide on macOS to interpret alt+something as actually alt+something, and not some special character.
  vim.g.neovide_input_macos_option_key_is_meta = 'both'
end
