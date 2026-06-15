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
    if confirm_yes_no "$prompt" N; then
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

  local src dest filename
  for src in "${hooks_src}"/*; do
    [[ -e "$src" ]] || continue
    filename="$(basename "$src")"
    dest="${hooks_dest}/${filename}"
    symlink_prompt "$src" "$dest"
  done
}

install_ranger() {
  local ranger_src="${DOTDIR}/ranger"
  local ranger_dest="${HOME}/.config/ranger"

  # 1. Sanity check: ensure source directory exists
  [[ -d "$ranger_src" ]] || die "Missing ranger config directory: $(name "$ranger_src")"

  # 2. Ensure ~/.config/ranger is a real directory
  ensure_dir_prompt "$ranger_dest" || return 0

  # 3. Auto-enumerate and link all files/directories found in source
  local src dest filename
  for src in "${ranger_src}"/*; do
    # Handle empty directory case (if glob returns literal string)
    [[ -e "$src" ]] || continue

    filename="$(basename "$src")"
    dest="${ranger_dest}/${filename}"

    symlink_prompt "$src" "$dest"
  done
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

install_alacritty() {
  # Alacritty itself is installed manually (not via Nix on Ubuntu — its OpenGL
  # stack doesn't play nice with Nix). We only manage the config here.
  local alacritty_src="${DOTDIR}/alacritty"
  local alacritty_dest="${HOME}/.config/alacritty"

  [[ -d "$alacritty_src" ]] || die "Missing alacritty config dir: $(name "$alacritty_src")"

  ensure_dir_prompt "$alacritty_dest" || return 0

  local src dest filename
  for src in "${alacritty_src}"/*; do
    [[ -e "$src" ]] || continue
    filename="$(basename "$src")"
    dest="${alacritty_dest}/${filename}"
    symlink_prompt "$src" "$dest"
  done
}

install_claude() {
  # Claude Code stores a lot of local state in ~/.claude (sessions, history,
  # credentials, projects). We only manage the tracked config files, symlinking
  # each into the existing directory rather than replacing the whole thing.
  local claude_src="${DOTDIR}/claude"
  local claude_dest="${HOME}/.claude"

  [[ -d "$claude_src" ]] || die "Missing claude config dir: $(name "$claude_src")"

  ensure_dir_prompt "$claude_dest" || return 0

  local src dest filename
  for src in "${claude_src}"/*; do
    [[ -e "$src" ]] || continue
    filename="$(basename "$src")"
    dest="${claude_dest}/${filename}"
    symlink_prompt "$src" "$dest"
  done
}

install_ssh_config() {
  local src="${DOTDIR}/ssh_config"
  local user_ssh_dir="${HOME}/.ssh"
  local user_ssh_config="${user_ssh_dir}/config"

  [[ -e "$src" ]] || die "Missing ssh_config: $(name "$src")"

  mkdir -p "$user_ssh_dir"
  chmod 700 "$user_ssh_dir"
  touch "$user_ssh_config"
  chmod 600 "$user_ssh_config"

  local include_line="Include ~/.sidorenko_dotfiles/ssh_config"
  if grep -qF "$include_line" "$user_ssh_config"; then
    log "$(name "$user_ssh_config") already includes sidorenko_dotfiles ssh_config"
    return 0
  fi

  log "Prepending Include block to $(name "$user_ssh_config")"
  # Include must come BEFORE any Host blocks to allow per-host overrides
  # in user's config (first match wins in OpenSSH).
  local tmp
  tmp="$(mktemp)"
  {
    printf '# >>> sidorenko_dotfiles >>>\n'
    printf '%s\n' "$include_line"
    printf '# <<< sidorenko_dotfiles <<<\n\n'
    cat "$user_ssh_config"
  } >"$tmp"
  mv "$tmp" "$user_ssh_config"
  chmod 600 "$user_ssh_config"
}

install_tmux() {
  local src="${DOTDIR}/tmux.conf"
  local dest="${HOME}/.tmux.conf"

  [[ -e "$src" ]] || die "Missing tmux config: $(name "$src")"
  symlink_prompt "$src" "$dest"
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
TARGET_DELAY_MS=195
TARGET_SPEED_MS=15

# MacOS uses "ticks" (1 tick = 15ms)
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

# Function to check and set Ubuntu (GNOME) key repeat values
configure_key_repeat_ubuntu() {
  if ! command -v gsettings &>/dev/null; then
    warn "Skipping keyboard repeat tuning: gsettings not found."
    return 0
  fi

  # Headless/minimal systems may have gsettings binary but no schemas/session.
  if ! gsettings list-schemas >/dev/null 2>&1; then
    warn "Skipping keyboard repeat tuning: gsettings schemas are unavailable."
    return 0
  fi

  if ! gsettings list-schemas | grep -Fxq "org.gnome.desktop.peripherals.keyboard"; then
    warn "Skipping keyboard repeat tuning: GNOME keyboard schema is unavailable."
    return 0
  fi

  # Check Delay (Strip 'uint32' if present)
  CURRENT_DELAY=$(gsettings get org.gnome.desktop.peripherals.keyboard delay 2>/dev/null | tr -cd '0-9')
  if [[ "$CURRENT_DELAY" != "$TARGET_DELAY_MS" ]]; then
    gsettings set org.gnome.desktop.peripherals.keyboard delay $TARGET_DELAY_MS
    KEY_REPEAT_CHANGE_MADE=1
  fi

  # Check Speed (Strip 'uint32' if present)
  CURRENT_SPEED=$(gsettings get org.gnome.desktop.peripherals.keyboard repeat-interval 2>/dev/null | tr -cd '0-9')
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
    warn "Skipping keyboard repeat tuning: unsupported operating system."
    return 0
  fi

  # Final Output
  if [[ "$KEY_REPEAT_CHANGE_MADE" -eq 1 ]]; then
    log "Settings updated. Please restart your user session for changes to take effect."
  else
    log "Settings already configured to snappy standards. No changes made."
  fi
}

# Set a gsettings key, skipping if the schema or key isn't installed
# (gsettings writable returns false in both cases).
gsettings_set() {
  local schema="$1"
  local key="$2"
  local value="$3"

  if gsettings writable "$schema" "$key" >/dev/null 2>&1; then
    gsettings set "$schema" "$key" "$value"
  else
    warn "Skipping non-writable gsettings key: $schema $key"
  fi
}

apply_gnome_tweaks() {
  # gsettings values: outer quotes are shell, inner quoting is the gsettings
  # type literal (string 'RIGHT', array ['<Super>1'], booleans/ints bare).

  # Fixed 4 workspaces.
  gsettings_set org.gnome.mutter dynamic-workspaces false
  gsettings_set org.gnome.desktop.wm.preferences num-workspaces 4

  # Workspaces on all monitors.
  gsettings_set org.gnome.mutter workspaces-only-on-primary false

  # App switching only within current workspace.
  gsettings_set org.gnome.shell.app-switcher current-workspace-only true

  # Super + 1..4 switches workspaces; Alt + 1..4 moves window to workspace.
  local i
  for i in 1 2 3 4; do
    gsettings_set org.gnome.desktop.wm.keybindings "switch-to-workspace-$i" "['<Super>$i']"
    gsettings_set org.gnome.desktop.wm.keybindings "move-to-workspace-$i" "['<Alt>$i']"
  done

  # Alt + click/drag manipulates windows (move with left, resize with right).
  gsettings_set org.gnome.desktop.wm.preferences mouse-button-modifier '<Alt>'

  # Disable GNOME Shell Super + number app switching. Clear 1..9, not just
  # 1..4, so 5..9 stay free if num-workspaces is later raised.
  for i in 1 2 3 4 5 6 7 8 9; do
    gsettings_set org.gnome.shell.keybindings "switch-to-application-$i" "[]"
  done

  # Disable Ubuntu Dock / Dash-to-Dock Super + number app launching.
  gsettings_set org.gnome.shell.extensions.dash-to-dock hot-keys false

  local kind
  for kind in app-hotkey app-shift-hotkey app-ctrl-hotkey; do
    for i in 1 2 3 4 5 6 7 8 9; do
      gsettings_set org.gnome.shell.extensions.dash-to-dock "$kind-$i" "[]"
    done
  done

  # Dock on the right + auto-hide.
  gsettings_set org.gnome.shell.extensions.dash-to-dock dock-position "'RIGHT'"
  gsettings_set org.gnome.shell.extensions.dash-to-dock dock-fixed false
  gsettings_set org.gnome.shell.extensions.dash-to-dock autohide true
  gsettings_set org.gnome.shell.extensions.dash-to-dock intellihide true

  # Disable window/workspace animations.
  gsettings_set org.gnome.desktop.interface enable-animations false

  # --- Appearance: dark mode + battery percentage ---
  gsettings_set org.gnome.desktop.interface color-scheme "'prefer-dark'"
  gsettings_set org.gnome.desktop.interface show-battery-percentage true

  # --- Power: never blank or auto-suspend (developer workstation) ---
  gsettings_set org.gnome.desktop.session idle-delay 0
  gsettings_set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "'nothing'"
  gsettings_set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 3600
  gsettings_set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 7200
  gsettings_set org.gnome.settings-daemon.plugins.power ambient-enabled false

  # --- Notifications: no popup banners, hidden on lock screen ---
  gsettings_set org.gnome.desktop.notifications show-banners false
  gsettings_set org.gnome.desktop.notifications show-in-lock-screen false

  # --- Touchpad: traditional (non-natural) scroll, two-finger right-click ---
  gsettings_set org.gnome.desktop.peripherals.touchpad natural-scroll false
  gsettings_set org.gnome.desktop.peripherals.touchpad click-method "'fingers'"

  # --- Display: enable fractional scaling (HiDPI) ---
  gsettings_set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"

  # --- Dock: per-workspace app indicators ---
  gsettings_set org.gnome.shell.extensions.dash-to-dock isolate-workspaces true

  # --- Tiling Assistant: orange active-window hint (no-op if extension absent) ---
  gsettings_set org.gnome.shell.extensions.tiling-assistant active-window-hint-color "'rgb(211,70,21)'"

  # --- Nautilus / file chooser: list view, show hidden files ---
  gsettings_set org.gnome.nautilus.preferences default-folder-viewer "'list-view'"
  gsettings_set org.gtk.gtk4.Settings.FileChooser show-hidden true

  # --- Keyboard: NumLock off at login ---
  gsettings_set org.gnome.desktop.peripherals.keyboard numlock-state false
}

maybe_configure_gnome() {
  if ! is_gnome; then
    log "Skipping GNOME tweaks (not a GNOME session)."
    return 0
  fi

  if ! command -v gsettings &>/dev/null; then
    warn "Skipping GNOME tweaks: gsettings not found."
    return 0
  fi

  if ! gsettings list-schemas >/dev/null 2>&1; then
    warn "Skipping GNOME tweaks: gsettings schemas are unavailable."
    return 0
  fi

  local prompt="${C_GREEN}[sidorenko_dotfiles] GNOME detected. Apply workspace/keybinding/dock tweaks? [y/N] ${C_RESET}"
  if ! confirm_yes_no "$prompt" N; then
    log "Skipped GNOME tweaks."
    return 0
  fi

  log "Applying GNOME tweaks..."
  apply_gnome_tweaks
  log "GNOME tweaks applied. Log out and back in for all changes to take effect."
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
  ensure_shrc_sources_repo bashrc shrc
  ensure_bash_profile_sources_bashrc
  ensure_shrc_sources_repo zshrc shrc
  ensure_zprofile_sources_zshrc
  maybe_switch_default_shell_to_zsh
  install_gitconfig
  install_git_hooks
  if has_gui; then
    install_font_droidsans_nerd
  else
    log "Skipping font install (headless)"
  fi
  install_ranger
  install_mc_keymap
  install_alacritty
  install_tmux
  install_claude
  install_ssh_config
  if has_gui; then
    make_keyboard_snappy
  else
    log "Skipping keyboard repeat tuning (headless)"
  fi
  if has_gui; then
    maybe_configure_gnome
  else
    log "Skipping GNOME tweaks (headless)"
  fi
  symlink_prompt "${DOTDIR}/nvim" "${HOME}/.config/nvim"

  # Nix supplies the nvim binary (and most other CLI tools), so install Nix
  # packages BEFORE restoring nvim plugins, which shells out to nvim. On a
  # fresh machine the old order skipped the restore because nvim wasn't there
  # yet.
  local prompt="${C_GREEN}[sidorenko_dotfiles] Install Nix packages? (This might take a while) [y/N] ${C_RESET}"
  if confirm_yes_no "$prompt" N; then
    install_nix_packages
  else
    log "Skipped Nix package installation."
  fi

  install_nvim_plugins

  # Non-Nix GUI apps last; they don't depend on anything above.
  maybe_install_extra_packages

  log "sidorenko_dotfiles successfully installed!"
}

main "$@"
