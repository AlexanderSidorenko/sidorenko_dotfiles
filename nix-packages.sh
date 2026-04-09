#!/usr/bin/env bash
# Canonical list of Nix packages.
# Sourced by install.sh and shrc (nix_reinstall).
# Expects has_gui() to be defined by the caller.

NIX_PACKAGES=(
  ast-grep
  bat
  cargo
  cmark-gfm
  coreutils
  cscope
  delta
  direnv
  duf
  eternal-terminal
  eza
  fd
  fish
  fzf
  git
  jq
  lazygit
  lua
  luarocks
  mc
  moor
  mosh
  ncdu
  neovim
  nix
  pv
  qrencode
  ranger
  ripgrep
  sshpass
  tig
  tldr
  tmux
  tokei
  tree
  tree-sitter
  universal-ctags
  wget
  zoxide
  zstd
)

# Linux GUI-only packages (Wayland/X11 clipboard tools)
if [[ "$(uname)" == "Linux" ]] && has_gui; then
  NIX_PACKAGES+=(
    wl-clipboard
    xclip
  )
fi
