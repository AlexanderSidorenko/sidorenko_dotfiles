# shellcheck shell=bash
# meminfo.sh — shared readers for the kernel's memory interfaces.
#
# WHY
#
# Sourced, never executed. bin/ram-health and bin/mem answer different questions
# — "am I in trouble, and why" versus "what is memory doing right now" — but they
# read the same handful of files, and every one of those reads has a trap in it:
# /proc/meminfo is in kB while sysfs is in bytes, PSI is key=value pairs rather
# than columns, a missing key must yield 0 rather than an empty string that turns
# into a shell arithmetic error, and a zswap parameter on the kernel cmdline is a
# request that the kernel may quietly have ignored.
#
# Those subtleties were already learned once. Duplicating them across two scripts
# means they drift, and this repo has a worked example of exactly that: the note
# in ram-health claiming the zswap compression ratio needed root outlived the
# fact by several commits, because nothing else read the same source.
#
# Everything here is read-only and unprivileged.
#
# Contract: functions print to stdout and never exit. Predicates return status.
# Sizes are kB unless the name says otherwise, matching /proc conventions.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf 'meminfo.sh is a library — source it, do not run it.\n' >&2
  exit 1
fi

# ---------- /proc readers ----------

# A field from /proc/meminfo, in kB. Missing keys yield 0 so arithmetic is safe.
mi() { awk -v k="$1:" '$1 == k { print $2; found = 1 } END { if (!found) print 0 }' /proc/meminfo; }

# A counter from /proc/vmstat.
vm() { awk -v k="$1" '$1 == k { print $2; found = 1 } END { if (!found) print 0 }' /proc/vmstat; }

# A PSI value, e.g. psi full avg60. /proc/pressure/memory lines look like:
#   full avg10=0.00 avg60=2.08 avg300=5.66 total=98859245
psi() {
  awk -v row="$1" -v key="$2" '
    $1 == row {
      for (i = 2; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == key) { print kv[2]; found = 1 }
      }
    }
    END { if (!found) print 0 }
  ' /proc/pressure/memory
}

# A kernel cmdline parameter's value, e.g. `kcmdline zswap.compressor`. Empty
# when the parameter was not passed at all.
kcmdline() {
  awk -v k="$1=" '
    {
      for (i = 1; i <= NF; i++)
        if (index($i, k) == 1) { print substr($i, length(k) + 1); found = 1 }
    }
    END { if (!found) print "" }
  ' /proc/cmdline
}

# Is a crypto algorithm registered right now? zswap can only use one that is.
crypto_has() {
  awk -v c="$1" '$1 == "name" && $3 == c { f = 1 } END { exit !f }' /proc/crypto
}

# ---------- zswap ----------

# A live zswap module parameter, or empty when the kernel has no such knob. This
# kernel has no zswap.zpool at all, for instance, so callers must tolerate empty.
zswap_param() { cat "/sys/module/zswap/parameters/$1" 2>/dev/null || true; }

zswap_enabled() { [[ "$(zswap_param enabled)" == "Y" ]]; }

# What the cmdline asked for, versus what the kernel actually runs. These differ
# more often than anyone expects: the compressor is resolved while zswap
# initialises, before a loadable crypto module can exist, so zswap.compressor=zstd
# on a kernel with CONFIG_CRYPTO_ZSTD=m silently yields the built-in default. The
# kernel logs that substitution once at boot and never mentions it again, and no
# later view contradicts it — which is precisely why it needs comparing.
zswap_compressor_wanted() { kcmdline zswap.compressor; }
zswap_compressor_live() { zswap_param compressor; }

# True when the cmdline asked for a compressor and did not get it.
zswap_compressor_mismatch() {
  local want live
  want="$(zswap_compressor_wanted)"
  live="$(zswap_compressor_live)"
  [[ -n "$want" && -n "$live" && "$want" != "$live" ]]
}

# ---------- formatting ----------

# Float comparison: succeeds when $1 >= $2.
fge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# kB -> human. Kept separate from numfmt so the units match /proc conventions.
hk() {
  awk -v k="$1" 'BEGIN {
    if (k >= 1048576) printf "%.1f GiB", k / 1048576
    else if (k >= 1024) printf "%.0f MiB", k / 1024
    else printf "%d KiB", k
  }'
}

# kB -> short human, for places where column width matters more than precision.
hks() {
  awk -v k="$1" 'BEGIN {
    if (k >= 1048576) printf "%.1fG", k / 1048576
    else if (k >= 1024) printf "%.0fM", k / 1024
    else printf "%dK", k
  }'
}

pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.0f", a * 100 / b; else printf "0" }'; }
