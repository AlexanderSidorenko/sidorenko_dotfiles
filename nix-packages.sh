#!/usr/bin/env bash
# Nix package install/reinstall helpers.
#
# THE LIST IS NOT HERE ANY MORE. It lives in ./manifests/packages.txt and is
# read below. It used to be a NIX_PACKAGES array in this file, which meant the
# same ~65 package names were also written out as environment.systemPackages
# by the NixOS host that consumes this repo. They had already drifted: this
# list carried git-lfs and the NixOS one did not, so `git status` in that repo
# failed with "git-lfs: command not found" on a machine whose dotfiles claimed
# to install it. One file, two readers now.
#
# Sourced by install.sh and shrc; defines NIX_PACKAGES, nix_install,
# nix_reinstall. The manifest ships with this repo, so the only way it can be
# missing is an incomplete checkout — in which case NIX_PACKAGES comes out
# empty and this file stays SILENT, because shrc sources it on every shell
# start and a warning here would print on every shell. The functions complain
# when actually called.

# This file's own directory IS the repo root. Derived from BASH_SOURCE rather
# than from $DOTDIR/$SIDORENKO_DOTFILES/$HOME, because those are unset in a
# bare `bash -c '. nix-packages.sh'` and guessing from $HOME then points
# somewhere that does not exist.
_nixpkg_self_dir() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || d=""
  if [[ -n $d ]]; then
    printf '%s' "$d"
  else
    printf '%s' "${DOTDIR:-${SIDORENKO_DOTFILES:-$HOME/.sidorenko_dotfiles}}"
  fi
}

# The manifests ship beside this file.
nix_manifest_dir() { printf '%s/manifests' "$(_nixpkg_self_dir)"; }

# Populate NIX_PACKAGES from the manifest, applying the same tag gates the
# NixOS side applies — minus `no-nixos`, since this path is nix-env on a
# non-NixOS box and those entries (nix itself, coreutils) are wanted here.
NIX_PACKAGES=()
_nix_packages_load() {
  local manifest_dir
  manifest_dir="$(nix_manifest_dir)"
  [[ -r "${manifest_dir}/manifest-lib.sh" ]] || return 1
  [[ -r "${manifest_dir}/packages.txt" ]] || return 1

  # shellcheck source=./manifests/manifest-lib.sh
  . "${manifest_dir}/manifest-lib.sh"

  # has_gui is defined by install.sh. In a plain interactive shell it is
  # absent, and we fall back to probing the environment the same way.
  local gui_flag="--no-gui"
  if declare -f has_gui >/dev/null 2>&1; then
    has_gui && gui_flag="--gui"
  elif [[ -n ${DISPLAY-}${WAYLAND_DISPLAY-} || $(uname) == Darwin ]]; then
    gui_flag="--gui"
  fi

  local platform
  platform="$(uname | tr '[:upper:]' '[:lower:]')"

  mapfile -t NIX_PACKAGES < <(
    manifest_packages "${manifest_dir}/packages.txt" \
      --platform "$platform" "$gui_flag"
  )
}
_nix_packages_load || true

# Tools that are NOT in nixpkgs and are built from a derivation kept in this
# repo instead. Each entry is a .nix file at the repo root that evaluates to a
# single derivation, installed by name with `nix-env -f <file> -i <name>`.
# Kept here rather than in packages.txt because these are local derivations
# specific to this repo, and NixOS does not install them this way at all.
NIX_LOCAL_DERIVATIONS=(
  "gitpane.nix gitpane"
)

# Repo root, whichever way this file was reached: install.sh exports DOTDIR,
# the shell config exports SIDORENKO_DOTFILES, and the default covers neither.
nix_dotdir() { _nixpkg_self_dir; }

# --- The nixpkgs PIN -------------------------------------------------------
#
# WHY PIN AT ALL. The goal is that EVERY PACKAGE THIS ASKS FOR ACTUALLY GETS
# INSTALLED. It is not that the versions match any other machine's — different
# platforms running different versions of the same tool is fine and expected.
#
# This used to be `nix-env -iA nixpkgs.<name>`, resolving against whatever the
# machine's `nix-channel` happened to be at that moment. That failed the goal
# outright, and a VM test caught it doing so:
#
#   the channel offered eternal-terminal 7.0.0, which is not in the binary
#   cache, so nix tried to build it and the build failed to compile (abseil
#   needs C++20 <compare>). `nix-env -iA` is ALL-OR-NOTHING, so that one
#   package left all 64 uninstalled.
#
# Pinning to a known rev means every name resolves to something already built
# and cached, so the batch completes. That is the whole argument: reliability
# and reproducibility of THIS install, nothing to do with matching elsewhere.
#
# THE REV LIVES IN ./flake.nix AND NOWHERE ELSE. A flake's `inputs` block
# cannot interpolate, so the URL there must be literal — which makes it the
# only possible single source for this value, and this function reads it back
# out rather than keeping a second copy. Parsed with grep so a fresh Ubuntu box
# needs no jq (jq is in packages.txt, i.e. one of the things not installed yet).
#
# Bumping it is a deliberate edit to flake.nix. A consumer's own pin may differ;
# that is not a fault.
nix_nixpkgs_rev() {
  local flake rev
  flake="$(nix_dotdir)/flake.nix"
  [[ -r $flake ]] || return 1
  rev="$(grep -oE 'github:NixOS/nixpkgs/[0-9a-f]{40}' "$flake" | head -1)"
  rev="${rev##*/}"
  [[ -n $rev ]] || return 1
  printf '%s' "$rev"
}

# The pinned nixpkgs as something `nix-env -f` accepts. A tarball URL rather
# than a flake ref so this works without the flakes feature enabled, which a
# stock Nix install does not have.
nix_nixpkgs_url() {
  local rev
  rev="$(nix_nixpkgs_rev)" || return 1
  printf 'https://github.com/NixOS/nixpkgs/archive/%s.tar.gz' "$rev"
}

# Fail with the real reason rather than "installing 0 packages".
_nix_packages_ready() {
  if (( ${#NIX_PACKAGES[@]} > 0 )); then
    return 0
  fi
  local manifest_dir
  manifest_dir="$(nix_manifest_dir)"
  echo "nix_install: the package list is empty." >&2
  if [[ ! -r "${manifest_dir}/packages.txt" ]]; then
    echo "nix_install: ${manifest_dir}/packages.txt is missing — incomplete checkout?" >&2
  else
    echo "nix_install: ${manifest_dir}/packages.txt yielded nothing — check the manifest" >&2
    echo "             and its tag gates with: ${manifest_dir}/validate.sh" >&2
  fi
  return 1
}

# Build and install every entry in NIX_LOCAL_DERIVATIONS. Slower than nix-env
# -iA against the channel, because the source is fetched and compiled locally --
# a few minutes on a cold store, nothing on a warm one.
nix_install_local() {
  local dotdir entry file attr output
  dotdir="$(nix_dotdir)"

  for entry in "${NIX_LOCAL_DERIVATIONS[@]}"; do
    file="${entry%% *}"
    attr="${entry##* }"
    if [[ ! -r "$dotdir/$file" ]]; then
      echo "nix_install_local: missing $dotdir/$file — skipping $attr" >&2
      continue
    fi
    echo "Building $attr from $file (this can take a few minutes)..."
    if ! output="$(nix-env -f "$dotdir/$file" -i "$attr" 2>&1)"; then
      printf '%s\n' "$output" >&2
      echo "nix_install_local: $attr failed — continuing" >&2
    fi
  done
}

# Install/upgrade every package in NIX_PACKAGES via nix-env -iA.
# Idempotent: re-running upgrades existing installs and adds missing ones.
nix_install() {
  if ! command -v nix-env >/dev/null 2>&1; then
    echo "nix_install: nix-env not found" >&2
    return 1
  fi

  # On NixOS this is the wrong tool: packages come from the system closure via
  # ./nix/home.nix reading this same manifest, and a parallel nix-env profile
  # would shadow them with a second, stale copy.
  if [[ -e /etc/NIXOS ]]; then
    echo "nix_install: this is NixOS — packages come from the system config," >&2
    echo "             not nix-env. Rebuild the host instead; its configuration" >&2
    echo "             imports this repo's nix/home.nix, which reads the same" >&2
    echo "             manifests/packages.txt." >&2
    return 1
  fi

  _nix_packages_ready || return 1

  # Resolve against the PINNED nixpkgs, not the machine's channel. See
  # nix_nixpkgs_rev above for why. Refused rather than silently falling back:
  # a quiet fall-back to the channel would reintroduce exactly the
  # irreproducibility this exists to remove, and would do it invisibly.
  local url
  if ! url="$(nix_nixpkgs_url)"; then
    echo "nix_install: cannot read the nixpkgs pin from $(nix_dotdir)/flake.nix." >&2
    echo "             Expected a 'github:NixOS/nixpkgs/<40-hex-rev>' URL there." >&2
    echo "             Refusing to fall back to the channel: that is unpinned," >&2
    echo "             and would install different versions than the NixOS side." >&2
    return 1
  fi

  # Attribute names are top-level under -f, so no `nixpkgs.` prefix.
  local nix_args=() pkg
  for pkg in "${NIX_PACKAGES[@]}"; do
    nix_args+=("$pkg")
  done

  # Quiet on success; only surface nix-env's output if the install fails.
  echo "Installing ${#NIX_PACKAGES[@]} packages from pinned nixpkgs ${url##*/archive/}"
  local output
  if ! output="$(nix-env -f "$url" -iA "${nix_args[@]}" 2>&1)"; then
    printf '%s\n' "$output" >&2
    # The usual cause is one package that is not in the binary cache for this
    # rev and fails to build, which takes the whole batch down with it. Say so,
    # because "64 packages failed" otherwise reads as something systemic.
    local failed
    failed="$(grep -oE "Cannot build '/nix/store/[a-z0-9]+-[^']*'" <<<"$output" |
              sed -E "s|.*/[a-z0-9]{32}-|  |; s|'$||" | sort -u | head -5)"
    if [[ -n $failed ]]; then
      echo "nix_install: nix-env is all-or-nothing, and these failed to BUILD:" >&2
      printf '%s\n' "$failed" >&2
      echo "             Everything else was fine. Either the pin needs bumping to a" >&2
      echo "             rev where they are cached, or drop them from packages.txt." >&2
    fi
    return 1
  fi

  nix_install_local
}

# Wipe every nix-env package, then reinstall from NIX_PACKAGES.
nix_reinstall() {
  if ! command -v nix-env >/dev/null 2>&1; then
    echo "nix_reinstall: nix-env not found" >&2
    return 1
  fi
  _nix_packages_ready || return 1

  echo "Querying installed packages..."
  local installed
  installed="$(nix-env -q)"
  if [[ -n $installed ]]; then
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
