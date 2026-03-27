#!/usr/bin/env bash
# Canonical list of Nix packages.
# Sourced by install.sh and shrc (nix_reinstall).

NIX_PACKAGES=(
  ast-grep
  bat
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
  pv
  qrencode
  ranger
  ripgrep
  sshpass
  tig
  tldr
  tmux
  tree
  tree-sitter
  universal-ctags
  wget
  zoxide
  zstd
)

# Linux-only packages (Wayland/X11 clipboard tools)
if [[ "$(uname)" == "Linux" ]]; then
  NIX_PACKAGES+=(
    wl-clipboard
    xclip
  )
fi
