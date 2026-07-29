#!/usr/bin/env bash
#
# install-yubikey-auth.sh — install the YubiKey step-down auth stack on this
# host, idempotently. See zenbook/yubikey/README.md for the design.
#
# Installs the plumbing (helper, config, PAM snippet, tmpfiles rule) but wires
# nothing into a real login path unless you ask:
#
#   sudo ./install-yubikey-auth.sh                     # plumbing only
#   sudo ./install-yubikey-auth.sh --enable gdm        # ...and wire GNOME
#   sudo ./install-yubikey-auth.sh --enable gdm,sudo   # ...and sudo
#   sudo ./install-yubikey-auth.sh --disable sudo      # unwire one service
#   ./install-yubikey-auth.sh --status                 # what is wired now
#
# Re-running is always safe: files are rewritten from the template, and wiring
# a service that is already wired is a no-op. The first time a service file is
# modified its original is kept alongside as <file>.pre-yubikey-auth.

set -euo pipefail

readonly SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly ETC_DIR=/etc/yubikey-auth
readonly CONFIG=$ETC_DIR/config
readonly LIBEXEC_DIR=/usr/local/libexec/yubikey-auth
readonly HELPER=$LIBEXEC_DIR/yubikey-auth-window
readonly PAM_DIR=/etc/pam.d
readonly PAM_FILE=$PAM_DIR/yubikey-auth
readonly PAM_TEST_FILE=$PAM_DIR/yubikey-auth-test
readonly TMPFILES=/etc/tmpfiles.d/yubikey-auth.conf
readonly BACKUP_SUFFIX=.pre-yubikey-auth
readonly SUDOERS_DROPIN=/etc/sudoers.d/10-yubikey-auth
readonly POLKIT_DROPIN_DIR='/etc/systemd/system/polkit-agent-helper@.service.d'
readonly POLKIT_DROPIN=$POLKIT_DROPIN_DIR/10-yubikey-auth.conf

# Service alias -> the /etc/pam.d file whose "@include common-auth" we swap.
# Anything that includes common-auth can be added here; these are the ones
# that have been reasoned about.
declare -A SERVICES=(
	[gdm]=gdm-password       # GNOME greeter *and* the lock screen
	[sudo]=sudo
	[sudo-i]=sudo-i
	[login]=login            # text console — the rescue path; think first
	[polkit]=polkit-1
)

readonly APT_PACKAGES=(libpam-u2f pamu2fcfg yubikey-manager pamtester)

# Services that ship no /etc/pam.d file on this distro and must be created
# before they can be wired. polkit is the case that matters: with the file
# absent, polkit-agent-helper-1 falls through to /etc/pam.d/other (which
# @includes common-auth), so every pkexec and GNOME privileged prompt silently
# uses the stock password stack. Creating it is what lets the YubiKey cover
# those — and, once KeePassXC 2.8 ships, its polkit Quick Unlock backend.
#
# Contents mirror Debian's stock polkit-1 stack so that unwiring leaves
# behaviour identical to the /etc/pam.d/other fallback it replaces.
declare -A CREATABLE=(
	[polkit]='#%PAM-1.0
# Created by zenbook/yubikey/install-yubikey-auth.sh.
# polkit ships no PAM file on Ubuntu; without this, authorisation falls through
# to /etc/pam.d/other. Mirrors the stock Debian polkit-1 stack.
@include common-auth
@include common-account
@include common-session-noninteractive'
)

# ------------------------------------------------------------------- output

if [[ -t 1 ]]; then
	readonly C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
else
	readonly C_OK='' C_WARN='' C_ERR='' C_DIM='' C_OFF=''
fi

info() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments

enable_list=()
disable_list=()
status_only=0
debug_set=

split_csv() {
	local IFS=,
	read -r -a REPLY <<<"$1"
}

while (($#)); do
	case $1 in
	--enable)
		[[ ${2:-} ]] || die "--enable needs a comma-separated service list"
		split_csv "$2"; enable_list+=("${REPLY[@]}"); shift 2 ;;
	--enable=*)
		split_csv "${1#--enable=}"; enable_list+=("${REPLY[@]}"); shift ;;
	--disable)
		[[ ${2:-} ]] || die "--disable needs a comma-separated service list"
		split_csv "$2"; disable_list+=("${REPLY[@]}"); shift 2 ;;
	--disable=*)
		split_csv "${1#--disable=}"; disable_list+=("${REPLY[@]}"); shift ;;
	--status) status_only=1; shift ;;
	--debug)
		case ${2:-} in
		on)  debug_set=1 ;;
		off) debug_set=0 ;;
		*)   die "--debug takes 'on' or 'off'" ;;
		esac
		shift 2 ;;
	-h | --help)
		sed -n '3,20p' -- "${BASH_SOURCE[0]}" | sed 's/^# \?//'
		exit 0 ;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
done

for svc in "${enable_list[@]}" "${disable_list[@]}"; do
	[[ ${SERVICES[$svc]:-} ]] || die "unknown service '$svc'; known: ${!SERVICES[*]}"
done

# ------------------------------------------------------------------- status

wiring_state() {
	# echoes: wired | stock | missing
	local file=$PAM_DIR/${SERVICES[$1]}
	[[ -f $file ]] || { echo missing; return; }
	if grep -qx '@include yubikey-auth' -- "$file"; then
		echo wired
	else
		echo stock
	fi
}

print_status() {
	step "YubiKey step-down auth status"
	local installed=yes
	for f in "$HELPER" "$PAM_FILE" "$CONFIG"; do
		[[ -e $f ]] || installed="no (missing $f)"
	done
	printf '  plumbing:  %s\n' "$installed"

	local authfile=/etc/yubikey-auth/u2f_mappings
	[[ -r $CONFIG ]] && authfile=$(. "$CONFIG" 2>/dev/null; printf '%s' "${AUTHFILE:-$authfile}")
	# The mapping file carries a comment header, so strip comments and blanks
	# before pulling usernames — otherwise the header is printed as if it were
	# a list of enrolled users.
	local users=''
	[[ -r $authfile ]] &&
		users=$(grep -v -e '^#' -e '^[[:space:]]*$' -- "$authfile" 2>/dev/null | cut -d: -f1 | paste -sd' ' -)
	if [[ -n $users ]]; then
		printf '  enrolled:  %s\n' "$users"
	else
		printf '  enrolled:  %snobody — run enroll-yubikey.sh%s\n' "$C_WARN" "$C_OFF"
	fi

	printf '  services:\n'
	local svc state colour
	for svc in $(printf '%s\n' "${!SERVICES[@]}" | sort); do
		state=$(wiring_state "$svc")
		case $state in
		wired)   colour=$C_OK ;;
		missing) colour=$C_DIM ;;
		*)       colour=$C_DIM ;;
		esac
		printf '    %-8s %-14s %s%s%s\n' "$svc" "${SERVICES[$svc]}" "$colour" "$state" "$C_OFF"
	done

	# Without this, sudo's own cache silently skips PAM and no touch is asked
	# for — the stack looks wired but does not behave as intended.
	if [[ -e $SUDOERS_DROPIN ]]; then
		printf '  sudo cache: %sdisabled%s (%s)\n' "$C_OK" "$C_OFF" "$SUDOERS_DROPIN"
	elif [[ $(wiring_state sudo) == wired || $(wiring_state sudo-i) == wired ]]; then
		printf '  sudo cache: %sSTILL ON%s — sudo skips PAM for ~15min after each success\n' "$C_WARN" "$C_OFF"
	fi

	# Wiring polkit without this drop-in looks correct but never asks for a
	# touch, because the helper's sandbox hides /dev/hidraw*.
	if [[ $(wiring_state polkit) == wired ]]; then
		if [[ -e $POLKIT_DROPIN ]]; then
			printf '  polkit dev: %sallowed%s (%s)\n' "$C_OK" "$C_OFF" "${POLKIT_DROPIN##*/}"
		else
			printf '  polkit dev: %sSANDBOXED%s — helper cannot see the YubiKey, so polkit\n' "$C_ERR" "$C_OFF"
			printf '              always falls back to a password. Re-run --enable polkit.\n'
		fi
	fi
}

if ((status_only)); then
	print_status
	exit 0
fi

((EUID == 0)) || die "must run as root (try: sudo $0 $*)"

# ------------------------------------------------------------ dependencies

step "Checking dependencies"
missing=()
[[ -e /usr/lib/$(uname -m)-linux-gnu/security/pam_u2f.so || -e /lib/security/pam_u2f.so ]] || missing+=(libpam-u2f)
command -v pamu2fcfg >/dev/null || missing+=(pamu2fcfg)
command -v ykman >/dev/null || missing+=(yubikey-manager)
command -v pamtester >/dev/null || missing+=(pamtester)

if ((${#missing[@]})); then
	info "  installing: ${missing[*]}"
	DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
else
	info "  all present"
fi

# --------------------------------------------------------------- plumbing

step "Installing helper and config"
install -d -o root -g root -m 0755 "$LIBEXEC_DIR" "$ETC_DIR"
install -o root -g root -m 0755 -- "$SRC_DIR/yubikey-auth-window" "$HELPER"
info "  $HELPER"

if [[ -e $CONFIG ]]; then
	info "  $CONFIG (kept — existing config is never overwritten)"
else
	install -o root -g root -m 0644 -- "$SRC_DIR/config.default" "$CONFIG"
	info "  $CONFIG (new)"
fi

# Load the (possibly hand-edited) config so the PAM snippet is rendered from
# the values actually in force.
ORIGIN=pam://$(hostname)
APPID=$ORIGIN
AUTHFILE=$ETC_DIR/u2f_mappings
CUE_PROMPT="Touch your YubiKey"
U2F_DEBUG=0
U2F_DEBUG_FILE=syslog
U2F_ATTEMPTS=3
SUDO_TIMESTAMP_TIMEOUT=5

# Probe the config in a subshell first and capture anything it writes to stderr.
# A malformed line — classically an unquoted value containing spaces, which the
# shell parses as VAR=word followed by a *command* — would otherwise abort the
# install with a bare "foo: command not found" naming neither the file nor the
# variable. Checking the exit status is not enough: `VAR=a b c` in the middle of
# the file leaves the overall status 0, and the assignment silently does not
# stick, so the variable quietly keeps its default.
config_err=$( . "$CONFIG" 2>&1 >/dev/null ) || true
if [[ -n $config_err ]]; then
	warn "$CONFIG produced errors while being read:"
	printf '    %s\n' "$config_err" >&2
	warn "the usual cause is a value containing spaces that is not quoted,"
	warn "e.g. CUE_PROMPT=Touch your YubiKey instead of CUE_PROMPT=\"Touch your YubiKey\";"
	warn "such a line does NOT set the variable, so its default is used instead."
fi

# shellcheck source=config.default
. "$CONFIG"

# --debug on|off rewrites the stored setting so it survives, then falls through
# to the normal render below.
if [[ -n $debug_set ]]; then
	if grep -qE '^[[:space:]]*U2F_DEBUG=' -- "$CONFIG"; then
		sed -i -E "s|^[[:space:]]*U2F_DEBUG=.*|U2F_DEBUG=$debug_set|" -- "$CONFIG"
	else
		printf '\nU2F_DEBUG=%s\n' "$debug_set" >>"$CONFIG"
	fi
	U2F_DEBUG=$debug_set
	info "  U2F_DEBUG=$debug_set in $CONFIG"
fi

for _var in ORIGIN APPID AUTHFILE; do
	[[ -n ${!_var:-} ]] ||
		die "$CONFIG left $_var empty — fix that line (values with spaces must be quoted)"
done
case $AUTHFILE in
/*) ;;
*) die "$CONFIG: AUTHFILE must be an absolute path, got '$AUTHFILE'" ;;
esac
[[ ${CUE_PROMPT:-} ]] ||
	warn "$CONFIG left CUE_PROMPT empty — pam_u2f will use its built-in prompt"

# The mapping file must exist before pam_u2f is in a login path: a missing
# authfile is a pam_u2f error rather than a clean "no credentials", and while
# that still degrades to the password branch it logs noisily.
if [[ ! -e $AUTHFILE ]]; then
	install -o root -g root -m 0644 /dev/null "$AUTHFILE"
	info "  $AUTHFILE (empty — nobody enrolled yet)"
fi

step "Installing tmpfiles rule for the window state directory"
cat >"$TMPFILES" <<-EOF
	# Window state for the YubiKey step-down auth stack. On tmpfs by design:
	# every window closes on reboot, so a cold boot always costs one password.
	d /run/yubikey-auth 0700 root root -
EOF
chmod 0644 "$TMPFILES"
systemd-tmpfiles --create "$TMPFILES"
info "  /run/yubikey-auth"

# ------------------------------------------------------------- PAM snippet

step "Rendering $PAM_FILE"
u2f_args="authfile=$AUTHFILE origin=$ORIGIN appid=$APPID userverification=1 cue"
[[ -n ${CUE_PROMPT:-} ]] && u2f_args+=" [cue_prompt=$CUE_PROMPT]"
if [[ ${U2F_DEBUG:-0} == 1 ]]; then
	u2f_args+=" debug debug_file=$U2F_DEBUG_FILE"
	# pam_u2f's `debug` also switches libfido2 into debug mode, and libfido2
	# writes to stderr regardless of debug_file. For polkit that stderr IS the
	# agent protocol socket, so the trace corrupts the conversation: the agent
	# reports "Unknown line ... from helper", authentication fails, and it
	# retries in a tight loop. Never leave this on with polkit wired.
	if [[ $(wiring_state polkit) == wired ]]; then
		warn "polkit is wired: pam_u2f debug will CORRUPT its agent protocol"
		warn "(libfido2 traces to stderr = the polkit socket) and cause an"
		warn "authentication retry loop. Turn it off with --debug off after use."
	fi
	# syslog/stderr/stdout are literal keywords, not paths — do not try to
	# create them. A real path must exist already: pam_u2f deliberately never
	# creates it, and silently logs nothing if it is missing.
	case $U2F_DEBUG_FILE in
	syslog | stderr | stdout) ;;
	*) install -o root -g root -m 0600 /dev/null "$U2F_DEBUG_FILE" ;;
	esac
	warn "pam_u2f debug logging is ON -> $U2F_DEBUG_FILE"
fi

# A bad attempt count would corrupt the jump arithmetic below and could send a
# closed window into the middle of the YubiKey block instead of to the password
# stack, so validate before it can reach the PAM file.
[[ $U2F_ATTEMPTS =~ ^[1-9][0-9]*$ ]] ||
	die "$CONFIG: U2F_ATTEMPTS must be a positive integer, got '$U2F_ATTEMPTS'"
((U2F_ATTEMPTS <= 10)) ||
	die "$CONFIG: U2F_ATTEMPTS=$U2F_ATTEMPTS is unreasonably high; the Bio blocks its sensor after 3 consecutive misses"

tmp=$(mktemp)
trap 'rm -f -- "$tmp"' EXIT

# Rendered with a read loop rather than sed: $u2f_args contains both '/' and
# the square brackets of [cue_prompt=...], and the YubiKey block is multi-line.
# The "default=" jump on the check line is emitted from the same U2F_ATTEMPTS
# as the block itself, so the two cannot drift apart.
while IFS= read -r line || [[ -n $line ]]; do
	case $line in
	*@U2F_LINES@*)
		for ((i = 1; i <= U2F_ATTEMPTS; i++)); do
			printf 'auth  [success=done default=ignore]  pam_u2f.so %s\n' "$u2f_args"
		done
		;;
	*)
		line=${line//@HELPER@/$HELPER}
		line=${line//@U2F_ATTEMPTS@/$U2F_ATTEMPTS}
		printf '%s\n' "$line"
		;;
	esac
done <"$SRC_DIR/pam/yubikey-auth.in" >"$tmp"

# Belt and braces: the number of pam_u2f lines actually emitted must equal the
# skip count actually emitted, or a closed window lands somewhere unintended.
emitted=$(grep -c '^auth.*pam_u2f\.so' -- "$tmp")
jump=$(sed -n 's/^auth *\[success=ok default=\([0-9]*\)\].*/\1/p' -- "$tmp")
[[ $emitted == "$jump" ]] ||
	die "internal error: $emitted pam_u2f lines but the check line skips $jump — refusing to install"

install -o root -g root -m 0644 -- "$tmp" "$PAM_FILE"
info "  origin=$ORIGIN authfile=$AUTHFILE attempts=$U2F_ATTEMPTS"

# A throwaway service so the stack can be exercised with pamtester without
# putting a real login path at risk.
cat >"$PAM_TEST_FILE" <<-EOF
	# Scratch service for exercising the YubiKey stack with pamtester:
	#     pamtester yubikey-auth-test \$USER authenticate
	# Nothing else references this file; it grants no access on its own.
	@include yubikey-auth
	@include common-account
EOF
chmod 0644 "$PAM_TEST_FILE"
info "  $PAM_TEST_FILE (for pamtester)"

# ----------------------------------------------------------------- wiring

wire() {
	local svc=$1 file=$PAM_DIR/${SERVICES[$svc]}
	if [[ ! -f $file && -n ${CREATABLE[$svc]:-} ]]; then
		printf '%s\n' "${CREATABLE[$svc]}" >"$file"
		chown root:root "$file"
		chmod 0644 "$file"
		info "  $svc ($file): ${C_OK}created${C_OFF} (this distro ships none)"
	fi
	[[ -f $file ]] || { warn "$svc: $file does not exist — skipping"; return; }
	if grep -qx '@include yubikey-auth' -- "$file"; then
		info "  $svc ($file): already wired"
		return
	fi
	grep -qx '@include common-auth' -- "$file" ||
		die "$svc: $file has no plain '@include common-auth' line to replace — wire it by hand"
	[[ -e $file$BACKUP_SUFFIX ]] || cp -a -- "$file" "$file$BACKUP_SUFFIX"
	sed -i 's|^@include common-auth$|@include yubikey-auth|' -- "$file"
	info "  $svc ($file): ${C_OK}wired${C_OFF} (original at $file$BACKUP_SUFFIX)"
}

unwire() {
	local svc=$1 file=$PAM_DIR/${SERVICES[$svc]}
	[[ -f $file ]] || { warn "$svc: $file does not exist — skipping"; return; }
	if ! grep -qx '@include yubikey-auth' -- "$file"; then
		info "  $svc ($file): not wired"
		return
	fi
	sed -i 's|^@include yubikey-auth$|@include common-auth|' -- "$file"
	info "  $svc ($file): ${C_WARN}unwired${C_OFF}"
}

# sudo keeps its own credential cache (sudo-rs: /run/sudo-rs/ts) and consults it
# *before* PAM. Left at the default 15 minutes it would short-circuit the whole
# stack, so you would get neither a touch nor a password after the first sudo —
# which is not "touch every time". Zero means every sudo goes through PAM.
#
# An invalid file under /etc/sudoers.d locks you out of sudo entirely, so this
# validates twice: the drop-in on its own, then the whole sudoers tree after
# installing, rolling back if that fails.
find_visudo() {
	# Prefer the checker belonging to the sudo actually in use — sudo-rs and
	# classic sudo do not accept identical syntax.
	local v
	for v in /usr/bin/visudo-rs /usr/sbin/visudo /usr/sbin/visudo.ws; do
		[[ -x $v ]] && { printf '%s' "$v"; return 0; }
	done
	return 1
}

install_sudoers_dropin() {
	local visudo
	if ! visudo=$(find_visudo); then
		warn "no visudo found — refusing to write $SUDOERS_DROPIN unvalidated."
		warn "sudo will keep its 15-minute cache, so a touch is not required every time."
		return
	fi

	[[ $SUDO_TIMESTAMP_TIMEOUT =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
		die "$CONFIG: SUDO_TIMESTAMP_TIMEOUT must be a number of minutes, got '$SUDO_TIMESTAMP_TIMEOUT'"

	local tmp rationale
	if [[ $SUDO_TIMESTAMP_TIMEOUT == 0 ]]; then
		rationale='# 0 disables the cache: every sudo re-runs the PAM stack, so a YubiKey
		# touch is required every single time.'
	else
		rationale='# Inside this window sudo never reaches PAM, so a quick follow-up command
		# costs nothing at all — no touch, no password. Outside it the stack in
		# /etc/pam.d/sudo applies as usual. sudo-rs keeps a separate record per
		# terminal, so the grace period cannot leak into another terminal.
		# 5 minutes is the long-standing macOS default.'
	fi

	tmp=$(mktemp)
	cat >"$tmp" <<-EOF
		# Managed by zenbook/yubikey/install-yubikey-auth.sh — do not edit.
		# Change SUDO_TIMESTAMP_TIMEOUT in /etc/yubikey-auth/config, then re-run
		# install-yubikey-auth.sh --enable sudo.
		#
		# Units are MINUTES; sudo-rs accepts fractions (0.5) but not suffixes ("30s").
		$rationale
		Defaults timestamp_timeout=$SUDO_TIMESTAMP_TIMEOUT
	EOF

	if ! "$visudo" --check --file="$tmp" >/dev/null 2>&1; then
		rm -f -- "$tmp"
		die "$visudo rejected the generated sudoers drop-in — not installing it"
	fi

	local restore=0
	[[ -e $SUDOERS_DROPIN ]] && restore=1 && cp -a -- "$SUDOERS_DROPIN" "$tmp.prev"
	install -o root -g root -m 0440 -- "$tmp" "$SUDOERS_DROPIN"
	rm -f -- "$tmp"

	# Now that it is in place, validate the tree as sudo will actually parse it.
	if ! "$visudo" --check >/dev/null 2>&1; then
		if ((restore)); then
			install -o root -g root -m 0440 -- "$tmp.prev" "$SUDOERS_DROPIN"
		else
			rm -f -- "$SUDOERS_DROPIN"
		fi
		rm -f -- "$tmp.prev"
		die "sudoers tree failed validation after adding the drop-in — rolled back"
	fi
	rm -f -- "$tmp.prev"
	info "  $SUDOERS_DROPIN: timestamp_timeout=0 (validated with ${visudo##*/})"
}

# polkit 127 runs its auth helper as a socket-activated systemd unit
# (polkit-agent-helper@.service) rather than a setuid binary, and that unit is
# heavily sandboxed:
#
#     PrivateDevices=yes
#     DevicePolicy=strict
#     DeviceAllow=/dev/null rw      <- /dev/null and nothing else
#
# pam_u2f talks to /dev/hidrawN directly, so inside that sandbox the YubiKey is
# both absent from /dev and forbidden by the cgroup device controller. Every
# polkit authentication therefore falls through to the password branch, no
# matter how the PAM stack is wired. (Modules that reach hardware over D-Bus
# instead — pam_fprintd, say — are unaffected, since AF_UNIX is permitted.)
#
# The binary hints at "disable polkit-agent-helper.socket and use setuid
# helper", but Ubuntu ships /usr/lib/polkit-1/polkit-agent-helper-1 as
# -rwxr-xr-x, NOT setuid: disabling the socket would break polkit auth
# outright. So the only safe fix is to relax the sandbox for hidraw only.
#
# This is deliberately narrow. PrivateDevices=no restores the real /dev, but
# DevicePolicy=strict stays in force and the DeviceAllow list still permits
# only /dev/null plus hidraw — so the helper gains access to HID devices and
# nothing else. It is still a local override of a distro hardening decision,
# and it is confined to services wired for polkit.
install_polkit_dropin() {
	install -d -o root -g root -m 0755 "$POLKIT_DROPIN_DIR"
	cat >"$POLKIT_DROPIN" <<-EOF
		# Managed by zenbook/yubikey/install-yubikey-auth.sh — do not edit.
		#
		# Lets pam_u2f reach the YubiKey from inside polkit's sandboxed auth
		# helper. Without this every polkit prompt silently demands a password
		# instead of a touch. See the script for the full rationale.
		[Service]
		# The stock unit gives the helper a private /dev with no hidraw nodes,
		# so the YubiKey is invisible. Turning it off exposes the real /dev —
		# but it also withdraws the small set of pseudo-devices that
		# PrivateDevices=yes was silently providing, and DevicePolicy=strict
		# then permits only what is listed below. pam_u2f reads /dev/urandom
		# directly to build its challenge, so omitting it fails with
		# "set_cdh: Failed to generate challenge" AFTER the key is found —
		# which looks like a hardware problem and is not one.
		PrivateDevices=no
		# DevicePolicy=strict still applies; these append to the stock
		# DeviceAllow list, so the helper reaches only these devices.
		# hidraw is char major 240 (see /proc/devices).
		DeviceAllow=char-hidraw rw
		DeviceAllow=/dev/urandom r
		DeviceAllow=/dev/random r
		DeviceAllow=/dev/zero rw
		DeviceAllow=/dev/full rw
		# The stock unit sets StandardInput/Output=socket and leaves
		# StandardError to default, which means it inherits stdout — the polkit
		# agent protocol socket. Anything a PAM module writes to stderr is then
		# parsed as protocol ("Unknown line ... from helper"), authentication
		# fails, and the agent retries in a tight loop. libfido2 does exactly
		# that whenever pam_u2f's debug flag is on. Sending stderr to the
		# journal keeps the protocol clean and makes the traces readable with
		#     journalctl -u 'polkit-agent-helper@*' -f
		StandardError=journal
	EOF
	chmod 0644 "$POLKIT_DROPIN"
	systemctl daemon-reload
	info "  $POLKIT_DROPIN: hidraw reachable from the polkit helper"
}

remove_polkit_dropin() {
	[[ -e $POLKIT_DROPIN ]] || return 0
	rm -f -- "$POLKIT_DROPIN"
	rmdir --ignore-fail-on-non-empty -- "$POLKIT_DROPIN_DIR" 2>/dev/null || true
	systemctl daemon-reload
	info "  $POLKIT_DROPIN: removed (polkit helper sandbox back to stock)"
}

remove_sudoers_dropin() {
	[[ -e $SUDOERS_DROPIN ]] || return 0
	rm -f -- "$SUDOERS_DROPIN"
	info "  $SUDOERS_DROPIN: removed (sudo's own cache is back to the default)"
}

if ((${#disable_list[@]})); then
	step "Unwiring services"
	for svc in "${disable_list[@]}"; do unwire "$svc"; done
	# Only drop the sudoers tweak once neither sudo service is wired any more.
	if [[ " ${disable_list[*]} " == *" sudo "* || " ${disable_list[*]} " == *" sudo-i "* ]] &&
		[[ $(wiring_state sudo) != wired && $(wiring_state sudo-i) != wired ]]; then
		remove_sudoers_dropin
	fi
	if [[ " ${disable_list[*]} " == *" polkit "* ]]; then
		remove_polkit_dropin
	fi
fi

if ((${#enable_list[@]})); then
	step "Wiring services"
	if ! [[ -s $AUTHFILE ]]; then
		warn "$AUTHFILE is empty — nobody has enrolled a key yet."
		warn "This is safe (every service still accepts your password) but the"
		warn "YubiKey branch cannot succeed until you run enroll-yubikey.sh."
	fi
	for svc in "${enable_list[@]}"; do wire "$svc"; done
	if [[ " ${enable_list[*]} " == *" sudo "* || " ${enable_list[*]} " == *" sudo-i "* ]]; then
		install_sudoers_dropin
	fi
	# Without this the polkit wiring is inert: the helper's sandbox hides the
	# YubiKey, so every prompt falls through to the password branch.
	if [[ " ${enable_list[*]} " == *" polkit "* ]]; then
		install_polkit_dropin
	fi
fi

echo
print_status
