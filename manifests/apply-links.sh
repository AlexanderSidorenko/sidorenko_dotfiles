#!/usr/bin/env bash
# Apply the symlink-family rows of links.txt. Idempotent; safe to re-run.
#
# WHY ONE SCRIPT FOR TWO PLATFORMS. Placing a symlink is identical on Ubuntu
# and NixOS, so writing it twice — once in install.sh's bash, once in Nix —
# would be two implementations of one behaviour, drifting independently. Both
# callers run THIS, reading THAT table:
#
#   ../install.sh     --on-conflict prompt   (Ubuntu / macOS, by hand)
#   ../nix/home.nix   --on-conflict skip     (NixOS activation)
#
# WHICH KINDS THIS OWNS: link, link-children, copy, firefox-user-js,
# ssh-include.
#
# WHICH KINDS IT DOES NOT, and why. shell-source and git-include inject a block
# INTO a file home-manager itself writes. On NixOS ~/.bashrc and ~/.gitconfig
# are read-only symlinks into /nix/store, so appending to them is not merely
# unidiomatic, it is impossible. Those two are applied natively per platform
# (install.sh appends marker blocks; home.nix uses programs.bash / programs.zsh
# / programs.git), with BOTH sides reading the source and target out of
# links.txt. The data stays in one place; only the mechanism differs.
#
# ssh-include is the deliberate exception and belongs here, because ~/.ssh/config
# is the one injected file home-manager must NOT own. That file holds this
# machine's hand-written `Host forgejo` block naming the deploy key this repo's
# own git remote uses; enabling programs.ssh would replace it with a store
# symlink and break `git fetch` on the host that manages the host. So nothing
# declarative owns ~/.ssh/config, appending works on both platforms, and the
# logic lives here once instead of twice.
#
# This script never deletes a link it did not create and never replaces a real
# file without being told to — see --on-conflict.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./manifest-lib.sh
. "${HERE}/manifest-lib.sh"

LINKS_FILE="${HERE}/links.txt"
DOTDIR="${SIDORENKO_DOTFILES:-${HOME}/.sidorenko_dotfiles}"
TARGET_HOME="${HOME}"
ON_CONFLICT="skip"       # skip | prompt | replace
GUI=0
NIXOS=0
DRY_RUN=0
QUIET=0

# Auto-detect the two gates rather than making every caller pass them.
[[ -n ${DISPLAY-}${WAYLAND_DISPLAY-} || $(uname) == Darwin ]] && GUI=1
[[ -e /etc/NIXOS ]] && NIXOS=1

usage() {
  cat <<'EOF'
apply-links.sh — apply the symlink rows of links.txt

  --dotdir DIR         dotfiles repo root (default $SIDORENKO_DOTFILES or ~/.sidorenko_dotfiles)
  --home DIR           target home (default $HOME)
  --links FILE         manifest (default ./links.txt)
  --on-conflict MODE   skip (default) | prompt | replace
  --gui / --no-gui     override graphical-session detection
  --nixos / --no-nixos override NixOS detection
  --dry-run            report only, change nothing
  --quiet              only report changes and problems
  -h, --help           this
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dotdir)      DOTDIR="$2"; shift ;;
    --home)        TARGET_HOME="$2"; shift ;;
    --links)       LINKS_FILE="$2"; shift ;;
    --on-conflict) ON_CONFLICT="$2"; shift ;;
    --gui)         GUI=1 ;;
    --no-gui)      GUI=0 ;;
    --nixos)       NIXOS=1 ;;
    --no-nixos)    NIXOS=0 ;;
    --dry-run)     DRY_RUN=1 ;;
    --quiet)       QUIET=1 ;;
    -h|--help)     usage ;;
    *) printf '[dotlinks] ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$ON_CONFLICT" in
  skip|prompt|replace) ;;
  *) printf '[dotlinks] ERROR: --on-conflict must be skip, prompt or replace\n' >&2; exit 2 ;;
esac

log()  { (( QUIET )) || printf '[dotlinks] %s\n' "$*"; }
say()  { printf '[dotlinks] %s\n' "$*"; }
warn() { printf '[dotlinks] WARNING: %s\n' "$*" >&2; }
die()  { printf '[dotlinks] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d $DOTDIR ]]      || die "dotfiles repo not found at ${DOTDIR} (set SIDORENKO_DOTFILES or pass --dotdir)"
[[ -r $LINKS_FILE ]]  || die "manifest not readable: ${LINKS_FILE}"
[[ -d $TARGET_HOME ]] || die "target home not a directory: ${TARGET_HOME}"

CHANGED=0 SKIPPED=0 OK=0

# Replace, or refuse to, per --on-conflict. Returns 0 if the caller may write.
clear_target() {
  local dest="$1" what="$2"
  case "$ON_CONFLICT" in
    skip)
      warn "${dest} exists (${what}) and is not ours — skipping. Resolve by hand or re-run with --on-conflict replace."
      SKIPPED=$((SKIPPED + 1))
      return 1 ;;
    prompt)
      local reply
      read -r -p "[dotlinks] ${dest} exists (${what}). Replace? [y/N] " reply </dev/tty || reply=N
      case "${reply:-N}" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) log "kept ${dest}"; SKIPPED=$((SKIPPED + 1)); return 1 ;;
      esac ;;
    replace) ;;
  esac

  # Back up anything with real content so a wrong call is recoverable.
  if [[ -e $dest && ! -L $dest ]]; then
    local stamp bak
    stamp="$(date +%Y%m%d%H%M%S)"
    bak="${dest}.pre-dotfiles.${stamp}"
    if (( DRY_RUN )); then
      say "DRY-RUN would back up ${dest} -> ${bak}"
    else
      mv -- "$dest" "$bak" || die "could not back up ${dest}"
      say "backed up ${dest} -> ${bak}"
    fi
    return 0
  fi

  (( DRY_RUN )) || rm -f -- "$dest"
  return 0
}

# Idempotent symlink: $1 absolute source, $2 absolute target.
make_link() {
  local src="$1" dest="$2"

  [[ -e $src ]] || { warn "source missing, skipping: ${src}"; SKIPPED=$((SKIPPED + 1)); return; }

  # Already exactly right? Do nothing — this is the common case on re-run.
  if [[ -L $dest && "$(readlink -- "$dest")" == "$src" ]]; then
    log "ok       ${dest#"$TARGET_HOME"/}"
    OK=$((OK + 1))
    return
  fi

  if [[ -e $dest || -L $dest ]]; then
    local what="regular file"
    [[ -d $dest && ! -L $dest ]] && what="directory"
    [[ -L $dest ]] && what="symlink -> $(readlink -- "$dest")"
    clear_target "$dest" "$what" || return
  fi

  if (( DRY_RUN )); then
    say "DRY-RUN would link ${dest} -> ${src}"
    CHANGED=$((CHANGED + 1))
    return
  fi

  mkdir -p -- "$(dirname -- "$dest")" || die "could not create $(dirname -- "$dest")"
  ln -s -- "$src" "$dest" || die "could not link ${dest}"
  say "linked   ${dest#"$TARGET_HOME"/} -> ${src}"
  CHANGED=$((CHANGED + 1))
}

make_copy() {
  local src="$1" dest="$2"
  [[ -e $src ]] || { warn "source missing, skipping: ${src}"; SKIPPED=$((SKIPPED + 1)); return; }

  if [[ -e $dest ]] && cmp -s -- "$src" "$dest"; then
    log "ok       ${dest#"$TARGET_HOME"/} (copy up to date)"
    OK=$((OK + 1))
    return
  fi

  if [[ -e $dest || -L $dest ]]; then
    clear_target "$dest" "existing copy" || return
  fi

  if (( DRY_RUN )); then
    say "DRY-RUN would copy ${src} -> ${dest}"
    CHANGED=$((CHANGED + 1))
    return
  fi

  mkdir -p -- "$(dirname -- "$dest")"
  cp -f -- "$src" "$dest" || die "could not copy to ${dest}"
  say "copied   ${dest#"$TARGET_HOME"/}"
  CHANGED=$((CHANGED + 1))
}

# Firefox prefs: the profile directories are randomly named, so this is the one
# row whose target cannot be written down. Covers both packaging layouts.
apply_firefox_user_js() {
  local src="$1" found=0 root profile
  [[ -e $src ]] || { warn "source missing, skipping: ${src}"; return; }

  for root in "${TARGET_HOME}/.mozilla/firefox" \
              "${TARGET_HOME}/snap/firefox/common/.mozilla/firefox" \
              "${TARGET_HOME}/Library/Application Support/Firefox/Profiles"; do
    [[ -d $root ]] || continue
    for profile in "$root"/*/; do
      [[ -d $profile ]] || continue
      # Real profiles contain prefs.js; skip scratch dirs that do not.
      [[ -e "${profile}prefs.js" ]] || continue
      found=1
      make_copy "$src" "${profile}user.js"
    done
  done

  (( found )) || log "no Firefox profile found — skipping user.js"
}

# Add `Include <src>` to an ssh config, keeping the block LAST in the file.
#
# Position is not cosmetic. The included file holds `Host *` defaults, and
# OpenSSH keeps the FIRST value it obtains for each option — so an Include at
# the top makes those defaults beat every per-host block below it, silently.
# The marker text matches what install.sh has always written, so machines that
# already ran the old installer are recognised and not appended to twice.
apply_ssh_include() {
  local abs_src="$1" dest="$2" rel_src="$3"
  local open_marker='# >>> sidorenko_dotfiles >>>'
  local close_marker='# <<< sidorenko_dotfiles <<<'

  [[ -e $abs_src ]] || { warn "source missing, skipping: ${abs_src}"; SKIPPED=$((SKIPPED + 1)); return; }

  # Prefer a ~-relative path over the expanded one: ssh understands ~, and it
  # keeps the file portable across machines and user names. Falls back to the
  # absolute path if the repo lives outside $HOME.
  local dot_display="$DOTDIR"
  if [[ $DOTDIR == "$TARGET_HOME"/* ]]; then
    # shellcheck disable=SC2088
    # The literal ~ is INTENDED and must not be expanded by the shell: it is
    # written verbatim into ~/.ssh/config, where OpenSSH expands it itself.
    # Substituting $HOME here would bake this machine's absolute path into a
    # file that is meant to stay portable across hosts and user names.
    dot_display="~/${DOTDIR#"$TARGET_HOME"/}"
  fi
  local include_line="Include ${dot_display}/${rel_src}"

  if [[ -f $dest ]] && grep -qF "$include_line" "$dest"; then
    # Present. Is it last? Anything non-blank after the close marker means a
    # later Host block would be overridden by the Host * defaults.
    if ! grep -qF "$open_marker" "$dest"; then
      log "ok       ${dest#"$TARGET_HOME"/} (hand-managed Include; left alone)"
      OK=$((OK + 1))
      return
    fi
    if awk -v m="$close_marker" 'seen && NF {bad=1; exit} $0==m {seen=1} END{exit bad}' "$dest"; then
      log "ok       ${dest#"$TARGET_HOME"/} (Include present and last)"
      OK=$((OK + 1))
      return
    fi
    log "Include block is not last in ${dest} — moving it to the bottom"
  fi

  if (( DRY_RUN )); then
    say "DRY-RUN would add '${include_line}' at the bottom of ${dest}"
    CHANGED=$((CHANGED + 1))
    return
  fi

  mkdir -p -- "$(dirname -- "$dest")"
  chmod 700 "$(dirname -- "$dest")" 2>/dev/null || true
  touch -- "$dest"

  # Everything except our marker block and leading blank lines, then the block
  # re-appended at the end.
  local body
  body="$(awk -v mo="$open_marker" -v mc="$close_marker" '
    $0 == mo {inblock=1; next}
    $0 == mc {inblock=0; next}
    inblock  {next}
    !started && !NF {next}
    {started=1; print}' "$dest")"

  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || die "could not create a temp file beside ${dest}"
  {
    [[ -n $body ]] && printf '%s\n\n' "$body"
    printf '%s\n' "$open_marker"
    printf '# "Host *" defaults — keep this block LAST so per-host blocks above win.\n'
    printf '%s\n' "$include_line"
    printf '%s\n' "$close_marker"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$dest" || die "could not update ${dest}"
  say "updated  ${dest#"$TARGET_HOME"/} (Include kept last)"
  CHANGED=$((CHANGED + 1))
}

# ---------------------------------------------------------------------------
# Walk the manifest
# ---------------------------------------------------------------------------
log "repo:   ${DOTDIR}"
log "home:   ${TARGET_HOME}"
log "gates:  gui=${GUI} nixos=${NIXOS} on-conflict=${ON_CONFLICT}$( ((DRY_RUN)) && printf ' DRY-RUN')"

PLATFORM="$(uname | tr '[:upper:]' '[:lower:]')"
ARGS=(--platform "$PLATFORM")
(( GUI ))   && ARGS+=(--gui)   || ARGS+=(--no-gui)
(( NIXOS )) && ARGS+=(--nixos)

while IFS=$'\t' read -r kind src dest _tags; do
  abs_src="${DOTDIR}/${src}"
  abs_dest="${TARGET_HOME}/${dest}"

  case "$kind" in
    link)
      make_link "$abs_src" "$abs_dest"
      ;;

    link-children)
      if [[ ! -d $abs_src ]]; then
        warn "link-children source is not a directory: ${abs_src}"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      # Enumerated HERE, at apply time, not at Nix evaluation time. That is
      # the whole reason this is a script: ${DOTDIR} lives outside the flake,
      # and a pure flake evaluation cannot readDir an absolute path outside
      # its own source tree. Enumerating at runtime also means a new file in
      # claude/skills/ is picked up by re-running this, with no rebuild.
      shopt -s nullglob dotglob
      children=("$abs_src"/*)
      shopt -u nullglob dotglob
      if (( ${#children[@]} == 0 )); then
        log "no children under ${src}/ — nothing to link"
        continue
      fi
      for child in "${children[@]}"; do
        make_link "$child" "${abs_dest}/$(basename -- "$child")"
      done
      ;;

    copy)
      make_copy "$abs_src" "$abs_dest"
      ;;

    firefox-user-js)
      apply_firefox_user_js "$abs_src"
      ;;

    ssh-include)
      apply_ssh_include "$abs_src" "$abs_dest" "$src"
      ;;

    shell-source|git-include)
      # Not ours; see the header. Named explicitly so an unrecognised kind
      # below is a real error rather than a silent no-op.
      ;;

    *)
      warn "unknown kind '${kind}' for ${src} — ignored"
      ;;
  esac
done < <(manifest_links "$LINKS_FILE" "${ARGS[@]}")

printf '[dotlinks] %d changed, %d already correct, %d skipped\n' "$CHANGED" "$OK" "$SKIPPED"
(( SKIPPED > 0 )) && exit 3
exit 0
