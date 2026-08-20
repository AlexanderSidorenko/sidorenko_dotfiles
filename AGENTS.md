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
bin/                — custom scripts (clip, mem, ram-health, ssh-host-setup.sh,
                      zswap-setup.sh, neovide, tmux-snapshot, tmux-restore,
                      tmux-pipe-log)
bin/lib/            — sourced helpers, not executables (meminfo.sh)
githooks/           — this repo's own git hooks (commit-msg enforces [job] prefix)
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

Scripts that source something from `bin/lib/` need `shellcheck -x` so it follows
the `source` line; plain `shellcheck` reports SC1091 and never checks the library's
contribution:

```bash
bash -n bin/mem && shellcheck -x bin/mem
bash -n bin/ram-health && shellcheck -x bin/ram-health
shellcheck bin/lib/meminfo.sh    # has a `shell=bash` directive, no shebang
```

shellcheck is not currently in `nix-packages.sh`, so on a machine without it
run the checks through Nix instead:

```bash
nix-shell -p shellcheck --run 'shellcheck bin/tmux-snapshot bin/tmux-pipe-log'
```

tmux behaviour is easy to get wrong from the man page alone; check it against a
throwaway server rather than the live one, which shares its socket with the
session you are working in:

```bash
tmux -L scratch -f /dev/null new-session -d -s t
tmux -L scratch ... ; tmux -L scratch kill-server
```

To exercise a script that shells out to `tmux`, put a shim earlier on PATH that
adds `-L scratch`, so a bug cannot reach the real sessions.

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

### Rewriting history is normal here
Both branches are amended, squashed, reordered and force-pushed as a matter of
course. This is a single-maintainer repo; a readable history is worth more than an
append-only guarantee. `master` being the *baseline* is a statement about content
(generic, world-readable) and about direction (`job` rebases onto `master`, never
the reverse) — it is **not** a claim that published commits are immutable.

- Amend, squash and reorder freely on `master` and on `job`, before or after
  publishing. Do not treat a pushed commit as frozen, and do not ask whether
  rewriting is allowed — it is.
- Publish a rewrite with `--force-with-lease`, never a bare `--force`: the lease
  is what catches a remote that someone else moved. Where a branch name collides
  with a remote name — `job` does here — pin the lease explicitly:
  `git push --force-with-lease=refs/heads/job:<sha> job refs/heads/job:refs/heads/job`
- Rewriting `master` reparents `job`, so rebase `job` onto the new `master` and
  force-push that too. Both halves, or the fold is silently broken.
- Rewrite by checking the branch out and using `rebase`/`--amend`. The plumbing
  prohibition below still applies: it governs how commits are *authored*, not
  whether history may change.
- Verify a content-preserving rewrite by comparing trees, not by eyeballing the
  log: `git diff <backup-ref> <branch>` empty, or the two `^{tree}` hashes equal.
  Tag the old tip first (`git branch backup/... <branch>`) so there is something
  to compare against and fall back to.
- Pushing still requires explicit per-push confirmation (see the push policy
  below). "Rewriting is allowed" and "ask before publishing" are independent
  rules; neither implies the other.

### The rule that matters: never leak
Never commit work-/employer-specific content to `master` or push it to `origin`:
internal hostnames (beyond public ones already here), internal URLs, credentials,
proprietary tooling, work-only paths. When unsure whether a change is generic or
work-specific, **STOP and ASK** — never guess toward `master`.

### Before any change
1. `git fetch origin`; rebase the current branch onto `origin/master` if behind.
2. If a `job` remote exists: `git fetch job`; rebase `job` if behind.

### Where a change goes (classify and switch branch BEFORE editing)
- Generic / machine-agnostic → `master`; when a push is requested, it goes to
  `origin master`.
- Work-/machine-specific → `job`; when a push is requested, it goes to the `job`
  remote. Never `origin`.
- After a generic commit lands on `master` (work machine): rebase `job` onto the
  new `master`; push (`--force-with-lease`, to the `job` remote) only on request.

### How commits are made (never with plumbing)
A commit is made by **checking out the target branch and running `git commit`** —
`git switch master`, edit, commit, `git switch job`. Preserve dirty state around
the switch with an explicit `git stash push` / `git stash pop --index`.

Never write a commit with plumbing (`git commit-tree`, `git hash-object` +
`git update-ref`, `git branch -f`) or from any path that leaves the working tree
on a different branch than the one being committed to. It looks equivalent and is
not:

- **Hooks do not run.** `commit-msg` is bypassed entirely, so the `[job]`-prefix
  guard silently stops applying in both directions.
- **The change never reaches the working tree.** Content committed to `master`
  from a `job` checkout exists only inside a git object. Nothing on disk changes,
  so anything that reads files rather than git — `install.sh`, a systemd unit, a
  script you then try to run — behaves as if the change was never made.
- **The fold is skipped and looks done.** `master` moves while `job` stays
  behind, with no dirty file and no reflog entry on `HEAD` to notice it by.

If `HEAD`'s reflog has no entry for a commit that a branch's reflog records, that
commit was made this way and its fold needs verifying by hand.

### Commit & push policy
**Committing and pushing are one action here.** Anything committed is pushed to
its remote in the same breath — `master` → `origin`, `job` → the `job` remote —
without stopping to ask. Do not leave a commit sitting unpushed and do not ask
whether to push; an unpushed commit is the failure mode, because it strands the
change on one machine and leaves the next machine's sync reconciling a divergence
that never needed to exist.

This deliberately overrides the global default in `~/.claude/CLAUDE.md`, which
requires per-push confirmation and grants the exception to repos that state their
own policy. This is that statement.

What does *not* relax, because it governs **what** is published rather than
whether to publish:
- Never let work-/machine-specific content reach `origin` — see "never leak"
  above. Classify onto the right branch *before* committing, not after.
- Force-push only with `--force-with-lease`, and pin the lease to the ref.
- Push both halves after a `master` rewrite: `master`, then `job` rebased onto
  it. Half a fold published is worse than none.

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
