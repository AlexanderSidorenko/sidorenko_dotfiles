return {
  -- Active theme: Dracula on pure black.
  {
    "Mofiqul/dracula.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      colors = {
        bg = "#000000",
        selection = "#44475a",
      },
    },
    config = function(_, opts)
      require("dracula").setup(opts)
      vim.cmd([[colorscheme dracula]])
    end,
  },
}

-- Other themes previously tried (kept here as a reference, not loaded):
--   loctvl842/monokai-pro.nvim       (filter "spectrum")
--   nyoom-engineering/oxocarbon.nvim
--   scottmckendry/cyberdream.nvim
--   maxmx03/fluoromachine.nvim
--   folke/tokyonight.nvim            (style "night")
--   catppuccin/nvim                  (mocha, overridden to black)
--   rebelot/kanagawa.nvim            (theme "dragon")
--   EdenEast/nightfox.nvim           (carbonfox, black bg)
--   rose-pine/neovim
