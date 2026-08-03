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
alacritty/          — Alacritty terminal config (TOML; alacritty itself installed manually)
nvim/               — Neovim config (LazyVim-based, Lua)
ranger/             — ranger file manager config
claude/             — Claude Code config (settings.json, CLAUDE.md, skills/; symlinked into ~/.claude)
bin/                — custom scripts (clip, ssh-host-setup.sh, neovide)
githooks/           — this repo's own git hooks (commit-msg enforces [job] prefix;
                      pre-commit verifies @ imports in claude/CLAUDE.md resolve)
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
- Claude Code instructions are tiered: `claude/CLAUDE.md` (tracked, symlinked to
  `~/.claude/CLAUDE.md`) holds global-all-machines content and ends by importing
  `~/.claude/CLAUDE.machine.md` (untracked, per-machine; missing import is
  silently skipped — install.sh creates a stub). Work-machine-class content goes
  on the `job` branch. Per-repo instructions live in each repo's own
  CLAUDE.md/AGENTS.md as usual.
- Reusable procedures live in `claude/skills/<name>/SKILL.md` (Agent Skills
  format, https://agentskills.io — portable across agents). Keep frontmatter
  spec-minimal (`name` + `description`); avoid Claude-Code-only fields unless a
  skill really needs them. Work-only skills go on the `job` branch.
- Third-party skills are vendored **verbatim** and never edited in place, so an
  upstream update is a clean overwrite; anything local (defaults, opt-outs) goes
  in `claude/CLAUDE.md` instead. `claude/skills/caveman/SKILL.md` comes from
  https://github.com/JuliusBrussee/caveman (`skills/caveman/SKILL.md`, upstream
  commit 710173f). Only that one file is vendored — upstream's Node installer,
  CLI, and companion skills are deliberately not used; `claude/` is symlinked
  into `~/.claude` by `install.sh` and the `@` import in `claude/CLAUDE.md` is
  what turns the skill on.

## Git workflow

This repo is distributed from a personal GitHub account and is **PUBLIC**. Treat
anything on `master` as world-readable.

### Remotes and branches
- `origin` — personal repo (SSH, pushable). Default destination for everything generic.
- `master` — the public baseline. All generic, machine-agnostic config lives here,
  pushed to `origin/master`.
- Work machines also have a `job` remote and check out a `job` branch that layers
  machine-/work-specific commits on top of `master`. `job` is always kept rebased on
  `origin/master` — master is the baseline, never the reverse.

### The rule that matters: never leak
Never commit work-/employer-specific content to `master` or push it to `origin`:
internal hostnames (beyond public ones already here), internal URLs, credentials,
proprietary tooling, work-only paths. When unsure whether a change is generic or
work-specific, **STOP and ASK** — never guess toward `master`.

### Before any change
1. `git fetch origin`; rebase the current branch onto `origin/master` if behind.
2. If a `job` remote exists: `git fetch job`; rebase `job` if behind.

### Where a change goes (classify and switch branch BEFORE editing)
- Generic / machine-agnostic → on `master`, commit, push `origin master`.
- Work-/machine-specific → on `job`, commit, push to the `job` remote. Never `origin`.
- After a generic commit lands on `master` (work machine): rebase `job` onto the new
  `master`, then `git push --force-with-lease job job`.

### Push policy
**Always commit AND push as part of finishing a change — on every machine (personal
and work) and on every branch.** A commit on `master` is pushed to `origin/master`;
a commit on `job` is pushed to the `job` remote. Skip the push only when explicitly
told to. (This overrides the usual "commit/push only when asked" and "branch before
committing to the default branch" defaults — here, generic commits go straight to
`master`.)

### Commit messages
`[scope] Imperative summary` (e.g. `[nvim] …`, `[install/gnome] …`, `[bin/ssh-host-setup] …`).
Keep the `Co-Authored-By:` trailer.

Commits that live only on the `job` branch (work-/machine-specific) prefix the
title with a `[job]` tag, with no space before the scope:
`[job][install] Install Slack on work machines`. This makes work-only history
obvious at a glance and guards against it drifting onto `master`.

This is enforced by the `githooks/commit-msg` hook (installed by `install.sh`):
on `job` it rejects titles that don't start with `[job]`, and on `master` it
rejects titles that do. Bypass for a one-off with `git commit --no-verify`.

### Work-machine overlay
Work-specific instructions, when they exist, live only on the `job` branch (e.g. an
`AGENTS.work.md` imported from the job branch's `CLAUDE.md`). They never exist on
`master`. There is no overlay file yet — add one only when there's actual work-specific
content to record.

## Bootstrapping a work machine

Clone the public repo (this becomes `origin`), add the enterprise remote as `job`,
and check out the `job` branch:

```bash
git clone git@github.com:AlexanderSidorenko/sidorenko_dotfiles.git ~/.sidorenko_dotfiles
cd ~/.sidorenko_dotfiles
git remote add job <enterprise-ssh-url>
git fetch job
git checkout -b job --track job/job   # first machine ever: `git checkout -b job master`, then `git push -u job job`
./install.sh
```
