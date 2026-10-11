#!/bin/sh
# Two assertions around the load, both from real failures:
#
#  - A persisted .ko outlives the kernel it was built for.  Flash a new kernel and `ksud
#    insmod` fails, and the failure path DISABLES boot loading - so the user loses the
#    configuration too, with only "make sure it was built for this device's kernel" as a clue.
#    The pre-check must refuse the load and KEEP the configuration.
#  - `insmod` returning 0 is not "the module armed".  And "not visible" is not a failure
#    either: susfs_guard_lkm filters itself out of /proc/modules and /sys/module for every
#    caller, root included, so for a susfs module only the supercall can confirm it.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
note() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "  ok   $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }

mkko() { printf 'junk\0vermagic=%s SMP preempt mod_unload aarch64\0name=%s\0junk' "$2" "$3" > "$1"; }

# ---- the pre-load vermagic gate, sliced out of post-fs-data.sh ----
A=$(grep -n '^# ---- pre-load integrity' post-fs-data.sh | cut -d: -f1)
B=$(grep -n '^touch "\$PENDING"' post-fs-data.sh | tail -1 | cut -d: -f1)
if [ -z "${A:-}" ] || [ -z "${B:-}" ] || [ "$A" -ge "$B" ]; then
    echo "  FAIL could not slice the pre-load gate out of post-fs-data.sh"
    exit 1
fi
sed -n "${A},$((B - 1))p" post-fs-data.sh > "$T/pre.sh"

run_pre() { # run_pre <ko-vermagic> <running-release>
    rm -rf "$T/r"; mkdir -p "$T/r"
    mkko "$T/r/persistent.ko" "$1" susfs_guard_lkm
    : > "$T/r/flag"
    rm -f "$T/r/warning" "$T/r/log" "$T/r/pending"
    loaded=yes
    ( PERSIST=$T/r/persistent.ko; LOG=$T/r/log; WARNING=$T/r/warning
      PENDING=$T/r/pending; FLAG=$T/r/flag
      uname() { if [ "${1-}" = -r ]; then printf '%s\n' "$2"; else command uname "$@"; fi; }
      # the real code reads the sysctl first; point it at a fake one
      sed "s#cat /proc/sys/kernel/osrelease#cat $T/osrel#" "$T/pre.sh" > "$T/pre.run"
      printf '%s\n' "$2" > "$T/osrel"
      . "$T/pre.run"
      : > "$T/r/reached_load" ) >/dev/null 2>&1
    [ -e "$T/r/reached_load" ] || loaded=no
    echo "$loaded"
}

r=$(run_pre "6.12.58-test" "6.12.58-test")
[ "$r" = yes ] && note ok "matching vermagic: proceeds to the load" || note fail "matching vermagic: proceeds to the load (got $r)"

r=$(run_pre "6.1.99-old-kernel" "6.12.58-test")
[ "$r" = no ] && note ok "stale vermagic: refuses the load" || note fail "stale vermagic: refuses the load (got $r)"
[ -s "$T/r/warning" ] && note ok "stale vermagic: tells the user why" || note fail "stale vermagic: tells the user why"
[ -e "$T/r/flag" ] && note ok "stale vermagic: KEEPS the configuration" || note fail "stale vermagic: KEEPS the configuration"
[ ! -e "$T/r/pending" ] && note ok "stale vermagic: leaves no bootloop marker behind" || note fail "stale vermagic: leaves no bootloop marker behind"
grep -q 'sha256' "$T/r/log" 2>/dev/null && note ok "records which bytes were considered" || note fail "records which bytes were considered"

echo
if [ "$fail" != 0 ]; then echo "$fail pre-load case(s) failed"; exit 1; fi
echo "all pre-load cases passed"
