#!/system/bin/sh
# Rewrites this module's own description so the KernelSU manager card shows live state
# instead of a fixed blurb.  Safe to run at any time and from anywhere: post-fs-data.sh
# (via its EXIT trap), boot-completed.sh, and the WebUI after a load/unload/remove.

MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/susfs_lkm_loader
[ -f "$MODDIR/module.prop" ] || exit 0

ROOT=/data/adb/lkm
BASE="Load any .ko from the WebUI, once or at every boot. Bootloop protected."

name=""
[ -s "$ROOT/loaded.name" ]     && name=$(cat "$ROOT/loaded.name" 2>/dev/null)
[ -z "$name" ] && [ -s "$ROOT/persistent.name" ] && name=$(cat "$ROOT/persistent.name" 2>/dev/null)
# A name is what rmmod and /sys/module take; refuse anything that is not one.
case "$name" in *[!A-Za-z0-9_-]*) name="" ;; esac

if [ -s "$ROOT/persistent.warning" ]; then
    state="disabled after a failed boot"
elif [ -z "$name" ] && [ ! -s "$ROOT/persistent.ko" ]; then
    state="no module configured"
else
    if [ -n "$name" ] && [ -d "/sys/module/$name" ]; then live="in kernel"; else live="not loaded"; fi
    if [ -f "$ROOT/persistent.enabled" ]; then boot="boot ON"; else boot="boot OFF"; fi
    state="${name:-unknown} - $live - $boot"
fi

# awk, not sed: a description can contain & and /, which sed would interpret.
tmp="$MODDIR/module.prop.new"
if awk -v d="[ $state ] $BASE" '/^description=/{print "description=" d; next} {print}' \
       "$MODDIR/module.prop" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv -f "$tmp" "$MODDIR/module.prop"
else
    rm -f "$tmp"
fi
exit 0
