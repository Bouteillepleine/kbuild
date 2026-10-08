#!/system/bin/sh
# Boot finished, so the persistent module did not break it: disarm the marker.
rm -f /data/adb/lkm/persistent.boot_pending
exit 0
