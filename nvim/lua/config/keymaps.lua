-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Clipboard Mappings
-- Alt+C to Copy (Visual Mode)
vim.keymap.set("v", "<M-c>", '"+y', { desc = "Copy to system clipboard" })

-- Alt+V to Paste (Insert Mode & Command Line)
vim.keymap.set({ "i", "c" }, "<M-v>", "<C-r>+", { desc = "Paste from system clipboard" })

-- Alt+V to Paste (Normal Mode)
vim.keymap.set("n", "<M-v>", '"+p', { desc = "Paste from system clipboard" })
