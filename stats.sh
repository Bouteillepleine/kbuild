#!/system/bin/sh
# Refresh susfs4ksu's WebUI stats cache from LIVE kernel state.
#
# That module writes susfs_stats.txt once, in its own boot-completed.sh, counting only
# the paths IT applied from its sus_path.txt -- rules added by this loader's hook never
# appear, so the tiles sit at 0 while the kernel is enforcing a dozen. Its WebUI runs
# `cat susfs_stats.txt` on every open, so keeping the file current is enough; nothing in
# that module needs changing. No-ops if susfs4ksu is not installed.

D=/data/adb/ksu/susfs4ksu
P=/sys/module/susfs_guard_lkm/parameters
[ -d "$D" ] || exit 0
[ -r /proc/susfs_path ] || exit 0

sus_path=$(grep -c '^path=' /proc/susfs_path 2>/dev/null)
sus_mount=$(sed -n 's/^mount prefixes: \([0-9]*\)\/.*/\1/p' "$P/hide_mounts" 2>/dev/null)
sus_map=$(sed -n 's/^rules=\([0-9]*\) .*/\1/p' "$P/map_stat" 2>/dev/null)
case "$sus_path" in ''|*[!0-9]*) sus_path=0 ;; esac
case "$sus_mount" in ''|*[!0-9]*) sus_mount=0 ;; esac
case "$sus_map" in ''|*[!0-9]*) sus_map=0 ;; esac

# try_umount stays 0: this LKM reports it DEPRECATED, it implements no umount.
for f in susfs_stats.txt susfs_stats1.txt; do
    [ -f "$D/$f" ] || continue
    had_path=0
    grep -q '^sus_path=' "$D/$f" && had_path=1
    {
        echo "sus_map=$sus_map"
        echo "sus_mount=$sus_mount"
        echo "try_umount=0"
        # `if`, not `&&`: a false `&&` would make the whole block exit non-zero and
        # silently skip the write for files that carry no sus_path key.
        if [ "$had_path" = 1 ]; then echo "sus_path=$sus_path"; fi
    } > "$D/$f.tmp" && cat "$D/$f.tmp" > "$D/$f"
    rm -f "$D/$f.tmp"
done
sync
exit 0
