#!/usr/bin/env bash
# fingerprint.sh — turn syscall present-maps into a NoMount invisibility audit.
#
# Canonical syscall names come from the NDK's asm-generic/unistd.h (authoritative,
# 0..462), so there's no hand-maintained table to rot.
#
# Modes:
#   fingerprint.sh --scan OUT.map            scan the connected device -> OUT.map, then audit it
#   fingerprint.sh MAP                       audit one present-map (flags unnamed = custom syscalls)
#   fingerprint.sh STOCK.map MODDED.map      diff two present-maps, labelled with syscall names
#
# A present-map is one syscall number per line (output of `scan START END`).
set -u

NDK="${NDK:-/c/Users/steve/AppData/Local/Android/Sdk/ndk/28.2.13676358}"
UNISTD="${UNISTD:-$NDK/toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/include/asm-generic/unistd.h}"
DEV_BIN=/data/local/tmp/scan
MAXNR=600

die() { echo "fingerprint: $*" >&2; exit 1; }

# --- build num -> name table from unistd.h -----------------------------------
declare -A NAME
load_names() {
  [ -r "$UNISTD" ] || die "unistd.h not found at $UNISTD (set NDK= or UNISTD=)"
  # parse both __NR_<name> N and the dual 32/64 __NR3264_<name> N forms
  # (fcntl/lseek/newfstatat/mmap/... are defined via __NR3264_*)
  while read -r num name; do NAME[$num]="$name"; done < <(
    awk '/^#define __NR(3264)?_[a-z_0-9]+ [0-9]+$/{n=$2; sub(/^__NR(3264)?_/,"",n); if(n!="syscalls") print $3, n}' "$UNISTD"
  )
}
nm() { echo "${NAME[$1]:-<unnamed>}"; }

# strip CR (maps captured via `adb shell >` on Windows carry \r)
clean() { tr -d '\r' < "$1" | grep -E '^[0-9]+$' | sort -n -u; }

# --- device scan helper ------------------------------------------------------
do_scan() {
  local out="$1"
  command -v adb >/dev/null || die "adb not in PATH"
  adb get-state >/dev/null 2>&1 || die "no device (adb get-state failed)"
  if ! adb shell "[ -x $DEV_BIN ]" 2>/dev/null | grep -q .; then :; fi
  adb shell "[ -x $DEV_BIN ] || echo MISSING" 2>/dev/null | tr -d '\r' | grep -q MISSING && {
    [ -f ./scan ] || die "$DEV_BIN missing on device and no local ./scan to push"
    echo "pushing ./scan -> $DEV_BIN" >&2
    adb push ./scan "$DEV_BIN" >/dev/null && adb shell chmod 755 "$DEV_BIN"
  }
  echo "scanning device 0..$MAXNR -> $out" >&2
  adb shell "$DEV_BIN 0 $MAXNR" | tr -d '\r' > "$out"
}

# --- audit a single map ------------------------------------------------------
audit() {
  local map="$1"
  local present; present="$(clean "$map")"
  local pcount; pcount=$(echo "$present" | grep -c .)
  echo "== syscall-table audit: $map =="
  echo "present syscalls: $pcount   (canonical table max = 462 mseal)"

  # unnamed present numbers = custom syscalls / out-of-table entries = the tell
  local unnamed=""
  for n in $present; do [ -n "${NAME[$n]:-}" ] || unnamed="$unnamed $n"; done
  if [ -n "$unnamed" ]; then
    echo "!! UNNAMED present (no canonical name -> custom syscall, strong detection tell):"
    for n in $unnamed; do echo "   ! $n"; done
  else
    echo "OK: every present syscall has a canonical name (no custom-syscall footprint)"
  fi

  # config-driven absences within the named table (context, not a problem)
  echo "-- compiled-out named syscalls in 0..462 (kernel CONFIG fingerprint) --"
  for n in $(seq 0 462); do
    [ -n "${NAME[$n]:-}" ] || continue                 # skip reserved gaps
    echo "$present" | grep -qx "$n" && continue         # present -> skip
    echo "   - $n $(nm "$n")"
  done | sort -t' ' -k2 -n
}

# --- diff two maps -----------------------------------------------------------
diffmaps() {
  local stock="$1" modded="$2"
  local A B; A="$(clean "$stock")"; B="$(clean "$modded")"
  echo "== syscall-table diff: stock=$stock  modded=$modded =="
  local added removed
  added="$(comm -13 <(echo "$A") <(echo "$B"))"   # in modded, not stock
  removed="$(comm -23 <(echo "$A") <(echo "$B"))" # in stock, not modded
  local na=0 nr=0 nu=0
  if [ -n "$added" ]; then
    echo "-- present on MODDED but not stock (footprint a detector can probe) --"
    for n in $added; do
      local name; name="$(nm "$n")"
      [ "$name" = "<unnamed>" ] && nu=$((nu+1))
      printf "   + %s %s%s\n" "$n" "$name" "$([ "$name" = "<unnamed>" ] && echo '   <-- CUSTOM SYSCALL')"
      na=$((na+1))
    done
  fi
  if [ -n "$removed" ]; then
    echo "-- present on STOCK but not modded (missing/backport gap) --"
    for n in $removed; do printf "   - %s %s\n" "$n" "$(nm "$n")"; nr=$((nr+1)); done
  fi
  echo "== summary: +$na added   -$nr removed   ($nu unnamed/custom) =="
  if [ "$na" = 0 ] && [ "$nr" = 0 ]; then
    echo ">> IDENTICAL: NoMount adds zero syscall-table footprint."
  fi
  return 0
}

# --- dispatch ----------------------------------------------------------------
load_names
case "${1:-}" in
  --scan) [ $# -eq 2 ] || die "usage: fingerprint.sh --scan OUT.map"; do_scan "$2"; audit "$2" ;;
  "" )    die "usage: fingerprint.sh [--scan OUT.map | MAP | STOCK.map MODDED.map]" ;;
  * )     if [ $# -eq 1 ]; then [ -f "$1" ] || die "no such map: $1"; audit "$1";
          elif [ $# -eq 2 ]; then diffmaps "$1" "$2";
          else die "too many args"; fi ;;
esac
