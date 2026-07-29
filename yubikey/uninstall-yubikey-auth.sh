#!/usr/bin/env bash
#
# uninstall-yubikey-auth.sh — back out the YubiKey step-down auth stack.
#
# Unwires every service first and only then removes the plumbing, so there is
# no window in which a PAM file references a helper that is already gone.
#
#   sudo ./uninstall-yubikey-auth.sh            # unwire + remove plumbing,
#                                               # keep enrolled credentials
#   sudo ./uninstall-yubikey-auth.sh --purge    # ...and delete /etc/yubikey-auth
#
# Credentials are kept by default: re-installing then costs nothing, whereas
# re-enrolling means touching the sensor again for every key.

set -euo pipefail

readonly ETC_DIR=/etc/yubikey-auth
readonly LIBEXEC_DIR=/usr/local/libexec/yubikey-auth
readonly PAM_DIR=/etc/pam.d
readonly PAM_FILE=$PAM_DIR/yubikey-auth
readonly PAM_TEST_FILE=$PAM_DIR/yubikey-auth-test
readonly TMPFILES=/etc/tmpfiles.d/yubikey-auth.conf
readonly STATE_DIR=/run/yubikey-auth
readonly BACKUP_SUFFIX=.pre-yubikey-auth
readonly SUDOERS_DROPIN=/etc/sudoers.d/10-yubikey-auth

purge=0
while (($#)); do
	case $1 in
	--purge) purge=1; shift ;;
	-h | --help) sed -n '3,13p' -- "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
	*) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
	esac
done

((EUID == 0)) || { printf 'error: must run as root\n' >&2; exit 1; }

step() { printf '==> %s\n' "$*"; }

step "Unwiring services"
shopt -s nullglob
wired=()
for f in "$PAM_DIR"/*; do
	[[ -f $f ]] || continue
	grep -qx '@include yubikey-auth' -- "$f" && wired+=("$f")
done

if ((${#wired[@]} == 0)); then
	printf '    nothing wired\n'
else
	for f in "${wired[@]}"; do
		sed -i 's|^@include yubikey-auth$|@include common-auth|' -- "$f"
		printf '    %s -> @include common-auth\n' "$f"
		# The .pre-yubikey-auth copy is left in place deliberately: it is the
		# evidence of what the file looked like before, and restoring it
		# wholesale would clobber unrelated edits made since.
		[[ -e $f$BACKUP_SUFFIX ]] && printf '      (original still at %s)\n' "$f$BACKUP_SUFFIX"
	done
fi

step "Restoring sudo's own credential cache"
if [[ -e $SUDOERS_DROPIN ]]; then
	rm -f -- "$SUDOERS_DROPIN"
	printf '    removed %s (sudo caches credentials again)\n' "$SUDOERS_DROPIN"
else
	printf '    nothing to restore\n'
fi

step "Removing plumbing"
for f in "$PAM_FILE" "$PAM_TEST_FILE" "$TMPFILES" "$LIBEXEC_DIR/yubikey-auth-window"; do
	if [[ -e $f ]]; then
		rm -f -- "$f"
		printf '    removed %s\n' "$f"
	fi
done
rmdir --ignore-fail-on-non-empty -- "$LIBEXEC_DIR" 2>/dev/null || true
rm -rf -- "$STATE_DIR"
printf '    cleared %s\n' "$STATE_DIR"

if ((purge)); then
	step "Purging credentials and config"
	rm -rf -- "$ETC_DIR"
	printf '    removed %s\n' "$ETC_DIR"
else
	step "Keeping $ETC_DIR (config + enrolled credentials)"
	printf '    re-run install-yubikey-auth.sh to restore the stack as it was\n'
	printf '    use --purge to delete it\n'
fi

step "Done — every service is back on the stock password stack"
