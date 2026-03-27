# sidorenko_dotfiles

Personal dotfiles for Alexander Sidorenko. Targets Linux (primary) and macOS.

## Repo structure

```
install.sh          — interactive installer; idempotent, safe to re-run
shrc                — unified shell config sourced by both bash and zsh
gitconfig           — git defaults (delta, nvim, moor pager)
gitconfig.personal  — optional personal identity include
tmux.conf           — tmux config; prefix Ctrl+Space, vi keys
ripgreprc           — global rg flags
tigrc               — tig config
mc.keymap           — Midnight Commander keymap
wezterm/            — WezTerm terminal config
nvim/               — Neovim config (LazyVim-based, Lua)
ranger/             — ranger file manager config
bin/                — custom scripts (clip, ssh-host-setup.sh, neovide)
```

## Key conventions

**Marker blocks** — install.sh injects source blocks into user RC files wrapped with:
```
# >>> sidorenko_dotfiles >>>
# <<< sidorenko_dotfiles <<<
```
Used in `~/.bashrc`, `~/.zshrc`, `~/.bash_profile`, `~/.zprofile`, `~/.gitconfig`.

**shrc structure** — sections in order:
1. Environment variables (LANG, EDITOR, umask, etc.)
2. PATH management (`path_prepend` / `path_append` helpers)
3. Shell-specific config (zsh block, then bash block)
4. Required tools check (`__require_tools`)
5. Colors / cosmetics
6. Aliases & modern replacements
7. Utility functions
8. Git aliases
9. Tool aliases (docker, k8s, terraform)
10. GPG & local config (`~/.bashrc.local` sourced last)

**bin/ scripts** — must be executable (`chmod +x`). Use `#!/usr/bin/env bash` + `set -euo pipefail`.

**install.sh helpers** — use `symlink_prompt` for config dirs/files, `copy_prompt` for files that must be copied (fonts), `ensure_shrc_sources_repo` for RC injection.

## Validating changes

Always syntax-check shell files after editing:

```bash
bash -n shrc            # syntax check (bash parser)
zsh -n shrc             # syntax check (zsh parser)
shellcheck shrc         # lint
bash -n install.sh && shellcheck install.sh
bash -n bin/ssh-host-setup.sh && shellcheck bin/ssh-host-setup.sh
```

## Important notes

- `shrc` is sourced by both bash and zsh — avoid bashisms or zshisms outside their respective `if` blocks.
- Tool integrations (fzf, zoxide, etc.) are guarded with `command -v` checks; keep this consistent for new additions.
- New tools that should be installed by default go in `install.sh:install_nix_packages`. Look up exact Nix attribute names at https://search.nixos.org/packages before adding. Platform-specific packages (e.g., wl-clipboard, xclip) go in the Linux-only section.
- `~/.bashrc.local` is sourced last for machine-specific overrides not tracked in this repo.
