#!/system/bin/sh
# Loads the module saved from the WebUI ("Save & load at every boot"), if any.
# Nothing is bundled with this KernelSU module.

ROOT="/data/adb/lkm"
PERSIST="$ROOT/persistent.ko"
FLAG="$ROOT/persistent.enabled"
PENDING="$ROOT/persistent.boot_pending"
WARNING="$ROOT/persistent.warning"
LOG="$ROOT/log"

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
    rm -f "$FLAG" "$PENDING"
    echo "WARNING: previous boot did not complete after loading the persistent module; disabled." >> "$LOG"
    echo "The saved kernel module was disabled because the last boot did not complete after it was loaded. It may be incompatible or unstable." > "$WARNING"
    exit 0
fi

# Arm the marker BEFORE insmod so it survives a crash or hang.
touch "$PENDING"
echo "Loading persistent module: $PERSIST" >> "$LOG"
"$KSUD" insmod "$PERSIST" >> "$LOG" 2>&1
RESULT=$?
echo "Exit code: $RESULT" >> "$LOG"

if [ "$RESULT" -ne 0 ]; then
    rm -f "$FLAG" "$PENDING"
    echo "The saved kernel module failed to load and was disabled. Make sure it was built for this device's kernel." > "$WARNING"
    echo "WARNING: persistent module failed to load; disabled." >> "$LOG"
fi

exit 0
