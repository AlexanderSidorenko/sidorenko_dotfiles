# sidorenko_dotfiles

Personal dotfiles for Alexander Sidorenko. Targets Linux (primary) and macOS.

## Repo structure

```
install.sh          — interactive installer; idempotent, safe to re-run
manifests/          — THE SOURCE OF TRUTH: packages.txt, links.txt, gsettings.txt,
                      plus the appliers both platforms run (apply-links.sh,
                      apply-gsettings.sh), the shared parser (manifest-lib.sh)
                      and validate.sh
nix/                — the Nix-side face: home.nix (home-manager module) and
                      manifest.nix (Nix reader for manifests/). Not needed by
                      install.sh; a machine without Nix is unaffected
flake.nix           — exports nix/home.nix + packages.gitpane; how a NixOS host
                      consumes this repo as a pinned input
tests/              — ubuntu-vm.sh: boots a CLEAN Ubuntu cloud image under
                      QEMU/KVM, runs install.sh unattended, then measures the
                      result with manifests/verify-applied.sh
shrc                — unified shell config sourced by both bash and zsh
gitconfig           — git defaults (delta, nvim, moor pager)
gitconfig.personal  — optional personal identity include
gitpane.nix         — nix derivation for gitpane (not in nixpkgs); see NIX_LOCAL_DERIVATIONS
gitpane/            — gitpane config TEMPLATE, seeded to ~/.config/gitpane (never symlinked)
tmux.conf           — tmux config; prefix Ctrl+Space, vi keys
ripgreprc           — global rg flags
tigrc               — tig config; diffs open in git's pager (delta) via bin/tig-diff
mc.keymap           — Midnight Commander keymap
alacritty/          — Alacritty terminal config (TOML; alacritty itself installed manually)
firefox/            — user.js, copied into every Firefox profile (never symlinked)
nvim/               — Neovim config (LazyVim-based, Lua)
ranger/             — ranger file manager config
claude/             — Claude Code config (settings.json, CLAUDE.md, skills/; symlinked into ~/.claude)
bin/                — custom scripts (clip, mem, ram-health, ssh-host-setup.sh,
                      zswap-setup.sh, neovide, tmux-snapshot, tmux-restore,
                      sweep-branches, audit-repos, tig-diff, and the PR review helpers:
                      pr-help, pr-prep, pr-draft, pr-diff, pr-threads)
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

**`manifests/` is the source of truth.** What to install, where each dotfile
goes, and which GSettings keys to set are declared as data, not code:

| file | holds | read by |
|---|---|---|
| `manifests/packages.txt` | package names + `bin:`/`nobin`/platform tags | `nix-packages.sh` (Ubuntu), `nix/home.nix` (NixOS), `shrc:dotfiles_doctor` |
| `manifests/links.txt` | where each dotfile goes, by kind | `manifests/apply-links.sh` (both), `install.sh` (shell/git kinds) |
| `manifests/gsettings.txt` | GNOME preference keys + values | `manifests/apply-gsettings.sh` (both) |

`apply-links.sh` and `apply-gsettings.sh` are the shared appliers that
`install.sh` and `nix/home.nix` both call, so placement logic exists once
rather than once per platform. `manifests/validate.sh` checks the manifests and
proves the bash and Nix readers agree.

**This repo is standalone, and that is a hard requirement.** `install.sh`
needs nothing but this checkout. The dependency runs the other way: a NixOS
host takes this repo as a **pinned flake input** and imports
`nix/home.nix` —

```
it_infra  ---(pinned flake input)--->  sidorenko_dotfiles
```

— never the reverse. An earlier arrangement had the manifests living in
it_infra with `install.sh` reaching into it, which meant a fresh Ubuntu box
needed two clones before a single file could be placed. Do not reintroduce
that: nothing here may require another repo.

**`nix/` is the Nix-side face**, and deliberately the only thing a consumer
needs to know about. `nix/home.nix` is a home-manager module whose options
(`livePath`, `gui`, `manageGnomeSettings`, `sourceRev`) carry everything
machine-specific, so no consumer learns this repo's internal layout.
`nix/manifest.nix` is the Nix reader for the manifests. `flake.nix` exports
both plus `packages.gitpane` and a `nix flake check` that validates the
manifests. None of it is needed by `install.sh`; a machine with no Nix at all
works exactly as before.

**Pinned for packages, live for links.** On NixOS the package list is read at
*evaluation* time from the pinned input (so a rebuild is reproducible and
cannot be changed by an uncommitted edit), while the link table is read at
*activation* time from the live working tree (so editing a dotfile takes effect
immediately, as on Ubuntu). `nix/home.nix` warns at activation when the pinned
rev and the working tree have diverged.

**Adding a dotfile** is a row in `links.txt`, not a function here. Pick a kind:
`link`, `link-children` (per-entry, for live state dirs like `~/.claude`),
`copy` (for files an app writes to, or that AppArmor blocks via symlink),
`shell-source`, `git-include`, `ssh-include`, `firefox-user-js`.

**install.sh helpers** — `confirm_override` / `rm_path` for the few paths it
still touches itself, `ensure_shrc_sources_repo` for RC injection. The old
`symlink_prompt` / `copy_prompt` / `ensure_dir_prompt` helpers and the per-app
`install_*` functions are **gone**; their work is `links.txt` rows applied by
`apply-links.sh`.

## Testing in a VM

Reading `install.sh` proves nothing about whether it works; it is a thousand
lines of idempotent-by-assertion shell. Two VM tests exercise it for real, and
both run the **same** measurement script so the platforms cannot drift apart:

```bash
# Ubuntu: clean cloud image -> install.sh --yes -> measure
nix shell nixpkgs#qemu nixpkgs#cloud-utils nixpkgs#openssh nixpkgs#curl nixpkgs#iproute2 \
  --command ./tests/ubuntu-vm.sh
./tests/ubuntu-vm.sh --packages   # also install the ~66 Nix packages (slow)
./tests/ubuntu-vm.sh --shell      # drop into the guest afterwards to poke around

# NixOS: a nixosTest living in the consuming repo, which imports nix/home.nix
nix build <it_infra>#checks.x86_64-linux.desktop-dotfiles
```

`manifests/verify-applied.sh` is the measurement half, and is deliberately
separate from the appliers: `apply-links.sh` reporting "12 linked" says what it
*tried* to do, this says what is *true afterwards*. It is read-only, derives
every expectation from the manifests (so a new `links.txt` row extends both
tests with no edit), and emits TSV so the two platforms' results can be diffed
rather than eyeballed. Run it on any machine to audit it:

```bash
./manifests/verify-applied.sh            # human-readable; exit 1 on any failure
./manifests/verify-applied.sh --tsv      # status<TAB>category<TAB>item<TAB>detail
```

It checks *effects*, not markers — whether an interactive shell really ends up
with `shrc` loaded, whether git actually resolves the included config, whether
each gsettings key holds the declared value. That distinction earned its keep
on the first run: two checks that looked fine by grep were wrong in reality
(Ubuntu's `/etc/bash.bashrc` sudo hint polluted the shell probe, and
`git config --global` silently ignores `include.path` without `--includes`).

**`install.sh` must stay unattended-runnable.** `--non-interactive` / `--yes`
exist so the VM test can drive it; a new prompt that does not route through
`confirm_yes_no` / `confirm_override` will hang the test forever rather than
fail it.

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

## Important notes

- `shrc` is sourced by both bash and zsh — avoid bashisms or zshisms outside their respective `if` blocks.
- Tool integrations (fzf, zoxide, etc.) are guarded with `command -v` checks; keep this consistent for new additions.
- New tools that should be installed by default go in
  `manifests/packages.txt`. Look up exact Nix attribute names at
  https://search.nixos.org/packages before adding — **a name that does not
  exist fails the whole NixOS rebuild**, not just that package, because
  `nix/home.nix` reads the file at evaluation time. Run
  `manifests/validate.sh` after editing; it checks every name
  against the pinned nixpkgs in seconds. Platform-specific packages go in the
  Linux-only / GUI-only sections (`linux`, `gui` tags). Add `bin:NAME` when the
  command differs from the package name, or `nobin` when it provides no
  command, so `dotfiles_doctor` stays accurate.
- A tool that is **not in nixpkgs** gets a derivation at the repo root and an
  entry in `NIX_LOCAL_DERIVATIONS` (`nix-packages.sh`), as `"<file>.nix <attr>"`.
  `nix_install` builds those after the channel packages, so `nix_reinstall` —
  which wipes the profile with `nix-env -e '*'` — puts them back too. `gitpane.nix`
  is the worked example, including how to bump its pinned version.
- Most configs are symlinked, but a config the **application itself writes to**
  must be seeded instead: copy it on a machine that has none, then never touch
  it again (the `gitpane/config.toml` row). Symlinking one turns every in-app
  preference into a dirty tracked file, and makes machine-specific content —
  scan roots, private paths — tracked content in a public repo. Per-machine
  values belong in the live copy only, like `~/.bashrc.local` and
  `~/.claude/CLAUDE.machine.md`.
- A config consumed by a **snap** must be copied too, for a different reason:
  snapd's `home` interface grants no access to dot-directories in `$HOME`, so a
  symlink into `~/.sidorenko_dotfiles` is denied by AppArmor and the app starts
  as if the file were absent, silently. The `firefox-user-js` kind is the
  worked example — a `copy`, never a link, and placed once per Firefox profile,
  since `user.js` is only read from inside a profile directory. It is its own
  kind rather than a `copy` row because the profile directory names are random,
  so the target cannot be written down in the manifest.
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
- A **family** of related skills keeps its shared prose in one
  `claude/skills/<family>-references/` directory, which deliberately has no
  `SKILL.md`: every skill's description competes for one listing budget, so a
  contract stated once as reference material costs nothing, while a seventh
  skill to hold it would. Skills reach it as `../<family>-references/<file>`;
  `req-references/` and `pr-references/` are the worked examples. The
  *mechanical* half of a family belongs in `bin/` instead — a tested script
  doesn't decay when context is compacted, and re-deriving one every run does.

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
