#!/usr/bin/env bash
set -euo pipefail

DOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

confirm_override() {
  local target="$1"
  local reply

  local prompt="${C_GREEN}[sidorenko_dotfiles] '${C_BLUE}${target}${C_GREEN}' exists. Override? [Y/n] ${C_RESET}"
  read -r -p "$prompt" reply || true
  reply="${reply:-Y}"

  case "$reply" in
  [Yy] | [Yy][Ee][Ss]) return 0 ;;
  *) return 1 ;;
  esac
}

confirm_yes_no() {
  local prompt="$1"
  local reply

  read -r -p "$prompt" reply || true
  reply="${reply:-N}"

  case "$reply" in
  [Yy] | [Yy][Ee][Ss]) return 0 ;;
  *) return 1 ;;
  esac
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

ensure_dir_prompt() {
  # Ensure PATH is a real directory. If something else exists, prompt to replace.
  local dir="$1"

  if [[ -d "$dir" && ! -L "$dir" ]]; then
    return 0
  fi

  if [[ -e "$dir" || -L "$dir" ]]; then
    if confirm_override "$dir"; then
      log "Removing: $(name "$dir")"
      rm_path "$dir"
    else
      log "Skipped creating dir: $(name "$dir")"
      return 1
    fi
  fi

  mkdir -p "$dir"
  log "Created dir: $(name "$dir")"
}

ensure_parent_dir() {
  mkdir -p "$(dirname "$1")"
}

symlink_prompt() {
  # Create/replace a symlink dest -> src (prompt before replacing).
  local src="$1"
  local dest="$2"

  [[ -e "$src" ]] || die "Source does not exist: $(name "$src")"
  ensure_parent_dir "$dest"

  # Already correct symlink? do nothing
  if [[ -L "$dest" ]]; then
    local cur
    cur="$(readlink "$dest")"
    if [[ "$cur" == "$src" ]]; then
      log "Symlink OK: $(name "$dest") -> $(name "$src")"
      return 0
    fi
  fi

  # Something exists at dest: prompt
  if [[ -e "$dest" || -L "$dest" ]]; then
    if confirm_override "$dest"; then
      log "Removing: $(name "$dest")"
      rm_path "$dest"
    else
      log "Skipped: $(name "$dest")"
      return 0
    fi
  fi

  ln -s "$src" "$dest"
  log "Linked: $(name "$dest") -> $(name "$src")"
}

ensure_shrc_sources_repo() {
  # Usage: ensure_rc_sources_repo bashrc
  local rc="$1"
  local repo_fragment="${DOTDIR}/${rc}"
  local user_rc="${HOME}/.${rc}"

  [[ -n "$rc" ]] || die "ensure_rc_sources_repo: missing rc name"
  [[ -e "$repo_fragment" ]] || die "Missing repo fragment: $(name "$repo_fragment")"

  # If ~/.<rc> exists but isn't a file/symlink, prompt to replace.
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
if [ -r "\$SIDORENKO_DOTFILES/${rc}" ]; then
  . "\$SIDORENKO_DOTFILES/${rc}"
fi
# <<< sidorenko_dotfiles <<<
EOF
}

install_gitconfig() {
  local repo_gitconfig="${DOTDIR}/gitconfig"
  local repo_gitconfig_personal="${DOTDIR}/gitconfig.personal"
  local user_gitconfig="${HOME}/.gitconfig"

  [[ -e "$repo_gitconfig" ]] || die "Missing gitconfig: $(name "$repo_gitconfig")"

  touch "$user_gitconfig"

  if grep -qE '^[[:space:]]*path = ~/.sidorenko_dotfiles/gitconfig$' "$user_gitconfig"; then
    log "$(name "$user_gitconfig") already includes sidorenko_dotfiles gitconfig"
  else
    log "Appending include block to $(name "$user_gitconfig")"
    cat >>"$user_gitconfig" <<EOF

# >>> sidorenko_dotfiles >>>
# Auto-added by \$HOME/.sidorenko_dotfiles/install.sh
[include]
  path = ~/.sidorenko_dotfiles/gitconfig
# <<< sidorenko_dotfiles <<<
EOF
  fi

  if [[ -e "$repo_gitconfig_personal" ]]; then
    if grep -qE '^[[:space:]]*path = ~/.sidorenko_dotfiles/gitconfig.personal$' "$user_gitconfig"; then
      log "$(name "$user_gitconfig") already includes sidorenko_dotfiles gitconfig.personal"
      return 0
    fi

    local prompt="${C_GREEN}[sidorenko_dotfiles] Install optional gitconfig.personal include? [y/N] ${C_RESET}"
    if confirm_yes_no "$prompt"; then
      log "Appending personal include block to $(name "$user_gitconfig")"
      cat >>"$user_gitconfig" <<EOF

# >>> sidorenko_dotfiles.personal >>>
# Auto-added by \$HOME/.sidorenko_dotfiles/install.sh
[include]
  path = ~/.sidorenko_dotfiles/gitconfig.personal
# <<< sidorenko_dotfiles.personal <<<
EOF
    else
      log "Skipped gitconfig.personal include"
    fi
  fi
}

install_ranger() {
  local ranger_dir="${HOME}/.config/ranger"
  local src="${DOTDIR}/ranger/rc.conf"
  local dest="${ranger_dir}/rc.conf"

  [[ -e "$src" ]] || die "Missing ranger config: $(name "$src")"

  # Ensure ~/.config/ranger is a real directory (not a symlink),
  # so we don't accidentally write into a symlinked tree.
  ensure_dir_prompt "$ranger_dir" || return 0

  symlink_prompt "$src" "$dest"
}

install_mc_keymap() {
  local mc_dir="${HOME}/.config/mc"
  local src="${DOTDIR}/mc.keymap"
  local dest="${mc_dir}/mc.keymap"

  [[ -e "$src" ]] || die "Missing mc keymap: $(name "$src")"

  # Ensure ~/.config/mc is a real directory (not a symlink),
  # so we don't accidentally write into a symlinked tree.
  ensure_dir_prompt "$mc_dir" || return 0

  symlink_prompt "$src" "$dest"
}

main() {
  log "Installing sidorenko_dotfiles from DOTDIR=$(name "$DOTDIR")..."
  ensure_shrc_sources_repo bashrc
  ensure_shrc_sources_repo zshrc
  install_gitconfig
  install_ranger
  install_mc_keymap
  log "sidorenko_dotfiles successfully installed!"
}

main "$@"
