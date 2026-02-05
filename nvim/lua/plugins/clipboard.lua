# Use OSC-52 to allow remote clients on the other size of SSH copy into system's local clipboard.
return {
  "ojroques/nvim-osc52",
  lazy = false,
  config = function()
    -- ENVIRONMENT CHECK
    local function is_ssh()
      return os.getenv("SSH_CLIENT") or os.getenv("SSH_TTY") or os.getenv("SSH_CONNECTION")
    end

    -- SETUP CLIPBOARD PROVIDER (SSH ONLY)
    -- Neovide handles the '+' register natively, so we only need OSC52 for remote terminals.
    if is_ssh() and not vim.g.neovide then
      local osc52 = require("osc52")
      osc52.setup({
        max_length = 0,
        silent = true,
        trim = false,
      })

      local function copy(lines, _)
        osc52.copy(table.concat(lines, "\n"))
      end

      local function paste()
        return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
      end

      vim.g.clipboard = {
        name = 'osc52',
        copy = { ['+'] = copy, ['*'] = copy },
        paste = { ['+'] = paste, ['*'] = paste },
      }
    end
  end,
}
