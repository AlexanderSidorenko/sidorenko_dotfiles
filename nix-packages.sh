#!/usr/bin/env bash
# Canonical list of Nix packages plus install/reinstall helpers.
# Sourced by install.sh and shrc; defines NIX_PACKAGES, nix_install, nix_reinstall.

NIX_PACKAGES=(
  ast-grep
  bat
  caligula
  cargo
  cargo-deny
  cargo-shear
  clippy
  cmark-gfm
  codex
  cyme
  coreutils
  cscope
  curl
  delta
  direnv
  duf
  eternal-terminal
  eza
  fd
  fish
  fzf
  gh # GitHub CLI
  git
  gnumake # provides `make`
  htop
  jq
  lazygit
  lstr
  lua
  luarocks
  mc
  moor
  mosh
  ncdu
  neovim
  nix
  nodejs # provides node, npm, npx
  pv
  qrencode
  ranger
  ripgrep
  rust-analyzer
  rust-cbindgen
  rustc
  rustfmt
  sshpass
  tig
  tldr
  tmux
  tokei
  tree
  tree-sitter
  universal-ctags
  unzip
  vim
  wget
  zoxide
  zsh-autosuggestions
  zsh-syntax-highlighting
  zstd
)

# Linux GUI-only packages (Wayland/X11 clipboard tools).
# has_gui is defined by install.sh; in interactive shells we just skip the gate.
if [[ "$(uname)" == "Linux" ]] && declare -f has_gui >/dev/null 2>&1 && has_gui; then
  NIX_PACKAGES+=(
    wl-clipboard
    xclip
  )
fi

# Install/upgrade every package in NIX_PACKAGES via nix-env -iA.
# Idempotent: re-running upgrades existing installs and adds missing ones.
nix_install() {
  if ! command -v nix-env >/dev/null 2>&1; then
    echo "nix_install: nix-env not found" >&2
    return 1
  fi

  local nix_args=() pkg
  for pkg in "${NIX_PACKAGES[@]}"; do
    nix_args+=("nixpkgs.$pkg")
  done

  # Quiet on success; only surface nix-env's output if the install fails.
  echo "Installing ${#NIX_PACKAGES[@]} packages..."
  local output
  if ! output="$(nix-env -iA "${nix_args[@]}" 2>&1)"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# Wipe every nix-env package, then reinstall from NIX_PACKAGES.
nix_reinstall() {
  if ! command -v nix-env >/dev/null 2>&1; then
    echo "nix_reinstall: nix-env not found" >&2
    return 1
  fi

  echo "Querying installed packages..."
  local installed
  installed="$(nix-env -q)"
  if [[ -n "$installed" ]]; then
    echo "$installed"
    echo ""
    echo "Uninstalling all packages..."
    nix-env -e '*'
  else
    echo "(none)"
  fi

  echo ""
  nix_install
}
