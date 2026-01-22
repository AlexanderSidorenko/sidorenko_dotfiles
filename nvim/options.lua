-- 1. & 2. Visualization
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

-- 3. Visual Extras (Optional but recommended)
vim.opt.colorcolumn = "80" -- Visual line at 80 characters
vim.opt.cursorline = false -- Highlight the current line

-- 4. Normal Line Numbers
vim.opt.number = true
vim.opt.relativenumber = false

-- 5. Default Indentation (Fallback settings)
-- These are used if the auto-detection plugin (below) finds nothing
vim.opt.expandtab = true -- Use spaces instead of tabs
vim.opt.shiftwidth = 2 -- Size of an indent
vim.opt.tabstop = 2 -- Number of spaces tabs count for<

-- Disable animations for a faster feel
vim.g.snacks_animate = false

-- Force Neovim to always use Dark Mode
vim.opt.background = "dark"
