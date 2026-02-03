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

vim.opt.cursorline = true -- Highlight the current line
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

if vim.g.neovide then
  vim.o.guifont = "DroidSansM Nerd Font:h14"
  vim.g.neovide_scale_factor = 1.0
end
