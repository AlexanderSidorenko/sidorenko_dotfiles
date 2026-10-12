#!/usr/bin/env bash
# Measure whether what the manifests CLAIM is actually true of this machine.
#
# Read-only. Changes nothing, ever — it is the measurement half of the
# install/activate story, and it is deliberately separate from the appliers so
# a passing run is evidence rather than a tautology. apply-links.sh reporting
# "12 linked" says what it tried to do; this says what is true afterwards.
#
# THE CRITERION IS COMPLETENESS: everything the manifests ask for on THIS
# machine must actually be present on it. Every package named in packages.txt
# has its command on PATH, every links.txt row has landed, every gsettings key
# holds its declared value.
#
# VERSIONS ARE NOT CHECKED, and are not required to match any other machine.
# Two platforms resolving the same package LIST against their own nixpkgs will
# legitimately end up with different versions of the same tool; that is correct
# rather than drift, and nothing here looks at it.
#
# ONE SCRIPT, BOTH PLATFORMS. The same file runs in a fresh Ubuntu VM after
# install.sh and in a NixOS VM built from the flake, so the two are compared on
# identical measurements instead of two hand-written checklists that drift.
# Everything it expects is DERIVED from the manifests, so adding a row to
# links.txt extends the test automatically.
#
# Usage:
#   ./verify-applied.sh                  # human-readable, exit 1 on any failure
#   ./verify-applied.sh --tsv            # machine-readable, one row per check
#   ./verify-applied.sh --tsv --out F    # ... to a file
#   ./verify-applied.sh --skip packages  # drop a whole category
#
# Categories: links, packages, gsettings, shell, git, ssh
#
# TSV FORMAT (stable; the VM harnesses diff on it)
#   status<TAB>category<TAB>item<TAB>detail
# status ∈ PASS | FAIL | SKIP. SKIP is for things not applicable here (no
# Firefox profile, no GNOME session) and never counts as failure — but it IS
# reported, so "nothing was checked" can never masquerade as "all passed".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./manifest-lib.sh
. "${HERE}/manifest-lib.sh"

DOTDIR="${SIDORENKO_DOTFILES:-$(cd "${HERE}/.." && pwd)}"
TARGET_HOME="${HOME}"
TSV=0
OUT=""
SKIP_CATS=""
GUI=0
NIXOS=0
PLATFORM="$(uname | tr '[:upper:]' '[:lower:]')"

[[ -n ${DISPLAY-}${WAYLAND_DISPLAY-} || $PLATFORM == darwin ]] && GUI=1
[[ -e /etc/NIXOS ]] && NIXOS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tsv)       TSV=1 ;;
    --out)       OUT="$2"; shift ;;
    --dotdir)    DOTDIR="$2"; shift ;;
    --home)      TARGET_HOME="$2"; shift ;;
    --skip)      SKIP_CATS="${SKIP_CATS},$2"; shift ;;
    --gui)       GUI=1 ;;
    --no-gui)    GUI=0 ;;
    --nixos)     NIXOS=1 ;;
    --no-nixos)  NIXOS=0 ;;
    --platform)  PLATFORM="$2"; shift ;;
    -h|--help)   sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'verify-applied: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

PASS=0; FAIL=0; SKIPPED=0
ROWS=()

skipped_cat() { [[ ",${SKIP_CATS}," == *",$1,"* ]]; }

emit() {
  # $1 status, $2 category, $3 item, $4 detail
  ROWS+=("$1	$2	$3	$4")
  case "$1" in
    PASS) PASS=$((PASS+1)) ;;
    FAIL) FAIL=$((FAIL+1)) ;;
    SKIP) SKIPPED=$((SKIPPED+1)) ;;
  esac
  if (( ! TSV )); then
    local c=''
    case "$1" in
      PASS) c=$'\033[32m✓\033[0m' ;;
      FAIL) c=$'\033[31m✗\033[0m' ;;
      SKIP) c=$'\033[33m-\033[0m' ;;
    esac
    printf '  %s %-10s %-44s %s\n' "$c" "$2" "$3" "$4"
  fi
}

GATES=(--platform "$PLATFORM")
(( GUI ))   && GATES+=(--gui)   || GATES+=(--no-gui)
(( NIXOS )) && GATES+=(--nixos) || GATES+=(--no-nixos)

(( TSV )) || {
  printf '\n== verify-applied ==\n'
  printf '   repo=%s home=%s\n' "$DOTDIR" "$TARGET_HOME"
  printf '   platform=%s gui=%s nixos=%s\n\n' "$PLATFORM" "$GUI" "$NIXOS"
}

# ---------------------------------------------------------------------------
# links / copies — derived from links.txt, so new rows are tested for free
# ---------------------------------------------------------------------------
check_link() {
  local src="$1" dest="$2" item="$3"
  if [[ ! -L $dest ]]; then
    if [[ -e $dest ]]; then
      emit FAIL links "$item" "exists but is not a symlink"
    else
      emit FAIL links "$item" "missing"
    fi
    return
  fi
  local actual; actual="$(readlink -- "$dest")"
  if [[ $actual != "$src" ]]; then
    emit FAIL links "$item" "-> ${actual} (expected ${src})"
    return
  fi
  # A symlink pointing at nothing is worse than no symlink: it looks installed.
  if [[ ! -e $dest ]]; then
    emit FAIL links "$item" "dangling -> ${src}"
    return
  fi
  emit PASS links "$item" "-> ${src}"
}

if ! skipped_cat links; then
  while IFS=$'\t' read -r kind src dest _tags; do
    abs_src="${DOTDIR}/${src}"
    abs_dest="${TARGET_HOME}/${dest}"

    case "$kind" in
      link)
        check_link "$abs_src" "$abs_dest" "$dest"
        ;;

      link-children)
        if [[ ! -d $abs_src ]]; then
          emit FAIL links "$dest/*" "source dir missing: ${abs_src}"
          continue
        fi
        shopt -s nullglob dotglob
        children=("$abs_src"/*)
        shopt -u nullglob dotglob
        for child in "${children[@]}"; do
          base="$(basename -- "$child")"
          check_link "$child" "${abs_dest}/${base}" "${dest}/${base}"
        done
        # The whole point of link-children: the target must NOT be a symlink
        # itself, or live state in it (e.g. ~/.claude/sessions) would have been
        # swallowed into the repo.
        if [[ -L $abs_dest ]]; then
          emit FAIL links "$dest" "is a directory SYMLINK; must be a real dir"
        else
          emit PASS links "$dest" "real directory (live state preserved)"
        fi
        ;;

      copy)
        if [[ ! -e $abs_dest ]]; then
          emit FAIL links "$dest" "missing (copy)"
        elif [[ -L $abs_dest ]]; then
          emit FAIL links "$dest" "is a symlink; this row must be a real copy"
        elif cmp -s -- "$abs_src" "$abs_dest"; then
          emit PASS links "$dest" "copy matches source"
        else
          emit FAIL links "$dest" "copy differs from source"
        fi
        ;;

      firefox-user-js)
        found=0
        for root in "${TARGET_HOME}/.mozilla/firefox" \
                    "${TARGET_HOME}/snap/firefox/common/.mozilla/firefox" \
                    "${TARGET_HOME}/Library/Application Support/Firefox/Profiles"; do
          [[ -d $root ]] || continue
          for profile in "$root"/*/; do
            [[ -e "${profile}prefs.js" ]] || continue
            found=1
            if [[ ! -e "${profile}user.js" ]]; then
              emit FAIL links "firefox:$(basename "$profile")" "no user.js"
            elif [[ -L "${profile}user.js" ]]; then
              # AppArmor denies Firefox reading a symlink into a dot-directory,
              # so a link here means the prefs are silently not applied.
              emit FAIL links "firefox:$(basename "$profile")" "user.js is a symlink (AppArmor will deny it)"
            elif cmp -s -- "$abs_src" "${profile}user.js"; then
              emit PASS links "firefox:$(basename "$profile")" "user.js matches"
            else
              emit FAIL links "firefox:$(basename "$profile")" "user.js differs"
            fi
          done
        done
        (( found )) || emit SKIP links "firefox" "no Firefox profile on this machine"
        ;;

      shell-source|git-include|ssh-include)
        : # measured in their own categories below
        ;;

      *) emit FAIL links "$dest" "unknown kind '${kind}'" ;;
    esac
  done < <(manifest_links "${HERE}/links.txt" "${GATES[@]}")
fi

# ---------------------------------------------------------------------------
# packages — is each expected COMMAND actually runnable?
# ---------------------------------------------------------------------------
# Deliberately checks commands rather than "did the package manager claim
# success": the thing that matters is whether the tool runs. bin:/nobin tags in
# packages.txt carry the package -> command mapping.
#
# CHECKED AGAINST THE PATH A USER ACTUALLY GETS, not this script's own. That
# distinction is the whole check on Ubuntu: nix-env installs into
# ~/.nix-profile/bin, which joins PATH only when a shell sources shrc (or
# nix's profile.d). This script is typically invoked over a NON-interactive ssh
# command, where neither has happened — so an earlier version reported all 52
# nix-installed tools as "not on PATH" on a machine where every one of them
# worked fine in a real terminal. It passed on NixOS only by accident, because
# there home.packages land on the global system PATH.
#
# So: ask an interactive shell for its PATH once, then resolve against that.
# One shell spawn rather than one per package.
if ! skipped_cat packages; then
  user_path=""
  path_source="this script's PATH"
  for sh in "${SHELL:-}" bash zsh; do
    [[ -n $sh ]] && command -v "$sh" >/dev/null 2>&1 || continue
    probe="$("$sh" -ic 'printf "\nSDFPATH:%s:END\n" "$PATH"' 2>/dev/null |
             grep -o 'SDFPATH:.*:END' | tail -1)"
    if [[ -n $probe ]]; then
      user_path="${probe#SDFPATH:}"; user_path="${user_path%:END}"
      path_source="interactive ${sh##*/}"
      break
    fi
  done
  if [[ -z $user_path ]]; then
    user_path="$PATH"
    emit SKIP packages "(path)" "could not read an interactive PATH; using this script's"
  else
    emit PASS packages "(path)" "resolving against the ${path_source} PATH"
  fi

  while IFS= read -r cmd; do
    [[ -n $cmd ]] || continue
    # Subshell so the PATH override cannot leak into later checks.
    if found="$(PATH="$user_path" command -v "$cmd" 2>/dev/null)" && [[ -n $found ]]; then
      emit PASS packages "$cmd" "$found"
    else
      emit FAIL packages "$cmd" "not found on the ${path_source} PATH"
    fi
  done < <(manifest_binaries "${HERE}/packages.txt" "${GATES[@]}")
fi

# ---------------------------------------------------------------------------
# shell — does a LOGIN SHELL actually end up with the config loaded?
# ---------------------------------------------------------------------------
# The functional test, not a grep for a marker block: markers can be present
# while the file fails to load (a syntax error, a guard, a read-only rc). Each
# shell is asked whether a function and a variable that only shrc defines are
# in fact there.
if ! skipped_cat shell; then
  row="$(manifest_links "${HERE}/links.txt" "${GATES[@]}" | awk -F'\t' '$1=="shell-source"{print; exit}')"
  if [[ -z $row ]]; then
    emit SKIP shell "shell-source" "no such row for this platform"
  else
    shell_src="$(cut -f2 <<<"$row")"
    for sh in bash zsh; do
      if ! command -v "$sh" >/dev/null 2>&1; then
        emit SKIP shell "$sh" "not installed"
        continue
      fi
      # -i so the rc file is read; the marker-block guard in shrc returns
      # early for non-interactive shells by design.
      #
      # The answer is wrapped in a sentinel and then grepped OUT of the
      # output rather than compared against the whole of it, because a login
      # shell prints whatever it likes first. Ubuntu's /etc/bash.bashrc emits
      # a sudo hint ("To run a command as administrator...") for users in the
      # sudo group, which made a leading-match check report a perfectly
      # working bash as broken — caught by the first real VM run.
      out="$("$sh" -ic 'printf "\nSDFMARK:%s:%s:\n" \
          "$(declare -f dotfiles_doctor >/dev/null 2>&1 && echo fn || echo nofn)" \
          "${SIDORENKO_DOTFILES:-unset}"' 2>/dev/null |
        grep -o 'SDFMARK:[^:]*:[^:]*:' | tail -1)"
      if [[ $out == SDFMARK:fn:* ]]; then
        var="${out#SDFMARK:fn:}"; var="${var%:}"
        emit PASS shell "$sh" "sources ${shell_src} (SIDORENKO_DOTFILES=${var})"
      elif [[ $out == SDFMARK:nofn:* ]]; then
        emit FAIL shell "$sh" "rc ran but ${shell_src} was not sourced (no dotfiles_doctor)"
      else
        emit FAIL shell "$sh" "interactive shell produced no marker; rc file not read?"
      fi
    done

    # bin/ on PATH is shrc's job, and it is what makes the repo's own commands
    # runnable; check one that only this repo provides.
    if "${SHELL:-bash}" -ic 'command -v clip >/dev/null' 2>/dev/null; then
      emit PASS shell "bin-on-path" "repo bin/ is on PATH (clip found)"
    else
      emit FAIL shell "bin-on-path" "repo bin/ not on PATH in an interactive shell"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# git — are the includes actually in effect?
# ---------------------------------------------------------------------------
# Asks git, not the file: `git config --get-all include.path` resolves whatever
# combination of global config and includes is really in play, which is the
# thing that matters and the thing a hand-edited ~/.gitconfig can break.
if ! skipped_cat git; then
  if ! command -v git >/dev/null 2>&1; then
    emit SKIP git "include.path" "git not installed"
  else
    mapfile -t includes < <(HOME="$TARGET_HOME" git config --global --get-all include.path 2>/dev/null)
    while IFS=$'\t' read -r _kind src _dest _tags; do
      want_suffix="/${src}"
      hit=0
      for inc in "${includes[@]}"; do
        [[ $inc == *"$want_suffix" ]] && hit=1
      done
      if (( hit )); then
        emit PASS git "include:${src}" "present in git config"
      else
        # gitconfig.personal is legitimately optional.
        if [[ ! -e "${DOTDIR}/${src}" ]]; then
          emit SKIP git "include:${src}" "source absent in repo"
        else
          emit FAIL git "include:${src}" "not included by git"
        fi
      fi
    done < <(manifest_links "${HERE}/links.txt" "${GATES[@]}" | awk -F'\t' '$1=="git-include"')

    # The include must actually RESOLVE to settings, not merely be listed —
    # a wrong path in include.path is silently ignored by git.
    #
    # --includes is not optional: git turns include processing OFF by default
    # when a specific file is selected (--global, --file, ...) and ON only when
    # searching all config. Without it this read can never see an included
    # value, and reported a correctly-installed config as broken — caught by
    # the first real VM run.
    pager="$(HOME="$TARGET_HOME" git config --includes --global --get core.pager 2>/dev/null)"
    if [[ -n $pager ]]; then
      emit PASS git "effective" "include resolves (core.pager=${pager})"
    else
      emit FAIL git "effective" "include.path listed but core.pager did not resolve"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# ssh — Include present AND last
# ---------------------------------------------------------------------------
if ! skipped_cat ssh; then
  while IFS=$'\t' read -r _kind src dest _tags; do
    cfg="${TARGET_HOME}/${dest}"
    if [[ ! -r $cfg ]]; then
      emit FAIL ssh "${dest}" "no such file"
      continue
    fi
    if ! grep -qE "^[[:space:]]*Include[[:space:]].*/${src}\$" "$cfg"; then
      emit FAIL ssh "${dest}" "no Include for ${src}"
      continue
    fi
    # OpenSSH keeps the FIRST value per option, so a `Host *` include must come
    # last or it beats every per-host block below it.
    last_include_line="$(grep -nE "^[[:space:]]*Include[[:space:]].*/${src}\$" "$cfg" | tail -1 | cut -d: -f1)"
    trailing="$(awk -v n="$last_include_line" 'NR>n && NF && $0 !~ /^[[:space:]]*#/ {print; exit}' "$cfg")"
    if [[ -n $trailing ]]; then
      emit FAIL ssh "${dest}" "Include is not last (followed by: ${trailing})"
    else
      emit PASS ssh "${dest}" "Include present and last"
    fi
  done < <(manifest_links "${HERE}/links.txt" "${GATES[@]}" | awk -F'\t' '$1=="ssh-include"')
fi

# ---------------------------------------------------------------------------
# gsettings — do the declared keys actually hold the declared values?
# ---------------------------------------------------------------------------
_gv_normalise() {
  local v="$1"
  v="$(sed -E 's/^@[a-zA-Z{}()ias]+[[:space:]]+//' <<<"$v")"
  v="$(sed -E 's/^(uint16|uint32|uint64|int16|int32|int64|byte|double|handle)[[:space:]]+//' <<<"$v")"
  v="$(tr -s '[:space:]' ' ' <<<"$v")"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

if ! skipped_cat gsettings; then
  if ! command -v gsettings >/dev/null 2>&1; then
    emit SKIP gsettings "all" "gsettings not installed"
  elif [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]] && [[ ! -S "/run/user/$(id -u)/bus" ]]; then
    emit SKIP gsettings "all" "no D-Bus session bus (headless)"
  else
    if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
      _uid="$(id -u)"
      export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_uid}/bus"
    fi
    declare -A HAVE=()
    while IFS= read -r s; do HAVE["$s"]=1; done < <(gsettings list-schemas 2>/dev/null)

    while IFS= read -r raw || [[ -n $raw ]]; do
      line="${raw%%$'\t'#*}"; line="${line%%' '#*}"
      [[ $line == '#'* ]] && line=''
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n $line ]] || continue
      read -r schema key rest <<<"$line"
      [[ -n ${rest:-} ]] || continue

      tags=""
      last="${rest##* }"
      case "$last" in
        no-nixos|nixos-only|gui)
          if [[ $rest != "$last" ]]; then
            tags="$last"; rest="${rest% *}"
            rest="${rest%"${rest##*[![:space:]]}"}"
          fi ;;
      esac
      [[ $tags == no-nixos   ]] && (( NIXOS ))   && continue
      [[ $tags == nixos-only ]] && (( ! NIXOS )) && continue

      if [[ -z ${HAVE[$schema]:-} ]]; then
        emit SKIP gsettings "${schema##*.} ${key}" "schema not installed"
        continue
      fi
      got="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
      if [[ "$(_gv_normalise "$got")" == "$(_gv_normalise "$rest")" ]]; then
        emit PASS gsettings "${schema##*.} ${key}" "$(_gv_normalise "$got")"
      else
        emit FAIL gsettings "${schema##*.} ${key}" "is $(_gv_normalise "$got"), want $(_gv_normalise "$rest")"
      fi
    done <"${HERE}/gsettings.txt"
  fi
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if (( TSV )); then
  # Written WITHOUT redirecting to /dev/stdout when no --out is given. That
  # redirect silently produced an empty capture when stdout was a pipe rather
  # than a tty — which is exactly how this is called from the VM harnesses, and
  # it yielded an empty artefact while the run still reported success.
  emit_tsv() {
    printf '# platform=%s gui=%s nixos=%s home=%s repo=%s\n' \
      "$PLATFORM" "$GUI" "$NIXOS" "$TARGET_HOME" "$DOTDIR"
    printf '# totals pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIPPED"
    (( ${#ROWS[@]} )) && printf '%s\n' "${ROWS[@]}"
  }
  if [[ -n $OUT ]]; then
    emit_tsv >"$OUT"
    printf 'verify-applied: %d pass, %d fail, %d skip -> %s\n' \
      "$PASS" "$FAIL" "$SKIPPED" "$OUT"
  else
    emit_tsv
  fi
else
  printf '\n  %d pass, %d fail, %d skip\n' "$PASS" "$FAIL" "$SKIPPED"
  if (( FAIL )); then
    printf '\n  FAILURES:\n'
    printf '%s\n' "${ROWS[@]}" | awk -F'\t' '$1=="FAIL"{printf "    %s %s: %s\n", $2, $3, $4}'
  fi
  printf '\n'
fi

(( FAIL == 0 ))
