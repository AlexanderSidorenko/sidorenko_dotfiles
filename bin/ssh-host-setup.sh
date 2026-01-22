#!/usr/bin/env bash
set -euo pipefail

GREEN="$(printf '\033[0;32m')"
BLUE="$(printf '\033[0;34m')"
RED="$(printf '\033[0;31m')"
RESET="$(printf '\033[0m')"

green() {
  printf "%b%s%b\n" "$GREEN" "$1" "$RESET"
}

blue() {
  printf "%b%s%b\n" "$BLUE" "$1" "$RESET"
}

print_diff_colorized() {
  while IFS= read -r line; do
    case "${line}" in
    "+++"* | "---"* | "@@"*)
      printf "%b%s%b\n" "$BLUE" "${line}" "$RESET"
      ;;
    "+"*)
      printf "%b%s%b\n" "$GREEN" "${line}" "$RESET"
      ;;
    "-"*)
      printf "%b%s%b\n" "$RED" "${line}" "$RESET"
      ;;
    *)
      printf "%s\n" "${line}"
      ;;
    esac
  done
}

prompt() {
  printf "%b%s%b" "$GREEN" "$1" "$RESET"
}

default_username="$(id -un)"
hostname_full="$(hostname)"

prompt "Friendly name for SSH host: "
read -r friendly_name
if [[ -z "${friendly_name}" ]]; then
  green "Friendly name is required."
  exit 1
fi

prompt "Remote host address(es) (space-separated): "
read -r address_line
if [[ -z "${address_line}" ]]; then
  green "At least one address is required."
  exit 1
fi

printf "%bUsername [%b%s%b]: %b" "$GREEN" "$BLUE" "${default_username}" "$GREEN" "$RESET"
read -r username
username="${username:-$default_username}"

prompt "Key algorithm [ed25519]: "
read -r algorithm
algorithm="${algorithm:-ed25519}"

friendly_safe="$(printf '%s' "${friendly_name}" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:alnum:]_-')"
hostname_safe="$(printf '%s' "${hostname_full}" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:alnum:]_-')"

key_base="id_${algorithm}_${hostname_safe}_${friendly_safe}"
key_path="${HOME}/.ssh/${key_base}"
comment="${hostname_full} -> ${username}@${friendly_name}"

green "Key name:"
blue "${key_base}"
green "Key comment:"
blue "${comment}"

mkdir -p "${HOME}/.ssh"

if [[ -f "${key_path}" || -f "${key_path}.pub" ]]; then
  printf "%bKey already exists at:%b %b%s%b %bOverwrite? [y/N]: %b" \
    "$GREEN" "$RESET" "$BLUE" "${key_path}" "$GREEN" "$RESET"
  read -r overwrite
  overwrite="${overwrite:-N}"
  if [[ ! "${overwrite}" =~ ^[Yy]$ ]]; then
    green "Aborting."
    exit 0
  fi
fi

ssh-keygen -t "${algorithm}" -f "${key_path}" -C "${comment}"

first_address="${address_line%% *}"
config_path="${HOME}/.ssh/config"

config_block=$(
  cat <<EOF
Host ${friendly_name}
  HostName ${first_address}
  User ${username}
  IdentityFile ${key_path}
EOF
)

tmp_config="$(mktemp)"
if [[ -f "${config_path}" ]]; then
  cp "${config_path}" "${tmp_config}"
fi
printf '\n%s\n' "${config_block}" >>"${tmp_config}"

green "Proposed ssh config diff:"
if [[ -f "${config_path}" ]]; then
  diff_output="$(diff -u "${config_path}" "${tmp_config}" || true)"
else
  diff_output="$(diff -u /dev/null "${tmp_config}" || true)"
fi
if [[ -n "${diff_output}" ]]; then
  printf "%s\n" "${diff_output}" | print_diff_colorized
else
  blue "(no changes)"
fi

printf "%bApply these changes to:%b %b%s%b %b[Y/n]: %b" \
  "$GREEN" "$RESET" "$BLUE" "${config_path}" "$GREEN" "$RESET"
read -r apply_config
apply_config="${apply_config:-Y}"

if [[ "${apply_config}" =~ ^[Yy]$ ]]; then
  if [[ -f "${config_path}" ]]; then
    printf '\n%s\n' "${config_block}" >>"${config_path}"
  else
    printf '%s\n' "${config_block}" >"${config_path}"
  fi
  chmod 600 "${config_path}"
  green "ssh config updated."
else
  green "Skipped ssh config update."
fi

printf "%bRun ssh-copy-id to:%b %b%s%b %b[Y/n]: %b" \
  "$GREEN" "$RESET" "$BLUE" "${username}@${first_address}" "$GREEN" "$RESET"
read -r do_copy
do_copy="${do_copy:-Y}"

if [[ "${do_copy}" =~ ^[Yy]$ ]]; then
  ssh-copy-id -i "${key_path}.pub" "${username}@${first_address}"
else
  green "Skipped ssh-copy-id."
fi

rm -f "${tmp_config}"
