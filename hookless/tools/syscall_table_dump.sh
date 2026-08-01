#!/usr/bin/env bash
# syscall_table_dump.sh — empirical syscall-footprint audit of a built kernel.
#
# NoMount is hookless: it hijacks per-inode/dentry op vtables, it does NOT add a
# syscall or touch sys_call_table. This proves that against a real vmlinux by
# auditing the syscall *wrapper symbols* — a syscall added via SYSCALL_DEFINE
# always emits an `__arm64_sys_<name>` (and `__arm64_compat_sys_<name>`) symbol.
# Any wrapper whose name is not in the canonical arm64 table is an injected
# custom syscall == a detectable footprint == gate failure.
#
# This symbol audit is relocation-proof (no raw table / KASLR / RELA parsing),
# so it is stable across GKI configs. A best-effort sys_call_table dump is also
# attempted for a present-map artifact, but never gates on its own.
#
#   syscall_table_dump.sh <vmlinux> [--names FILE] [--fail-on-custom] [--out MAP]
#
# Tool overrides: NM= / READELF= (default: llvm-nm/llvm-readelf if present, else
# the binutils ones). Exit 2 = usage/error, 1 = custom syscall found (with
# --fail-on-custom), 0 = clean.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMES="$SELF_DIR/syscall_names_arm64.txt"
FAIL=0
OUTMAP=""
VMLINUX=""

die() { echo "syscall_table_dump: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --names) NAMES="$2"; shift 2;;
    --fail-on-custom) FAIL=1; shift;;
    --out) OUTMAP="$2"; shift 2;;
    -*) die "unknown flag: $1";;
    *) VMLINUX="$1"; shift;;
  esac
done
[ -n "$VMLINUX" ] && [ -r "$VMLINUX" ] || die "usage: syscall_table_dump.sh <vmlinux> [opts]"
[ -r "$NAMES" ] || die "canonical names file not found: $NAMES (pass --names)"

pick() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done; }
NM="${NM:-$(pick llvm-nm nm aarch64-linux-gnu-nm)}"
READELF="${READELF:-$(pick llvm-readelf readelf aarch64-linux-gnu-readelf)}"
[ -n "$NM" ] || die "no nm found (set NM=)"

echo "== syscall footprint audit: $VMLINUX =="
echo "   nm=$NM  readelf=${READELF:-<none>}  names=$(grep -vc '^#' "$NAMES")"

# canonical name set
declare -A CANON
while read -r _num name; do [ -n "${name:-}" ] && CANON[$name]=1; done < <(grep -vE '^#' "$NAMES")

# non-table wrappers that legitimately exist as __arm64_sys_* but are not gated
# (present on stock kernels; not a custom footprint)
ALLOW=" ni_syscall "

# ---- primary check: syscall-wrapper symbol audit --------------------------
# match __arm64_sys_<name>, __arm64_compat_sys_<name>, __se_sys_<name>
mapfile -t WRAPPERS < <(
  "$NM" "$VMLINUX" 2>/dev/null \
    | grep -oE '__(arm64|se)_(compat_)?sys_[a-z0-9_]+' \
    | sed -E 's/^__(arm64|se)_(compat_)?sys_//' \
    | sort -u
)
if [ "${#WRAPPERS[@]}" -eq 0 ]; then
  echo "!! no __arm64_sys_* wrappers found — wrong ELF, stripped symtab, or a"
  echo "   pre-4.17 kernel using bare sys_* naming. Cannot audit symbols."
  [ "$FAIL" = 1 ] && exit 2 || exit 0
fi

custom=()
for w in "${WRAPPERS[@]}"; do
  [ -n "${CANON[$w]:-}" ] && continue
  case "$ALLOW" in *" $w "*) continue;; esac
  custom+=("$w")
done

echo "   syscall wrappers: ${#WRAPPERS[@]}   canonical: matched   custom: ${#custom[@]}"
if [ "${#custom[@]}" -gt 0 ]; then
  echo "!! CUSTOM SYSCALL WRAPPERS (not in canonical arm64 table — injected footprint):"
  for w in "${custom[@]}"; do echo "   ! __arm64_sys_$w"; done
else
  echo "OK: every syscall wrapper maps to a canonical name — zero added syscalls."
fi

# ---- best-effort: present-map from sys_call_table (never gates) ------------
if [ -n "$OUTMAP" ] && [ -n "${READELF:-}" ]; then
  sct=$("$NM" -n "$VMLINUX" 2>/dev/null | awk '$3=="sys_call_table"{print $1; exit}')
  if [ -n "$sct" ]; then
    echo "   sys_call_table @ 0x$sct (present-map -> $OUTMAP, advisory)"
    # resolve wrapper vaddr -> name once
    declare -A ADDR2NAME
    while read -r a _t n; do ADDR2NAME[$a]="$n"; done < <(
      "$NM" -n "$VMLINUX" 2>/dev/null | grep -E ' __(arm64|se)_(compat_)?sys_'
    )
    # RELA addends give link-time targets independent of KASLR
    "$READELF" -rW "$VMLINUX" 2>/dev/null \
      | awk -v base="$((16#$sct))" '
          / R_AARCH64_RELATIVE /{
            off=strtonum("0x"$1); add=$NF;
            if (off>=base) { idx=(off-base)/8; if (idx==int(idx) && idx<600) print idx, add }
          }' \
      | while read -r idx add; do
          nm2="${ADDR2NAME[${add#0x}]:-}"
          case "$nm2" in
            *ni_syscall*) : ;;                          # absent
            __*sys_*) echo "$idx ${nm2##*sys_}";;       # present
          esac
        done | sort -n -u > "$OUTMAP" || true
    echo "   present entries: $(grep -c . "$OUTMAP" 2>/dev/null || echo 0)"
  else
    echo "   (sys_call_table symbol absent — skipping present-map)"
  fi
fi

if [ "${#custom[@]}" -gt 0 ] && [ "$FAIL" = 1 ]; then
  echo "== FAIL: $((${#custom[@]})) custom syscall(s) — NoMount must add zero. =="
  exit 1
fi
echo "== PASS: no custom syscall footprint. =="
exit 0
