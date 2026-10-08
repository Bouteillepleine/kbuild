#!/system/bin/sh
# Boot finished, so the persistent module did not break it: disarm the marker.
rm -f /data/adb/lkm/persistent.boot_pending
sync
# The card still says whatever post-fs-data left; boot survived, so settle it.
sh "${0%/*}/desc.sh" >/dev/null 2>&1
exit 0
