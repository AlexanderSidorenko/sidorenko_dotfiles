#!/usr/bin/env bash
#
# enroll-yubikey.sh — prepare a YubiKey Bio and register it for step-down auth.
#
# Three things have to be true before the YubiKey branch of /etc/pam.d/yubikey-auth
# can ever succeed, and this script walks all three:
#
#   1. a FIDO2 PIN is set   — the Bio refuses to enrol fingerprints without one,
#                             and the PIN is what unblocks the key after three
#                             rejected fingerprints
#   2. fingerprints enrolled— enrol at least two (one per hand): a cut or a cold
#                             finger should not cost you the second factor
#   3. a credential in $AUTHFILE — root-owned, outside $HOME, so that a process
#                             running as you cannot mint itself a second factor
#
# Run as your normal user with the key plugged in. It sudoes only for the final
# write to the root-owned mapping file.
#
#   ./enroll-yubikey.sh              # enrol this key for $USER
#   ./enroll-yubikey.sh --user bob   # ...for someone else
#   ./enroll-yubikey.sh --list       # show what is enrolled, change nothing
#
# Run it again with a second YubiKey to add a backup: credentials accumulate,
# they do not replace each other.

set -euo pipefail

readonly CONFIG=/etc/yubikey-auth/config

if [[ -t 1 ]]; then
	readonly C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_B=$'\e[1m' C_OFF=$'\e[0m'
else
	readonly C_OK='' C_WARN='' C_ERR='' C_B='' C_OFF=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_OK" "$C_OFF" "$C_B" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

ask() { # ask "prompt" -> 0 on yes
	local reply
	read -r -p "    $1 [y/N] " reply
	[[ ${reply,,} == y* ]]
}

# ---------------------------------------------------------------- arguments

target_user=${SUDO_USER:-$USER}
list_only=0
while (($#)); do
	case $1 in
	--user) target_user=${2:?--user needs a value}; shift 2 ;;
	--user=*) target_user=${1#--user=}; shift ;;
	--list) list_only=1; shift ;;
	-h | --help) sed -n '3,26p' -- "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

[[ -r $CONFIG ]] || die "$CONFIG not found — run install-yubikey-auth.sh first"
ORIGIN= APPID= AUTHFILE=
# shellcheck source=config.default
. "$CONFIG"
[[ $ORIGIN && $APPID && $AUTHFILE ]] || die "$CONFIG must define ORIGIN, APPID and AUTHFILE"

command -v ykman >/dev/null || die "ykman not found — run install-yubikey-auth.sh first"
command -v pamu2fcfg >/dev/null || die "pamu2fcfg not found — run install-yubikey-auth.sh first"

# ------------------------------------------------------------------ listing

credential_count() { # credential_count <user>
	local line
	line=$(grep -m1 "^$1:" -- "$AUTHFILE" 2>/dev/null) || { echo 0; return; }
	# user:cred[:cred...] — fields after the username are the credentials.
	awk -F: '{print NF - 1}' <<<"$line"
}

show_enrolled() {
	step "Enrolled credentials in $AUTHFILE"
	if [[ ! -s $AUTHFILE ]]; then
		info "(none)"
		return
	fi
	local line user n
	while IFS= read -r line; do
		[[ $line && $line != \#* ]] || continue
		user=${line%%:*}
		n=$(awk -F: '{print NF - 1}' <<<"$line")
		info "$(printf '%-16s %s credential(s)' "$user" "$n")"
	done <"$AUTHFILE"
}

if ((list_only)); then
	show_enrolled
	step "Key state"
	ykman fido info 2>/dev/null || info "no YubiKey detected"
	exit 0
fi

# --------------------------------------------------------------- key checks

step "Detecting YubiKey"
ykman info >/dev/null 2>&1 || die "no YubiKey detected — plug it in and retry"
ykman info | sed 's/^/    /'

fido_info=$(ykman fido info)
printf '\n'
sed 's/^/    /' <<<"$fido_info"

# 1. PIN ---------------------------------------------------------------------
step "FIDO2 PIN"
if grep -q '^PIN: *Not set' <<<"$fido_info"; then
	warn "no FIDO2 PIN is set; fingerprints cannot be enrolled without one."
	info "This PIN is your fallback when a fingerprint is rejected three times,"
	info "and it is NOT your login password. Store it in KeePassXC."
	ask "Set a FIDO2 PIN now?" || die "a PIN is required to continue"
	ykman fido access change-pin
	info "${C_OK}PIN set${C_OFF}"
else
	info "already set"
fi

# 2. Fingerprints ------------------------------------------------------------
step "Fingerprints"

# "ykman fido info" reports enrolment without needing the PIN; "fingerprints
# list" prompts for it. Only reach for the latter once we know there is
# something to list, so the PIN prompt never arrives unexplained.
list_fingerprints() {
	if grep -q '^Fingerprints: *Not registered' <<<"$(ykman fido info)"; then
		return 1
	fi
	info "Listing fingerprints requires the FIDO2 PIN:"
	ykman fido fingerprints list
}

enrolled_count=0
if fingerprints=$(list_fingerprints); then
	sed 's/^/    /' <<<"$fingerprints"
	enrolled_count=$(grep -c . <<<"$fingerprints")
else
	info "none enrolled"
fi

while :; do
	if ((enrolled_count == 0)); then
		info "At least one fingerprint is needed for the touch-to-unlock path."
		prompt="Enrol a fingerprint now?"
	elif ((enrolled_count == 1)); then
		warn "only one fingerprint enrolled — a cut or a cold finger would drop"
		warn "you back to typing your password until you re-enrol."
		prompt="Enrol a second fingerprint (other hand)?"
	else
		prompt="Enrol another fingerprint?"
	fi

	ask "$prompt" || break

	read -r -p "    Name for this finger (e.g. right-index): " fp_name
	[[ $fp_name ]] || { warn "empty name — skipping"; continue; }
	info "Touch the sensor repeatedly, lifting between touches, until it reports success..."
	if ykman fido fingerprints add "$fp_name"; then
		enrolled_count=$((enrolled_count + 1))
	else
		warn "enrolment failed — try again"
	fi
done

((enrolled_count > 0)) || die "no fingerprints enrolled — the YubiKey branch could never succeed"

# 3. PAM credential ----------------------------------------------------------
step "Registering a PAM credential for $target_user"
info "origin=$ORIGIN appid=$APPID"
info "Touch the sensor when the key blinks."

# -n prints only the credential fields, for appending to an existing line.
# -V requires user verification (the fingerprint) at every authentication.
if ! new_cred=$(pamu2fcfg -n -o "$ORIGIN" -i "$APPID" -V); then
	die "pamu2fcfg failed — credential NOT registered"
fi
new_cred=${new_cred#:}                       # tolerate either output convention
[[ $new_cred ]] || die "pamu2fcfg produced no credential"

existing=$(grep -m1 "^$target_user:" -- "$AUTHFILE" 2>/dev/null || true)
if [[ $existing ]]; then
	new_line="$existing:$new_cred"
	info "appending to $(credential_count "$target_user") existing credential(s)"
else
	new_line="$target_user:$new_cred"
	info "first credential for $target_user"
fi

tmp=$(mktemp)
trap 'rm -f -- "$tmp"' EXIT
{
	printf '# pam_u2f credentials for the YubiKey step-down auth stack.\n'
	printf '# Managed by zenbook/yubikey/enroll-yubikey.sh — one line per user:\n'
	printf '#     username:keyhandle,pubkey,cose_type,options[:...]\n'
	# Every other user's line, unchanged, then ours.
	grep -v -e '^#' -e '^[[:space:]]*$' -e "^$target_user:" -- "$AUTHFILE" 2>/dev/null || true
	printf '%s\n' "$new_line"
} >"$tmp"

sudo install -o root -g root -m 0644 -- "$tmp" "$AUTHFILE"
info "${C_OK}registered${C_OFF} — $target_user now has $(credential_count "$target_user") credential(s)"

# ------------------------------------------------------------------- verify
step "Verifying"
if command -v pamtester >/dev/null && [[ -f /etc/pam.d/yubikey-auth-test ]]; then
	info "About to authenticate against the real stack via pamtester."
	info "The window is closed, so expect a PASSWORD prompt first — that is the"
	info "correct behaviour. Run it a second time and you should get the touch"
	info "prompt instead."
	# Must go through sudo. pam_exec runs the helper with the effective uid, so
	# an unprivileged pamtester cannot write the root-owned stamp: the password
	# would succeed, the window would silently stay shut, and every subsequent
	# run would ask for a password again. Real login paths (gdm, sudo) are
	# privileged, so this is a limitation of the test harness, not the stack.
	if ask "Run the test now (needs sudo)?"; then
		if sudo pamtester yubikey-auth-test "$target_user" authenticate; then
			info "${C_OK}stack accepted the authentication${C_OFF}"
			info "Now run it again — this time it should ask for a touch:"
			info "    sudo pamtester yubikey-auth-test $target_user authenticate"
		else
			warn "pamtester failed — inspect: journalctl -t yubikey-auth -n 20"
		fi
	fi
else
	warn "pamtester or /etc/pam.d/yubikey-auth-test missing; skipping verification"
fi

show_enrolled
printf '\n%sNext:%s wire a service, e.g.\n' "$C_B" "$C_OFF"
printf '    sudo ./install-yubikey-auth.sh --enable gdm\n'
