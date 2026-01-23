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

copy_prompt() {
  # Copy src -> dest (prompt before replacing).
  local src="$1"
  local dest="$2"

  [[ -e "$src" ]] || die "Source does not exist: $(name "$src")"
  ensure_parent_dir "$dest"

  if [[ -e "$dest" || -L "$dest" ]]; then
    if confirm_override "$dest"; then
      log "Removing: $(name "$dest")"
      rm_path "$dest"
    else
      log "Skipped: $(name "$dest")"
      return 0
    fi
  fi

  cp -f "$src" "$dest"
  log "Copied: $(name "$dest")"
}

ensure_shrc_sources_repo() {
  # Usage: ensure_rc_sources_repo bashrc
  local rc="$1"
  local repo_fragment="${DOTDIR}/${rc}"
  local user_rc="${HOME}/.${rc}"

  [[ -n "$rc" ]] || die "ensure_rc_sources_repo: missing rc name"
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
if [ -r "\$SIDORENKO_DOTFILES/${rc}" ]; then
  . "\$SIDORENKO_DOTFILES/${rc}"
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

install_wezterm() {
  local wezterm_dir="${HOME}/.config/wezterm"
  local src="${DOTDIR}/wezterm/wezterm.lua"
  local dest="${wezterm_dir}/wezterm.lua"

  [[ -e "$src" ]] || die "Missing wezterm config: $(name "$src")"

  ensure_dir_prompt "$wezterm_dir" || return 0
  symlink_prompt "$src" "$dest"
}

install_font_droidsans_nerd() {
  local src="${DOTDIR}/DroidSansMNerdFont-Regular.otf"
  local font_dir
  local dest

  [[ -e "$src" ]] || die "Missing font: $(name "$src")"

  if [[ "$(uname)" == "Darwin" ]]; then
    font_dir="${HOME}/Library/Fonts"
  elif [[ "$(uname)" == "Linux" ]]; then
    font_dir="${HOME}/.local/share/fonts"
  else
    warn "Unsupported Operating System for font install."
    return 0
  fi

  ensure_dir_prompt "$font_dir" || return 0
  dest="${font_dir}/$(basename "$src")"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    log "Font already installed: $(name "$dest")"
    return 0
  fi
  copy_prompt "$src" "$dest"

  if [[ "$(uname)" == "Linux" ]] && command -v fc-cache &>/dev/null; then
    log "Updating font cache..."
    fc-cache -f "$font_dir" >/dev/null 2>&1 || true
  fi
}

# Target Keyboard Repeat Settings (Snappy: 150ms delay, 15ms interval)
TARGET_DELAY_MS=150
TARGET_SPEED_MS=15

# MacOS uses "ticks" (1 tick = 15ms)
MAC_TARGET_DELAY=10 # 10 * 15ms = 150ms
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

# Function to check and set Ubuntu (GNOME) key repeat values
configure_key_repeat_ubuntu() {
  if ! command -v gsettings &>/dev/null; then
    warn "Error: gsettings not found. Requires standard GNOME environment."
    exit 1
  fi

  # Check Delay (Strip 'uint32' if present)
  CURRENT_DELAY=$(gsettings get org.gnome.desktop.peripherals.keyboard delay | tr -cd '0-9')
  if [[ "$CURRENT_DELAY" != "$TARGET_DELAY_MS" ]]; then
    gsettings set org.gnome.desktop.peripherals.keyboard delay $TARGET_DELAY_MS
    KEY_REPEAT_CHANGE_MADE=1
  fi

  # Check Speed (Strip 'uint32' if present)
  CURRENT_SPEED=$(gsettings get org.gnome.desktop.peripherals.keyboard repeat-interval | tr -cd '0-9')
  if [[ "$CURRENT_SPEED" != "$TARGET_SPEED_MS" ]]; then
    gsettings set org.gnome.desktop.peripherals.keyboard repeat-interval $TARGET_SPEED_MS
    KEY_REPEAT_CHANGE_MADE=1
  fi
}

make_keyboard_snappy() {
  log "Configuring keyboard to be snappy..."

  # Detect OS and Run
  if [[ "$(uname)" == "Darwin" ]]; then
    configure_key_repeat_macos
  elif [[ "$(uname)" == "Linux" ]]; then
    configure_key_repeat_ubuntu
  else
    warn "Unsupported Operating System."
    exit 1
  fi

  # Final Output
  if [[ "$KEY_REPEAT_CHANGE_MADE" -eq 1 ]]; then
    log "Settings updated. Please restart your user session for changes to take effect."
  else
    log "Settings already configured to snappy standards. No changes made."
  fi
}

main() {
  log "Installing sidorenko_dotfiles from DOTDIR=$(name "$DOTDIR")..."
  ensure_shrc_sources_repo bashrc
  ensure_bash_profile_sources_bashrc
  ensure_shrc_sources_repo zshrc
  ensure_zprofile_sources_zshrc
  install_gitconfig
  install_font_droidsans_nerd
  install_ranger
  install_mc_keymap
  install_wezterm
  make_keyboard_snappy
  symlink_prompt "${DOTDIR}/nvim" "${HOME}/.config/nvim"
  log "sidorenko_dotfiles successfully installed!"
}

main "$@"
