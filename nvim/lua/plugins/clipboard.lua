# Use OSC-52 to allow remote clients on the other size of SSH copy into system's local clipboard.
return {
  "ojroques/nvim-osc52",
  config = function()
    -- 1. If we are running Neovide, STOP.
    -- Neovide handles clipboard syncing natively (even over SSH), 
    -- so we don't need OSC 52.
    if vim.g.neovide then
      return
    end

    local osc52 = require("osc52")
    osc52.setup({
      max_length = 0,
      silent = true,
      trim = false,
    })

    -- 2. Check if we are in a standard SSH session
    local function is_ssh()
      return os.getenv("SSH_CLIENT") or os.getenv("SSH_TTY") or os.getenv("SSH_CONNECTION")
    end

    local function copy()
      if vim.v.event.operator == "y" and vim.v.event.regname == "+" then
        if is_ssh() then
          -- Remote (Terminal): Use OSC 52
          osc52.copy_register("+")
        else
          -- Local (Terminal): Do nothing.
          -- Neovim's 'unnamedplus' handles it naturally via the OS.
        end
      end
    end

    vim.api.nvim_create_autocmd("TextYankPost", { callback = copy })
  end,
}
