#!/usr/bin/env bash
# zswap-setup.sh — enable zswap, a compressed swap cache in front of the disk
# swapfile.
#
# WHY
#
# On a machine whose committed memory exceeds RAM, reclaim runs at disk latency:
# the desktop stalls hard (PSI "full" — every task blocked on memory) and
# systemd-oomd then SIGKILLs the largest cgroup in the session, normally the
# browser. It dies with no crash report, no shutdown checkpoints and no kernel
# oom_kill counter, so it reads as an unexplained crash rather than a kill.
#
# zswap is not a device. It is a hook inside the swap path: pages on their way
# out are compressed into a dynamically-sized RAM pool, and the real swap device
# is only touched when zswap decides to evict. Because it lives in the reclaim
# path it knows which pages are cold, and its shrinker pushes the coldest entries
# out to disk *before* the pool fills. Nothing to size by hand, correct tiering,
# and incompressible pages are rejected straight to disk instead of burning CPU
# compressing data that will not shrink.
#
# One consequence worth knowing: zswap reserves a slot on the backing swap
# device for every page it pools, including pages it never writes out. The
# swapfile is therefore load-bearing rather than a mere overflow tier, and a
# small one caps the pool no matter what max_pool_percent says — which is why
# this script sizes the swapfile itself rather than assuming the distro's
# default is adequate. Ubuntu's installer picks a swapfile for a machine it
# knows nothing about; 8 GiB behind 128 GiB of RAM is not a swap tier, it is a
# rounding error.
#
# Re-running converges on exactly the state it was given. The swapfile is
# rebuilt at the target size whenever the current one differs — growing or
# shrinking, by a gigabyte or by a hundred — with no thresholds, disk-share
# caps or second-file fallbacks quietly substituting a different number. When
# the target cannot be reached, the script fails and says why rather than
# settling for something smaller and reporting success.
#
# PERSISTENCE
#
# zswap is built into the kernel (CONFIG_ZSWAP is bool, not tristate), so
# modprobe.d never applies to it. The usual advice is to put zswap.* on the
# kernel command line. That works, and it is the least portable thing this
# script could possibly do: editing the cmdline means knowing the bootloader.
# grubby is GRUB2/BLS only and explicitly does not support systemd-boot;
# kernelstub is Pop!_OS with systemd-boot; /etc/kernel/cmdline applies only to
# unified-kernel-image and kernel-install flows; /etc/default/grub.d is a
# Debian/Ubuntu patch to grub-mkconfig rather than anything upstream GRUB knows
# about. Four mechanisms, four ecosystems, no overlap. Worse, a drop-in has to
# strip pre-existing zswap.* tokens on every update-grub to stay idempotent,
# which silently deletes whatever else put zswap.* on the cmdline.
#
# So this script does not touch the bootloader at all. A systemd oneshot unit
# writes the same values through /sys/module/zswap/parameters instead. Every
# zswap parameter is writable at runtime, the sysfs path is identical on every
# distribution, and nothing has to know how this machine boots. An older version
# of this script did write a GRUB drop-in; step 6 removes it.
#
# Ordering is the part that is easy to get wrong. systemd-tmpfiles can write
# sysfs too ("w /sys/module/zswap/parameters/enabled - - - - 1"), but
# systemd-tmpfiles-setup.service is only ordered Before=sysinit.target -- and so
# are the .swap units, which leaves the two unordered with respect to each
# other. tmpfiles also cannot check its work: "w" is documented as writing "to
# a file, if the file exists", so a parameter this kernel does not have is a
# silent no-op. The unit installed here is therefore ordered Before= the actual
# .swap unit -- not merely before swap.target, which the swap units are ordered
# before as well -- and the script it runs reads every value back and fails
# loudly when the kernel did not take it.
#
# Running after the root filesystem is mounted also means it can modprobe the
# compressor itself. That removes the other half of the old design: there is no
# initramfs to keep in sync, and no way left to hit Ubuntu's LP #1977764, where
# zswap resolves zswap.compressor= before the root filesystem exists, logs
# "compressor zstd not available, using default lzo" once, and runs the fallback
# forever while every later view reports it as though it were intentional.
#
# Usage (needs root):
#   sudo ~/.sidorenko_dotfiles/bin/zswap-setup.sh [options]
#
#   --size SIZE          exact size for the swapfile ("64G", "65536M", or
#                        bytes); replaces the RAM-based heuristic, and is used
#                        as given -- the file is rebuilt to match it, up or down
#   --swapfile PATH      swapfile to manage (default /swap.img)
#   --compressor NAME    zstd (default), lz4, lzo, deflate, 842
#   --zpool NAME         pool allocator: zsmalloc (default), zbud, z3fold
#   --pool-percent N     max % of RAM the compressed pool may use (default 25)
#   --no-resize          leave swap exactly as it is
#   --no-service         do not install the systemd unit. Nothing then persists:
#                        the parameters are applied now and lost at reboot
#   -h, --help           show this text
#
# These are FLAGS and not just environment variables for a reason. sudo runs
# with "Defaults env_reset", which wipes the caller's environment, so
#     SWAP_SIZE=64G sudo zswap-setup.sh      # <- silently ignored
# assigns the variable to sudo and never reaches the script: it runs with the
# default size and says nothing. Arguments are not filtered, so
#     sudo zswap-setup.sh --size 64G
# always arrives. The env form still works when already root, or when the
# variable is set inside the command rather than around sudo:
#     sudo env SWAP_SIZE=64G zswap-setup.sh
#
# Tuning with no flag of its own, env only (so: as root, or under `sudo env`):
#   SWAPPINESS=100             vm.swappiness
#   PAGE_CLUSTER=1             vm.page-cluster (2^N pages read per swap-in)
#   SWAP_MIN_GIB=4             floor for the heuristic (--size ignores both)
#   SWAP_MAX_GIB=128           ceiling for the heuristic (the server case)

set -euo pipefail

GREEN="$(printf '\033[0;32m')"
BLUE="$(printf '\033[0;34m')"
YELLOW="$(printf '\033[0;33m')"
RED="$(printf '\033[0;31m')"
RESET="$(printf '\033[0m')"

log() { printf '%b[zswap-setup]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b[zswap-setup]%b %s\n' "$YELLOW" "$RESET" "$*"; }
die() {
  printf '%b[zswap-setup] %s%b\n' "$RED" "$*" "$RESET" >&2
  exit 1
}
name() { printf '%b%s%b' "$BLUE" "$1" "$RESET"; }

# ---------- arguments ----------

usage() { sed -n '/^# Usage (needs root):/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

opt_size="" opt_swapfile="" opt_compressor="" opt_pool_percent="" opt_zpool=""
opt_no_resize="" opt_no_service=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --size) opt_size="${2:?--size needs a value}"; shift 2 ;;
  --size=*) opt_size="${1#*=}"; shift ;;
  --swapfile) opt_swapfile="${2:?--swapfile needs a value}"; shift 2 ;;
  --swapfile=*) opt_swapfile="${1#*=}"; shift ;;
  --compressor) opt_compressor="${2:?--compressor needs a value}"; shift 2 ;;
  --compressor=*) opt_compressor="${1#*=}"; shift ;;
  --zpool) opt_zpool="${2:?--zpool needs a value}"; shift 2 ;;
  --zpool=*) opt_zpool="${1#*=}"; shift ;;
  --pool-percent) opt_pool_percent="${2:?--pool-percent needs a value}"; shift 2 ;;
  --pool-percent=*) opt_pool_percent="${1#*=}"; shift ;;
  --no-resize) opt_no_resize=1; shift ;;
  --no-service) opt_no_service=1; shift ;;
  # Removed rather than accepted-and-ignored. Both used to gate a bootloader
  # step that no longer exists, and silently accepting them would imply this
  # still writes a cmdline somewhere.
  --skip-grub | --grub | --skip-initramfs)
    die "${1} is gone: this script no longer touches the bootloader or the
     initramfs at all. zswap is configured by zswap-params.service; see
     PERSISTENCE in --help. Drop the flag." ;;
  -h | --help) usage; exit 0 ;;
  *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------- configuration ----------
#
# Flag, then environment, then default. The env layer is kept so the script
# stays scriptable from a root shell, but the flag is what survives sudo.

SWAPFILE="${opt_swapfile:-${SWAPFILE:-/swap.img}}"
FSTAB="/etc/fstab"
PARAMS_SCRIPT="/usr/local/sbin/zswap-params"
SERVICE_UNIT="/etc/systemd/system/zswap-params.service"
# Only referenced by step 6, which deletes what older versions of this script
# put there.
GRUB_DROPIN="/etc/default/grub.d/99-zswap.cfg"
SYSCTL_CONF="/etc/sysctl.d/99-swap-tuning.conf"
INITRAMFS_MODULES="/etc/initramfs-tools/modules"
PARAM_DIR="/sys/module/zswap/parameters"

ZSWAP_MAX_POOL_PERCENT="${opt_pool_percent:-${ZSWAP_MAX_POOL_PERCENT:-25}}"
ZSWAP_COMPRESSOR="${opt_compressor:-${ZSWAP_COMPRESSOR:-zstd}}"
# Whether an allocator was actually named. On kernels from 6.15 the zpool knob
# does not exist at all, and that is a hard error only for a caller who asked
# for a specific allocator -- for everyone else it is a log line.
ZPOOL_EXPLICIT=0
if [[ -n "${opt_zpool}" || -n "${ZSWAP_ZPOOL:-}" ]]; then ZPOOL_EXPLICIT=1; fi
ZSWAP_ZPOOL="${opt_zpool:-${ZSWAP_ZPOOL:-zsmalloc}}"
SWAPPINESS="${SWAPPINESS:-100}"
PAGE_CLUSTER="${PAGE_CLUSTER:-1}"

# Canonical from here on. swapon reports back whatever string it was handed, so
# an uncanonical --swapfile ("/./swap.img", a symlink) would compare unequal to
# the very device it names -- and the resize path would then read "not active"
# for a file that is very much active, and delete it out from under the kernel.
SWAPFILE="$(realpath -m -- "${SWAPFILE}")"

SWAP_SIZE="${opt_size:-${SWAP_SIZE:-}}"
SKIP_SWAP_RESIZE="${opt_no_resize:-${SKIP_SWAP_RESIZE:-}}"
SKIP_SERVICE="${opt_no_service:-${SKIP_SERVICE:-}}"
SWAP_MIN_GIB="${SWAP_MIN_GIB:-4}"
SWAP_MAX_GIB="${SWAP_MAX_GIB:-128}"

GIB=$((1024 * 1024 * 1024))

# Set when a resize drained the swapfile, which empties it. The closing note
# about pre-existing uncompressed pages is only true when that did not happen.
SWAP_DRAINED=0

# ---------- preflight ----------

[[ "${EUID}" -eq 0 ]] || die "must run as root: sudo $0"
[[ -d "${PARAM_DIR}" ]] || die "this kernel has no zswap support (${PARAM_DIR} missing)"

[[ "${ZSWAP_MAX_POOL_PERCENT}" =~ ^[0-9]+$ ]] || die "ZSWAP_MAX_POOL_PERCENT must be an integer"
((ZSWAP_MAX_POOL_PERCENT >= 1 && ZSWAP_MAX_POOL_PERCENT <= 90)) ||
  die "ZSWAP_MAX_POOL_PERCENT must be 1-90, got ${ZSWAP_MAX_POOL_PERCENT}"

for _v in SWAP_MIN_GIB SWAP_MAX_GIB; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] || die "${_v} must be an integer, got '${!_v}'"
done
unset _v
((SWAP_MIN_GIB <= SWAP_MAX_GIB)) ||
  die "SWAP_MIN_GIB (${SWAP_MIN_GIB}) must not exceed SWAP_MAX_GIB (${SWAP_MAX_GIB})"

# ---------- step 1: a backing swap device, sized for this machine ----------

# zswap is a cache in front of real swap. With no swap device it does nothing at
# all, and with a tiny one its shrinker has nowhere useful to evict to — every
# pooled page reserves a backing slot, so the swapfile is a hard ceiling on the
# pool. Sizing it is therefore part of setting zswap up, not a separate chore.

meminfo_kb() { awk -v k="${1}:" '$1 == k { print $2; exit }' /proc/meminfo; }

# Pure: no logging, because callers capture stdout.
gib() { awk -v b="${1}" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'; }

# "32G", "32GiB", "32768M", or a plain byte count.
parse_size() {
  local raw num unit
  raw="${1^^}"
  [[ "${raw}" =~ ^([0-9]+)(B|K|KIB|M|MIB|G|GIB|T|TIB)?$ ]] ||
    die "cannot parse SWAP_SIZE='${1}' (try 32G, 32768M, or a byte count)"
  num="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]:-B}"
  case "${unit}" in
  B) printf '%s' "${num}" ;;
  K | KIB) printf '%s' "$((num * 1024))" ;;
  M | MIB) printf '%s' "$((num * 1024 * 1024))" ;;
  G | GIB) printf '%s' "$((num * GIB))" ;;
  T | TIB) printf '%s' "$((num * 1024 * GIB))" ;;
  esac
}

canon() { realpath -m -- "${1}" 2>/dev/null || printf '%s' "${1}"; }

# Total across every active swap device, for the closing report only. The
# target applies to SWAPFILE alone: a swap partition someone else set up is not
# a reason to give you a smaller file than you asked for.
swap_total_bytes() {
  local total=0 size
  while read -r size; do
    [[ -n "${size}" ]] && total=$((total + size))
  done < <(swapon --noheadings --bytes --show=SIZE 2>/dev/null)
  printf '%s' "${total}"
}

# "<size> <used>" for one device, or "0 0" when it is not in the swap set.
# Both sides of the comparison are canonicalised: see the note on SWAPFILE.
swap_device_stat() {
  local want="${1}" n sz us
  while read -r n sz us; do
    if [[ "$(canon "${n}")" == "${want}" ]]; then
      # Newline matters: the caller uses read, which reports EOF without one
      # and takes set -e down with it.
      printf '%s %s\n' "${sz}" "${us}"
      return 0
    fi
  done < <(swapon --noheadings --bytes --show=NAME,SIZE,USED 2>/dev/null)
  printf '0 0\n'
}

# Is this path in the swap set right now, under any spelling?
swap_is_active() {
  local want="${1}" n
  while read -r n; do
    [[ "$(canon "${n}")" == "${want}" ]] && return 0
  done < <(swapon --noheadings --show=NAME 2>/dev/null)
  return 1
}

# Free bytes on the filesystem holding this path.
disk_avail_bytes() {
  df -B1 --output=avail "$(dirname -- "${1}")" | tail -n1 | tr -d '[:space:]'
}

hibernation_configured() {
  grep -qsE '(^|[[:space:]])resume=' /proc/cmdline && return 0
  local dev
  dev="$(cat /sys/power/resume 2>/dev/null || true)"
  [[ -n "${dev}" && "${dev}" != "0:0" ]]
}

# The default when no --size was given, and only then: an explicit size is used
# exactly as written, and SWAP_MIN_GIB/SWAP_MAX_GIB do not clamp it.
#
# Tiered rather than one ratio, because the two ends of the range want opposite
# things.
#
# A 16 GiB laptop wants swap comparable to RAM. It is the machine that actually
# runs out, the absolute numbers are small enough that generosity costs nothing,
# and RAM-sized swap is also what hibernation needs.
#
# A 1 TiB server wants a flat cap. Half a terabyte of swapfile would never be
# more than a rounding error of pressure relief on a host that size, while
# consuming disk that is worth more for almost anything else. What matters
# there is that swap exists and is deep enough to back the zswap pool and
# absorb a burst — not that it keeps tracking RAM upward forever.
#
# Everything between is half of RAM, with a floor so the halving cannot produce
# a uselessly small file. The cap is where the ratio stops applying, so it and
# the top of the proportional band meet at 256 GiB rather than stepping.
heuristic_swap_bytes() {
  local ram_gib="${1}" want
  if ((ram_gib <= 2)); then
    want=$((ram_gib * 2))
  elif ((ram_gib <= 8)); then
    want=$(((ram_gib * 3) / 2))
  elif ((ram_gib <= 16)); then
    # Floored at what the tier below yields at its own top (8 * 1.5), so more
    # RAM never means less swap across the seam.
    want=$((ram_gib))
    if ((want < 12)); then want=12; fi
  elif ((ram_gib <= 256)); then
    want=$((ram_gib / 2))
    if ((want < 16)); then want=16; fi
  else
    want=$((SWAP_MAX_GIB))
  fi
  if ((want < SWAP_MIN_GIB)); then want=$((SWAP_MIN_GIB)); fi
  if ((want > SWAP_MAX_GIB)); then want=$((SWAP_MAX_GIB)); fi
  printf '%s' "$((want * GIB))"
}

# Filesystem-aware, because "make a big file" is not portable for swap:
#   ext4   fallocate produces real extents; swapon is happy.
#   xfs    fallocate produces UNWRITTEN extents and swapon refuses them, so the
#          file has to be written out for real.
#   btrfs  needs nodatacow and no compression, and the file must not be
#          reflinked; btrfs-progs does allocate+mkswap in one command and gets
#          those details right, so use it rather than reimplementing them.
#   zfs    a swapfile on ZFS can deadlock the machine — the write path needs to
#          allocate memory in order to free memory. Refuse instead of building
#          a hang that only appears under the pressure it exists to relieve.
# allocate_swapfile() starts by deleting the target, so it is worth being sure
# the target is what we think it is. A typo in --swapfile otherwise means a
# silent rm of whatever that path happens to name.
assert_safe_to_replace() {
  local path="${1}" type
  [[ -L "${path}" ]] &&
    die "${path} is a symlink. Point --swapfile at the real file; refusing to
     follow it and delete something else."
  [[ -e "${path}" && ! -f "${path}" ]] &&
    die "${path} exists and is not a regular file. Refusing to delete it."

  # Belt and braces on the resize path: by the time we get here the file must
  # already be swapped off. If it is not, the canonicalisation above missed a
  # spelling and deleting it now would pull an in-use swapfile out from under
  # the kernel.
  if swap_is_active "${path}"; then
    die "${path} is still an active swap device. Refusing to delete it.
     Run: swapoff ${path}"
  fi

  # Non-empty and not swap-formatted means this path is somebody else's file.
  if [[ -s "${path}" ]]; then
    type="$(blkid -p -s TYPE -o value -- "${path}" 2>/dev/null || true)"
    [[ "${type}" == "swap" ]] ||
      die "${path} already exists, is not empty, and is not a swapfile
     (blkid reports '${type:-unrecognised content}'). Refusing to delete it.
     Remove it by hand if that is really what you want."
  fi
}

allocate_swapfile() {
  local path="${1}" bytes="${2}" fstype
  fstype="$(findmnt -no FSTYPE --target "$(dirname -- "${path}")")"

  assert_safe_to_replace "${path}"
  rm -f -- "${path}"

  case "${fstype}" in
  zfs)
    die "${path} would live on ZFS, where a swapfile can deadlock the host under
     memory pressure. Use a dedicated zvol or a swap partition instead."
    ;;
  btrfs)
    command -v btrfs >/dev/null 2>&1 ||
      die "btrfs-progs is required to create a swapfile on btrfs"
    log "Allocating $(gib "${bytes}") on btrfs (nodatacow, uncompressed)..."
    btrfs filesystem mkswapfile --size "${bytes}" -- "${path}" >/dev/null ||
      die "btrfs filesystem mkswapfile failed (needs btrfs-progs 6.1+ and a
     subvolume that is not snapshotted)"
    chmod 600 -- "${path}"
    # mkswapfile already formatted it; running mkswap again would be wrong.
    return 0
    ;;
  xfs)
    log "Allocating $(gib "${bytes}") on xfs by writing it out (fallocate leaves"
    log "unwritten extents, which swapon rejects)..."
    dd if=/dev/zero of="${path}" bs=1M count="$((bytes / 1024 / 1024))" status=none ||
      die "could not write ${path}"
    ;;
  *)
    log "Allocating $(gib "${bytes}") on ${fstype}..."
    if ! fallocate -l "${bytes}" -- "${path}" 2>/dev/null; then
      warn "fallocate failed on ${fstype}; writing the file out instead."
      dd if=/dev/zero of="${path}" bs=1M count="$((bytes / 1024 / 1024))" status=none ||
        die "could not write ${path}"
    fi
    ;;
  esac

  chmod 600 -- "${path}"
  mkswap -- "${path}" >/dev/null || die "mkswap ${path} failed"
}

ensure_fstab_entry() {
  local path="${1}"
  if awk -v p="${path}" '$1 == p && $3 == "swap" { found = 1 } END { exit !found }' "${FSTAB}"; then
    return 0
  fi
  log "Adding $(name "${path}") to $(name "${FSTAB}") so it survives a reboot..."
  cp -a -- "${FSTAB}" "${FSTAB}.bak"
  printf '%s\tnone\tswap\tsw\t0\t0\n' "${path}" >>"${FSTAB}"
}

# Recreating the swapfile moves it on disk. A hibernating machine points at the
# OLD physical block through resume_offset=, and a stale value does not fail
# loudly — it resumes from garbage or silently cold-boots.
warn_stale_resume_offset() {
  grep -qs 'resume_offset=' /proc/cmdline || return 0
  warn "The kernel cmdline pins resume_offset=, which points at the swapfile's"
  warn "OLD physical location. The file has moved; recompute and update it:"
  warn "  filefrag -v ${SWAPFILE} | awk '\$1 == \"0:\" { gsub(/\\.\\./, \"\", \$4); print \$4 }'"
}

# Between swapoff and a successful swapon the machine has no swap on this file
# at all — which, on the very host that was swapping hard enough to need a
# bigger file, is the worst moment for the script to give up and exit. Anything
# that leaves that window unfinished (a full disk, mkswap failing, swapon
# refusing the new file) lands here first and puts a working swapfile back at
# the size it had before. Best-effort by construction: the old contents are
# gone either way, so the goal is a machine with swap, not the machine it was.
SWAP_CRITICAL=0
SWAP_PREV_SIZE=0

restore_swapfile_on_failure() {
  local rc=$?
  ((SWAP_CRITICAL)) || return 0
  SWAP_CRITICAL=0 # never let the restore path re-enter itself

  warn "Failed while rebuilding $(name "${SWAPFILE}") (exit ${rc}); ${SWAPFILE} is"
  warn "currently NOT providing swap. Putting one back at its previous size..."
  # set -e is still in force inside a trap handler, so nothing here may fail
  # hard: the whole point is to reach the message at the bottom.
  rm -f -- "${SWAPFILE}" || true
  # allocate_swapfile dies on failure and die() exits; the subshell contains
  # that so this handler survives to say so out loud.
  if (allocate_swapfile "${SWAPFILE}" "${SWAP_PREV_SIZE}") && swapon -- "${SWAPFILE}"; then
    warn "Restored $(name "${SWAPFILE}") at $(gib "${SWAP_PREV_SIZE}"); swap is active again."
  else
    warn "COULD NOT restore ${SWAPFILE}. This machine has no swap on it right now."
    warn "Fix by hand: fallocate -l ${SWAP_PREV_SIZE} ${SWAPFILE} &&"
    warn "  chmod 600 ${SWAPFILE} && mkswap ${SWAPFILE} && swapon ${SWAPFILE}"
  fi
}
trap restore_swapfile_on_failure EXIT

ensure_backing_swap() {
  if [[ -n "${SKIP_SWAP_RESIZE:-}" ]]; then
    warn "Resizing disabled (--no-resize); leaving swap as it is."
    return 0
  fi

  local ram_b ram_gib target sf_size sf_used on_disk avail avail_ram

  ram_b=$(($(meminfo_kb MemTotal) * 1024))
  ram_gib=$((ram_b / GIB))

  if [[ -n "${SWAP_SIZE}" ]]; then
    target="$(parse_size "${SWAP_SIZE}")"
    log "Swap target: $(name "$(gib "${target}")") (explicit override)."
  else
    target="$(heuristic_swap_bytes "${ram_gib}")"
    log "Swap target: $(name "$(gib "${target}")") for $(gib "${ram_b}") of RAM."
  fi

  # mkswap works in whole pages and dd counts in MiB, so align the request down
  # to a MiB. This is the only adjustment made to a size that was asked for.
  target=$((target / 1024 / 1024 * 1024 * 1024))
  ((target >= 1024 * 1024)) || die "swap target rounds down to nothing; ask for at least 1M"

  # Said once, as information. A hibernation image needs swap >= RAM, but the
  # target is what was asked for, not what this would have preferred.
  if hibernation_configured && ((target < ram_b)); then
    warn "Hibernation is configured and the target $(gib "${target}") is below RAM"
    warn "($(gib "${ram_b}")), so a hibernation image will not fit. Using it anyway."
  fi

  read -r sf_size sf_used < <(swap_device_stat "${SWAPFILE}")

  on_disk=0
  if [[ -f "${SWAPFILE}" ]]; then on_disk="$(stat -c %s -- "${SWAPFILE}")"; fi

  # Compare the file, not what swapon reports: mkswap spends the first page on a
  # header, so an active swapfile always measures one page smaller than itself.
  if ((on_disk == target && sf_size > 0)); then
    log "$(name "${SWAPFILE}") is already $(name "$(gib "${target}")") and active."
    ensure_fstab_entry "${SWAPFILE}"
    return 0
  fi

  # The file is replaced rather than added to, so the space it holds now is
  # available to the new one. Running out of disk is a hard failure: a caller
  # who named a size is entitled to hear that it did not happen, rather than
  # get a smaller file and a success message.
  avail="$(disk_avail_bytes "${SWAPFILE}")"
  if ((target > avail + on_disk)); then
    die "not enough room on $(dirname -- "${SWAPFILE}") for $(gib "${target}"): $(gib "${avail}") free,
     plus $(gib "${on_disk}") reclaimable from the current file. Free space or ask
     for a size that fits."
  fi

  if ((sf_size == 0)); then
    # Not in the swap set: nothing to drain, nothing to lose. Covers a fresh
    # host with no swap at all, and a file that exists but was never enabled.
    log "Creating $(name "${SWAPFILE}") at $(name "$(gib "${target}")")..."
  else
    log "Rebuilding $(name "${SWAPFILE}"): $(gib "${sf_size}") -> $(name "$(gib "${target}")")."

    # A swapfile cannot be resized in place while it is in use, and swapoff
    # pulls every page it holds back into RAM. Warn when that looks tight —
    # then do it, because it is what was asked for.
    avail_ram=$(($(meminfo_kb MemAvailable) * 1024))
    if ((sf_used > avail_ram)); then
      warn "It holds $(gib "${sf_used}") and only $(gib "${avail_ram}") of RAM is available to"
      warn "take those pages back; the swapoff below may trigger an OOM kill."
    fi
    log "Draining $(gib "${sf_used}") back into RAM ($(gib "${avail_ram}") available)..."
    swapoff -- "${SWAPFILE}" ||
      die "swapoff ${SWAPFILE} failed; swap is unchanged and still active"

    # From here until swapon returns, this file provides no swap.
    SWAP_PREV_SIZE="${on_disk}"
    SWAP_CRITICAL=1
    SWAP_DRAINED=1
  fi

  allocate_swapfile "${SWAPFILE}" "${target}"
  swapon -- "${SWAPFILE}" || die "swapon ${SWAPFILE} failed"
  SWAP_CRITICAL=0

  ensure_fstab_entry "${SWAPFILE}"
  warn_stale_resume_offset

  log "Active swap is now $(name "$(gib "$(swap_total_bytes)")")."
}

# ---------- step 2: the script that actually sets the parameters ------------

# Generated rather than sourced from the repo: the unit that runs it starts with
# DefaultDependencies=no, before anything but the root filesystem is mounted, so
# a path under /home would simply not be there. Everything it needs is baked in.
write_params_script() {
  local desired
  desired="$(
    cat <<EOF
#!/bin/sh
# Managed by sidorenko_dotfiles bin/zswap-setup.sh — edits will be overwritten.
#
# Applies the zswap parameters through sysfs. Run by zswap-params.service before
# any swap device is activated, and by zswap-setup.sh itself when it runs.
#
# Self-contained on purpose: this executes before /home (or any other non-root
# filesystem) is mounted, so it cannot call the script that generated it.
# Re-run zswap-setup.sh to change any of the values below.
set -eu

COMPRESSOR='${ZSWAP_COMPRESSOR}'
ZPOOL='${ZSWAP_ZPOOL}'
ZPOOL_EXPLICIT=${ZPOOL_EXPLICIT}
MAX_POOL_PERCENT='${ZSWAP_MAX_POOL_PERCENT}'
P=/sys/module/zswap/parameters

say() { echo "zswap-params: \$*"; }
fail() {
  echo "zswap-params: \$*" >&2
  exit 1
}

[ -d "\$P" ] || {
  say "this kernel has no zswap support (\$P missing); nothing to do"
  exit 0
}

# zswap only accepts a compressor already registered with the crypto API, and
# the kernel's own default is lzo. Loading it here, from the mounted root
# filesystem, is what makes initramfs surgery unnecessary: this runs before the
# first page can be swapped, so there is nothing to be too late for.
if ! awk -v c="\$COMPRESSOR" '\$1 == "name" && \$3 == c { f = 1 } END { exit !f }' /proc/crypto; then
  modprobe "\$COMPRESSOR" 2>/dev/null || true
fi

# Sizing and algorithm before enabling, so the first pool created is the one
# that was asked for rather than one that gets corrected afterwards.
printf '%s' "\$MAX_POOL_PERCENT" >"\$P/max_pool_percent"

# Every write is read back. A write that "succeeds" proves nothing: when the
# algorithm is unavailable the kernel keeps its own value, and free(1),
# swapon(8) and sysfs then all report that value as though it had been chosen.
{ printf '%s' "\$COMPRESSOR" >"\$P/compressor"; } 2>/dev/null || true
live="\$(cat "\$P/compressor")"
[ "\$live" = "\$COMPRESSOR" ] ||
  fail "COMPRESSOR MISMATCH: asked for '\$COMPRESSOR', kernel is using '\$live'. That algorithm is not registered with the crypto API, so the kernel kept its own. zswap has NOT been enabled."
say "compressor verified as \$COMPRESSOR"

if [ -e "\$P/zpool" ]; then
  { printf '%s' "\$ZPOOL" >"\$P/zpool"; } 2>/dev/null || true
  live="\$(cat "\$P/zpool")"
  [ "\$live" = "\$ZPOOL" ] ||
    fail "ZPOOL MISMATCH: asked for '\$ZPOOL', kernel is using '\$live'. Not cosmetic: zbud caps the pool near 2:1 however well the compressor does, so most of the compression would be thrown away. zswap has NOT been enabled."
  say "allocator verified as \$ZPOOL"
elif [ "\$ZPOOL_EXPLICIT" = 1 ]; then
  fail "'\$ZPOOL' was asked for, but this kernel has no \$P/zpool. Since 6.15 zbud and z3fold are gone and zsmalloc is the only allocator, so the knob itself no longer exists. Drop --zpool."
else
  say "no zpool parameter on this kernel (zsmalloc is the only allocator); not setting it"
fi

printf '1' >"\$P/enabled"
state="\$(cat "\$P/enabled")"
case "\$state" in
Y | 1) ;;
*) fail "zswap did not come up (enabled=\$state)" ;;
esac

say "enabled, max_pool_percent=\$MAX_POOL_PERCENT"
EOF
  )"

  if [[ -f "${PARAMS_SCRIPT}" ]] && [[ "$(cat "${PARAMS_SCRIPT}")" == "${desired}" ]]; then
    log "$(name "${PARAMS_SCRIPT}") already correct."
  else
    [[ -f "${PARAMS_SCRIPT}" ]] && cp -a "${PARAMS_SCRIPT}" "${PARAMS_SCRIPT}.bak"
    log "Writing $(name "${PARAMS_SCRIPT}")..."
    printf '%s\n' "${desired}" >"${PARAMS_SCRIPT}"
    chmod 755 -- "${PARAMS_SCRIPT}"
  fi

  # Generated code is still code. A syntax error here would otherwise surface as
  # a failed unit on the next boot, with swap already running uncompressed.
  sh -n "${PARAMS_SCRIPT}" || die "generated ${PARAMS_SCRIPT} is not valid sh"
}

# ---------- step 3: apply now, and prove the kernel accepted it -------------

# Deliberately ahead of anything that writes persistent configuration. The sysfs
# read-backs inside the script are the only authoritative test of whether this
# kernel can actually do the requested compressor and allocator, and there is no
# sense pinning a combination to the bootloader before it is known to work.
apply_runtime() {
  log "Applying zswap parameters now via $(name "${PARAMS_SCRIPT}")..."
  "${PARAMS_SCRIPT}" 2>&1 | sed 's/^/    /' ||
    die "${PARAMS_SCRIPT} failed (see above); nothing persistent has been written"

  if [[ -r "${PARAM_DIR}/shrinker_enabled" ]]; then
    log "Shrinker: $(name "$(cat "${PARAM_DIR}/shrinker_enabled")") (this is what evicts cold pool entries to disk)."
  fi
}

# ---------- step 4: persist, without involving the bootloader ---------------

# See PERSISTENCE at the top for why this is a unit and not a kernel cmdline or
# a tmpfiles.d snippet.
setup_service() {
  if [[ -n "${SKIP_SERVICE:-}" ]]; then
    warn "--no-service: not installing $(name "${SERVICE_UNIT}")."
    warn "Nothing persists: zswap will be OFF again after the next reboot."
    return 0
  fi

  command -v systemctl >/dev/null 2>&1 ||
    die "systemctl not found, so the unit cannot be installed and nothing would
     survive a reboot. On a machine without systemd, set the parameters from
     whatever this host runs at boot -- the values are in ${PARAMS_SCRIPT} once
     --no-service has written it."

  local swap_unit desired
  swap_unit="$(systemd-escape --path --suffix=swap -- "${SWAPFILE}")"

  desired="$(
    cat <<EOF
# Managed by sidorenko_dotfiles bin/zswap-setup.sh — edits will be overwritten.
[Unit]
Description=Configure zswap (compressed swap cache)
Documentation=https://docs.kernel.org/admin-guide/mm/zswap.html
ConditionPathIsDirectory=${PARAM_DIR}

# DefaultDependencies=no is what allows this to run early enough; the shutdown
# ordering it switches off is put back by hand on the next two lines, as
# convention requires.
DefaultDependencies=no
Conflicts=shutdown.target
Before=shutdown.target

# Before= names the swap unit itself, not just swap.target. The .swap units are
# ordered Before=swap.target as well, so ordering against the target alone would
# leave this racing them -- and losing the race means pages reach the swapfile
# uncompressed. After= is for the compressor module, which the script may load.
After=systemd-modules-load.service
Before=swap.target ${swap_unit}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PARAMS_SCRIPT}

[Install]
WantedBy=sysinit.target
EOF
  )"

  if [[ -f "${SERVICE_UNIT}" ]] && [[ "$(cat "${SERVICE_UNIT}")" == "${desired}" ]]; then
    log "$(name "${SERVICE_UNIT}") already correct."
  else
    [[ -f "${SERVICE_UNIT}" ]] && cp -a "${SERVICE_UNIT}" "${SERVICE_UNIT}.bak"
    log "Writing $(name "${SERVICE_UNIT}") (ordered before $(name "${swap_unit}"))..."
    printf '%s\n' "${desired}" >"${SERVICE_UNIT}"
    systemctl daemon-reload
  fi

  systemctl enable zswap-params.service >/dev/null 2>&1 ||
    die "systemctl enable zswap-params.service failed"

  # Start it too, so the unit itself is exercised now rather than first
  # discovered to be broken at the next boot.
  if ! systemctl restart zswap-params.service; then
    journalctl -u zswap-params.service -n 20 --no-pager 2>&1 | sed 's/^/    /' || true
    die "zswap-params.service failed to start (journal above)"
  fi
  log "$(name zswap-params.service) enabled and active."
}

# ---------- step 5: reclaim tuning ----------

# The right swappiness depends on how expensive swap is relative to dropping
# page cache. Disk-only swap justifies the stock 60. zswap is cheaper than that:
# the first tier is compressed RAM, but once the pool fills, eviction goes to
# NVMe. 100 treats swapping and file reclaim as equally costly, which is the
# honest description of a hybrid tier.
setup_sysctl() {
  local desired
  desired="$(
    cat <<EOF
# Managed by sidorenko_dotfiles bin/zswap-setup.sh — edits will be overwritten.
# zswap compresses into RAM first but evicts to disk under pressure, so swapping
# is cheaper than plain disk swap. 100 weighs swapping and page-cache reclaim
# equally.
vm.swappiness = ${SWAPPINESS}
# Readahead on swap-in: 2^N pages. A pure RAM tier wants 0 and a disk wants 3;
# zswap spans both, so pull a small batch.
vm.page-cluster = ${PAGE_CLUSTER}
EOF
  )"

  if [[ -f "${SYSCTL_CONF}" ]] && [[ "$(cat "${SYSCTL_CONF}")" == "${desired}" ]]; then
    log "$(name "${SYSCTL_CONF}") already correct."
  else
    log "Writing $(name "${SYSCTL_CONF}") (swappiness=${SWAPPINESS}, page-cluster=${PAGE_CLUSTER})..."
    printf '%s\n' "${desired}" >"${SYSCTL_CONF}"
  fi
  sysctl -q --load="${SYSCTL_CONF}"
}

# ---------- step 6: undo the bootloader configuration older versions wrote --

# This script used to pin zswap.* on the kernel command line and add the
# compressor to the initramfs. Deleting that code does not delete what it left
# on disk, and the drop-in is not inert: it re-runs on every update-grub,
# stripping every zswap.* token out of GRUB_CMDLINE_LINUX_DEFAULT before adding
# its own back, so it keeps quietly deleting anything else that sets them -- and
# it pins values that zswap-params.service is now the source of truth for.
#
# Only ever removes what carries this script's own marker. An unmarked file at
# the same path belongs to somebody else and is left alone, loudly. Once there
# is nothing left to clean, this says nothing at all.
remove_legacy_bootloader_config() {
  local did_grub=0 did_initramfs=0

  if [[ -f "${GRUB_DROPIN}" ]]; then
    if grep -qF 'Managed by sidorenko_dotfiles bin/zswap-setup.sh' "${GRUB_DROPIN}"; then
      log "Removing $(name "${GRUB_DROPIN}") (written by an older version of this script)."
      cp -a -- "${GRUB_DROPIN}" "${GRUB_DROPIN}.bak"
      rm -f -- "${GRUB_DROPIN}"
      did_grub=1
    else
      warn "$(name "${GRUB_DROPIN}") exists but carries no marker from this script,"
      warn "so it is somebody else's file and is being left alone. It may still be"
      warn "putting zswap.* on the kernel command line."
    fi
  fi

  if [[ -f "${INITRAMFS_MODULES}" ]] &&
    grep -qF 'Added by sidorenko_dotfiles bin/zswap-setup.sh' "${INITRAMFS_MODULES}"; then
    log "Removing this script's block from $(name "${INITRAMFS_MODULES}")."
    cp -a -- "${INITRAMFS_MODULES}" "${INITRAMFS_MODULES}.bak"
    # The block is the marker comment, its continuation lines, and the single
    # bare module name that follows them. Nothing else is touched.
    awk '
      /^# Added by sidorenko_dotfiles bin\/zswap-setup\.sh/ { skip = 1; next }
      skip && /^#/ { next }
      skip { skip = 0; next }
      { print }
    ' "${INITRAMFS_MODULES}.bak" >"${INITRAMFS_MODULES}"
    did_initramfs=1
  fi

  ((did_grub || did_initramfs)) || return 0

  if ((did_grub)) && command -v update-grub >/dev/null 2>&1; then
    log "Regenerating the bootloader config..."
    update-grub 2>&1 | sed 's/^/    /' ||
      warn "update-grub failed. ${GRUB_DROPIN} is gone but the generated grub.cfg
     still carries the old cmdline; run update-grub by hand."
  fi

  if ((did_initramfs)) && command -v update-initramfs >/dev/null 2>&1; then
    log "Regenerating the initramfs (takes a moment)..."
    update-initramfs -u 2>&1 | sed 's/^/    /' ||
      warn "update-initramfs failed; run 'update-initramfs -u' by hand."
  fi

  warn "The running kernel keeps whatever zswap.* it booted with until you reboot."
  warn "$(name zswap-params.service) is the source of truth from here on."
}

# ---------- run ----------

ensure_backing_swap
write_params_script
apply_runtime
setup_service
setup_sysctl
remove_legacy_bootloader_config

echo
log "zswap parameters now:"
for p in "${PARAM_DIR}"/*; do
  printf '    %-28s %s\n' "$(basename "${p}")" "$(cat "${p}" 2>/dev/null)"
done

echo
log "Swap devices (zswap is invisible here by design — it is a cache, not a device):"
swapon --show
echo
log "Memory:"
free -h

if [[ -d /sys/kernel/debug/zswap ]]; then
  echo
  log "zswap stats:"
  for s in /sys/kernel/debug/zswap/*; do
    printf '    %-28s %s\n' "$(basename "${s}")" "$(cat "${s}" 2>/dev/null)"
  done

  # Compression ratio: uncompressed bytes held / actual RAM the pool occupies.
  stored="$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)"
  pool="$(cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 0)"
  if ((stored > 0 && pool > 0)); then
    log "Compression ratio right now: $(name "$(awk -v s="${stored}" -v p="${pool}" 'BEGIN { printf "%.2fx", (s * 4096) / p }')")"
  else
    log "Pool is still empty — the ratio only means something once pages have been swapped out."
  fi
fi

echo
if ((SWAP_DRAINED)); then
  log "The swapfile was rebuilt, so swap started empty: every page in it from here"
  log "on has gone through zswap."
else
  warn "Pages already sitting in ${SWAPFILE} stay uncompressed; only pages swapped"
  warn "out from now on go through zswap."
fi
log "Re-check the ratio later from stored_pages vs pool_total_size under /sys/kernel/debug/zswap."
log "Watch for stalls with $(name /proc/pressure/memory) — 'full avg60' should stay near 0."
