#!/usr/bin/env bash
# Compare two verify-applied.sh TSV runs — typically Ubuntu vs NixOS.
#
# WHAT IS AND IS NOT BEING CHECKED. The criterion is COMPLETENESS: everything
# the manifests ask for on a platform must actually be present on it. That is a
# per-platform property, and each VM test already asserts it on its own side.
#
# VERSIONS ARE NOT COMPARED and are not expected to match. The two platforms
# resolve the same package LIST against their own nixpkgs, so Ubuntu having a
# different `bat` than NixOS is correct, not drift. Nothing here looks at
# versions, and a difference in them is not a finding.
#
# What this adds on top of the two independent runs is the cross-check neither
# can do alone: an item that one platform PROVES is achievable while the other
# reports it missing. That asymmetry usually means a real gap in one side's
# install path rather than a legitimate platform difference.
#
#   PASS vs FAIL   one platform has it, the other does not, and both tried.
#                  A completeness gap. This exits non-zero.
#   PASS vs SKIP   out of scope on one side — a headless cloud image has no
#                  GNOME schemas, so every gsettings row is SKIP there and PASS
#                  on a GUI NixOS host. Reported, not fatal.
#   only on one    the manifests' platform/gui/nixos tags put it out of scope
#                  on the other side. Reported, not fatal.
#
# Usage:
#   ./tests/compare-platforms.sh UBUNTU.tsv NIXOS.tsv
#   ./tests/compare-platforms.sh            # uses the last run of each
set -uo pipefail

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/sidorenko-dotfiles-vmtest"
A="${1:-}"
B="${2:-}"

if [[ -z $A ]]; then
  A="$(ls -1t "${CACHE}"/last-ubuntu-*/verify.tsv 2>/dev/null | head -1)"
  [[ -n $A ]] || { echo "no Ubuntu run found; pass one explicitly" >&2; exit 2; }
fi
if [[ -z $B ]]; then
  # The NixOS result is a nix build output. `ls -t` is useless here: every
  # store path carries the same epoch mtime, so ordering by it picked an OLD
  # run with an EMPTY artefact — and the comparison then cheerfully reported
  # agreement between 22 rows and nothing. Rank by ctime (when the path
  # entered the store) and consider only candidates that actually have rows.
  B="$(
    # Both spellings: the test is named after this repo now, but a consumer
    # re-exporting it may still produce the older store name.
    for d in /nix/store/*-vm-test-run-sidorenko-dotfiles-nixos \
             /nix/store/*-vm-test-run-desktop-dotfiles; do
      [[ -r "$d/verify.tsv" ]] || continue
      grep -qvE '^#|^$' "$d/verify.tsv" || continue
      printf '%s\t%s/verify.tsv\n' "$(stat -c '%Z' "$d")" "$d"
    done | sort -rn | head -1 | cut -f2
  )"
  [[ -n $B ]] || { echo "no NixOS run with a non-empty verify.tsv found.
  Build it first:  nix build .#checks.x86_64-linux.nixos-vm
  or pass the TSV explicitly." >&2; exit 2; }
fi

[[ -r $A ]] || { echo "cannot read $A" >&2; exit 2; }
[[ -r $B ]] || { echo "cannot read $B" >&2; exit 2; }

# Neither side may be empty. An empty input makes every comparison below
# trivially true, which is the one way this script could lie.
for f in "$A" "$B"; do
  n="$(grep -cvE '^#|^$' "$f" || true)"
  (( n > 0 )) || { echo "ERROR: $f has no check rows; it proves nothing." >&2; exit 2; }
done

printf 'A (left) : %s\n' "$A"
printf '           %s\n' "$(grep -m1 '^# platform' "$A" || true)"
printf 'B (right): %s\n' "$B"
printf '           %s\n\n' "$(grep -m1 '^# platform' "$B" || true)"

# key = category/item, value = status. Sorted, because join needs it and the
# first version of this comparison silently mis-joined without it.
key_status() { awk -F'\t' '!/^#/ && NF>=3 {print $2"/"$3"\t"$1}' "$1" | sort -u -t$'\t' -k1,1; }

TA="$(mktemp)"; TB="$(mktemp)"
trap 'rm -f "$TA" "$TB"' EXIT
key_status "$A" >"$TA"
key_status "$B" >"$TB"

count() { awk -F'\t' -v s="$2" '$1!~/^#/ && $1==s {n++} END{print n+0}' "$1"; }
printf 'counts   A: PASS=%s FAIL=%s SKIP=%s\n' \
  "$(count "$A" PASS)" "$(count "$A" FAIL)" "$(count "$A" SKIP)"
printf 'counts   B: PASS=%s FAIL=%s SKIP=%s\n\n' \
  "$(count "$B" PASS)" "$(count "$B" FAIL)" "$(count "$B" SKIP)"

GAPS=0

# --- the one that matters --------------------------------------------------
both="$(join -t$'\t' -j1 "$TA" "$TB")"
real="$(awk -F'\t' '
  ($2=="PASS" && $3=="FAIL") || ($2=="FAIL" && $3=="PASS") {print}
' <<<"$both")"
if [[ -n $real ]]; then
  printf '\033[31mCOMPLETENESS GAP\033[0m — present on one platform, missing on the other:\n'
  awk -F'\t' '{printf "  %-50s A=%-5s B=%s\n", $1, $2, $3}' <<<"$real"
  GAPS=1
else
  printf '\033[32mNo gaps\033[0m — nothing is present on one platform and missing on the other.\n'
fi

# --- scope differences, expected but worth seeing --------------------------
scope="$(awk -F'\t' '$2!=$3 && !(($2=="PASS"&&$3=="FAIL")||($2=="FAIL"&&$3=="PASS")) {print}' <<<"$both")"
if [[ -n $scope ]]; then
  printf '\nScope differences (%s), expected where the manifests tag rows per platform:\n' \
    "$(grep -c . <<<"$scope")"
  awk -F'\t' '{printf "  %-50s A=%-5s B=%s\n", $1, $2, $3}' <<<"$scope" | head -12
  (( $(grep -c . <<<"$scope") > 12 )) && printf '  ... and %s more\n' \
    "$(( $(grep -c . <<<"$scope") - 12 ))"
fi

only_a="$(join -t$'\t' -j1 -v1 "$TA" "$TB")"
only_b="$(join -t$'\t' -j1 -v2 "$TA" "$TB")"
[[ -n $only_a ]] && printf '\nOnly measured on A (%s):\n%s\n' "$(grep -c . <<<"$only_a")" \
  "$(awk -F'\t' '{printf "  %-50s %s\n", $1, $2}' <<<"$only_a" | head -8)"
[[ -n $only_b ]] && printf '\nOnly measured on B (%s):\n%s\n' "$(grep -c . <<<"$only_b")" \
  "$(awk -F'\t' '{printf "  %-50s %s\n", $1, $2}' <<<"$only_b" | head -8)"

shared_pass="$(awk -F'\t' '$2=="PASS" && $3=="PASS"' <<<"$both" | grep -c . || true)"
printf '\nShared core: %s checks PASS on both.\n' "$shared_pass"

if (( GAPS )); then
  printf '\n\033[31mFAIL\033[0m — one platform is missing something the other proves installable.\n'
  exit 1
fi
printf '\033[32mOK\033[0m — every platform has everything its manifests ask for.\n'
