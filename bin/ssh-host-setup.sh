#!/usr/bin/env bash
# ssh-host-setup.sh — make a key for one SSH destination, wire it into
# ~/.ssh/config and install it there. Interactive. Run it again to give the
# same destination another key: another kind, or another YubiKey.
#
# KINDS OF KEY
#   tpm      Made inside this machine's TPM by ssh-tpm-keygen and served by
#            ssh-tpm-agent. The private half never exists outside the TPM: the
#            .tpm file is useless on any other machine, so a compromise of this
#            one leaves nothing behind that still works. ECDSA P-256, because
#            TPMs have no Ed25519. Gone if the TPM is cleared or reset, which is
#            what the YubiKey keys are for.
#   yubikey  A resident ed25519-sk credential with verify-required, made inside
#            one YubiKey: a touch plus the FIDO2 PIN on every use. Run once per
#            token. The file in ~/.ssh is only a handle; `ssh-keygen -K`
#            recreates it on any machine from the token, under OpenSSH's own
#            name (id_ed25519_sk_rk_<name>-<label>), to be renamed to the one
#            below. Installed with the verify-required option, so the server
#            demands the PIN as well.
#   file     A plain key file on disk, as this script always made. For
#            machines with no TPM.
#
# FILES, in ~/.ssh (<this> is this machine's hostname, <name> the destination):
#   tpm      id_ecdsa_tpm_<this>_<name>.tpm and .pub
#   yubikey  id_ed25519_yk_<name>_<label> and .pub   (application ssh:<name>-<label>)
#   file     id_<alg>_<this>_<name> and .pub
#
# ~/.ssh/config gets one `Host <name>` block per destination, written above the
# sidorenko_dotfiles Include so the block wins over its `Host *` defaults. A
# later run adds an IdentityFile line to the existing block (and IdentitiesOnly
# yes if it is missing) instead of writing a second block. ssh tries keys the
# agent holds first, so the TPM key is used without a touch and a YubiKey only
# when the TPM key is gone or refused.
#
# INSTALLING happens over ssh, logging in with a password or with a key that
# already works, and is idempotent: a key already in authorized_keys is not
# added again. Where ssh cannot write authorized_keys (a git forge, RouterOS, a
# host whose keys are declared in a repo) the script prints the key to paste.
# Then, if asked, it logs in once on a fresh connection that can use ONLY the
# new key, and says plainly whether that worked.
#
# SSH_HOST_SETUP_DIR=<dir> works on <dir> instead of ~/.ssh and runs ssh with
# -F <dir>/config. It exists for testing; a real run leaves it unset.
set -euo pipefail

GREEN="$(printf '\033[0;32m')"
BLUE="$(printf '\033[0;34m')"
RED="$(printf '\033[0;31m')"
YELLOW="$(printf '\033[0;33m')"
RESET="$(printf '\033[0m')"

green() { printf "%b%s%b\n" "$GREEN" "$1" "$RESET"; }
blue() { printf "%b%s%b\n" "$BLUE" "$1" "$RESET"; }
yellow() { printf "%b%s%b\n" "$YELLOW" "$1" "$RESET"; }
die() {
  printf "%b%s%b\n" "$RED" "$1" "$RESET" >&2
  exit 1
}

print_diff_colorized() {
  while IFS= read -r line; do
    case "${line}" in
    "+++"* | "---"* | "@@"*) printf "%b%s%b\n" "$BLUE" "${line}" "$RESET" ;;
    "+"*) printf "%b%s%b\n" "$GREEN" "${line}" "$RESET" ;;
    "-"*) printf "%b%s%b\n" "$RED" "${line}" "$RESET" ;;
    *) printf "%s\n" "${line}" ;;
    esac
  done
}

# ask <question> [default] — the prompt goes to stderr so $(ask ...) captures
# only the answer.
ask() {
  local question="$1" default="${2:-}" answer=""
  if [[ -n "${default}" ]]; then
    printf "%b%s [%b%s%b]: %b" "$GREEN" "${question}" "$BLUE" "${default}" "$GREEN" "$RESET" >&2
  else
    printf "%b%s: %b" "$GREEN" "${question}" "$RESET" >&2
  fi
  read -r answer || true
  printf '%s' "${answer:-$default}"
}

safe_name() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:alnum:]_-'; }

ssh_dir="${SSH_HOST_SETUP_DIR:-$HOME/.ssh}"
config_path="${ssh_dir}/config"
ssh_cmd=(ssh)
if [[ -n "${SSH_HOST_SETUP_DIR:-}" ]]; then
  ssh_cmd+=(-F "${config_path}")
fi

# id -un can fail on AD-joined hosts when sssd/winbind NSS lookups break.
# Fall back to $USER / $LOGNAME; if all empty, the prompt below will require input.
default_username="$(id -un 2>/dev/null || true)"
default_username="${default_username:-${USER:-${LOGNAME:-}}}"
hostname_full="$(hostname 2>/dev/null || uname -n)"
hostname_safe="$(safe_name "${hostname_full}")"

# --- The destination --------------------------------------------------------

friendly_name="$(ask "Friendly name for SSH host")"
[[ -n "${friendly_name}" ]] || die "Friendly name is required."
[[ "${friendly_name}" =~ ^[A-Za-z0-9._-]+$ ]] ||
  die "Friendly name: letters, digits, dots, dashes, underscores (it becomes a Host pattern)."
friendly_safe="$(safe_name "${friendly_name}")"

mkdir -p "${ssh_dir}"
chmod 700 "${ssh_dir}"

# The `Host <name>` block for exactly this name, if the config has one.
print_block() {
  [[ -f "${config_path}" ]] || return 0
  awk -v h="${friendly_name}" '
    inb && (tolower($1) == "host" || tolower($1) == "match" || /^# >>> sidorenko_dotfiles/) { exit }
    !inb && tolower($1) == "host" && NF == 2 && $2 == h { inb = 1 }
    inb { print }
  ' "${config_path}"
}

block_existed=0
if [[ -n "$(print_block)" ]]; then
  block_existed=1
  green "${config_path} already has a block for ${friendly_name}; this run adds a key to it:"
  print_block | sed 's/^/    /'
  username="$("${ssh_cmd[@]}" -G "${friendly_name}" | awk '$1 == "user" { print $2; exit }')"
else
  address_line="$(ask "Remote host address(es) (space-separated)")"
  [[ -n "${address_line}" ]] || die "At least one address is required."
  username="$(ask "Username" "${default_username}")"
  [[ -n "${username}" ]] || die "Username is required."
fi

# --- The kind of key --------------------------------------------------------

tpm_socket() {
  if [[ -n "${SSH_TPM_AUTH_SOCK:-}" ]]; then
    printf '%s' "${SSH_TPM_AUTH_SOCK}"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    printf '%s' "${XDG_RUNTIME_DIR}/ssh-tpm-agent.sock"
  fi
}

# The _SSH_TPM_AGENT_SIMULATOR / SSH_TPM_AGENT_SWTPM switches are
# ssh-tpm-agent's own test TPMs; with either set there is no device to check.
tpm_usable() {
  command -v ssh-tpm-keygen >/dev/null 2>&1 || return 1
  [[ -n "${_SSH_TPM_AGENT_SIMULATOR:-}${SSH_TPM_AGENT_SWTPM:-}" ]] && return 0
  [[ -r /dev/tpmrm0 && -w /dev/tpmrm0 ]]
}

default_kind="file"
if tpm_usable; then default_kind=tpm; fi
kind="$(ask "Key kind: tpm, yubikey or file" "${default_kind}")"
case "${kind}" in
t | tpm) kind=tpm ;;
y | yk | yubikey) kind=yubikey ;;
f | file) kind="file" ;;
*) die "Unknown key kind: ${kind} (tpm, yubikey or file)." ;;
esac

if [[ "${kind}" == tpm ]] && ! tpm_usable; then
  command -v ssh-tpm-keygen >/dev/null 2>&1 ||
    die "ssh-tpm-keygen is not installed. It comes with ssh-tpm-agent (on NixOS: security.tpm2.enable, the tss group, and home-manager's services.ssh-tpm-agent)."
  die "No read/write access to /dev/tpmrm0. Is ${default_username} in the tss group? A new group takes effect at the next login. ls -l /dev/tpmrm0"
fi

# reuse / overwrite / abort, for a key whose files are already there.
existing_choice() {
  local choice
  choice="$(ask "A key already exists at $1. Reuse it (r), overwrite it (o) or abort (a)?" r)"
  case "${choice}" in
  r | reuse) echo reuse ;;
  o | overwrite) echo overwrite ;;
  *) echo abort ;;
  esac
}

# What this run made (or reused), in parallel arrays.
new_idfiles=() # the path the config's IdentityFile names
new_pubs=()    # the public key file
new_kinds=()   # tpm | yubikey | file
new_opts=()    # authorized_keys options for the line, if any

case "${kind}" in
tpm)
  key_path="${ssh_dir}/id_ecdsa_tpm_${hostname_safe}_${friendly_safe}"
  generate=1
  if [[ -e "${key_path}.tpm" || -e "${key_path}.pub" ]]; then
    case "$(existing_choice "${key_path}.tpm")" in
    reuse) generate=0 ;;
    overwrite) rm -f -- "${key_path}.tpm" "${key_path}.pub" ;;
    *) green "Aborting."; exit 0 ;;
    esac
  fi
  if ((generate)); then
    green "Generating the key inside the TPM. A PIN is optional: empty means the agent signs without asking."
    ssh-tpm-keygen -t ecdsa -f "${key_path}" -C "${hostname_full} tpm -> ${username}@${friendly_name}" ||
      die "ssh-tpm-keygen failed. If it mentions authorization (TPM_RC_BAD_AUTH, AUTH_FAIL), the TPM's owner hierarchy has a password, which Windows or a provisioning tool may have set. Check with: tpm2_getcap properties-variable | grep ownerAuthSet"
  fi
  sock="$(tpm_socket)"
  if [[ -n "${sock}" && -S "${sock}" ]]; then
    SSH_TPM_AUTH_SOCK="${sock}" ssh-tpm-add "${key_path}.tpm" ||
      yellow "ssh-tpm-add failed; ssh-tpm-agent will load the key from ${ssh_dir} when it next starts."
  else
    yellow "ssh-tpm-agent is not running here; it loads the key from ${ssh_dir} when it starts."
  fi
  if [[ -n "${sock}" && "${SSH_AUTH_SOCK:-}" != "${sock}" ]]; then
    yellow "SSH_AUTH_SOCK is '${SSH_AUTH_SOCK:-}', not ssh-tpm-agent's ${sock}, so ssh will not find this key until ssh-tpm-agent is the session's agent."
  fi
  new_idfiles+=("${key_path}.pub")
  new_pubs+=("${key_path}.pub")
  new_kinds+=(tpm)
  new_opts+=("")
  ;;

yubikey)
  ssh -Q key 2>/dev/null | grep -qx 'sk-ssh-ed25519@openssh.com' ||
    die "This OpenSSH cannot make security-key keys (it was built without FIDO support)."
  while :; do
    serial=unknown
    if command -v ykman >/dev/null 2>&1; then
      serials=() # a read loop, not mapfile: macOS's stock bash 3.2 has none
      while IFS= read -r s; do
        [[ -n "${s}" ]] && serials+=("${s}")
      done < <(ykman list --serials 2>/dev/null || true)
      if ((${#serials[@]} != 1)); then
        die "Plug in exactly one YubiKey (found ${#serials[@]}), so the credential lands on the token you mean."
      fi
      serial="${serials[0]}"
      if ykman --device "${serial}" fido info 2>/dev/null | grep -qi 'PIN is not set'; then
        die "YubiKey ${serial} has no FIDO2 PIN, and verify-required needs one: ykman fido access change-pin"
      fi
    else
      yellow "ykman is not installed, so the token count and its FIDO2 PIN go unchecked; ssh-keygen uses whichever token answers."
    fi

    label="$(ask "Label for this YubiKey (e.g. main, backup)")"
    [[ "${label}" =~ ^[a-z0-9-]+$ ]] || die "Label: lowercase letters, digits and dashes."
    key_path="${ssh_dir}/id_ed25519_yk_${friendly_safe}_${label}"
    application="ssh:${friendly_safe}-${label}"

    generate=1
    if [[ -e "${key_path}" || -e "${key_path}.pub" ]]; then
      case "$(existing_choice "${key_path}")" in
      reuse) generate=0 ;;
      overwrite) rm -f -- "${key_path}" "${key_path}.pub" ;;
      *) green "Aborting."; exit 0 ;;
      esac
    fi
    if ((generate)); then
      green "Making a resident credential ${application} on YubiKey ${serial}. Touch it when it blinks, then enter its FIDO2 PIN."
      yellow "If ssh-keygen says a credential for ${application} already exists on the token, answering yes REPLACES it, and every server that trusts the old one stops accepting this token. Answer no unless that is what you want."
      ssh-keygen -t ed25519-sk -O resident -O verify-required -O "application=${application}" \
        -C "yk-${label}-${serial} ${username}@${friendly_name}" -N "" -f "${key_path}" ||
        die "ssh-keygen could not make the credential (no FIDO2 PIN? resident slots full? the existing credential kept?)."
    fi
    new_idfiles+=("${key_path}")
    new_pubs+=("${key_path}.pub")
    new_kinds+=(yubikey)
    new_opts+=("verify-required")

    another="$(ask "Enrol another YubiKey for ${friendly_name}? Swap the token in first (y/n)" n)"
    [[ "${another}" =~ ^[Yy] ]] || break
  done
  ;;

file)
  algorithm="$(ask "Key algorithm" ed25519)"
  key_path="${ssh_dir}/id_${algorithm}_${hostname_safe}_${friendly_safe}"
  generate=1
  if [[ -e "${key_path}" || -e "${key_path}.pub" ]]; then
    case "$(existing_choice "${key_path}")" in
    reuse) generate=0 ;;
    overwrite) rm -f -- "${key_path}" "${key_path}.pub" ;;
    *) green "Aborting."; exit 0 ;;
    esac
  fi
  if ((generate)); then
    ssh-keygen -t "${algorithm}" -f "${key_path}" -C "${hostname_full} -> ${username}@${friendly_name}"
  fi
  new_idfiles+=("${key_path}")
  new_pubs+=("${key_path}.pub")
  new_kinds+=(file)
  new_opts+=("")
  ;;
esac

for pub in "${new_pubs[@]}"; do
  [[ -r "${pub}" ]] || die "${pub} is missing."
done

green "Key(s):"
for pub in "${new_pubs[@]}"; do
  blue "  ${pub}  $(ssh-keygen -lf "${pub}" | awk '{print $2}')"
done

# --- ~/.ssh/config ----------------------------------------------------------

tmp_config="$(mktemp)"
trap 'rm -f "${tmp_config}"' EXIT

if ((block_existed)); then
  # Two passes over the config: the first finds the block and what is in it,
  # the second prints it back with the new lines. Keys that are not on a token
  # go in front of the first YubiKey handle, so ssh reaches for them before
  # asking for a touch.
  awk -v h="${friendly_name}" -v ids="$(printf '%s\n' "${new_idfiles[@]}")" '
    BEGIN { n = split(ids, idl, "\n"); home = ENVIRON["HOME"] }
    function norm(p) { return substr(p, 1, 2) == "~/" ? home substr(p, 2) : p }
    function is_sk(p) { return p ~ /id_(ed25519|ecdsa)_sk/ }
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
  ' "${config_path}" "${config_path}" >"${tmp_config}"
else
  first_address="${address_line%% *}"
  block="Host ${friendly_name}
  HostName ${first_address}
  User ${username}
  IdentitiesOnly yes"
  for f in "${new_idfiles[@]}"; do
    block+="
  IdentityFile ${f}"
  done
  # Above the dotfiles Include, so this block's settings win over `Host *`.
  if [[ -f "${config_path}" ]]; then
    awk -v blk="${block}" '
      !done && /^# >>> sidorenko_dotfiles >>>/ { printf "%s\n\n", blk; done = 1 }
      { print }
      END { if (!done) printf "\n%s\n", blk }
    ' "${config_path}" >"${tmp_config}"
  else
    printf '%s\n' "${block}" >"${tmp_config}"
  fi
fi

green "Proposed ssh config diff:"
if [[ -f "${config_path}" ]]; then
  diff_output="$(diff -u "${config_path}" "${tmp_config}" || true)"
else
  diff_output="$(diff -u /dev/null "${tmp_config}" || true)"
fi
if [[ -n "${diff_output}" ]]; then
  printf "%s\n" "${diff_output}" | print_diff_colorized
  apply_config="$(ask "Apply these changes to ${config_path}? (Y/n)" Y)"
  if [[ "${apply_config}" =~ ^[Yy]$ ]]; then
    cat "${tmp_config}" >"${config_path}"
    chmod 600 "${config_path}"
    green "ssh config updated."
  else
    green "Skipped ssh config update."
  fi
else
  blue "(no changes: the block already names these keys)"
fi

# --- Installing -------------------------------------------------------------

default_install=p
if ((block_existed)); then default_install=k; fi
# A git forge takes keys in its web UI only; ssh there runs no commands.
dest_host="$("${ssh_cmd[@]}" -G "${friendly_name}" | awk '$1 == "hostname" { print $2; exit }')"
if [[ "${username}" == git || "${dest_host}" == *github.com || "${dest_host}" == *gitlab.com ]]; then
  default_install=m
fi
green "Install the public key(s) on ${friendly_name}:"
green "  p  over ssh, logging in with a password"
green "  k  over ssh, logging in with a key that already works"
green "  m  print them to paste (a git forge, RouterOS, keys declared in a repo)"
green "  s  skip"
install_mode="$(ask "How" "${default_install}")"

# Runs in the remote user's login shell. Reads pairs of lines: the key's base64
# blob (to find it whatever options or comment it was installed with) and the
# authorized_keys line to add.
# shellcheck disable=SC2016 # expanded remotely, on purpose
remote_install='umask 077 && mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys &&
while read -r blob && IFS= read -r line; do
  if grep -qF "$blob" ~/.ssh/authorized_keys; then
    printf "already installed: %s\n" "$line"
  else
    printf "%s\n" "$line" >> ~/.ssh/authorized_keys && printf "installed: %s\n" "$line"
  fi
done'

payload=""
for i in "${!new_pubs[@]}"; do
  pubtext="$(<"${new_pubs[$i]}")"
  blob="$(awk '{ print $2 }' <<<"${pubtext}")"
  line="${new_opts[$i]:+${new_opts[$i]} }${pubtext}"
  payload+="${blob}"$'\n'"${line}"$'\n'
done

case "${install_mode}" in
p | k)
  install_opts=(-T -o ControlMaster=no -o ControlPath=none)
  if [[ "${install_mode}" == p ]]; then
    install_opts+=(-o "PreferredAuthentications=password,keyboard-interactive" -o PubkeyAuthentication=no)
  fi
  printf '%s' "${payload}" | "${ssh_cmd[@]}" "${install_opts[@]}" "${friendly_name}" "${remote_install}" ||
    die "Installing over ssh failed. Nothing else was changed on ${friendly_name}."
  ;;
m)
  green "Paste each of these where ${friendly_name} keeps its keys:"
  for i in "${!new_pubs[@]}"; do
    printf '%s\n' "$(<"${new_pubs[$i]}")"
  done
  if [[ " ${new_kinds[*]} " == *" yubikey "* ]]; then
    yellow "On a host you control, put 'verify-required ' in front of each sk- line, so the server demands the PIN. Git forges take the line as it is."
  fi
  ;;
*)
  green "Skipped installing."
  ;;
esac

# --- Verifying --------------------------------------------------------------

[[ "${install_mode}" == s ]] && exit 0
verify="$(ask "Verify a fresh login that can use ONLY the new key(s)? (Y/n)" Y)"
[[ "${verify}" =~ ^[Yy] ]] || exit 0

# Resolve the destination once through the config, then connect with -F
# /dev/null and those values spelled out: IdentityFile lines accumulate, so a
# login through the config could succeed with an older key and prove nothing.
resolved="$("${ssh_cmd[@]}" -G "${friendly_name}")"
get() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' <<<"${resolved}"; }
verify_opts=(
  -F /dev/null -T
  -o "HostName=$(get hostname)" -o "Port=$(get port)" -o "User=$(get user)"
  -o "UserKnownHostsFile=$(get userknownhostsfile)"
  -o "GlobalKnownHostsFile=$(get globalknownhostsfile)"
  -o "StrictHostKeyChecking=$(get stricthostkeychecking)"
  -o ControlMaster=no -o ControlPath=none
  -o IdentitiesOnly=yes -o PreferredAuthentications=publickey
)
proxy_jump="$(get proxyjump)"
if [[ -n "${proxy_jump}" && "${proxy_jump}" != none ]]; then verify_opts+=(-o "ProxyJump=${proxy_jump}"); fi
host_key_alias="$(get hostkeyalias)"
if [[ -n "${host_key_alias}" && "${host_key_alias}" != none ]]; then verify_opts+=(-o "HostKeyAlias=${host_key_alias}"); fi

failed=0
for i in "${!new_idfiles[@]}"; do
  f="${new_idfiles[$i]}"
  agent=none
  if [[ "${new_kinds[$i]}" == tpm ]]; then agent="$(tpm_socket)"; fi
  green "Logging in to ${friendly_name} with ${f} only$([[ ${new_kinds[$i]} == yubikey ]] && echo ': touch the token, then enter the PIN')."
  out="$(mktemp)"
  set +e
  ssh -n "${verify_opts[@]}" -o "IdentityAgent=${agent:-none}" -o "IdentityFile=${f}" "${friendly_name}" true 2>&1 | tee "${out}"
  rc="${PIPESTATUS[0]}"
  set -e
  # Git forges authenticate the key, then refuse the command with a non-zero
  # exit; their greeting is the success signal there.
  if [[ "${rc}" == 0 ]] || grep -qiE 'successfully authenticated|^Hi [^ ]+!' "${out}"; then
    green "OK: ${f} logs in to ${friendly_name}."
  else
    printf "%b%s%b\n" "$RED" "FAILED: ${f} did not log in to ${friendly_name} (ssh exit ${rc})." "$RESET"
    failed=1
  fi
  rm -f "${out}"
done
exit "${failed}"
