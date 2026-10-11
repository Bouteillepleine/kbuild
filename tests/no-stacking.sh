#!/bin/sh
# Two SUSFS implementations in one kernel is unsupported, and `ksud insmod` only refuses a
# module of the SAME NAME (-EEXIST) - so it does not catch a built-in SUSFS or an LKM packaged
# under a different name.  post-fs-data.sh asks the ksu_susfs interface instead, and gates that
# question on the module being susfs itself, because this loader exists to load ANY .ko.
set -u
cd "$(dirname "$0")/.." || exit 1

BLOCK=$(mktemp); T=$(mktemp -d)
trap 'rm -rf "$BLOCK" "$T"' EXIT

A=$(grep -n '^# The module.s own name, out of .modinfo' post-fs-data.sh | cut -d: -f1)
# End at the pre-load integrity block, NOT at `touch $PENDING`: v2.12 inserted the vermagic
# gate between the two, and slicing up to the touch dragged that gate into this test, where its
# fake .ko has a vermagic the host kernel does not match - so every case read as "refuse".
B=$(grep -n '^# ---- pre-load integrity' post-fs-data.sh | cut -d: -f1)
if [ -z "${A:-}" ] || [ -z "${B:-}" ] || [ "$A" -ge "$B" ]; then
    echo "  FAIL could not locate the stacking guard in post-fs-data.sh (did it move?)"
    exit 1
fi
sed -n "${A},$((B - 1))p" post-fs-data.sh > "$BLOCK"

pass=0; fail=0
mkko() { printf 'junk\0vermagic=x\0name=%s\0junk' "$2" > "$1"; }

# $1 label  $2 module name  $3 susfs-present: yes|no|nobin  $4 expect: load|refuse
case_run() {
    rm -rf "$T"; mkdir -p "$T"
    PERSIST=$T/persistent.ko; LOG=$T/log; WARNING=$T/warning
    mkko "$PERSIST" "$2"; : > "$LOG"
    case $3 in
        yes)   printf '#!/bin/sh\nexit 0\n'  > "$T/ksu_susfs"; chmod +x "$T/ksu_susfs"; SB=$T/ksu_susfs ;;
        no)    printf '#!/bin/sh\nexit 1\n'  > "$T/ksu_susfs"; chmod +x "$T/ksu_susfs"; SB=$T/ksu_susfs ;;
        nobin) SB=$T/absent ;;
    esac
    # What matters is whether execution CONTINUES to the load, so the discriminator is a
    # sentinel written after the block returns - not the warning file, which the guard writes
    # on the line before it exits (judging on that cannot tell "warned and stopped" from
    # "warned and carried on", and a deliberately removed `exit 0` slipped past it).
    rm -f "$T/continued"
    ( PERSIST=$PERSIST LOG=$LOG WARNING=$WARNING SUSFS_BIN=$SB
      . "$BLOCK"
      : > "$T/continued" ) >/dev/null 2>&1
    if [ -e "$T/continued" ]; then got=load; else got=refuse; fi
    if [ "$got" = "$4" ]; then pass=$((pass + 1)); echo "  ok   $1"
    else fail=$((fail + 1)); echo "  FAIL $1: expected $4, got $got"; fi
}

case_run "susfs module + SUSFS already live -> refuse"   susfs_guard_lkm yes   refuse
case_run "susfs module, nothing live -> load"            susfs_guard_lkm no    load
case_run "susfs module, no ksu_susfs binary -> load"     susfs_guard_lkm nobin load
case_run "UNRELATED module + SUSFS live -> load anyway"  8812au          yes   load
case_run "unrelated module, nothing live -> load"        rtw_core        no    load

echo
if [ "$fail" != 0 ]; then echo "$fail stacking case(s) failed"; exit 1; fi
echo "all stacking cases passed"
