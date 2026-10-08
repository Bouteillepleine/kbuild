#!/system/bin/sh
# Loads the module saved from the WebUI ("Save & load at every boot"), if any.
# Nothing is bundled with this KernelSU module.

ROOT="/data/adb/lkm"
PERSIST="$ROOT/persistent.ko"
FLAG="$ROOT/persistent.enabled"
PENDING="$ROOT/persistent.boot_pending"
WARNING="$ROOT/persistent.warning"
LOG="$ROOT/log"

MODDIR=${0%/*}
# Refresh the manager card on every exit path, of which this script has five.
trap 'sh "$MODDIR/desc.sh" >/dev/null 2>&1' EXIT

mkdir -p "$ROOT"
chmod 700 "$ROOT"

{
    echo "Universal Kernel Module Autoloader"
    echo "Kernel: $(uname -r)"
} > "$LOG"

KSUD="/data/adb/ksu/bin/ksud"
[ -x "$KSUD" ] || KSUD="$(command -v ksud)"
if [ -z "$KSUD" ]; then
    echo "ERROR: ksud not found" >> "$LOG"
    exit 0
fi

if [ ! -f "$FLAG" ] || [ ! -s "$PERSIST" ]; then
    echo "No persistent module configured." >> "$LOG"
    exit 0
fi

# A leftover pending marker means the previous boot never reached
# boot-completed.sh after loading the persistent module: disable it.
if [ -f "$PENDING" ]; then
    rm -f "$FLAG" "$PENDING" "$ROOT/loaded.name"
    sync
    echo "WARNING: previous boot did not complete after loading the persistent module; disabled." >> "$LOG"
    echo "The saved kernel module was disabled because the last boot did not complete after it was loaded. It may be incompatible or unstable." > "$WARNING"
    exit 0
fi

# Arm the marker BEFORE insmod so it survives a crash or hang - and sync it, because
# "written" is not "on disk": a module that panics the kernel inside insmod takes the
# page cache with it, the marker is lost, and the next boot cheerfully retries the same
# module.  That is the one case this guard exists for.
touch "$PENDING"
sync
echo "Loading persistent module: $PERSIST" >> "$LOG"
"$KSUD" insmod "$PERSIST" >> "$LOG" 2>&1
RESULT=$?
echo "Exit code: $RESULT" >> "$LOG"

# The module NAME, for the WebUI's live controls (rmmod takes a name, not a path).
# Read out of the .ko's .modinfo; harmless if the tools are missing.
NAME="$(strings "$PERSIST" 2>/dev/null | sed -n 's/^name=\([A-Za-z0-9_-]\{1,\}\)$/\1/p' | head -1)"
[ -n "$NAME" ] && printf '%s\n' "$NAME" > "$ROOT/loaded.name"

if [ "$RESULT" -ne 0 ]; then
    rm -f "$FLAG" "$PENDING" "$ROOT/loaded.name"
    sync
    echo "The saved kernel module failed to load and was disabled. Make sure it was built for this device's kernel." > "$WARNING"
    echo "WARNING: persistent module failed to load; disabled." >> "$LOG"
fi

exit 0
