return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    keys = {
      { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diffview: open" },
      { "<leader>gV", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
      { "<leader>gf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
      { "<leader>gF", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: branch history" },
    },
    config = function(_, opts)
      -- Subtle diff backgrounds that preserve treesitter syntax colors.
      -- Chunk boundaries stay visible via a faint tint instead of an opaque wash.
      vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#0a2e0a" })
      vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#2e0a0a" })
      vim.api.nvim_set_hl(0, "DiffChange", { bg = "#0a1a2e" })
      vim.api.nvim_set_hl(0, "DiffText", { bg = "#1a2a4a" })
      require("diffview").setup(opts)
    end,
    opts = {
      view = {
        merge_tool = {
          layout = "diff3_mixed",
        },
      },
      keymaps = {
        view = {
          { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
        },
        file_panel = {
          { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
        },
        file_history_panel = {
          { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
        },
      },
    },
  },
}
