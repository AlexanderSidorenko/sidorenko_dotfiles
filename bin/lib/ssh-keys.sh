# shellcheck shell=bash
# ssh-keys.sh — what bin/ssh-host-setup.sh and bin/ssh-restore-yk must agree on.
#
# Sourced, never executed. One script makes SSH keys, the other puts a
# YubiKey's handles back after a wipe, and both then name the handle in
# ~/.ssh/config. If they disagree on a file name, or on where a line goes in a
# Host block, a restored handle lands where the config does not look. So the
# names, the config edits and the reading of a token's PIN state live here.
#
# NAMES
#   safe_name TEXT       lowercase, spaces to _, then only [a-z0-9_-]. This is
#                        the <name> in application ssh:<name>-<label> and in
#                        every key file name.
#   yk_handle NAME LABEL id_ed25519_yk_<name>_<label>
#
# ~/.ssh/config. Each function reads CONFIG, which need not exist, and prints;
# none of them writes. The caller shows the diff and writes the result back
# with `cat new >CONFIG`, which leaves a config that is a link (it_infra's
# desktop/ssh_config) a link.
#   ssh_config_block CONFIG HOST       the `Host HOST` block, if there is one
#   ssh_config_hosts_for CONFIG NAME   each single-name Host whose safe_name is
#                                      NAME: `Host git.jfj.sh` for gitjfjsh
#   ssh_config_names CONFIG FILE       true when an IdentityFile line names FILE
#   ssh_config_add_ids CONFIG HOST FILE...
#                                      the config with every FILE the HOST block
#                                      lacks added to it, and IdentitiesOnly yes
#   ssh_config_new_block CONFIG HOST ADDRESS USER PORT FILE...
#                                      the config with a new block above the
#                                      dotfiles Include, so it wins over Host *.
#                                      PORT empty or 22 writes no Port line
# A block ends at the next Host or Match line, or at the dotfiles Include.
# Handles of keys on a token (id_*_sk_*, id_*_yk_*) go after the block's other
# keys, so ssh tries those before asking for a touch.
#
# YUBIKEY. `ykman fido info` is the only place the PIN state shows, and its
# wording changed between versions:
#   ykman 4   PIN is set, with 8 attempt(s) remaining.  PIN is not set.
#             PIN is set, but has been blocked.
#   ykman 5   PIN:  8 attempt(s) remaining   PIN:  Not set   PIN:  Blocked
#   both      PIN is temporarily blocked. ...   (three wrong in a row)
#   yk_pin_state INFO   set, notset, blocked, temporary, or unknown when the
#                       output matches neither: say so, do not guess
#   yk_pin_tries INFO   the tries left, or nothing

safe_name() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:alnum:]_-'; }

yk_handle() { printf 'id_ed25519_yk_%s_%s' "$1" "$2"; }

ssh_config_block() {
  [[ -f $1 ]] || return 0
  awk -v h="$2" '
    inb && (tolower($1) == "host" || tolower($1) == "match" || /^# >>> sidorenko_dotfiles/) { exit }
    !inb && tolower($1) == "host" && NF == 2 && $2 == h { inb = 1 }
    inb { print }
  ' "$1"
}

ssh_config_hosts_for() {
  [[ -f $1 ]] || return 0
  awk -v n="$2" '
    function safe(s) { s = tolower(s); gsub(/ /, "_", s); gsub(/[^a-z0-9_-]/, "", s); return s }
    tolower($1) == "host" && NF == 2 && safe($2) == n && !seen[$2]++ { print $2 }
  ' "$1"
}

ssh_config_names() {
  [[ -f $1 ]] || return 1
  awk -v f="$2" '
    BEGIN { home = ENVIRON["HOME"] }
    function norm(p) { return substr(p, 1, 2) == "~/" ? home substr(p, 2) : p }
    tolower($1) == "identityfile" && norm($2) == norm(f) { found = 1; exit }
    END { exit !found }
  ' "$1"
}

# Two passes over the config: the first finds the block and what is in it, the
# second prints it back with the new lines. A key not on a token goes in front
# of the block's first token handle.
ssh_config_add_ids() {
  local config=$1 host=$2
  shift 2
  awk -v h="${host}" -v ids="$(printf '%s\n' "$@")" '
    BEGIN { n = split(ids, idl, "\n"); home = ENVIRON["HOME"] }
    function norm(p) { return substr(p, 1, 2) == "~/" ? home substr(p, 2) : p }
    function is_sk(p) { return p ~ /id_(ed25519|ecdsa)_(sk|yk)_/ }
    NR == FNR {
      if (inb && (tolower($1) == "host" || tolower($1) == "match" || /^# >>> sidorenko_dotfiles/)) { inb = 0; done = 1 }
      if (!inb && !done && tolower($1) == "host" && NF == 2 && $2 == h) { inb = 1; last = FNR; next }
      if (inb) {
        if ($0 ~ /[^[:space:]]/) last = FNR
        if (indent == "" && match($0, /^[[:space:]]+[^[:space:]#]/)) {
          match($0, /^[[:space:]]+/); indent = substr($0, 1, RLENGTH)
        }
        k = tolower($1)
        if (k == "identitiesonly") hasonly = 1
        if (k == "identityfile") {
          have[norm($2)] = 1
          if (!firstid) firstid = FNR
          if (is_sk($2) && !firstsk) firstsk = FNR
        }
      }
      next
    }
    FNR == 1 {
      if (indent == "") indent = "  "
      for (i = 1; i <= n; i++) {
        p = idl[i]
        if (p == "" || (norm(p) in have)) continue
        if (!is_sk(p) && firstsk) before[firstsk] = before[firstsk] indent "IdentityFile " p "\n"
        else after[last] = after[last] indent "IdentityFile " p "\n"
      }
      if (!hasonly) {
        if (firstid) before[firstid] = indent "IdentitiesOnly yes\n" before[firstid]
        else after[last] = indent "IdentitiesOnly yes\n" after[last]
      }
    }
    {
      if (FNR in before) printf "%s", before[FNR]
      print
      if (FNR in after) printf "%s", after[FNR]
    }
  ' "${config}" "${config}"
}

ssh_config_new_block() {
  local config=$1 host=$2 address=$3 user=$4 port=$5 block f
  shift 5
  block="Host ${host}
  HostName ${address}
  User ${user}"
  if [[ -n ${port} && ${port} != 22 ]]; then
    block+="
  Port ${port}"
  fi
  block+="
  IdentitiesOnly yes"
  for f in "$@"; do
    block+="
  IdentityFile ${f}"
  done
  if [[ -f ${config} ]]; then
    awk -v blk="${block}" '
      !done && /^# >>> sidorenko_dotfiles >>>/ { printf "%s\n\n", blk; done = 1 }
      { print }
      END { if (!done) printf "\n%s\n", blk }
    ' "${config}"
  else
    printf '%s\n' "${block}"
  fi
}

yk_pin_state() {
  if grep -qi 'PIN is temporarily blocked' <<<"$1"; then
    echo temporary
  elif grep -qiE '^PIN:[[:space:]]*Not set|^PIN is not set' <<<"$1"; then
    echo notset
  elif grep -qiE '^PIN:[[:space:]]*Blocked|^PIN is set, but has been blocked' <<<"$1"; then
    echo blocked
  elif grep -qiE '^PIN:[[:space:]]*[0-9]+ attempt|^PIN is set, with [0-9]+ attempt' <<<"$1"; then
    echo set
  else
    echo unknown
  fi
}

yk_pin_tries() {
  grep -iE '^PIN(:| is set, with)' <<<"$1" | grep -oE '[0-9]+ attempt' | head -1 | grep -oE '[0-9]+' || true
}
