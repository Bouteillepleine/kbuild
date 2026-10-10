#!/bin/sh
# uninstall.sh wipes /data/adb/lkm - except while a second copy of this loader is still
# installed and using it.  That case is not hypothetical: the id changed once
# (susfs_lkm_loader -> ukma_loader) and both were installed at the same time, so an
# unconditional wipe would have deleted the surviving module's persistent .ko, boot flag,
# armed hook and hash marker.
set -u
cd "$(dirname "$0")/.." || exit 1

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0

# $1 label  $2 expect: wiped|kept  $3.. sibling specs "id[:remove][:noowner]"
case_run() {
    lbl=$1; want=$2; shift 2
    rm -rf "$T/m" "$T/lkm"; mkdir -p "$T/lkm"; : > "$T/lkm/persistent.ko"
    mkdir -p "$T/m/ukma_loader"
    cp uninstall.sh "$T/m/ukma_loader/uninstall.sh"
    printf 'ukma_loader\n' > "$T/m/ukma_loader/lkm-owner"      # ourselves
    for spec in "$@"; do
        id=${spec%%:*}; rest=${spec#"$id"}
        mkdir -p "$T/m/$id"
        case "$rest" in *noowner*) : ;; *) printf '%s\n' "$id" > "$T/m/$id/lkm-owner" ;; esac
        case "$rest" in *remove*) : > "$T/m/$id/remove" ;; esac
    done
    # EXECUTED, not sourced: uninstall.sh finds its own directory from $0 to exclude itself,
    # and sourcing would make that the harness's path - which silently defeats the check.
    LKM_DIR=$T/lkm MODULES_DIR=$T/m sh "$T/m/ukma_loader/uninstall.sh" >/dev/null 2>&1
    got=kept; [ -d "$T/lkm" ] || got=wiped
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "  ok   $lbl"
    else fail=$((fail + 1)); echo "  FAIL $lbl: expected $want, got $got"; fi
}

case_run "last loader standing: wipe"                      wiped
case_run "a sibling loader is installed: keep"             kept   susfs_lkm_loader
case_run "the sibling is also being removed: wipe"         wiped  susfs_lkm_loader:remove
case_run "an unrelated module is not a loader: wipe"       wiped  some_other_module:noowner
case_run "two siblings, one leaving, one staying: keep"    kept   old_a:remove old_b
case_run "our own lkm-owner must not count as a sibling"   wiped

echo
if [ "$fail" != 0 ]; then echo "$fail uninstall case(s) failed"; exit 1; fi
echo "all uninstall cases passed"
