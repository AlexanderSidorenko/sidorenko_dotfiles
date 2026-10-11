#!/usr/bin/env bash
# Shared parser for the manifests in this directory.
#
# Sourced by:
#   ./validate.sh                            — checks the manifests
#   ./apply-links.sh                         — applies links.txt
#   ~/.sidorenko_dotfiles/nix-packages.sh    — Ubuntu package install
#
# The point of a library rather than three parsers is the same point as the
# manifests themselves: the FORMAT is also a fact, and a second implementation
# of it is a second thing to drift. The Nix side has its own reader in
# ../nix/home.nix because Nix cannot source bash — that one is the single
# unavoidable reimplementation, and ./validate.sh exists partly to prove the
# two agree on the same file.
#
# Pure bash 4+, no external commands in the hot path: this runs on a fresh
# Ubuntu box before any Nix package (jq, python) is installed.

# Strip comments and surrounding whitespace from one line.
# A '#' only starts a comment when it is at line start or preceded by
# whitespace, so a '#' inside a value is kept.
_manifest_strip() {
  local line="$1"
  line="${line%%$'\t'#*}"
  line="${line%%' '#*}"
  [[ $line == '#'* ]] && line=''
  # Trim leading/trailing whitespace.
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
}

# Does the comma-separated tag list $1 contain tag $2?
_manifest_has_tag() {
  local tags=",${1}," t=",${2},"
  [[ $tags == *"$t"* ]]
}

# manifest_packages <file> [--platform linux|darwin] [--gui|--no-gui] [--nixos]
#
# Prints one package name per line, filtered by tag. Defaults: platform from
# uname, GUI off, not NixOS.
manifest_packages() {
  local file="$1"; shift
  local platform gui=0 nixos=0
  platform="$(uname | tr '[:upper:]' '[:lower:]')"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)  platform="$2"; shift ;;
      --gui)       gui=1 ;;
      --no-gui)    gui=0 ;;
      --nixos)     nixos=1 ;;
      --no-nixos)  nixos=0 ;;
      *) printf 'manifest_packages: unknown option %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done

  [[ -r $file ]] || { printf 'manifest_packages: cannot read %s\n' "$file" >&2; return 1; }

  local raw name tags
  while IFS= read -r raw || [[ -n $raw ]]; do
    raw="$(_manifest_strip "$raw")"
    [[ -n $raw ]] || continue

    # Split on whitespace: first field is the name, second (if any) is tags.
    read -r name tags <<<"$raw"
    [[ -n $name ]] || continue
    tags="${tags:-}"

    # Tag gates.
    if _manifest_has_tag "$tags" linux && [[ $platform != linux ]]; then continue; fi
    if _manifest_has_tag "$tags" darwin && [[ $platform != darwin ]]; then continue; fi
    if _manifest_has_tag "$tags" gui && (( ! gui )); then continue; fi
    if _manifest_has_tag "$tags" no-nixos && (( nixos )); then continue; fi

    printf '%s\n' "$name"
  done <"$file"
}

# manifest_binaries <file> [same options as manifest_packages]
#
# Prints the COMMAND each selected package puts on PATH, one per line:
# the bin:NAME tag when present, otherwise the package name. Packages tagged
# nobin (shell plugins, coreutils) are omitted — they have nothing to check.
#
# This is what shrc's dotfiles_doctor iterates, instead of its own array.
manifest_binaries() {
  local file="$1"; shift
  local raw name tags t bin

  # Index the tag field by package name, then let manifest_packages do the
  # gating — so the platform/gui/nixos rules have exactly one implementation.
  local -A TAGS=()
  while IFS= read -r raw; do
    raw="$(_manifest_strip "$raw")"
    [[ -n $raw ]] || continue
    read -r name tags <<<"$raw"
    [[ -n $name ]] || continue
    TAGS["$name"]="${tags:-}"
  done <"$file"

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    tags="${TAGS[$name]:-}"
    _manifest_has_tag "$tags" nobin && continue

    bin="$name"
    IFS=',' read -ra _tl <<<"$tags"
    for t in "${_tl[@]}"; do
      case "$t" in bin:*) bin="${t#bin:}" ;; esac
    done
    printf '%s\n' "$bin"
  done < <(manifest_packages "$file" "$@")
}

# manifest_links <file> [--platform linux|darwin] [--gui|--no-gui] [--nixos]
#
# Prints one TAB-separated row per link: kind \t source \t target \t tags
#
# The platform gate matters as much here as it does for packages: the font row
# exists twice, once per OS, because the user font directory differs
# (.local/share/fonts vs Library/Fonts). Without this gate both rows applied on
# both systems.
manifest_links() {
  local file="$1"; shift
  local gui=0 nixos=0 platform
  platform="$(uname | tr '[:upper:]' '[:lower:]')"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)  platform="$2"; shift ;;
      --gui)       gui=1 ;;
      --no-gui)    gui=0 ;;
      --nixos)     nixos=1 ;;
      --no-nixos)  nixos=0 ;;
      *) printf 'manifest_links: unknown option %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done

  [[ -r $file ]] || { printf 'manifest_links: cannot read %s\n' "$file" >&2; return 1; }

  local raw kind src dest tags
  while IFS= read -r raw || [[ -n $raw ]]; do
    raw="$(_manifest_strip "$raw")"
    [[ -n $raw ]] || continue

    read -r kind src dest tags <<<"$raw"
    [[ -n $kind && -n $src && -n $dest ]] || {
      printf 'manifest_links: malformed row (need kind src target): %s\n' "$raw" >&2
      return 1
    }
    tags="${tags:-}"

    if _manifest_has_tag "$tags" linux && [[ $platform != linux ]]; then continue; fi
    if _manifest_has_tag "$tags" darwin && [[ $platform != darwin ]]; then continue; fi
    if _manifest_has_tag "$tags" gui && (( ! gui )); then continue; fi
    if _manifest_has_tag "$tags" no-nixos && (( nixos )); then continue; fi
    if _manifest_has_tag "$tags" nixos-only && (( ! nixos )); then continue; fi

    printf '%s\t%s\t%s\t%s\n' "$kind" "$src" "$dest" "$tags"
  done <"$file"
}
