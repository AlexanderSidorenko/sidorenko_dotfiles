#!/usr/bin/env bash
# Apply gsettings.txt. Idempotent; safe to run at every login.
#
# Called from BOTH
#   ../install.sh     (Ubuntu / macOS, run by hand)
#   ../nix/home.nix   (NixOS, graphical-session user unit)
#
# so the values in gsettings.txt are applied by one implementation on both
# platforms, with no GVariant->Nix translation layer to keep in step.
#
# SKIPS RATHER THAN FAILS, by design. A desktop-preferences layer must never be
# the reason a login or a rebuild fails, and most of what it touches is
# legitimately absent in some sessions:
#   - dash-to-dock / tiling-assistant exist on Ubuntu, not on stock GNOME
#   - a key can be locked down by a system override (then it is not writable)
#   - there may be no session bus at all (headless, or activation before login)
# Each of those is reported and stepped over. A genuinely wrong value — a bad
# enum, a type mismatch — IS reported as a failure, because that means this
# file is wrong and wants fixing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="${HERE}/gsettings.txt"
NIXOS=0
DRY_RUN=0
QUIET=0

[[ -e /etc/NIXOS ]] && NIXOS=1

usage() {
  cat <<'EOF'
apply-gsettings.sh — apply gsettings.txt

  --settings FILE       manifest (default ./gsettings.txt)
  --nixos / --no-nixos  override NixOS detection (gates the no-nixos rows)
  --dry-run             report only
  --quiet               only report changes and problems
  -h, --help            this
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)  SETTINGS_FILE="$2"; shift ;;
    --nixos)     NIXOS=1 ;;
    --no-nixos)  NIXOS=0 ;;
    --dry-run)   DRY_RUN=1 ;;
    --quiet)     QUIET=1 ;;
    -h|--help)   usage ;;
    *) printf '[gsettings] ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

log()  { (( QUIET )) || printf '[gsettings] %s\n' "$*"; }
say()  { printf '[gsettings] %s\n' "$*"; }
warn() { printf '[gsettings] WARNING: %s\n' "$*" >&2; }

[[ -r $SETTINGS_FILE ]] || { printf '[gsettings] ERROR: cannot read %s\n' "$SETTINGS_FILE" >&2; exit 1; }

if ! command -v gsettings >/dev/null 2>&1; then
  log "gsettings not installed — nothing to do."
  exit 0
fi

# No session bus means every write would land in the memory backend and be
# thrown away at exit, which looks like success and changes nothing.
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
  probe="/run/user/$(id -u)/bus"
  if [[ -S $probe ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${probe}"
    log "using session bus at ${probe}"
  else
    log "no D-Bus session bus — skipping (writes would go to the memory backend)."
    exit 0
  fi
fi

if ! gsettings list-schemas >/dev/null 2>&1; then
  log "gsettings schemas unavailable — skipping."
  exit 0
fi

# Schemas present in this session, so a missing extension is reported once
# rather than once per key (dash-to-dock alone is 32 rows).
declare -A HAVE_SCHEMA=()
while IFS= read -r s; do HAVE_SCHEMA["$s"]=1; done < <(gsettings list-schemas 2>/dev/null)

CHANGED=0 OK=0 SKIPPED=0 FAILED=0
declare -A MISSING_REPORTED=()

# Strip a GVariant type annotation and normalise whitespace, so the text
# `gsettings get` prints can be compared against the literal in the manifest.
#   "uint32 195"  -> "195"
#   "@as []"      -> "[]"
#   "@a{ss} {}"   -> "{}"
_gv_normalise() {
  local v="$1"
  # Leading explicit type: @<type> <value>
  v="$(sed -E 's/^@[a-zA-Z{}()ias]+[[:space:]]+//' <<<"$v")"
  # Leading named basic type: uint32 / int64 / byte / ...
  v="$(sed -E 's/^(uint16|uint32|uint64|int16|int32|int64|byte|double|handle)[[:space:]]+//' <<<"$v")"
  # Collapse internal whitespace and trim.
  v="$(tr -s '[:space:]' ' ' <<<"$v")"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

while IFS= read -r raw || [[ -n $raw ]]; do
  # Strip comments and trim. '#' only starts a comment at line start or after
  # whitespace, matching ./manifest-lib.sh.
  line="${raw%%$'\t'#*}"; line="${line%%' '#*}"
  [[ $line == '#'* ]] && line=''
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n $line ]] || continue

  # schema, key, then the value is the REST of the line (values may contain
  # spaces), with an optional trailing tag field.
  read -r schema key rest <<<"$line"
  [[ -n ${schema:-} && -n ${key:-} && -n ${rest:-} ]] || {
    warn "malformed row: ${line}"
    FAILED=1
    continue
  }

  # Peel a trailing tag word off the end if it is one of ours.
  tags=""
  last="${rest##* }"
  case "$last" in
    no-nixos|nixos-only|gui)
      if [[ $rest != "$last" ]]; then
        tags="$last"
        rest="${rest% *}"
        rest="${rest%"${rest##*[![:space:]]}"}"
      fi ;;
  esac
  value="$rest"

  # Tag gates.
  [[ $tags == no-nixos   ]] && (( NIXOS ))   && { SKIPPED=$((SKIPPED+1)); continue; }
  [[ $tags == nixos-only ]] && (( ! NIXOS )) && { SKIPPED=$((SKIPPED+1)); continue; }

  if [[ -z ${HAVE_SCHEMA[$schema]:-} ]]; then
    if [[ -z ${MISSING_REPORTED[$schema]:-} ]]; then
      log "schema not installed, skipping its keys: ${schema}"
      MISSING_REPORTED["$schema"]=1
    fi
    SKIPPED=$((SKIPPED+1))
    continue
  fi

  if ! gsettings writable "$schema" "$key" >/dev/null 2>&1; then
    log "not writable, skipping: ${schema} ${key}"
    SKIPPED=$((SKIPPED+1))
    continue
  fi

  current="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
  # `gsettings get` prints a GVariant with its TYPE ANNOTATION when the type is
  # not inferable from the text — `uint32 195` for the keyboard delay, `@as []`
  # for an empty string array. The manifest stores the bare literal that
  # `gsettings set` accepts, so a naive comparison never matches and every run
  # re-writes those keys, reporting a change each time and never looking
  # idempotent. Normalise both sides before comparing.
  if [[ "$(_gv_normalise "$current")" == "$(_gv_normalise "$value")" ]]; then
    OK=$((OK+1))
    continue
  fi

  if (( DRY_RUN )); then
    say "DRY-RUN ${schema} ${key}: ${current} -> ${value}"
    CHANGED=$((CHANGED+1))
    continue
  fi

  if err="$(gsettings set "$schema" "$key" "$value" 2>&1)"; then
    # Read back: a set can be accepted and then normalised to something else.
    now="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
    say "set ${schema} ${key} = ${now}"
    CHANGED=$((CHANGED+1))
  else
    warn "FAILED ${schema} ${key} = ${value}"
    warn "  ${err}"
    warn "  This usually means gsettings.txt holds a value this schema version"
    warn "  no longer accepts — fix the manifest rather than ignoring this."
    FAILED=1
  fi
done <"$SETTINGS_FILE"

printf '[gsettings] %d changed, %d already correct, %d skipped\n' "$CHANGED" "$OK" "$SKIPPED"
(( FAILED )) && exit 1
exit 0
