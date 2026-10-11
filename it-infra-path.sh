#!/usr/bin/env bash
# Locate the it_infra clone, which holds the shared dotfile manifests.
#
# WHY THIS FILE EXISTS. The canonical lists — which packages to install, where
# each dotfile goes, which GSettings keys to set — live in it_infra at
# desktop/nixos/dotfiles/, because the NixOS side has to read them during flake
# evaluation and a flake can only read files inside its own tree. This repo
# therefore consumes them from there instead of keeping its own copies, which
# is the whole point: one list, not two that drift.
#
# THE TRADE, stated plainly: this repo is no longer standalone. A fresh machine
# needs BOTH clones before install.sh can do anything. In practice it_infra is
# already cloned on every machine that gets these dotfiles, so the cost is a
# clear error message rather than a real obstacle — but it is a cost, and
# moving the manifests here would remove it at the price of the NixOS side
# needing to reach outside its flake.
#
# Sourced by: install.sh, nix-packages.sh (and so, transitively, shrc).
#
# Defines:
#   it_infra_dir       — print the clone path, or nothing if not found
#   it_infra_dotfiles  — print the manifest directory, or nothing
#   it_infra_require   — print the manifest directory or die with instructions
#
# MUST STAY QUIET WHEN NOT FOUND. shrc sources nix-packages.sh on every shell
# start, including non-interactive ones over ssh; a message here would print on
# every single shell. Only it_infra_require is allowed to speak up, and it is
# only called from paths the user invoked on purpose.

# Candidate locations, first match wins. $IT_INFRA overrides everything.
_it_infra_candidates() {
  [[ -n ${IT_INFRA-} ]] && printf '%s\n' "$IT_INFRA"
  printf '%s\n' \
    "${HOME}/code/it_infra" \
    "${HOME}/it_infra" \
    "${HOME}/src/it_infra" \
    "${HOME}/projects/it_infra"
}

# A directory is the real thing only if the manifests are actually in it —
# a half-clone or a same-named unrelated directory should not count.
_it_infra_valid() {
  local d="$1"
  [[ -n $d && -d $d ]] || return 1
  [[ -r "${d}/desktop/nixos/dotfiles/packages.txt" ]] || return 1
  [[ -r "${d}/desktop/nixos/dotfiles/links.txt" ]] || return 1
  return 0
}

it_infra_dir() {
  local d
  while IFS= read -r d; do
    if _it_infra_valid "$d"; then
      printf '%s' "$d"
      return 0
    fi
  done < <(_it_infra_candidates)
  return 1
}

it_infra_dotfiles() {
  local d
  d="$(it_infra_dir)" || return 1
  printf '%s' "${d}/desktop/nixos/dotfiles"
}

it_infra_require() {
  local d
  if d="$(it_infra_dotfiles)"; then
    printf '%s' "$d"
    return 0
  fi

  cat >&2 <<EOF

ERROR: cannot find the it_infra clone.

  The shared dotfile manifests (packages.txt, links.txt, gsettings.txt) live
  in it_infra at desktop/nixos/dotfiles/. This repo reads them from there so
  that the Ubuntu and NixOS paths install the same things — there is no second
  copy here to fall back on, by design.

  Looked in:
$(_it_infra_candidates | sed 's/^/    /')

  Fix either by cloning it:
    git clone <it_infra remote> "\$HOME/code/it_infra"

  or by pointing at an existing clone:
    export IT_INFRA=/path/to/it_infra

EOF
  return 1
}
