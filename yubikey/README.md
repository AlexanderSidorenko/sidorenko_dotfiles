# YubiKey step-down auth

Password once per 12 hours; a fingerprint on the YubiKey every time after that.

The laptop's LUKS passphrase is **not** part of this and stays password-only —
this covers post-boot authentication only.

## Policy

| Situation | What it costs you |
| --- | --- |
| First auth after a boot | Password |
| First auth after the window expires | Password |
| Any auth within 12h of the last password | Touch the YubiKey (fingerprint) |
| YubiKey absent, rejected, or cancelled | Password (always available) |

Two deliberate choices behind that table:

- **The window dies on reboot.** State lives in `/run`, a tmpfs. A cold boot
  always costs one password, so someone who power-cycles a stolen laptop can
  never land in touch-only mode.
- **A touch does not extend the window.** The 12h is measured from the last
  *password*, not the last successful auth, so the exposure has a hard
  deadline instead of sliding forward forever while you keep working. Retune
  with `WINDOW_SECONDS` in `/etc/yubikey-auth/config`; a sliding window would
  mean moving the `stamp` line in the PAM snippet, not just a config change.

The window is **shared across every wired service**. Typing your password at
the GNOME lock screen also buys touch-only `sudo` for the rest of the window,
which is the point: one password event, not one per service.

## The hardware

```
Device type:   YubiKey C Bio - FIDO Edition
Serial number: 32189864
Firmware:      5.7.4
Applications:  FIDO U2F + FIDO2 only
               Yubico OTP / OATH / PIV / OpenPGP — Not available
```

That inventory drives every design decision here. A FIDO-only key means
`pam_u2f` is the sole integration route: no PIV smartcard login, no GPG, and —
see below — no KeePassXC.

"Always Require UV" is on, so the key demands user verification (the
fingerprint, or the PIN as fallback) for every assertion. Credentials are
registered with `pamu2fcfg -V` and authenticated with `userverification=1`, so
a touch alone can never satisfy the key — it has to be *your* finger.

## Architecture

Two pieces: a freshness window, and a PAM stack that branches on it.

```
                    ┌─────────────────────────────┐
 auth request ─────▶│ pam_exec … yubikey-auth-window check │
                    └──────┬───────────────┬──────┘
                    open   │               │  closed / expired
                           ▼               ▼
                    ┌────────────┐   ┌──────────────┐
                    │  pam_u2f   │   │ common-auth  │  ← the stock password stack
                    │ fingerprint│   └──────┬───────┘
                    └──┬──────┬──┘          │ password OK
                  ok   │      │ fail        ▼
                       ▼      └────▶ ┌──────────────┐
                    SUCCESS          │ …window stamp│
              (window NOT extended)  └──────┬───────┘
                                            ▼
                                         SUCCESS
```

`/etc/pam.d/yubikey-auth` is the whole thing:

```
auth  [success=ok default=3]         pam_exec.so seteuid … yubikey-auth-window check
auth  [success=done default=ignore]  pam_u2f.so authfile=… userverification=1 cue …
auth  [success=done default=ignore]  pam_u2f.so …          (repeated U2F_ATTEMPTS times)
auth  [success=done default=ignore]  pam_u2f.so …
@include common-auth
auth  optional                       pam_exec.so seteuid … yubikey-auth-window stamp
```

Each line is load-bearing:

1. **`default=N`** — any non-success from the window check (closed, expired,
   corrupt stamp, helper missing, helper crashed) skips the whole YubiKey
   block, jumping straight to the password stack. **N must equal the number of
   `pam_u2f` lines.** The installer emits both from `U2F_ATTEMPTS` and then
   re-counts the rendered file, refusing to install if they disagree — get this
   wrong and a closed window lands in the middle of the block instead of on
   `common-auth`.
2. **`success=done`** — a good fingerprint returns success for the *entire*
   stack, which is what keeps a touch from reaching the `stamp` line and
   extending the window. `default=ignore` means every YubiKey failure falls
   through to the *next* copy of the module, and after the last one to the
   password, instead of denying.
3. **The repetition is the retry.** `pam_u2f` has no retry option, so listing
   the module `U2F_ATTEMPTS` times is the PAM idiom for "offer the sensor
   again". Without it a single bad-angle read costs you a password.
3. **`@include common-auth`** — the distro's own stack, untouched, still
   managed by `pam-auth-update`.
4. **`seteuid` is mandatory.** `pam_exec` runs its command with the *real* uid
   by default. `sudo` is setuid-root, so under it the real uid remains the
   invoking user while only the effective uid is root — without `seteuid`,
   `check` cannot read the root-owned state file and `stamp` refuses to write
   it, leaving sudo permanently on the password branch. GDM runs as root either
   way and never exposes this, which is exactly why testing only the login path
   would hide the bug.
5. **`stamp` is only reachable after a *correct* password.** A wrong one
   aborts inside `common-auth` at its `auth requisite pam_deny.so` line, which
   returns from the whole stack before control can ever get here. A correct
   one makes `pam_unix` jump over `pam_deny` to `pam_permit` and fall out of
   `common-auth` into this line. This is why the snippet uses `@include` and
   **not** `substack`: `substack` would contain that abort, and a failed
   password would then reach `stamp` and open a window. Do not "clean this up"
   into a substack.

### Why not `pam_timestamp`?

Ubuntu ships `pam_timestamp.so`, which is the same idea off-the-shelf and was
seriously considered — a stock upstream C module beats our own script on
principle. Two properties of it rule it out here, both verified rather than
assumed:

- **It keys timestamps per-TTY**, as `/var/run/pam_timestamp/<user>/<tty>`
  (the `%s/%s/%s` format string in the module). Every new terminal is a fresh
  `pts/N` with no timestamp, so `sudo` would demand a *password* in each new
  terminal window rather than a touch.
- **It only writes timestamps in `pam_sm_open_session`.** GNOME runs the full
  stack on login but only the `auth` stack on *unlock*, so once the window
  lapsed, a password unlock could not re-open it — you would be back to a
  password on every unlock until the next full logout and login.

`nm -D pam_timestamp.so` confirms the phases: `pam_sm_authenticate` checks,
`pam_sm_open_session` writes. The helper here exists precisely to put the
write in the **auth** stack, where unlock can reach it.

### Why the window is shared rather than per-service

One window covers every wired service, so a password at the lock screen also
buys touch-only `sudo`. Per-service windows were explicitly fine too, but
sharing is both simpler (one state path) and fewer passwords. Switching to
per-service means adding `$PAM_SERVICE` to the state path in the PAM snippet —
`pam_exec` exports it — and nothing else.

### Why the mapping file lives in `/etc`

`AUTHFILE=/etc/yubikey-auth/u2f_mappings`, root-owned, rather than
`~/.config/Yubico/u2f_keys`. In the default location any process running as
you could enrol an extra key and mint itself a second factor — the file that
defines your second factor must not be writable by the account it protects.

## Lockout analysis

**There is no state in which this stack can lock you out.** Every failure
degrades to the stock password prompt:

| Failure | Result |
| --- | --- |
| YubiKey lost, dead, or unplugged | `pam_u2f` fails → password |
| Fingerprint rejected / sensor dirty | `pam_u2f` fails → password |
| Fingerprints wiped, PIN blocked | `pam_u2f` fails → password |
| `u2f_mappings` empty or deleted | `pam_u2f` fails → password |
| Helper deleted, chmod'd, or crashing | `pam_exec` non-success → password |
| `/run/yubikey-auth` unwritable | no stamp → window never opens → password |
| Clock jumps backwards | stamp reads as future-dated → treated closed → password |

The escape hatch if a PAM edit ever goes wrong anyway: **Ctrl+Alt+F3** for a
text console. `/etc/pam.d/login` is not wired by default precisely so that it
stays a stock password login. Undo from there with
`sudo ./uninstall-yubikey-auth.sh`.

## Files

| Repo | Installed to | What it is |
| --- | --- | --- |
| `yubikey-auth-window` | `/usr/local/libexec/yubikey-auth/` | the window: `check` / `stamp` / `clear` / `status` |
| `pam/yubikey-auth.in` | `/etc/pam.d/yubikey-auth` | PAM snippet template, rendered at install |
| `config.default` | `/etc/yubikey-auth/config` | window length, origin, authfile, cue prompt |
| `install-yubikey-auth.sh` | — | idempotent installer + service wiring |
| `uninstall-yubikey-auth.sh` | — | unwire everything, back to stock |
| `enroll-yubikey.sh` | — | PIN → fingerprints → PAM credential |
| `yubikey-auth-status.sh` | — | read-only health snapshot |
| — | `/etc/yubikey-auth/u2f_mappings` | enrolled credentials, root-owned |
| — | `/run/yubikey-auth/<user>` | the window itself (tmpfs, 0600 root) |
| — | `/etc/sudoers.d/10-yubikey-auth` | sudo's cache timeout, only when sudo is wired |
| — | `/etc/pam.d/polkit-1` | created by us — Ubuntu ships none |
| — | `/etc/systemd/system/polkit-agent-helper@.service.d/10-yubikey-auth.conf` | un-sandboxes the polkit helper enough to reach the key |

## Setup

```sh
sudo ./install-yubikey-auth.sh     # plumbing only — wires nothing yet
./enroll-yubikey.sh                # PIN, fingerprints, credential
```

`enroll-yubikey.sh` walks three prerequisites in order, because the Bio
enforces them in order: a FIDO2 PIN must exist before fingerprints can be
enrolled, and a fingerprint must exist before a UV credential is any use.

Enrol **two fingers, one per hand**. A cut or a cold finger otherwise drops
you back to typing your password until you re-enrol. The Bio holds up to five
templates, and enrolling the *same* finger twice at different angles helps
more with awkward-angle misreads than retries do.

### The FIDO2 PIN

**It is not your login password**, and in this setup it is an *administrative*
credential rather than a daily one. Day-to-day authentication is the
fingerprint; when that fails the stack falls through to your login password,
so no lock screen ever prompts for this PIN. It is needed only to add, list or
delete fingerprints, to unblock the sensor, and to change FIDO config.

| | |
| --- | --- |
| Minimum | 4 characters (this key reports `minpinlen: 4`) |
| Maximum | 63 bytes UTF-8, measured after NFC normalisation |
| Character set | any alphanumeric — it is a passphrase, not digits |
| Wrong-guess budget | 8 total, in batches of 3+3+2 (reinsert between batches) |
| After 8 wrong | FIDO2 application locks → reset → **all credentials wiped** |

Because it is typed rarely, make it long and random and store it:

```sh
keepassxc-cli generate -L 24 -U -l -n
```

~20–24 random alphanumerics. Going to the 63-byte maximum buys nothing —
verification happens on-key behind a hardware retry counter, so an attacker
gets 8 guesses ever and there is no offline attack to harden against. Avoid
symbols: keyboard-layout pain for no gain.

Keep it somewhere that does **not** depend on the YubiKey. KeePassXC is
password-based today, so it qualifies; if [`keepassxc-unlock`](#keepassxc--deferred-but-there-is-a-viable-path)
is ever adopted, keep an offline copy too.

### Counters, and what actually ratchets

Nothing accumulates permanently from failed touches. Both counters reset on
success:

| Counter | Decrements on | Resets on | At zero |
| --- | --- | --- | --- |
| `uv retries` (3) | failed fingerprint match | any successful match | sensor blocked → any PIN operation unblocks it, credentials intact |
| `pin retries` (8) | wrong PIN | any correct PIN | FIDO2 app locks → reset → credentials wiped |

So a fumbled read costs nothing durable; it takes **three consecutive** misses
with no success between them to block the sensor. Unblock with any PIN
operation, e.g. `ykman fido fingerprints list`.

The PIN counter bottoming out is the one unrecoverable path, and the reason
the PIN belongs in a password manager rather than in your memory.

Read both counters at any time with `ykman fido info`, or raw via
`fido2-token -I /dev/hidrawN`.

FIDO2 credentials also carry a monotonic **signature counter** that never
resets, but it is an anti-cloning measure for relying parties, not a budget —
`pam_u2f` does not gate on it.

Then verify against the real stack without risking a login path:

```sh
pamtester yubikey-auth-test "$USER" authenticate   # 1st: password (window closed)
pamtester yubikey-auth-test "$USER" authenticate   # 2nd: touch prompt
```

Only once the second run prompts for a touch, wire the services — GNOME first,
on its own, so that if something is wrong there is still a working `sudo` to
fix it with:

```sh
sudo ./install-yubikey-auth.sh --enable gdm
```

Then — **before logging out** — lock the screen (`Super+L`) and unlock it from
a session you can still recover. Keep a terminal open until you have seen it
work.

Only after GNOME is proven, add sudo, keeping a live root shell
(`sudo -i`) open in a second terminal while you test:

```sh
sudo ./install-yubikey-auth.sh --enable sudo
```

### Adding a backup key

Re-run `./enroll-yubikey.sh` with the second key plugged in. Credentials
accumulate on the user's line; they do not replace each other.

## Per-service notes

### GNOME (`gdm-password`) — wired first

`gdm-session-worker` uses `gdm-password` for both the greeter and the lock
screen, so wiring that one file covers login and unlock together.

`gdm-fingerprint` (the built-in laptop reader) is inert here — `fprintd`
reports **no devices available** on this machine, so it is not a bypass around
this policy. If a reader ever appears, that stack authenticates with
`pam_fprintd` alone and would need wiring or disabling.

**Known consequence — the GNOME keyring.** `pam_gnome_keyring` unlocks your
login keyring using the password you just typed. On the touch-only path there
is no password to hand it, and `success=done` returns before that module runs,
so the keyring stays locked and GNOME prompts for it separately. In practice
this rarely bites: after a reboot the window is closed, so a fresh login is a
password login and the keyring unlocks normally. It only shows up if you log
out and back in within the window. Screen *unlock* is unaffected — the keyring
is already open.

### sudo (`sudo-rs`)

`sudo ./install-yubikey-auth.sh --enable sudo` wires `/etc/pam.d/sudo` **and**
installs `/etc/sudoers.d/10-yubikey-auth`.

That second half is not optional. This host runs **`sudo-rs` 0.2.13**, not
classic sudo — `/usr/bin/sudo` → `/etc/alternatives/sudo` →
`/usr/lib/cargo/bin/sudo`. Like classic sudo it keeps its own credential cache
(`/run/sudo-rs/ts`) and consults it *before* PAM, so at the stock 15-minute
timeout you would get neither a touch nor a password after the first sudo.

The drop-in sets `timestamp_timeout` from `SUDO_TIMESTAMP_TIMEOUT` in
`/etc/yubikey-auth/config`, in **minutes** (`sudo-rs` accepts fractions like
`0.5`, but not suffixes like `30s`). The default is **5**, which deliberately
mirrors macOS with Touch ID: a quick follow-up command costs nothing, because
sudo never reaches PAM inside that window. Set it to `0` for a touch on
literally every sudo. `sudo-rs` keeps a separate record per terminal, so the
grace period cannot leak into another terminal.

For reference, macOS wires the same shape: `auth sufficient pam_tid.so` in
`/etc/pam.d/sudo_local` (a file Apple added in Sonoma precisely so the change
survives OS updates), sitting before the password module — with sudo's own
5-minute timestamp left intact.

An invalid file under `/etc/sudoers.d` locks you out of sudo completely, so
the installer validates **twice** — the drop-in alone, then the whole sudoers
tree once it is in place — and rolls back if either fails. It validates with
`visudo-rs` in preference to classic `visudo`, since the two implementations
do not accept identical syntax and `visudo-rs` is the one that matches the
binary actually parsing the file at runtime.

Note `/usr/sbin/visudo` on this host is a **dangling symlink** into
`/etc/alternatives` with no alternative registered; the working checkers are
`/usr/bin/visudo-rs` and `/usr/sbin/visudo.ws`.

Keep a second terminal with a live root shell (`sudo -i`) open the first time
you enable this, so a mistake is recoverable without a reboot.

### polkit — three separate traps

`--enable polkit` covers every polkit prompt: `pkexec`, GNOME admin actions,
printer config, and (once KeePassXC 2.8 ships) its Quick Unlock backend.

Getting there required three fixes, none of which is discoverable and each of
which fails in a way that looks like something else. Do not unpick them.

**1. Ubuntu ships no `/etc/pam.d/polkit-1`.** With the file absent, PAM falls
through to `/etc/pam.d/other`, which `@include`s `common-auth` — so polkit
silently uses the stock password stack and no amount of wiring elsewhere
changes it. The installer creates the file (mirroring Debian's stock polkit-1
stack) before wiring it.

**2. The helper runs in a systemd sandbox.** polkit 127 does not use a setuid
binary; it delegates to a socket-activated unit, `polkit-agent-helper@.service`,
hardened with:

```
PrivateDevices=yes
DevicePolicy=strict
DeviceAllow=/dev/null rw     # plus char-rtc r — and nothing else
```

`pam_u2f` opens `/dev/hidrawN` directly, so inside that sandbox the key is
invisible. Two consequences worth internalising:

- The binary hints at *"disable polkit-agent-helper.socket and use setuid
  helper"*, but Ubuntu ships `/usr/lib/polkit-1/polkit-agent-helper-1` as
  `-rwxr-xr-x`, **not setuid** — disabling the socket breaks polkit auth
  outright. Do not go down that road.
- `PrivateDevices=no` alone is a **trap**. It exposes `/dev`, but it also
  withdraws the pseudo-devices that `PrivateDevices=yes` had been quietly
  providing, and `DevicePolicy=strict` then allows only what is listed.
  `pam_u2f` reads **`/dev/urandom`** to build its challenge, so the key is
  found and authentication *still* fails at
  `set_cdh: Failed to generate challenge` — after the device is opened, before
  any touch is requested. The sensor never lights up, which reads exactly like
  a hardware fault. The drop-in therefore restores `urandom`, `random`, `zero`
  and `full` alongside `char-hidraw`.

**3. The helper's stderr is the protocol socket.** The stock unit sets
`StandardInput=socket` and `StandardOutput=socket` and leaves `StandardError`
unset, so it inherits stdout. Anything a PAM module writes to stderr is then
parsed as agent protocol — the agent logs `Unknown line ... from helper`,
authentication fails, and it retries in a tight loop. `pam_u2f`'s `debug` flag
also switches **libfido2** into debug mode, and libfido2 traces to stderr
regardless of `debug_file`, so turning on debug actively breaks polkit.

The drop-in sets `StandardError=journal`, which both protects the protocol and
makes the traces readable:

```sh
journalctl -u 'polkit-agent-helper@*' -f
```

Without that redirect the trace simply stops at the last `pam_u2f` syslog line
and everything after it is discarded as protocol garbage — which is what made
this hard to diagnose in the first place.

**Debugging note.** `U2F_DEBUG_FILE` must be `syslog`, not a path:
`ProtectSystem=strict` makes `/var/log` read-only inside the sandbox, so a file
target silently logs nothing exactly where it is most needed.

**Security note.** This is a local override of a deliberate distro hardening
decision on a root-privileged auth helper. It is narrow — `DevicePolicy=strict`
stays in force, so the helper reaches only the listed devices — but it is real.
`--disable polkit` removes it cleanly.

### KeePassXC — deferred, but there is a viable path

KeePassXC is **out of scope for now** and stays on its password. Recording the
research so it does not have to be redone:

**This YubiKey cannot unlock KeePassXC directly**, verified two ways. Its only
hardware-key mechanism is HMAC-SHA1 challenge-response
(`YubiKeyInterfaceUSB` / `YubiKeyInterfacePCSC` in the 2.7.10 binary), which
needs the **Yubico OTP application** — this key reports
`Yubico OTP: Not available` and the Bio FIDO Edition cannot have it added. The
only FIDO2 code in the binary is `BrowserWebAuthn` / `fido2Credentials`, which
is KeePassXC *storing passkeys for websites*, not unlocking its own database.
Its quick-unlock is `Touch ID / Windows Hello` — macOS and Windows only.

**But KeePassXC never needs to talk to the key.** It can ride the session
unlock that the YubiKey already authorised:
[`sumwale/keepassxc-unlock`](https://github.com/sumwale/keepassxc-unlock) is a
C, root-owned systemd service that watches `org.freedesktop.login1` for the
session `LockedHint` going false and then calls KeePassXC's D-Bus method. That
method exists in the shipped binary:

```
<interface name="org.keepassxc.KeePassXC.MainWindow">
  <method name="openDatabase">
    <arg direction="in" type="s" name="fileName"/>
    <arg direction="in" type="s" name="pw"/>
    <arg direction="in" type="s" name="keyFile"/>
```

It stores the database password under systemd's service-credential scheme
(AES256-GCM + SHA256) keyed to a local system key plus the **TPM2** — this
host has one (`/dev/tpm0`, TPM 2.0) — making the stored secret device-bound.
It verifies the `keepassxc` binary's SHA512 before calling. Its threat model
assumes root is trusted, which is not a new assumption: root can already
`gcore` the running KeePassXC and read every password out of the heap.

Two things to check before adopting it: it is a **third-party root daemon**
(build from source, not `curl | bash`), and **GNOME 50 on Wayland has not been
confirmed to flip `LockedHint`** — the premise of the whole approach. Verify
with `loginctl show-session <id> -p LockedHint` while the screen is locked.

## Operations

```sh
./yubikey-auth-status.sh                     # key, enrolment, wiring, window, recent decisions
sudo /usr/local/libexec/yubikey-auth/yubikey-auth-window status
sudo /usr/local/libexec/yubikey-auth/yubikey-auth-window clear    # force a password next time
journalctl -t yubikey-auth -f                # watch decisions live
```

Every decision the window makes is logged to `authpriv` with the
`yubikey-auth` tag, including why: `open`, `closed (no valid stamp)`, or
`expired (Xh Ym since password)`.

To change the window length, edit `WINDOW_SECONDS` in
`/etc/yubikey-auth/config` — it is read live, no reinstall needed. Changing
`ORIGIN`/`APPID`/`AUTHFILE` requires re-running the installer (they are baked
into the PAM snippet), and changing `ORIGIN` or `APPID` **invalidates every
enrolled credential**.

`ORIGIN` is a fixed `pam://zenbook` rather than `pam_u2f`'s default of
`pam://$(hostname)`, so renaming the host does not silently kill the YubiKey
path.

## The blinking LED

The Bio's amber blink is firmware-driven and there is **no software switch for
it** — the `ykman config` LED options apply to the OTP application, which this
key does not have. Enrolling fingerprints changes what it signals; it does not
give you a way to turn it off.
