#!/usr/bin/env bash
# Boot a CLEAN Ubuntu VM, run install.sh in it, and measure the result.
#
# WHY. install.sh is 1000 lines of idempotent-by-assertion shell that nothing
# ever executed end to end. Reading it proves nothing: the only honest test is
# a vanilla image that has never seen these dotfiles, the installer run
# unattended, and then manifests/verify-applied.sh measuring what is actually
# true of that machine afterwards.
#
# The NixOS side is tested by a nixosTest in the it_infra repo, and runs the
# SAME manifests/verify-applied.sh, so the two platforms are judged on
# identical measurements rather than two checklists that drift apart.
#
# HOW IT RUNS. QEMU + KVM, an Ubuntu cloud image, and cloud-init for the
# unattended part. Everything is user-mode: no sudo on the host, no bridge, no
# libvirt. /dev/kvm needs to be readable, which it is on this box.
#
# The repo reaches the guest through a 9p mount rather than being baked into
# the image, so the VM always tests the WORKING TREE as it is right now —
# including uncommitted edits, which is exactly what you want while iterating.
# It is mounted read-only and copied inside the guest, so a test run can never
# write to your checkout.
#
# Usage:
#   ./tests/ubuntu-vm.sh                 # fast: placement + config, no packages
#   ./tests/ubuntu-vm.sh --packages      # also install the ~66 Nix packages (slow)
#   ./tests/ubuntu-vm.sh --keep          # leave the VM disk for inspection
#   ./tests/ubuntu-vm.sh --shell         # drop to a shell in the guest at the end
#   ./tests/ubuntu-vm.sh --release jammy # a different Ubuntu
#
# Exit code is the verifier's: 0 only if every check passed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sidorenko-dotfiles-vmtest"
RELEASE="noble"
MEM=4096
CPUS=4
DISK_SIZE="20G"
WITH_PACKAGES=0
KEEP=0
DROP_SHELL=0
TIMEOUT=1800
SSH_PORT=0          # 0 = pick a free one

log()  { printf '\033[36m[ubuntu-vm]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[ubuntu-vm]\033[0m WARNING: %s\n' "$*" >&2; }
die()  { printf '\033[31m[ubuntu-vm]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --packages)  WITH_PACKAGES=1 ;;
    --keep)      KEEP=1 ;;
    --shell)     DROP_SHELL=1; KEEP=1 ;;
    --release)   RELEASE="$2"; shift ;;
    --mem)       MEM="$2"; shift ;;
    --cpus)      CPUS="$2"; shift ;;
    --timeout)   TIMEOUT="$2"; shift ;;
    -h|--help)   usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Preconditions, checked up front with actionable messages
# ---------------------------------------------------------------------------
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not read-write for this user.
  Virtualization must be enabled in firmware and the kvm module loaded.
  Check:  grep -oE 'svm|vmx' /proc/cpuinfo | sort -u ; ls -l /dev/kvm"

need() { command -v "$1" >/dev/null 2>&1 || MISSING+=("$2"); }
MISSING=()
need qemu-system-x86_64 qemu
need qemu-img qemu
need cloud-localds cloud-utils
need ssh openssh
need ssh-keygen openssh
need curl curl
if (( ${#MISSING[@]} )); then
  # De-duplicated: qemu provides two of the probes, and listing it twice reads
  # like two separate problems.
  mapfile -t MISSING < <(printf '%s\n' "${MISSING[@]}" | sort -u)
  # Everything needed is in nixpkgs, so say the one command that provides it
  # rather than leaving the reader to work it out.
  die "missing tools: ${MISSING[*]}
  Run this script inside:
    nix shell nixpkgs#qemu nixpkgs#cloud-utils nixpkgs#openssh nixpkgs#curl --command ${BASH_SOURCE[0]} $*"
fi

mkdir -p "$CACHE_DIR"
WORK="$(mktemp -d "${CACHE_DIR}/run-XXXXXX")"
cleanup() {
  local rc=$?
  if [[ -n ${QEMU_PID:-} ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    log "shutting the VM down"
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if (( KEEP )); then
    log "kept: $WORK"
  else
    rm -rf "$WORK"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Base image, cached between runs
# ---------------------------------------------------------------------------
BASE="${CACHE_DIR}/${RELEASE}-server-cloudimg-amd64.img"
if [[ ! -f $BASE ]]; then
  URL="https://cloud-images.ubuntu.com/${RELEASE}/current/${RELEASE}-server-cloudimg-amd64.img"
  log "fetching ${RELEASE} cloud image (once; cached in ${CACHE_DIR})"
  curl -fL --progress-bar -o "${BASE}.part" "$URL" || die "could not fetch $URL"
  mv "${BASE}.part" "$BASE"
fi
log "base image: $BASE"

# A qcow2 overlay, so the pristine base is never written to and each run starts
# from an identical machine.
DISK="${WORK}/root.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DISK" "$DISK_SIZE"

# ---------------------------------------------------------------------------
# cloud-init: a user, our key, and the packages the installer itself needs
# ---------------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/id" -C vmtest
PUBKEY="$(cat "${WORK}/id.pub")"

# git/curl/xz are install.sh's own prerequisites on a bare image. zsh is here
# because the installer offers to make it the login shell and the verifier
# checks that zsh loads shrc too. 9p modules mount the repo.
cat >"${WORK}/user-data" <<EOF
#cloud-config
hostname: dotfiles-test
users:
  - name: tester
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: false
    ssh_authorized_keys:
      - ${PUBKEY}
package_update: true
packages: [git, curl, xz-utils, zsh, ca-certificates]
write_files:
  - path: /etc/modules-load.d/9p.conf
    content: |
      9p
      9pnet
      9pnet_virtio
runcmd:
  - [modprobe, 9p]
  - [modprobe, 9pnet_virtio]
  - [mkdir, -p, /mnt/dotfiles-src]
  - [mount, -t, 9p, -o, "trans=virtio,version=9p2000.L,ro", dotfiles, /mnt/dotfiles-src]
  - [touch, /run/cloud-init-done]
EOF
printf 'instance-id: dotfiles-test\nlocal-hostname: dotfiles-test\n' >"${WORK}/meta-data"
cloud-localds "${WORK}/seed.iso" "${WORK}/user-data" "${WORK}/meta-data"

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------
if (( SSH_PORT == 0 )); then
  # Ask the kernel for a free port rather than guessing one and racing.
  SSH_PORT="$(
    ss -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -n |
    awk 'BEGIN{p=2222} {if ($1==p) p++} END{print p}'
  )"
fi
log "booting ${RELEASE} (mem=${MEM}M cpus=${CPUS}, ssh on localhost:${SSH_PORT})"

qemu-system-x86_64 \
  -name dotfiles-ubuntu-test \
  -machine accel=kvm,type=q35 -cpu host -smp "$CPUS" -m "$MEM" \
  -nographic -serial "file:${WORK}/console.log" -monitor none \
  -drive "if=virtio,format=qcow2,file=${DISK}" \
  -drive "if=virtio,format=raw,file=${WORK}/seed.iso,readonly=on" \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
  -device virtio-net-pci,netdev=net0 \
  -virtfs "local,path=${REPO_DIR},mount_tag=dotfiles,security_model=none,readonly=on" \
  -device virtio-rng-pci \
  &
QEMU_PID=$!

SSH_OPTS=(-i "${WORK}/id" -p "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5)
in_vm() { ssh "${SSH_OPTS[@]}" tester@127.0.0.1 "$@"; }

log "waiting for ssh"
deadline=$(( SECONDS + 300 ))
until in_vm true 2>/dev/null; do
  kill -0 "$QEMU_PID" 2>/dev/null || die "qemu exited early; see ${WORK}/console.log"
  (( SECONDS < deadline )) || die "VM did not come up within 300s; see ${WORK}/console.log"
  sleep 3
done
log "ssh is up"

log "waiting for cloud-init to finish (it installs git/zsh and mounts the repo)"
in_vm 'cloud-init status --wait >/dev/null 2>&1 || true'
in_vm 'test -e /run/cloud-init-done' || warn "cloud-init runcmd marker missing; continuing"
in_vm 'test -d /mnt/dotfiles-src/manifests' ||
  die "the repo did not mount in the guest (9p). See ${WORK}/console.log"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
# Copied out of the read-only 9p mount: install.sh pins the repo's git identity
# and the git hooks, so it needs a writable checkout — and a test must never be
# able to write to the host's working tree.
log "copying the repo into the guest"
in_vm 'rm -rf ~/.sidorenko_dotfiles && cp -a /mnt/dotfiles-src ~/.sidorenko_dotfiles && git -C ~/.sidorenko_dotfiles status --short >/dev/null 2>&1 || true'

INSTALL_FLAGS="--yes --no-apt"
(( WITH_PACKAGES )) && INSTALL_FLAGS="$INSTALL_FLAGS --packages" || INSTALL_FLAGS="$INSTALL_FLAGS --no-nix --no-packages"

log "running install.sh ${INSTALL_FLAGS}"
set +e
in_vm "cd ~/.sidorenko_dotfiles && timeout ${TIMEOUT} ./install.sh ${INSTALL_FLAGS} 2>&1" \
  | tee "${WORK}/install.log"
INSTALL_RC=${PIPESTATUS[0]}
set -e
log "install.sh exited ${INSTALL_RC} (log: ${WORK}/install.log)"
(( INSTALL_RC == 0 )) || warn "install.sh failed; the verifier below will show what is missing"

# ---------------------------------------------------------------------------
# Measure
# ---------------------------------------------------------------------------
# --no-gui: a cloud image is headless, so gui-tagged rows are out of scope and
# the verifier reports them as SKIP rather than pretending to check them.
VERIFY_FLAGS="--no-gui --no-nixos --platform linux"
(( WITH_PACKAGES )) || VERIFY_FLAGS="$VERIFY_FLAGS --skip packages"

log "running verify-applied.sh ${VERIFY_FLAGS}"
set +e
in_vm "cd ~/.sidorenko_dotfiles && ./manifests/verify-applied.sh ${VERIFY_FLAGS} 2>&1" \
  | tee "${WORK}/verify.log"
VERIFY_RC=${PIPESTATUS[0]}
in_vm "cd ~/.sidorenko_dotfiles && ./manifests/verify-applied.sh ${VERIFY_FLAGS} --tsv 2>/dev/null" \
  > "${WORK}/verify.tsv"
set -e

RESULTS_DIR="${CACHE_DIR}/last-ubuntu-${RELEASE}"
mkdir -p "$RESULTS_DIR"
cp -f "${WORK}/verify.tsv" "${WORK}/verify.log" "${WORK}/install.log" "$RESULTS_DIR/" 2>/dev/null || true
cp -f "${WORK}/console.log" "$RESULTS_DIR/" 2>/dev/null || true

if (( DROP_SHELL )); then
  log "dropping you into the guest; exit the shell to finish"
  ssh "${SSH_OPTS[@]}" -t tester@127.0.0.1 || true
fi

printf '\n'
log "results: ${RESULTS_DIR}"
log "  verify.tsv   machine-readable rows (diff this against the NixOS run)"
log "  verify.log   human-readable"
log "  install.log  what install.sh did"
log "  console.log  the guest's serial console"

if (( VERIFY_RC == 0 )); then
  printf '\033[32m[ubuntu-vm] PASS\033[0m — every check the manifests imply holds in a clean %s VM\n' "$RELEASE"
else
  printf '\033[31m[ubuntu-vm] FAIL\033[0m — see %s/verify.log\n' "$RESULTS_DIR"
fi
exit "$VERIFY_RC"
