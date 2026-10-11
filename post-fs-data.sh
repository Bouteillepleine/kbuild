#!/system/bin/sh
# Loads the module saved from the WebUI ("Save & load at every boot"), if any.
# Nothing is bundled with this KernelSU module.

ROOT="/data/adb/lkm"
PERSIST="$ROOT/persistent.ko"
FLAG="$ROOT/persistent.enabled"
PENDING="$ROOT/persistent.boot_pending"
WARNING="$ROOT/persistent.warning"
# Optional user script, run ONLY after the module is really in the kernel.  This is the
# only correctly-ordered place for a module's own configuration: a control ABI that the
# .ko itself provides (a SUSFS supercall, a netlink socket, a /proc node) does not exist
# until insmod returns, and ksud's own init has already run by then.
HOOK="$ROOT/post-insmod.sh"
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
chmod 600 "$LOG"

KSUD="/data/adb/ksu/bin/ksud"
[ -x "$KSUD" ] || KSUD="$(command -v ksud)"
if [ -z "$KSUD" ]; then
    echo "ERROR: ksud not found" >> "$LOG"
    exit 0
fi

# ---- keep the armed hook current across module updates --------------------------------
# $HOOK is a COPY of the module's post-insmod.sh.susfs, armed once from the WebUI, and
# nothing used to refresh it: a module update shipped a new template that never reached
# /data/adb/lkm, so the hook that actually ran stayed whatever version armed it.  It is
# also a template people are meant to edit, so a blind copy would destroy their work.
# The marker holds the sha256 of what was armed - still matching means untouched, so it
# can be refreshed; differing means theirs, so it is left alone and said once.
HOOK_SRC="$MODDIR/post-insmod.sh.susfs"
HOOK_MARK="$ROOT/post-insmod.sha256"

hook_sum() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

if [ -s "$HOOK" ] && [ -f "$HOOK_SRC" ]; then
    hook_now=$(hook_sum "$HOOK")
    hook_want=$(hook_sum "$HOOK_SRC")
    hook_was=$(cat "$HOOK_MARK" 2>/dev/null)
    if [ -n "$hook_now" ] && [ -n "$hook_want" ] && [ "$hook_now" != "$hook_want" ]; then
        if [ "$hook_now" = "$hook_was" ]; then
            if cp -f "$HOOK_SRC" "$HOOK"; then
                chmod 700 "$HOOK"
                printf '%s\n' "$hook_want" > "$HOOK_MARK"
                chmod 600 "$HOOK_MARK"
                sync
                echo "Refreshed the post-insmod hook from the module (it was unmodified)." >> "$LOG"
            else
                echo "WARNING: could not refresh the post-insmod hook; the armed one still runs." >> "$LOG"
            fi
        elif [ -z "$hook_was" ]; then
            echo "NOTE: a newer post-insmod hook ships with this module. Yours was left alone because nothing recorded what armed it - re-arm from the WebUI to adopt it." >> "$LOG"
        else
            echo "NOTE: a newer post-insmod hook ships with this module. Yours has been edited, so it was left alone." >> "$LOG"
        fi
    elif [ "$hook_now" = "$hook_want" ] && [ "$hook_was" != "$hook_want" ]; then
        # Already current, just unmarked (armed before this check existed): record it so the
        # NEXT update can refresh silently.
        printf '%s\n' "$hook_want" > "$HOOK_MARK"
        chmod 600 "$HOOK_MARK"
    fi
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
# The module's own name, out of .modinfo - needed BEFORE the load for the stacking check
# below, and reused afterwards for the WebUI's rmmod control.
NAME="$(strings "$PERSIST" 2>/dev/null | sed -n 's/^name=\([A-Za-z0-9_-]\{1,\}\)$/\1/p' | head -1)"

# Two SUSFS implementations in one kernel is not a supported configuration: they hook the same
# LSM slots and /proc nodes, and the second one to arm wins silently.  `ksud insmod` only
# refuses a module of the SAME NAME (-EEXIST), so it does not catch a built-in SUSFS or an LKM
# packaged under another name.  Ask the interface instead - ksu_susfs talks to whichever
# implementation is live - and only for a module that is itself susfs, because this loader
# exists to load ANY .ko and an unrelated module has no business being gated on this.
case "$NAME" in
    susfs*)
        SUSFS_BIN=${SUSFS_BIN:-/data/adb/ksu/bin/ksu_susfs}
        if [ -x "$SUSFS_BIN" ] && "$SUSFS_BIN" show version >/dev/null 2>&1; then
            echo "SUSFS already answers on this kernel ($("$SUSFS_BIN" show version 2>/dev/null)): refusing to load $NAME on top of it." >> "$LOG"
            echo "A SUSFS implementation is already active on this kernel, so the saved module was NOT loaded. Stacking two of them is not supported - remove one." > "$WARNING"
            exit 0
        fi
        ;;
esac

# ---- pre-load integrity ----------------------------------------------------------------
# A persisted .ko outlives the kernel it was built for: flash a new one and this file is now
# for the wrong one.  `ksud insmod` then fails and the failure path below DISABLES boot
# loading, so the user loses the configuration as well as the load, with "make sure it was
# built for this device's kernel" as the only clue.  Checking first turns that into a precise
# message and KEEPS the configuration, because a kernel change is not a bad module.
#
# /proc/sys/kernel/osrelease, not `uname -r`: susfs's set_uname spoofs uname(2) and leaves the
# sysctl alone, so matching vermagic against uname would fail on a device that spoofs it.
# The sha256 is recorded, not enforced: this loader loads whatever the user configured, so
# there is no authoritative hash to compare against - it is in the log to say exactly which
# bytes were loaded, which is what a later "why did it stop working" needs.
KREL=$(cat /proc/sys/kernel/osrelease 2>/dev/null || true)
[ -n "$KREL" ] || KREL=$(uname -r)
KO_VM="$(strings "$PERSIST" 2>/dev/null | sed -n 's/^vermagic=\([^ ]*\).*/\1/p' | head -1)"
echo "module: $(stat -c %s "$PERSIST" 2>/dev/null) bytes, sha256 $(sha256sum "$PERSIST" 2>/dev/null | cut -d' ' -f1)" >> "$LOG"
echo "vermagic: ${KO_VM:-unreadable} / running: $KREL" >> "$LOG"
if [ -n "$KO_VM" ] && [ "$KO_VM" != "$KREL" ]; then
    echo "WARNING: the saved module was built for $KO_VM but this kernel is $KREL - NOT loading it." >> "$LOG"
    echo "The saved kernel module was built for $KO_VM and this kernel is $KREL, so it was not loaded. It is still configured: replace it from the WebUI with one built for this kernel." > "$WARNING"
    rm -f "$PENDING"
    sync
    exit 0
fi

touch "$PENDING"
sync
echo "Loading persistent module: $PERSIST" >> "$LOG"
"$KSUD" insmod "$PERSIST" >> "$LOG" 2>&1
RESULT=$?
echo "Exit code: $RESULT" >> "$LOG"

# NAME was read before the load (see the stacking check); publish it for the WebUI's live
# controls, which take a name rather than a path.
if [ -n "$NAME" ]; then
    printf '%s\n' "$NAME" > "$ROOT/loaded.name"
    chmod 600 "$ROOT/loaded.name"
fi

# ---- post-load assertion ---------------------------------------------------------------
# `insmod` returning 0 means the kernel took the image and init_module() did not fail; it does
# NOT mean the feature came up.  Check for the module where it should be visible - and treat
# "nowhere" as a NOTE rather than an error, because a module that hides itself is exactly what
# this one does: susfs_guard_lkm filters itself out of /proc/modules and /sys/module for every
# caller, root included, so for a susfs module the supercall interface is the only honest
# witness.
if [ "$RESULT" -eq 0 ]; then
    armed=unknown
    if [ -n "$NAME" ] && [ -d "/sys/module/$NAME" ]; then
        armed=yes
    elif [ -n "$NAME" ] && grep -q "^$NAME " /proc/modules 2>/dev/null; then
        armed=yes
    else
        case "$NAME" in
            susfs*)
                SUSFS_BIN=${SUSFS_BIN:-/data/adb/ksu/bin/ksu_susfs}
                if [ -x "$SUSFS_BIN" ] && v=$("$SUSFS_BIN" show version 2>/dev/null); then
                    armed=yes
                    echo "susfs answers: $v" >> "$LOG"
                fi
                ;;
        esac
    fi
    echo "armed: $armed" >> "$LOG"
    [ "$armed" = yes ] || echo "NOTE: insmod reported success but $NAME is not visible in /sys/module or /proc/modules and no interface answered - it may be hiding itself, or it may have loaded without arming." >> "$LOG"
fi

if [ "$RESULT" -eq 0 ] && [ -s "$HOOK" ]; then
    echo "--- post-insmod hook ---" >> "$LOG"
    sh "$HOOK" >> "$LOG" 2>&1
    echo "hook exit: $?" >> "$LOG"
fi

if [ "$RESULT" -ne 0 ]; then
    rm -f "$FLAG" "$PENDING" "$ROOT/loaded.name"
    sync
    # ksud reports its own exit code; the module's reason for refusing is in dmesg, and
    # nothing above would ever show it.  susfs_guard_lkm's hide gate is a FATAL init layer
    # from 2026-10-10 on, so "could not be supplied" is now a routine cause of a failed
    # load - not a wrong kernel - and the two deserve different advice.
    REASON=$(dmesg 2>/dev/null | grep -E 'refusing to load|Unknown symbol' | tail -1)
    if [ -n "$REASON" ]; then
        echo "kernel said: $REASON" >> "$LOG"
    fi
    case "$REASON" in
        *refusing\ to\ load*|*Unknown\ symbol*)
            echo "The saved kernel module was disabled: the kernel refused to load it because a symbol it needs could not be supplied. If this is susfs_guard_lkm, load it AFTER kernelsu.ko, or use susfs_insmod on a device without KernelSU." > "$WARNING"
            ;;
        *)
            echo "The saved kernel module failed to load and was disabled. Make sure it was built for this device's kernel." > "$WARNING"
            ;;
    esac
    echo "WARNING: persistent module failed to load; disabled." >> "$LOG"
fi

exit 0
