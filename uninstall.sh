#!/system/bin/sh
# Removing this module cleans up its state in $LKM_DIR - but ONLY if no other copy of this
# loader is still installed. The id changed once (susfs_lkm_loader -> ukma_loader), and for
# as long as both were installed they shared one $LKM_DIR: an unconditional wipe here would
# have taken the surviving module's persistent .ko, its boot flag, the armed post-insmod hook
# and the hook's hash marker with it, leaving a loader installed with nothing configured.
# A sibling is recognised by the lkm-owner file this module ships, and one already marked
# `remove` is on its way out too, so it does not count.
LKM_DIR=${LKM_DIR:-/data/adb/lkm}
MODULES_DIR=${MODULES_DIR:-/data/adb/modules}
MODDIR=${0%/*}

keep=0
for owner in "$MODULES_DIR"/*/lkm-owner; do
    [ -f "$owner" ] || continue
    d=${owner%/lkm-owner}
    [ "$d" = "$MODDIR" ] && continue      # ourselves
    [ -f "$d/remove" ] && continue        # also being removed
    keep=1
done

[ "$keep" = 1 ] || rm -rf "$LKM_DIR"
exit 0
