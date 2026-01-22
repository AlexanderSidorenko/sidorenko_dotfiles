return {
  -- 7. DRACULA
  -- The classic vampire theme. Very high contrast when bg is black.
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
      vim.cmd([[colorscheme dracula]]) -- Set Default Here
    end,
  },
  -- 1. MONOKAI PRO (Your Current Favorite)
  -- High Saturation, Yellow/Orange/Pink pop.
  {
    "loctvl842/monokai-pro.nvim",
    lazy = false,
    opts = {
      transparent_background = false,
      filter = "spectrum", -- The most vibrant filter
      override = function(c)
        return {
          Normal = { bg = "#000000" },
          NeoTreeNormal = { bg = "#000000" },
          NeoTreeNormalNC = { bg = "#000000" },
        }
      end,
    },
  },

  -- 2. OXOCARBON
  -- Designed for pure black. Minimal but extremely neon.
  { "nyoom-engineering/oxocarbon.nvim" },

  -- 3. CYBERDREAM
  -- Built specifically for "High Contrast" usage.
  {
    "scottmckendry/cyberdream.nvim",
    opts = {
      transparent = false,
      theme = {
        colors = { bg = "#000000" }, -- Ensures it stays black
      },
    },
  },

  -- 4. FLUOROMACHINE
  -- Cyberpunk/Synthwave. Glowy pinks and purples on black.
  {
    "maxmx03/fluoromachine.nvim",
    config = function()
      local fm = require("fluoromachine")
      fm.setup({
        glow = true,
        theme = "fluoromachine",
        transparent = false,
        overrides = {
          Normal = { bg = "#000000" },
          SignColumn = { bg = "#000000" },
        },
      })
    end,
  },

  -- 5. TOKYO NIGHT (Night Style)
  -- The community standard, forced to Void mode.
  {
    "folke/tokyonight.nvim",
    opts = {
      style = "night",
      on_colors = function(colors)
        colors.bg = "#000000"
        colors.bg_dark = "#000000"
        colors.bg_float = "#000000"
        colors.bg_sidebar = "#000000"
      end,
    },
  },

  -- 6. CATPPUCCIN (Mocha)
  -- Usually pastel, but with the overrides below it becomes High Contrast.
  {
    "catppuccin/nvim",
    name = "catppuccin",
    opts = {
      flavour = "mocha",
      color_overrides = {
        mocha = {
          base = "#000000",
          mantle = "#000000",
          crust = "#000000",
        },
      },
    },
  },

  -- {
  --   "maxmx03/dracula.nvim",
  --   lazy = false,
  --   priority = 1000,
  --   config = function()
  --     local dracula = require("dracula")
  --     dracula.setup({
  --       -- This fork has a dedicated "black" option!
  --       theme = {
  --         colors = {
  --           bg = "#000000", -- Force black
  --         },
  --       },
  --     })
  --     vim.cmd.colorscheme("dracula")
  --   end,
  -- },

  -- 8. KANAGAWA (Dragon)
  -- Organic, ink-like colors. A "samurai" aesthetic.
  {
    "rebelot/kanagawa.nvim",
    opts = {
      theme = "dragon",
      overrides = function(colors)
        return {
          Normal = { bg = "#000000" },
          Floating = { bg = "#000000" },
          TelescopeBorder = { bg = "#000000" },
        }
      end,
    },
  },

  -- 9. NIGHTFOX (Carbonfox)
  -- A "stealth" theme. Geometric and precise.
  {
    "EdenEast/nightfox.nvim",
    opts = {
      options = {
        transparent = false,
      },
      palettes = {
        carbonfox = {
          bg1 = "#000000", -- Main background
          bg0 = "#000000", -- Sidebar/Float
        },
      },
    },
  },

  -- 10. ROSE PINE (Main)
  -- Gold, Rose, and Pine highlights. Very elegant on black.
  {
    "rose-pine/neovim",
    name = "rose-pine",
    opts = {
      styles = {
        bold = true,
        italic = true,
        transparency = false,
      },
      highlight_groups = {
        Normal = { bg = "#000000" },
        TelescopeBorder = { fg = "highlight_high", bg = "#000000" },
        TelescopeNormal = { bg = "#000000" },
      },
    },
  },
}
