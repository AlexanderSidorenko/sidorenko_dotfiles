#!/usr/bin/env bash
# Check the manifests in this directory before they can break a rebuild.
#
# WHY. ../nix/home.nix reads packages.txt at EVALUATION time, so a single bad
# attribute name does not fail one package — it fails the entire
# `nixos-rebuild`, with a Nix error that points at the module rather than at
# the typo. This script finds it in a few seconds instead, against the exact
# nixpkgs the flake pins.
#
# Also catches the cheap structural mistakes: a links.txt source that does not
# exist in the dotfiles repo, two rows writing the same target, an unknown
# kind, and bash/Nix disagreeing about how to parse the same file.
#
# Usage:
#   ./validate.sh                 # validate against the flake's pinned nixpkgs
#   ./validate.sh --nixpkgs PATH  # or against a specific nixpkgs
#   ./validate.sh --quick         # structure only; skip the slow nixpkgs eval
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./manifest-lib.sh
. "${HERE}/manifest-lib.sh"

# This directory is <repo>/manifests, so the repo root is one level up. Derived
# from the script's own location rather than from $HOME or
# $SIDORENKO_DOTFILES, so the checks work in a clone at any path — including
# the read-only store copy `nix flake check` runs against.
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
DOTDIR="$REPO_ROOT"
NIX_READER="${REPO_ROOT}/nix/manifest.nix"
NIXPKGS=""
QUICK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nixpkgs) NIXPKGS="$2"; shift ;;
    --dotdir)  DOTDIR="$2"; shift ;;
    --quick)   QUICK=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
FAILED=0
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; FAILED=1; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
head_ "packages.txt — structure"
# ---------------------------------------------------------------------------
PKG_FILE="${HERE}/packages.txt"
if [[ ! -r $PKG_FILE ]]; then
  bad "cannot read ${PKG_FILE}"
else
  mapfile -t ALL_PKGS < <(manifest_packages "$PKG_FILE" --platform linux --gui)
  ok "${#ALL_PKGS[@]} packages parse cleanly (linux, gui)"

  # Duplicates mean the list is being edited in two places at once.
  dupes="$(printf '%s\n' "${ALL_PKGS[@]}" | sort | uniq -d)"
  if [[ -n $dupes ]]; then
    bad "duplicate entries: $(tr '\n' ' ' <<<"$dupes")"
  else
    ok "no duplicates"
  fi

  # An unknown tag is almost always a typo, and it fails OPEN (the gate never
  # matches, so the package installs everywhere) — which is the silent kind.
  while IFS= read -r raw; do
    raw="$(_manifest_strip "$raw")"
    [[ -n $raw ]] || continue
    read -r _name tags <<<"$raw"
    [[ -n ${tags:-} ]] || continue
    IFS=',' read -ra tl <<<"$tags"
    for t in "${tl[@]}"; do
      case "$t" in
        linux|darwin|gui|no-nixos|nixos-only|nobin) ;;
        bin:?*) ;;
        bin:) bad "empty bin: tag in packages.txt line: ${raw}" ;;
        *) bad "unknown tag '${t}' in packages.txt line: ${raw}" ;;
      esac
    done
  done <"$PKG_FILE"
fi

# ---------------------------------------------------------------------------
head_ "links.txt — structure"
# ---------------------------------------------------------------------------
LINKS_FILE="${HERE}/links.txt"
if [[ ! -r $LINKS_FILE ]]; then
  bad "cannot read ${LINKS_FILE}"
else
  if ! rows="$(manifest_links "$LINKS_FILE" --gui 2>&1)"; then
    bad "links.txt failed to parse: ${rows}"
    rows=""
  else
    ok "$(grep -c . <<<"$rows") rows parse cleanly"
  fi

  declare -A SEEN_TARGET=()
  while IFS=$'\t' read -r kind src dest tags; do
    [[ -n ${kind:-} ]] || continue

    case "$kind" in
      link|link-children|copy|shell-source|git-include|ssh-include|firefox-user-js) ;;
      *) bad "unknown kind '${kind}' (row: ${kind} ${src} ${dest})" ;;
    esac

    # Source must exist in the dotfiles repo, else the link silently skips.
    if [[ -d $DOTDIR ]]; then
      if [[ ! -e "${DOTDIR}/${src}" ]]; then
        bad "source does not exist: ${DOTDIR}/${src}"
      fi
      if [[ $kind == link-children && ! -d "${DOTDIR}/${src}" ]]; then
        bad "link-children source is not a directory: ${DOTDIR}/${src}"
      fi
    fi

    # Two rows claiming one target is a real conflict — except git-include,
    # where stacking several includes into ~/.gitconfig is the intent.
    if [[ $dest != - && $kind != git-include ]]; then
      if [[ -n ${SEEN_TARGET[$dest]:-} ]]; then
        bad "target '${dest}' claimed twice (${SEEN_TARGET[$dest]} and ${kind})"
      fi
      SEEN_TARGET[$dest]="$kind"
    fi

    # Absolute or escaping paths would write outside $HOME / the repo.
    case "$src"  in /*|*..*) bad "source must be repo-relative: ${src}" ;; esac
    case "$dest" in /*|*..*) [[ $dest == - ]] || bad "target must be \$HOME-relative: ${dest}" ;; esac
  done <<<"$rows"

  [[ -d $DOTDIR ]] || warn "dotfiles repo not at ${DOTDIR}; skipped source-existence checks"
fi

# ---------------------------------------------------------------------------
head_ "bash and Nix agree on the manifests"
# ---------------------------------------------------------------------------
# The format IS implemented twice (bash in manifest-lib.sh, Nix in
# manifest.nix) because Nix cannot source bash. Running both readers over the
# same files is what keeps "two parsers" from becoming "two sources of truth".
#
# This check earns its keep: it is how the platform-gate bug was caught, where
# manifest.nix filtered links on linux/darwin tags and manifest-lib.sh did not,
# so the macOS font row would also have been applied on Linux.
if command -v nix >/dev/null 2>&1 && [[ -r "$NIX_READER" ]]; then
  nix_read() {
    # $1 = nix expression over `m`
    nix eval --impure --raw --expr \
      "let m = import $NIX_READER { lib = (import <nixpkgs> {}).lib; }; in $1" 2>/dev/null
  }

  for ctx in "linux:true:true" "linux:true:false" "darwin:true:false" "linux:false:false"; do
    IFS=':' read -r plat gui nixos <<<"$ctx"
    bash_args=(--platform "$plat")
    [[ $gui == true ]] && bash_args+=(--gui) || bash_args+=(--no-gui)
    [[ $nixos == true ]] && bash_args+=(--nixos)
    label="platform=${plat} gui=${gui} nixos=${nixos}"

    # packages
    if nix_list="$(nix_read "builtins.concatStringsSep \"\\n\" (m.packagesFor { gui = ${gui}; nixos = ${nixos}; platform = \"${plat}\"; })")"; then
      bash_list="$(manifest_packages "$PKG_FILE" "${bash_args[@]}" | sort)"
      if [[ "$(sort <<<"$nix_list")" == "$bash_list" ]]; then
        ok "packages agree (${label}): $(grep -c . <<<"$bash_list")"
      else
        bad "packages DISAGREE (${label}):"
        diff <(sort <<<"$nix_list") <(printf '%s\n' "$bash_list") | sed 's/^/      /'
      fi
    else
      warn "could not evaluate packagesFor (${label})"
    fi

    # links — compare kind/source/target triples
    if nix_links="$(nix_read "builtins.concatStringsSep \"\\n\" (map (r: \"\${r.kind} \${r.source} \${r.target}\") (m.linksFor { gui = ${gui}; nixos = ${nixos}; platform = \"${plat}\"; }))")"; then
      bash_links="$(manifest_links "$LINKS_FILE" "${bash_args[@]}" |
                    awk -F'\t' '{print $1" "$2" "$3}' | sort)"
      if [[ "$(sort <<<"$nix_links")" == "$bash_links" ]]; then
        ok "links agree (${label}): $(grep -c . <<<"$bash_links")"
      else
        bad "links DISAGREE (${label}):"
        diff <(sort <<<"$nix_links") <(printf '%s\n' "$bash_links") | sed 's/^/      /'
      fi
    else
      warn "could not evaluate linksFor (${label})"
    fi
  done
else
  warn "nix or nix/manifest.nix unavailable; skipping cross-reader check"
fi

# ---------------------------------------------------------------------------
head_ "every package exists in nixpkgs"
# ---------------------------------------------------------------------------
if (( QUICK )); then
  warn "--quick: skipped"
elif ! command -v nix >/dev/null 2>&1; then
  warn "nix not available; skipped"
elif (( ${#ALL_PKGS[@]} == 0 )); then
  warn "no packages parsed; skipped"
else
  if [[ -z $NIXPKGS ]]; then
    # Prefer the rev the flake pins, so this validates what will actually be
    # built rather than whatever the local channel happens to be.
    pinned="$(grep -oE 'github:NixOS/nixpkgs/[0-9a-f]{40}' "${REPO_ROOT}/flake.nix" 2>/dev/null |
              tail -1 | cut -d/ -f3)"
    local_rev=""
    if lp="$(nix-instantiate --find-file nixpkgs 2>/dev/null)"; then
      local_rev="$(cat "${lp}/.git-revision" 2>/dev/null || true)"
    fi
    if [[ -n $pinned && $pinned == "$local_rev" ]]; then
      NIXPKGS="$lp"
      ok "local nixpkgs IS the pinned rev (${pinned:0:12}) — validating offline"
    elif [[ -n $pinned ]]; then
      NIXPKGS="flake:github:NixOS/nixpkgs/${pinned}"
      warn "local nixpkgs (${local_rev:0:12}) != pinned (${pinned:0:12}); fetching the pin"
    else
      NIXPKGS="$lp"
      warn "could not read a pinned rev from flake.nix; using local nixpkgs"
    fi
  fi

  # One eval for the whole list: ~60 separate `nix eval` calls take minutes,
  # this takes seconds. tryEval per name so one bad name reports itself
  # instead of aborting the batch.
  expr='
    let
      pkgs = import NIXPKGS_PLACEHOLDER {};
      names = builtins.fromJSON (builtins.readFile NAMES_PLACEHOLDER);
      missing = builtins.filter (n:
        let r = builtins.tryEval (pkgs.${n}.outPath or pkgs.${n}.name);
        in !r.success || r.value == null
      ) names;
    in builtins.concatStringsSep " " missing
  '
  names_json="$(mktemp)"
  trap 'rm -f "$names_json"' EXIT
  { printf '['; first=1
    for p in "${ALL_PKGS[@]}"; do (( first )) || printf ','; printf '"%s"' "$p"; first=0; done
    printf ']'; } >"$names_json"

  case "$NIXPKGS" in
    flake:*) nixpkgs_expr="(builtins.getFlake \"${NIXPKGS#flake:}\").outPath" ;;
    *)       nixpkgs_expr="$NIXPKGS" ;;
  esac
  expr="${expr//NIXPKGS_PLACEHOLDER/$nixpkgs_expr}"
  expr="${expr//NAMES_PLACEHOLDER/$names_json}"

  if missing="$(nix eval --impure --raw --expr "$expr" 2>/dev/null)"; then
    if [[ -z ${missing// /} ]]; then
      ok "all ${#ALL_PKGS[@]} package names resolve in nixpkgs"
    else
      bad "these names do NOT exist in nixpkgs: ${missing}"
      bad "fix them in packages.txt — each one would fail the whole rebuild"
    fi
  else
    warn "nixpkgs evaluation failed; could not verify names"
  fi
fi

printf '\n'
if (( FAILED )); then
  printf '%sFAILED%s — fix the above before rebuilding.\n' "$C_RED" "$C_RESET"
  exit 1
fi
printf '%sAll manifest checks passed.%s\n' "$C_GREEN" "$C_RESET"
