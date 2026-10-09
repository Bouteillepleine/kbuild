#!/system/bin/sh
# Runs once, at install. Adopts a kernel module that was built for THIS kernel so the
# common case needs no trip through the WebUI picker.
#
# Two sources, because a kernel flash does not always leave the module on storage:
#   *.ko      - anykernel.sh copied it out during the flash (Android, or decrypted recovery)
#   AK3*.zip  - it did not (undecrypted recovery), but the zip you flashed is still here
#
# Deliberately conservative: it adopts only when exactly ONE candidate matches the running
# kernel, and never touches an already-configured module. Anything ambiguous is left to the
# WebUI, which shows every candidate and says why each does or does not match.

ROOT=/data/adb/lkm
mkdir -p "$ROOT"; chmod 700 "$ROOT"

ui_print " "
if [ -s "$ROOT/persistent.ko" ]; then
    ui_print "- A module is already configured; leaving it alone."
    ui_print "- Use the WebUI to replace it."
    return 0 2>/dev/null || exit 0
fi

KREL=$(uname -r)
ui_print "- Looking for a module built for $KREL"

# vermagic out of a .ko on disk. The field is NUL-separated in .modinfo, so anchor on it.
ko_vermagic() {
    strings "$1" 2>/dev/null | sed -n 's/^vermagic=\([^ ]*\).*/\1/p' | head -1
}

TMP=$ROOT/.adopt.ko
FOUND=0
MATCH=
MATCH_FROM=

UNZIP=$(command -v unzip 2>/dev/null)
[ -n "$UNZIP" ] || { [ -x /data/adb/ksu/bin/busybox ] && UNZIP="/data/adb/ksu/bin/busybox unzip"; }

# Priority order, and the FIRST directory that yields anything wins. Download is where a
# flash leaves the module, so it decides; /data/local/tmp is only consulted when Download
# had nothing, because that is a scratch directory and on a developer's phone it is full of
# modules from other work - measured: 4 stale susfs builds there, which would otherwise
# make every install ambiguous forever.
for d in /sdcard/Download /storage/emulated/0/Download /sdcard /data/local/tmp; do
    [ -d "$d" ] || continue

    for f in "$d"/*.ko; do
        [ -f "$f" ] || continue
        [ "$(ko_vermagic "$f")" = "$KREL" ] || continue
        FOUND=$((FOUND + 1)); MATCH=$f; MATCH_FROM=$f
    done

    if [ -n "$UNZIP" ]; then
        for z in "$d"/AK3*.zip; do
            [ -f "$z" ] || continue
            $UNZIP -p "$z" susfs_guard_lkm.ko > "$TMP" 2>/dev/null || continue
            [ -s "$TMP" ] || continue
            [ "$(ko_vermagic "$TMP")" = "$KREL" ] || continue
            FOUND=$((FOUND + 1)); MATCH=$TMP; MATCH_FROM="$z (bundled)"
        done
    fi

    [ "$FOUND" -gt 0 ] && break
done

if [ "$FOUND" -eq 0 ]; then
    rm -f "$TMP"
    ui_print "- No module for this kernel found."
    ui_print "- Pick one in the WebUI when you have it."
    return 0 2>/dev/null || exit 0
fi

if [ "$FOUND" -gt 1 ]; then
    rm -f "$TMP"
    ui_print "- $FOUND modules match this kernel; not guessing."
    ui_print "- Choose one in the WebUI."
    return 0 2>/dev/null || exit 0
fi

cat "$MATCH" > "$ROOT/persistent.ko" && chmod 600 "$ROOT/persistent.ko"
NAME=$(strings "$ROOT/persistent.ko" 2>/dev/null | sed -n 's/^name=\([A-Za-z0-9_-]\{1,\}\)$/\1/p' | head -1)
[ -n "$NAME" ] && { printf '%s\n' "$NAME" > "$ROOT/persistent.name"; chmod 600 "$ROOT/persistent.name"; }
touch "$ROOT/persistent.enabled"
rm -f "$TMP" "$ROOT/persistent.warning" "$ROOT/persistent.boot_pending"
sync

ui_print "- Adopted ${NAME:-module} from $MATCH_FROM"
ui_print "- It will load at every boot. Bootloop protection is armed."
