#!/usr/bin/env bash
#
# yubikey-auth-status.sh — read-only snapshot of the YubiKey step-down auth
# stack: is the key healthy, who is enrolled, what is wired, is the window
# open, and what has the stack actually been deciding lately.
#
# Safe to run any time; it changes nothing. Without sudo it still reports
# everything except the window state (/run/yubikey-auth is root-only).
#
#   ./yubikey-auth-status.sh
#   sudo ./yubikey-auth-status.sh          # includes the live window state

set -uo pipefail

readonly CONFIG=/etc/yubikey-auth/config
readonly HELPER=/usr/local/libexec/yubikey-auth/yubikey-auth-window
readonly PAM_DIR=/etc/pam.d
readonly LOG_LINES=15

if [[ -t 1 ]]; then
	C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_B=$'\e[1m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
else
	C_OK='' C_WARN='' C_ERR='' C_B='' C_DIM='' C_OFF=''
fi
readonly C_OK C_WARN C_ERR C_B C_DIM C_OFF

hdr()  { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_OFF"; }
row()  { printf '  %-18s %s\n' "$1" "$2"; }
ok()   { printf '%s%s%s' "$C_OK" "$*" "$C_OFF"; }
bad()  { printf '%s%s%s' "$C_ERR" "$*" "$C_OFF"; }
meh()  { printf '%s%s%s' "$C_WARN" "$*" "$C_OFF"; }
dim()  { printf '%s%s%s' "$C_DIM" "$*" "$C_OFF"; }

target_user=${SUDO_USER:-$USER}

# ------------------------------------------------------------------ install

hdr "Installation"
AUTHFILE=/etc/yubikey-auth/u2f_mappings
WINDOW_SECONDS=43200
ORIGIN='(unset)'
if [[ -r $CONFIG ]]; then
	# shellcheck source=config.default
	. "$CONFIG"
	row "config" "$(ok present) — window $((WINDOW_SECONDS / 3600))h, origin $ORIGIN"
else
	row "config" "$(bad "missing $CONFIG") — run install-yubikey-auth.sh"
fi
[[ -x $HELPER ]] && row "helper" "$(ok "$HELPER")" || row "helper" "$(bad "missing $HELPER")"
[[ -f $PAM_DIR/yubikey-auth ]] && row "pam snippet" "$(ok "$PAM_DIR/yubikey-auth")" ||
	row "pam snippet" "$(bad "missing $PAM_DIR/yubikey-auth")"

# ---------------------------------------------------------------------- key

hdr "YubiKey"
if ! command -v ykman >/dev/null; then
	row "ykman" "$(bad "not installed")"
elif ! key_info=$(ykman info 2>/dev/null); then
	row "device" "$(meh "not plugged in") — the password path still works"
else
	row "device" "$(ok "$(sed -n 's/^Device type: *//p' <<<"$key_info")")"
	row "serial" "$(sed -n 's/^Serial number: *//p' <<<"$key_info")"
	row "firmware" "$(sed -n 's/^Firmware version: *//p' <<<"$key_info")"
	if fido_info=$(ykman fido info 2>/dev/null); then
		# ykman's wording changed across versions: older builds print a
		# "PIN: Not set" field, 5.2.x prints the prose "PIN is not set."
		# Match both for the decision, and display whatever line ykman emitted
		# so a future rewording still shows something sensible.
		if grep -qiE 'PIN is not set|^PIN: *Not set' <<<"$fido_info"; then
			row "fido2 pin" "$(bad "not set") — fingerprints cannot be enrolled"
		else
			pin_state=$(grep -iE '^PIN' <<<"$fido_info" | head -n1)
			row "fido2 pin" "$(ok "${pin_state:-set}")"
		fi
		# Deliberately read off "fido info" rather than "fingerprints list":
		# the latter prompts for the PIN, which would hang a status command.
		if grep -qiE 'No fingerprints have been registered|^Fingerprints: *Not registered' <<<"$fido_info"; then
			row "fingerprints" "$(bad "none enrolled") — run enroll-yubikey.sh"
		else
			fp_state=$(grep -iE 'ingerprint' <<<"$fido_info" | head -n1)
			row "fingerprints" "$(ok "${fp_state:-registered}")"
		fi
	fi
fi

# --------------------------------------------------------------- enrollment

hdr "Enrolled credentials"
if [[ ! -r $AUTHFILE ]]; then
	row "$AUTHFILE" "$(bad unreadable)"
elif ! grep -qv -e '^#' -e '^[[:space:]]*$' -- "$AUTHFILE"; then
	row "(none)" "$(meh "run enroll-yubikey.sh") — every service falls back to passwords"
else
	while IFS= read -r line; do
		[[ $line && $line != \#* ]] || continue
		row "${line%%:*}" "$(awk -F: '{print NF - 1}' <<<"$line") credential(s)"
	done <"$AUTHFILE"
fi

# ------------------------------------------------------------------ wiring

hdr "Wired services"
found=0
shopt -s nullglob
for f in "$PAM_DIR"/*; do
	[[ -f $f ]] || continue
	if grep -qx '@include yubikey-auth' -- "$f" 2>/dev/null; then
		row "${f##*/}" "$(ok "step-down auth active")"
		found=1
	fi
done
((found)) || row "(none)" "$(dim "stock password stack everywhere")"

# ------------------------------------------------------------------- window

hdr "Window for $target_user"
if [[ -x $HELPER ]]; then
	"$HELPER" status --user "$target_user" 2>&1 | sed 's/^/  /'
else
	row "state" "$(bad "helper missing")"
fi

# --------------------------------------------------------------- recent log

hdr "Recent decisions (last $LOG_LINES)"
if log=$(journalctl -t yubikey-auth -n "$LOG_LINES" --no-pager -o short-iso 2>/dev/null) && [[ $log ]]; then
	# Colour the outcome so a wall of lines is still scannable.
	sed -e "s/\(open\b\)/$C_OK\1$C_OFF/" \
		-e "s/\(closed\|expired\)/$C_WARN\1$C_OFF/" \
		-e "s/^/  /" <<<"$log"
else
	printf '  %s\n' "$(dim "nothing logged yet (or no journal access — try sudo)")"
fi
printf '\n'
