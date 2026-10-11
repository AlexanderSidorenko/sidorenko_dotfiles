#!/usr/bin/env bash
# Interactive installer for these dotfiles. Idempotent; safe to re-run.
#
# WHAT MOVED, and why this file got ~450 lines shorter. The questions "which
# packages", "where does each dotfile go" and "which GSettings keys" are now
# answered by three manifests in ./manifests/:
#
#   manifests/packages.txt
#   manifests/links.txt
#   manifests/gsettings.txt
#
# with two shared appliers beside them, apply-links.sh and apply-gsettings.sh,
# that THIS script and the NixOS module in ./nix/home.nix both call. Before
# that, this file had its own symlink/copy/gsettings logic and its own package
# array, duplicating what a consuming NixOS host declared separately — and they
# had already drifted (the NixOS side was missing git-lfs).
#
# So the per-app installers that used to live here (install_tmux,
# install_ranger, install_alacritty, install_claude, install_gitpane,
# install_firefox_prefs, install_ssh_config, install_font_droidsans_nerd,
# apply_gnome_tweaks, configure_key_repeat_ubuntu) are gone, replaced by rows
# in links.txt / gsettings.txt. Adding a dotfile is now a line in a manifest,
# not a function here.
#
# WHAT STAYS HERE. Everything that is genuinely Ubuntu/macOS-only or cannot be
# expressed as data: apt and PPA packages, Obsidian, the Nix installation
# itself, the Claude Code native installer, the GNOME extension install, the
# nvim plugin restore, macOS `defaults write` key repeat, chsh, and the
# marker-block injections into ~/.bashrc / ~/.zshrc / ~/.gitconfig (on NixOS
# home-manager owns those files, so they cannot be appended to there).
#
# STANDALONE. This repo needs nothing but itself: the manifests live in
# ./manifests/ and so does the logic that applies them. An earlier version put
# them in the consuming it_infra repo and reached into it from here, which
# meant a fresh Ubuntu box needed two clones before this script could place a
# single file. The dependency now points the other way — a NixOS consumer takes
# THIS repo as a pinned flake input (see ./flake.nix) and imports
# ./nix/home.nix. Nothing in this repo knows that consumer exists.
set -euo pipefail

DOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${DOTDIR}/manifests"

# --- Run mode ---------------------------------------------------------------
# Interactive by default, because that is how this is normally used. The
# non-interactive modes exist so the installer can be TESTED: a VM harness
# boots a clean Ubuntu image, runs this unattended, and then measures the
# result with manifests/verify-applied.sh. Without them, nothing here could be
# exercised end to end — a prompt in a VM with no tty just hangs forever.
INTERACTIVE=1          # 0 = never read from stdin
ASSUME=default         # default | yes  — what non-interactive prompts answer
ON_CONFLICT=""         # passed to apply-links.sh; default depends on the mode
DO_NIX=1               # install Nix itself if absent
DO_PACKAGES=auto       # auto = ask (or default) | yes | no
DO_APT=1               # apt/PPA packages and Obsidian

# ---------- colors ----------
C_RESET=$'\033[0m'
C_GREEN=$'\033[32m'
C_BLUE=$'\033[34m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'

# Default color is green; names/paths/etc. are blue.
name() { printf '%b' "${C_BLUE}$1${C_GREEN}"; }

log() { printf '%b\n' "${C_GREEN}[sidorenko_dotfiles] $*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}[sidorenko_dotfiles] $*${C_RESET}"; }
die() {
  printf '%b\n' "${C_RED}[sidorenko_dotfiles] ERROR: $*${C_RESET}" >&2
  exit 1
}

# True if a graphical environment is available (macOS, X11, or Wayland).
has_gui() {
  [[ -n "${DISPLAY-}" || -n "${WAYLAND_DISPLAY-}" || "$(uname)" == "Darwin" ]]
}

# True if the current session is GNOME (or a GNOME-derived shell like Ubuntu).
is_gnome() {
  case "${XDG_CURRENT_DESKTOP-}" in
  *GNOME* | *gnome*) return 0 ;;
  esac
  case "${DESKTOP_SESSION-}" in
  *gnome* | *GNOME*) return 0 ;;
  esac
  return 1
}

confirm_override() {
  local target="$1"
  local reply

  # Non-interactive: this one defaults to YES when interactive, so --yes keeps
  # that and plain --non-interactive deliberately does NOT — overwriting a
  # file in someone's $HOME without being asked is not a safe default for an
  # unattended run.
  if (( ! INTERACTIVE )); then
    if [[ $ASSUME == yes ]]; then
      log "Non-interactive: overriding $(name "$target")"
      return 0
    fi
    warn "Non-interactive: keeping existing $(name "$target") (pass --yes to override)"
    return 1
  fi

  local prompt="${C_GREEN}[sidorenko_dotfiles] ${C_BLUE}${target}${C_GREEN} exists. Override? [Y/n] ${C_RESET}"
  read -r -p "$prompt" reply || true
  reply="${reply:-Y}"

  case "$reply" in
  [Yy] | [Yy][Ee][Ss]) return 0 ;;
  *) return 1 ;;
  esac
}

confirm_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local reply

  if (( ! INTERACTIVE )); then
    # --yes answers yes to everything; plain --non-interactive takes each
    # prompt's own documented default, so an unattended run behaves like a
    # user who pressed Enter at every question.
    if [[ $ASSUME == yes ]]; then
      return 0
    fi
    case "$default" in
    [Yy]) return 0 ;;
    *) return 1 ;;
    esac
  fi

  read -r -p "$prompt" reply || true
  case "$default" in
  [Yy]) reply="${reply:-Y}" ;;
  *) reply="${reply:-N}" ;;
  esac

  case "$reply" in
  [Yy] | [Yy][Ee][Ss]) return 0 ;;
  *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
install.sh — install these dotfiles. Idempotent; safe to re-run.

  -n, --non-interactive   never read stdin; every prompt takes its own default
  -y, --yes               implies -n and answers YES to every prompt
      --on-conflict MODE  what to do when a target exists and is not ours:
                          prompt (default when interactive) | skip | replace
      --no-nix            do not install Nix even if it is missing
      --packages          install the Nix package set (default when --yes)
      --no-packages       skip the Nix package set (much faster)
      --no-apt            skip apt/PPA packages and Obsidian
  -h, --help              this

The non-interactive modes exist so this can be tested unattended in a VM; see
manifests/verify-applied.sh for the measurement half.
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--non-interactive) INTERACTIVE=0 ;;
      -y|--yes)             INTERACTIVE=0; ASSUME=yes ;;
      --on-conflict)        ON_CONFLICT="$2"; shift ;;
      --no-nix)             DO_NIX=0 ;;
      --packages)           DO_PACKAGES=yes ;;
      --no-packages)        DO_PACKAGES=no ;;
      --no-apt)             DO_APT=0 ;;
      -h|--help)            usage ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  case "${ON_CONFLICT:-}" in
    ""|prompt|skip|replace) ;;
    *) die "--on-conflict must be prompt, skip or replace (got: ${ON_CONFLICT})" ;;
  esac

  # A prompt-based conflict policy cannot work without a tty, so pick a safe
  # one rather than hanging on a read that never returns.
  if [[ -z $ON_CONFLICT ]]; then
    if (( INTERACTIVE )); then
      ON_CONFLICT=prompt
    elif [[ $ASSUME == yes ]]; then
      ON_CONFLICT=replace
    else
      ON_CONFLICT=skip
    fi
  elif [[ $ON_CONFLICT == prompt ]] && (( ! INTERACTIVE )); then
    die "--on-conflict prompt cannot be used with --non-interactive"
  fi
}

rm_path() {
  local path="$1"
  if [[ -L "$path" || -f "$path" ]]; then
    rm -f "$path"
  elif [[ -d "$path" ]]; then
    rm -rf "$path"
  else
    rm -f "$path" 2>/dev/null || true
  fi
}


# --- Reading links.txt for the kinds this script still applies itself -------
#
# shell-source and git-include are injected by the functions below rather than
# by apply-links.sh, because on NixOS home-manager owns ~/.bashrc and
# ~/.gitconfig. But WHICH file to source and WHICH files to include are still
# facts that belong in the manifest, so they are read from it here instead of
# being written down a second time.

# Sourced once; defines manifest_links / manifest_packages / manifest_binaries.
# shellcheck source=./manifests/manifest-lib.sh
. "${MANIFEST_DIR}/manifest-lib.sh"

# Rows of one kind, as the non-NixOS platform sees them.
_manifest_rows_of_kind() {
  manifest_links "${MANIFEST_DIR}/links.txt" --no-nixos |
    awk -F'\t' -v k="$1" '$1==k'
}

# Print the repo-relative source of the single shell-source row.
manifest_shell_source() {
  local row
  row="$(_manifest_rows_of_kind shell-source | awk -F'\t' '{print $2; exit}')"
  [[ -n $row ]] || return 1
  printf '%s' "$row"
}

# Print the rc files the shell-source row targets, one per line (".bashrc").
manifest_shell_targets() {
  local targets
  targets="$(_manifest_rows_of_kind shell-source | awk -F'\t' '{print $3; exit}')"
  [[ -n $targets ]] || return 1
  tr ',' '\n' <<<"$targets"
}

# Print the repo-relative source of each git-include row, one per line.
manifest_git_includes() {
  _manifest_rows_of_kind git-include | awk -F'\t' '{print $2}'
}

ensure_shrc_sources_repo() {
  # Usage: ensure_shrc_sources_repo <user_rc> <repo_file>
  # e.g.  ensure_shrc_sources_repo bashrc shrc
  local user_rc_name="$1"
  local repo_file="$2"
  local repo_fragment="${DOTDIR}/${repo_file}"
  local user_rc="${HOME}/.${user_rc_name}"

  [[ -n "$user_rc_name" ]] || die "ensure_shrc_sources_repo: missing user rc name"
  [[ -n "$repo_file" ]] || die "ensure_shrc_sources_repo: missing repo file"
  [[ -e "$repo_fragment" ]] || die "Missing repo fragment: $(name "$repo_fragment")"

  # Prompt before replacing unexpected path types (e.g., dir or device file).
  if [[ -e "$user_rc" && ! -f "$user_rc" && ! -L "$user_rc" ]]; then
    if confirm_override "$user_rc"; then
      log "Removing: $(name "$user_rc")"
      rm_path "$user_rc"
    else
      log "Skipped $(name "$user_rc") setup"
      return 0
    fi
  fi

  touch "$user_rc"

  local begin="# >>> sidorenko_dotfiles >>>"
  if grep -qF "$begin" "$user_rc"; then
    log "$(name "$user_rc") already sources sidorenko_dotfiles"
    return 0
  fi

  log "Appending source block to $(name "$user_rc")"
  cat >>"$user_rc" <<EOF

# >>> sidorenko_dotfiles >>>
# Auto-added by \$HOME/.sidorenko_dotfiles/install.sh
export SIDORENKO_DOTFILES="\$HOME/.sidorenko_dotfiles"
if [ -r "\$SIDORENKO_DOTFILES/${repo_file}" ]; then
  . "\$SIDORENKO_DOTFILES/${repo_file}"
fi
# <<< sidorenko_dotfiles <<<
EOF
}

ensure_bash_profile_sources_bashrc() {
  local user_profile="${HOME}/.bash_profile"

  # Prompt before replacing unexpected path types (e.g., dir or device file).
  if [[ -e "$user_profile" && ! -f "$user_profile" && ! -L "$user_profile" ]]; then
    if confirm_override "$user_profile"; then
      log "Removing: $(name "$user_profile")"
      rm_path "$user_profile"
    else
      log "Skipped $(name "$user_profile") setup"
      return 0
    fi
  fi

  touch "$user_profile"

  if grep -qE '^[[:space:]]*(source|\.)[[:space:]]+~/.bashrc([[:space:]]|$)' "$user_profile"; then
    log "$(name "$user_profile") already sources .bashrc"
    return 0
  fi

  local begin="# >>> sidorenko_dotfiles.bash_profile >>>"
  if grep -qF "$begin" "$user_profile"; then
    log "$(name "$user_profile") already includes sidorenko_dotfiles bash_profile block"
    return 0
  fi

  log "Appending .bashrc source block to $(name "$user_profile")"
  cat >>"$user_profile" <<'EOF'

# >>> sidorenko_dotfiles.bash_profile >>>
# Auto-added by $HOME/.sidorenko_dotfiles/install.sh
if [ -r ~/.bashrc ]; then
  . ~/.bashrc
fi
# <<< sidorenko_dotfiles.bash_profile <<<
EOF
}

ensure_zprofile_sources_zshrc() {
  local user_profile="${HOME}/.zprofile"

  # Prompt before replacing unexpected path types (e.g., dir or device file).
  if [[ -e "$user_profile" && ! -f "$user_profile" && ! -L "$user_profile" ]]; then
    if confirm_override "$user_profile"; then
      log "Removing: $(name "$user_profile")"
      rm_path "$user_profile"
    else
      log "Skipped $(name "$user_profile") setup"
      return 0
    fi
  fi

  touch "$user_profile"

  if grep -qE '^[[:space:]]*(source|\.)[[:space:]]+~/.zshrc([[:space:]]|$)' "$user_profile"; then
    log "$(name "$user_profile") already sources .zshrc"
    return 0
  fi

  local begin="# >>> sidorenko_dotfiles.zprofile >>>"
  if grep -qF "$begin" "$user_profile"; then
    log "$(name "$user_profile") already includes sidorenko_dotfiles zprofile block"
    return 0
  fi

  log "Appending .zshrc source block to $(name "$user_profile")"
  cat >>"$user_profile" <<'EOF'

# >>> sidorenko_dotfiles.zprofile >>>
# Auto-added by $HOME/.sidorenko_dotfiles/install.sh
if [ -r ~/.zshrc ]; then
  . ~/.zshrc
fi
# <<< sidorenko_dotfiles.zprofile <<<
EOF
}

install_gitconfig() {
  local repo_gitconfig_personal="${DOTDIR}/gitconfig.personal"
  local user_gitconfig="${HOME}/.gitconfig"

  touch "$user_gitconfig"

  # Which files to include comes from links.txt's git-include rows, so adding
  # another include is a manifest line rather than another block here. The
  # marker suffix is derived from the file name, matching the markers the
  # earlier hand-written version used ("" for gitconfig, ".personal" for
  # gitconfig.personal), so machines installed before this refactor are
  # recognised and not appended to twice.
  local src marker suffix
  while IFS= read -r src; do
    [[ -n $src ]] || continue

    if [[ ! -e "${DOTDIR}/${src}" ]]; then
      # gitconfig.personal is legitimately optional.
      log "Skipping git include (absent): $(name "$src")"
      continue
    fi

    case "$src" in
      gitconfig)  suffix="" ;;
      gitconfig.*) suffix=".${src#gitconfig.}" ;;
      *)          suffix=".${src//\//-}" ;;
    esac
    marker="# >>> sidorenko_dotfiles${suffix} >>>"

    if grep -qE "^[[:space:]]*path = ~/\.sidorenko_dotfiles/${src//./\\.}\$" "$user_gitconfig"; then
      log "$(name "$user_gitconfig") already includes $(name "$src")"
      continue
    fi
    if grep -qF "$marker" "$user_gitconfig"; then
      log "$(name "$user_gitconfig") already has the $(name "$src") block"
      continue
    fi

    log "Appending include block for $(name "$src") to $(name "$user_gitconfig")"
    cat >>"$user_gitconfig" <<EOF

${marker}
# Auto-added by \$HOME/.sidorenko_dotfiles/install.sh (links.txt: git-include)
[include]
  path = ~/.sidorenko_dotfiles/${src}
# <<< sidorenko_dotfiles${suffix} <<<
EOF
  done < <(manifest_git_includes)

  # Always pin THIS repo to personal at the repo-local level, so it stays
  # personal even where the global identity is something else (e.g. the work
  # identity the job branch installs). Local config beats global.
  local pname pemail
  pname="$(git config -f "$repo_gitconfig_personal" user.name 2>/dev/null || true)"
  pemail="$(git config -f "$repo_gitconfig_personal" user.email 2>/dev/null || true)"
  if [[ -n "$pemail" ]]; then
    git -C "$DOTDIR" config --local user.name "$pname"
    git -C "$DOTDIR" config --local user.email "$pemail"
    log "Pinned $(name "$DOTDIR") commits to personal identity ($(name "$pemail"))"
  fi
}

install_git_hooks() {
  # Install this repo's own git hooks. commit-msg enforces the [job] commit
  # prefix convention from AGENTS.md. Hooks live under githooks/ and are
  # symlinked into the repo's real hooks dir, so edits to the tracked files
  # take effect immediately.
  local hooks_src="${DOTDIR}/githooks"

  if [[ ! -d "$hooks_src" ]]; then
    warn "Missing githooks dir; skipping git hook install."
    return 0
  fi

  local git_dir
  git_dir="$(git -C "$DOTDIR" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [[ -z "$git_dir" ]]; then
    log "Skipping git hook install ($(name "$DOTDIR") is not a git checkout)."
    return 0
  fi

  local hooks_dest="${git_dir}/hooks"
  mkdir -p "$hooks_dest"

  # Linked here rather than through links.txt / apply-links.sh on purpose:
  # that manifest maps repo files into $HOME, and these go into this repo's own
  # .git/hooks. They are not dotfiles and no other machine wants them.
  local src dest filename
  for src in "${hooks_src}"/*; do
    [[ -e "$src" ]] || continue
    filename="$(basename "$src")"
    dest="${hooks_dest}/${filename}"

    if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
      log "Hook OK: $(name "$filename")"
      continue
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
      if ! confirm_override "$dest"; then
        log "Skipped hook: $(name "$filename")"
        continue
      fi
      rm_path "$dest"
    fi
    ln -s "$src" "$dest"
    log "Linked hook: $(name "$filename")"
  done
}









maybe_switch_default_shell_to_zsh() {
  local current_shell=""
  local current_shell_base=""
  local zsh_path=""
  local prompt=""
  local user_name
  local passwd_entry=""

  user_name="$(id -un 2>/dev/null || echo "${USER:-}")"
  if [[ -z "$user_name" ]]; then
    warn "Cannot determine username. Skipping default shell switch."
    return 0
  fi

  if command -v getent &>/dev/null; then
    passwd_entry="$(getent passwd "$user_name" || true)"
    current_shell="$(printf '%s' "$passwd_entry" | cut -d: -f7)"
  elif [[ "$(uname)" == "Darwin" ]] && command -v dscl &>/dev/null; then
    current_shell="$(dscl . -read "/Users/${user_name}" UserShell 2>/dev/null | awk '{print $2}' || true)"
  fi

  if [[ -z "$current_shell" ]]; then
    current_shell="${SHELL:-}"
  fi

  current_shell_base="$(basename "${current_shell:-}")"
  if [[ "$current_shell_base" == "zsh" ]]; then
    log "Default shell already set to zsh"
    return 0
  fi

  if [[ -x /usr/bin/zsh ]]; then
    zsh_path="/usr/bin/zsh"
  else
    zsh_path="$(command -v zsh || true)"
  fi

  if [[ -z "$zsh_path" ]]; then
    if [[ "$(uname)" == "Linux" ]] && command -v apt &>/dev/null; then
      # We intentionally install distro zsh instead of Nix zsh because chsh expects
      # a stable shell path listed in /etc/shells (for example /usr/bin/zsh).
      prompt="${C_GREEN}[sidorenko_dotfiles] zsh is not installed. Install ${C_BLUE}zsh${C_GREEN} with apt now? [Y/n] ${C_RESET}"
      if confirm_yes_no "$prompt" Y; then
        if sudo apt update && sudo apt install -y zsh; then
          if [[ -x /usr/bin/zsh ]]; then
            zsh_path="/usr/bin/zsh"
          else
            zsh_path="$(command -v zsh || true)"
          fi
        else
          warn "Could not install zsh with apt."
        fi
      fi
    fi
  fi

  if [[ -z "$zsh_path" ]]; then
    warn "zsh is not installed. Skipping default shell switch."
    return 0
  fi

  prompt="${C_GREEN}[sidorenko_dotfiles] Default shell is ${C_BLUE}${current_shell:-unknown}${C_GREEN}. Change it to ${C_BLUE}${zsh_path}${C_GREEN}? [Y/n] ${C_RESET}"
  if ! confirm_yes_no "$prompt" Y; then
    log "Kept current default shell: $(name "${current_shell:-unknown}")"
    return 0
  fi

  if ! command -v chsh &>/dev/null; then
    warn "chsh command not found. Unable to change default shell."
    return 0
  fi

  if chsh -s "$zsh_path"; then
    log "Default shell changed to $(name "$zsh_path")"
    log "Open a new terminal session for the shell change to take effect."
  else
    warn "Could not change default shell automatically. You can run: chsh -s $zsh_path"
  fi
}


# Target keyboard repeat: 195 ms before the first repeat, 15 ms between.
#
# The millisecond values themselves now live in gsettings.txt (peripherals.
# keyboard delay / repeat-interval), which is what Linux reads. Only the macOS
# translation stays here, because macOS counts in "ticks" of 15 ms via
# `defaults write` rather than milliseconds via GSettings — there is nothing to
# share. Keep the two in step by hand if the target ever changes.
MAC_TARGET_DELAY=13 # 13 * 15ms = 195ms
MAC_TARGET_SPEED=1  # 1 * 15ms = 15ms

KEY_REPEAT_CHANGE_MADE=0

# Function to check and set macOS key repeat values
configure_key_repeat_macos() {
  # Check Accent Menu (Default is enabled/missing. We want it disabled 'false' or '0')
  CURRENT_PRESSHOLD=$(defaults read -g ApplePressAndHoldEnabled 2>/dev/null)
  if [[ "$CURRENT_PRESSHOLD" != "0" && "$CURRENT_PRESSHOLD" != "false" ]]; then
    defaults write -g ApplePressAndHoldEnabled -bool false
    KEY_REPEAT_CHANGE_MADE=1
  fi

  # Check Initial Delay
  CURRENT_DELAY=$(defaults read -g InitialKeyRepeat 2>/dev/null)
  if [[ "$CURRENT_DELAY" != "$MAC_TARGET_DELAY" ]]; then
    defaults write -g InitialKeyRepeat -int $MAC_TARGET_DELAY
    KEY_REPEAT_CHANGE_MADE=1
  fi

  # Check Repeat Speed
  CURRENT_SPEED=$(defaults read -g KeyRepeat 2>/dev/null)
  if [[ "$CURRENT_SPEED" != "$MAC_TARGET_SPEED" ]]; then
    defaults write -g KeyRepeat -int $MAC_TARGET_SPEED
    KEY_REPEAT_CHANGE_MADE=1
  fi
}

# macOS only. The Linux half used to live here as configure_key_repeat_ubuntu
# and is now two rows in gsettings.txt (peripherals.keyboard delay /
# repeat-interval), applied by apply-gsettings.sh like every other GNOME key.
#
# That move also fixed a real bug. The old check read the current value with
#
#     gsettings get ... delay | tr -cd '0-9'
#
# whose comment said "strip uint32 if present" — but tr keeps the 32 out of
# "uint32", so `uint32 195` became `32195`, never equalled the target 195, and
# the key was rewritten on EVERY run while reporting "Settings updated. Please
# restart your user session." It could never report "already configured".
# apply-gsettings.sh strips the GVariant type annotation properly.
#
# macOS cannot follow: it uses `defaults write -g InitialKeyRepeat` in 15 ms
# ticks rather than GSettings in milliseconds, so there is nothing to share.
make_keyboard_snappy() {
  if [[ "$(uname)" != "Darwin" ]]; then
    return 0
  fi

  log "Configuring keyboard to be snappy (macOS)..."
  configure_key_repeat_macos

  if [[ "$KEY_REPEAT_CHANGE_MADE" -eq 1 ]]; then
    log "Settings updated. Please restart your user session for changes to take effect."
  else
    log "Settings already configured to snappy standards. No changes made."
  fi
}

# The ~75 workspace / keybinding / dock / appearance keys are rows in
# gsettings.txt, applied by the shared apply-gsettings.sh. The schema and
# session checks that used to be duplicated here live in that script, which
# also skips keys whose schema is absent (dash-to-dock on stock GNOME) rather
# than failing.
maybe_configure_gnome() {
  if ! is_gnome; then
    log "Skipping GNOME tweaks (not a GNOME session)."
    return 0
  fi

  local manifest_dir="$MANIFEST_DIR"

  local prompt="${C_GREEN}[sidorenko_dotfiles] GNOME detected. Apply workspace/keybinding/dock tweaks? [y/N] ${C_RESET}"
  if ! confirm_yes_no "$prompt" N; then
    log "Skipped GNOME tweaks."
    return 0
  fi

  log "Applying GNOME preferences from $(name "gsettings.txt")..."
  # --no-nixos: this path is only ever taken on Ubuntu/macOS, and the no-nixos
  # rows exist precisely because NixOS modules own those keys there.
  if bash "${manifest_dir}/apply-gsettings.sh" --no-nixos; then
    log "GNOME tweaks applied. Log out and back in for all changes to take effect."
  else
    warn "Some GNOME preferences failed to apply (see above)."
  fi
}

# Place every dotfile named in links.txt. Replaces the per-app installers this
# file used to carry; the same script runs on NixOS from home.nix.
apply_dotfile_links() {
  local manifest_dir="$MANIFEST_DIR"

  log "Placing dotfiles from $(name "links.txt")..."

  # Built as an array rather than an unquoted command substitution, so the
  # flag cannot be word-split or glob-expanded.
  local -a args=(--dotdir "$DOTDIR" --on-conflict "$ON_CONFLICT")
  if has_gui; then args+=(--gui); else args+=(--no-gui); fi

  local rc=0
  # --on-conflict defaults to prompt interactively, which is this script's
  # long-standing behaviour: anything already in the way is asked about, not
  # silently replaced. Unattended runs get skip (or replace with --yes), and
  # nix/home.nix passes skip because an activation must never block on input.
  bash "${manifest_dir}/apply-links.sh" "${args[@]}" || rc=$?

  case "$rc" in
    0) ;;
    3) warn "Some dotfiles were skipped (listed above)." ;;
    *) die "apply-links.sh failed (exit ${rc})." ;;
  esac

  # Fonts are a `copy` row rather than a symlink, so the font cache has to be
  # told. NixOS does not need this: home.nix installs the packaged font and
  # fontconfig picks it up from the profile.
  if has_gui && [[ "$(uname)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f >/dev/null 2>&1 && log "Font cache refreshed."
  fi
}

# --- GNOME Shell extension: Astra Monitor (memory history plot in the top bar) ---
#
# https://extensions.gnome.org/extension/6682/astra-monitor/
# Chosen over the alternatives because it is the only one that draws a real
# history plot in the panel itself (rather than only in its dropdown), it is the
# only one that surfaces zswap, and it needs no dependencies and no root.
MEMORY_MONITOR_UUID="monitor@astraext.github.io"
MEMORY_MONITOR_EGO_ID=6682

# `gnome-extensions enable` cannot be used for a freshly installed extension. The
# shell only discovers extensions by scanning datadirs once at startup and keeps
# no directory monitor, so its D-Bus EnableExtension returns false for an unknown
# UUID; the CLI then reports "does not exist" and persists nothing. Writing the
# gsettings key directly works and takes effect at next login.
enable_gnome_extension() {
  local uuid="$1"
  local cur

  cur="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '@as []')"
  case "$cur" in
  *"'${uuid}'"*)
    log "Extension already enabled: $(name "$uuid")"
    ;;
  "@as []" | "[]")
    gsettings set org.gnome.shell enabled-extensions "['${uuid}']"
    ;;
  *)
    gsettings set org.gnome.shell enabled-extensions "${cur%]}, '${uuid}']"
    ;;
  esac

  # disabled-extensions takes precedence over enabled-extensions, and
  # disable-user-extensions is a global kill switch; neither must veto us.
  gsettings set org.gnome.shell disable-user-extensions false
}

# Panel config, memory only. Uses dconf rather than gsettings_set because an
# extensions.gnome.org schema is not in the default schema lookup path; dconf
# writes also work before the extension has ever been loaded.
configure_memory_monitor() {
  local d="/org/gnome/shell/extensions/astra-monitor"

  if ! command -v dconf &>/dev/null; then
    warn "dconf not found; leaving Astra Monitor at its defaults."
    return 0
  fi

  # memory-header-graph defaults to false, so without this there is no plot.
  dconf write "${d}/memory-header-show" true
  dconf write "${d}/memory-header-graph" true
  dconf write "${d}/memory-header-graph-width" 80
  dconf write "${d}/memory-header-graph-breakdown" true
  dconf write "${d}/memory-header-percentage" true
  dconf write "${d}/memory-header-bars" false
  dconf write "${d}/memory-update" 2.0

  # Keep the panel to memory alone. GPU stats in particular stay off: enabling
  # them is a known cause of periodic desktop hiccups.
  dconf write "${d}/processor-header-show" false
  dconf write "${d}/storage-header-show" false
  dconf write "${d}/network-header-show" false
  dconf write "${d}/gpu-header-show" false
}

install_memory_monitor() {
  local uuid="$MEMORY_MONITOR_UUID"

  if [[ -d "${HOME}/.local/share/gnome-shell/extensions/${uuid}" ]]; then
    log "Astra Monitor already installed; refreshing settings."
    enable_gnome_extension "$uuid"
    configure_memory_monitor
    return 0
  fi

  local shell_major
  shell_major="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  if [[ -z "$shell_major" ]]; then
    warn "Could not determine the GNOME Shell version; skipping Astra Monitor."
    return 0
  fi

  local info
  info="$(curl -fsSL "https://extensions.gnome.org/extension-info/?pk=${MEMORY_MONITOR_EGO_ID}&shell_version=${shell_major}" 2>/dev/null || true)"
  if [[ -z "$info" ]]; then
    warn "Could not reach extensions.gnome.org; skipping Astra Monitor."
    return 0
  fi

  # The API hands back a version_tag even for shell versions the extension does
  # not support, so trust shell_version_map instead of the top-level fields.
  local tag
  tag="$(printf '%s' "$info" | python3 -c 'import json, sys
entry = json.load(sys.stdin).get("shell_version_map", {}).get(sys.argv[1])
print(entry["pk"] if entry else "")' "$shell_major" 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    warn "Astra Monitor publishes no build for GNOME Shell ${shell_major}; skipping."
    return 0
  fi

  local zip
  zip="$(mktemp --suffix=.shell-extension.zip)"
  log "Downloading Astra Monitor build ${tag} for GNOME Shell ${shell_major}..."
  if curl -fsSL "https://extensions.gnome.org/download-extension/${uuid}.shell-extension.zip?version_tag=${tag}" -o "$zip"; then
    # install --force also compiles the extension's gsettings schemas for us.
    if gnome-extensions install --force "$zip"; then
      log "Installed $(name "$uuid")."
      enable_gnome_extension "$uuid"
      configure_memory_monitor
    else
      warn "gnome-extensions install failed for Astra Monitor."
    fi
  else
    warn "Could not download Astra Monitor from extensions.gnome.org."
  fi
  rm -f "$zip"
}

maybe_install_memory_monitor() {
  if ! is_gnome; then
    log "Skipping memory monitor (not a GNOME session)."
    return 0
  fi

  local tool
  for tool in gnome-extensions gsettings curl python3; do
    if ! command -v "$tool" &>/dev/null; then
      warn "Skipping memory monitor: ${tool} not found."
      return 0
    fi
  done

  local prompt="${C_GREEN}[sidorenko_dotfiles] Install Astra Monitor (memory graph in the top bar)? [y/N] ${C_RESET}"
  if ! confirm_yes_no "$prompt" N; then
    log "Skipped memory monitor."
    return 0
  fi

  install_memory_monitor
  log "Log out and back in to load it — Wayland cannot restart GNOME Shell in place."
}

install_nvim_plugins() {
  # Pin plugins to the commits in nvim/lazy-lock.json. Without this, lazy.nvim
  # auto-installs missing plugins at the latest branch commit and overwrites
  # the lockfile, defeating reproducibility.
  if ! command -v nvim &>/dev/null; then
    log "Skipping nvim plugin restore: nvim not installed."
    return 0
  fi

  if [[ ! -f "${DOTDIR}/nvim/lazy-lock.json" ]]; then
    log "Skipping nvim plugin restore: no lazy-lock.json."
    return 0
  fi

  log "Restoring nvim plugins to lockfile versions (may take a while on first run)..."
  local output
  if output="$(nvim --headless "+Lazy! restore" +qa 2>&1)"; then
    log "nvim plugin restore complete."
  else
    warn "nvim plugin restore failed; you can run :Lazy restore manually."
    printf '%s\n' "$output" >&2
  fi
}

# ---------------------------------------------------------------------------
# Non-Nix GUI apps. Everything that can come from Nix does (see nix-packages.sh);
# these stay on apt/PPA because their OpenGL/Electron stacks don't work well
# under Nix on Ubuntu. Each installer is idempotent and a no-op if present.
# ---------------------------------------------------------------------------

# Pinned Obsidian version (bump to upgrade).
OBSIDIAN_VERSION="1.12.7"

apt_pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

require_apt() {
  if ! command -v apt-get &>/dev/null; then
    warn "apt-get not found; skipping $1."
    return 1
  fi
}

# Alacritty: not in Nix on Ubuntu (OpenGL stack conflicts), so use the
# upstream maintainer's PPA. install_alacritty() above only manages the config.
install_alacritty_pkg() {
  require_apt "Alacritty" || return 0
  if apt_pkg_installed alacritty; then
    log "Alacritty already installed."
    return 0
  fi
  log "Adding Alacritty PPA (ppa:aslatter/ppa) and installing..."
  if ! command -v add-apt-repository &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y software-properties-common
  fi
  sudo add-apt-repository -y ppa:aslatter/ppa
  sudo apt-get update
  sudo apt-get install -y alacritty
}

install_obsidian() {
  require_apt "Obsidian" || return 0
  if apt_pkg_installed obsidian; then
    log "Obsidian already installed."
    return 0
  fi
  local url="https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/obsidian_${OBSIDIAN_VERSION}_amd64.deb"
  local deb
  deb="$(mktemp --suffix=.deb)"
  log "Downloading Obsidian ${OBSIDIAN_VERSION}..."
  if curl -fsSL "$url" -o "$deb"; then
    sudo apt-get install -y "$deb"
  else
    warn "Could not download Obsidian from $url"
  fi
  rm -f "$deb"
}

maybe_install_extra_packages() {
  local prompt="${C_GREEN}[sidorenko_dotfiles] Install non-Nix GUI apps (Alacritty, Obsidian)? [y/N] ${C_RESET}"
  if ! confirm_yes_no "$prompt" N; then
    log "Skipped non-Nix package installation."
    return 0
  fi
  if has_gui; then
    install_alacritty_pkg
    install_obsidian
  else
    log "Skipping GUI apps (headless)."
  fi
}

# Nix itself (multi-user daemon install). Nearly every CLI tool comes from Nix
# (see nix-packages.sh), so on a fresh machine this is the prerequisite for
# install_nix_packages below. The official installer is interactive and uses
# sudo internally; a no-op when /nix already exists.
maybe_install_nix() {
  if [[ -d /nix ]] || command -v nix-env &>/dev/null; then
    log "Nix already installed."
    return 0
  fi
  local prompt="${C_GREEN}[sidorenko_dotfiles] Nix is not installed. Run the official multi-user installer now? (interactive, uses sudo) [y/N] ${C_RESET}"
  if ! confirm_yes_no "$prompt" N; then
    log "Skipped Nix installation."
    return 0
  fi
  if curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install | sh -s -- --daemon; then
    # Make nix usable for the rest of THIS run (new shells get it via shrc).
    if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
      set +u
      # shellcheck disable=SC1091
      source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
      set -u
    fi
    log "Nix installed."
  else
    warn "Nix installation failed (see output above)."
  fi
}

# Claude Code binary. Native installer, no sudo: binary versions land in
# ~/.local/share/claude with a ~/.local/bin/claude symlink. Config/skills are
# handled separately by install_claude (symlinks into ~/.claude); credentials
# are per-machine — run `claude` and /login after installing.
maybe_install_claude_bin() {
  if command -v claude &>/dev/null || [[ -x "${HOME}/.local/bin/claude" ]]; then
    log "Claude Code already installed."
    return 0
  fi
  local prompt="${C_GREEN}[sidorenko_dotfiles] Claude Code is not installed. Install it now? (native installer, no sudo) [Y/n] ${C_RESET}"
  if ! confirm_yes_no "$prompt" Y; then
    log "Skipped Claude Code installation."
    return 0
  fi
  if curl -fsSL https://claude.ai/install.sh | bash; then
    log "Claude Code installed. Authenticate with: $(name "claude") then /login"
  else
    warn "Claude Code installation failed (see output above)."
  fi
}

# Function to install Nix packages
install_nix_packages() {
  log "Installing Nix packages..."

  # shellcheck source=nix-packages.sh
  source "${DOTDIR}/nix-packages.sh"

  log "The following packages will be installed: $(name "${NIX_PACKAGES[*]}")"

  if ! command -v nix-env &>/dev/null; then
    warn "nix-env command not found. Skipping Nix package installation."
    return 0
  fi

  if nix_install; then
    log "Nix package installation complete."
  else
    warn "Nix package installation failed (see output above)."
  fi
}

main() {
  log "Installing sidorenko_dotfiles from DOTDIR=$(name "$DOTDIR")..."

  # The manifests ship with this repo, so the only way they are missing is an
  # incomplete checkout. Fail here rather than halfway through.
  local manifest_dir="$MANIFEST_DIR"
  for required in packages.txt links.txt gsettings.txt manifest-lib.sh apply-links.sh; do
    [[ -r "${manifest_dir}/${required}" ]] ||
      die "missing ${manifest_dir}/${required} — incomplete checkout?
              Re-clone, or run: git -C $(name "$DOTDIR") status"
  done
  log "Manifests: $(name "$manifest_dir")"

  # On NixOS this script is the wrong tool for most of what follows:
  # ./nix/home.nix reads the same manifests declaratively, and a parallel
  # nix-env profile plus hand-appended ~/.bashrc blocks would fight
  # home-manager over files it owns.
  if [[ -e /etc/NIXOS ]]; then
    die "this is NixOS — the dotfiles are applied by the system configuration.
              Rebuild the host instead; it imports ./nix/home.nix, which reads
              the very same manifests this script would."
  fi

  # --- Shell and git: marker-block injections, Ubuntu/macOS only ----------
  # These append to files home-manager owns on NixOS, which is why they are
  # not in apply-links.sh. The file names still come from links.txt.
  local shell_src rc
  shell_src="$(manifest_shell_source)" ||
    die "links.txt has no shell-source row; cannot wire up the shell config"
  # Targets come from the manifest too (".bashrc,.zshrc"), so adding a shell
  # there needs no change here.
  while IFS= read -r rc; do
    [[ -n $rc ]] || continue
    ensure_shrc_sources_repo "${rc#.}" "$shell_src"
  done < <(manifest_shell_targets)

  ensure_bash_profile_sources_bashrc
  ensure_zprofile_sources_zshrc
  maybe_switch_default_shell_to_zsh
  install_gitconfig
  install_git_hooks

  # --- Everything named in links.txt --------------------------------------
  # One call replaces install_tmux / install_ranger / install_alacritty /
  # install_claude / install_gitpane / install_firefox_prefs /
  # install_ssh_config / install_font_droidsans_nerd / the nvim symlink.
  apply_dotfile_links

  maybe_install_claude_bin

  make_keyboard_snappy   # macOS only; Linux key repeat is in gsettings.txt

  if has_gui; then
    maybe_configure_gnome
    maybe_install_memory_monitor
  else
    log "Skipping GNOME tweaks (headless)"
  fi

  # Nix supplies the nvim binary (and most other CLI tools), so install Nix
  # packages BEFORE restoring nvim plugins, which shells out to nvim. On a
  # fresh machine the old order skipped the restore because nvim wasn't there
  # yet.
  if (( DO_NIX )); then
    maybe_install_nix
  else
    log "Skipping Nix installation (--no-nix)."
  fi

  # The package set is the slow part by far — ~66 packages to fetch — so it is
  # separately switchable. A VM run that only checks dotfile PLACEMENT can skip
  # it and finish in a minute; a full run installs everything.
  case "$DO_PACKAGES" in
    yes) install_nix_packages ;;
    no)  log "Skipped Nix package installation (--no-packages)." ;;
    *)
      local prompt="${C_GREEN}[sidorenko_dotfiles] Install Nix packages? (This might take a while) [y/N] ${C_RESET}"
      if confirm_yes_no "$prompt" N; then
        install_nix_packages
      else
        log "Skipped Nix package installation."
      fi
      ;;
  esac

  install_nvim_plugins

  # Non-Nix GUI apps last; they do not depend on anything above.
  if (( DO_APT )); then
    maybe_install_extra_packages
  else
    log "Skipping apt/PPA packages and Obsidian (--no-apt)."
  fi

  log "sidorenko_dotfiles successfully installed!"
}

parse_args "$@"
main
