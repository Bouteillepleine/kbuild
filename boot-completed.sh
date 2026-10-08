#!/system/bin/sh
# Boot finished, so the persistent module did not break it: disarm the marker.
rm -f /data/adb/lkm/persistent.boot_pending
sync
# The card still says whatever post-fs-data left; boot survived, so settle it.
sh "${0%/*}/desc.sh" >/dev/null 2>&1

# susfs4ksu rewrites its WebUI stats cache from its own boot-completed.sh, which may run
# after this one. Re-assert for a couple of minutes, backgrounded, so script ordering
# does not decide whether the tiles show the real numbers. No-op without susfs4ksu.
if [ -x "${0%/*}/stats.sh" ]; then
    # Fully detached: an inherited stdout would keep whatever started this script
    # waiting on us for the whole two minutes.
    (
        i=0
        while [ "$i" -lt 12 ]; do
            sh "${0%/*}/stats.sh" >/dev/null 2>&1
            sleep 10
            i=$((i + 1))
        done
    ) >/dev/null 2>&1 </dev/null &
fi
exit 0
