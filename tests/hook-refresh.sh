#!/bin/sh
# post-fs-data.sh refreshes the armed post-insmod hook on a module update, but must NEVER
# overwrite one the user edited.  The whole decision is the sha256 marker, so these cases are
# the contract: neutering the "is it still what we armed" test makes 4 and 5 fail.
set -u
cd "$(dirname "$0")/.." || exit 1

BLOCK=$(mktemp); T=$(mktemp -d)
trap 'rm -rf "$BLOCK" "$T"' EXIT

A=$(grep -n '^# ---- keep the armed hook current' post-fs-data.sh | cut -d: -f1)
B=$(grep -n '^if \[ ! -f "\$FLAG" \]' post-fs-data.sh | cut -d: -f1)
if [ -z "${A:-}" ] || [ -z "${B:-}" ] || [ "$A" -ge "$B" ]; then
    echo "  FAIL could not locate the refresh block in post-fs-data.sh (did it move?)"
    exit 1
fi
sed -n "${A},$((B - 2))p" post-fs-data.sh > "$BLOCK"

pass=0; fail=0
OLDSUM=$(printf 'OLD PRISTINE\n' | sha256sum | cut -d' ' -f1)

setup() {
    rm -rf "$T"; mkdir -p "$T/lkm" "$T/mod"
    printf 'NEW TEMPLATE\n' > "$T/mod/post-insmod.sh.susfs"
    : > "$T/lkm/log"
}
runblock() {
    ( ROOT="$T/lkm"; MODDIR="$T/mod"; HOOK="$T/lkm/post-insmod.sh"; LOG="$T/lkm/log"
      . "$BLOCK" )
}
chk() { # label  expected-hook-content  TEMPLATE|OLD|none  expected-log-substring
    lbl=$1; eh=$2; em=$3; el=${4:-}
    gh=$(cat "$T/lkm/post-insmod.sh" 2>/dev/null || true)
    gm=$(cat "$T/lkm/post-insmod.sha256" 2>/dev/null || true)
    case $em in
        TEMPLATE) wm=$(sha256sum "$T/mod/post-insmod.sh.susfs" | cut -d' ' -f1) ;;
        OLD)      wm=$OLDSUM ;;
        *)        wm="" ;;
    esac
    ok=1; why=
    [ "$gh" = "$eh" ] || { ok=0; why="hook content: got [$gh] want [$eh]"; }
    [ "$gm" = "$wm" ] || { ok=0; why="marker: got [$gm] want [$wm]"; }
    if [ -n "$el" ] && ! grep -q "$el" "$T/lkm/log" 2>/dev/null; then
        ok=0; why="log does not mention: $el"
    fi
    if [ "$ok" = 1 ]; then pass=$((pass + 1)); echo "  ok   $lbl"
    else fail=$((fail + 1)); echo "  FAIL $lbl -- $why"; fi
}

setup; runblock
chk "not armed: nothing to do" "" none

setup; printf 'NEW TEMPLATE\n' > "$T/lkm/post-insmod.sh"; runblock
chk "current but unmarked: record the marker" "NEW TEMPLATE" TEMPLATE

setup; printf 'OLD PRISTINE\n' > "$T/lkm/post-insmod.sh"
printf '%s\n' "$OLDSUM" > "$T/lkm/post-insmod.sha256"; runblock
chk "pristine older copy: refresh it" "NEW TEMPLATE" TEMPLATE "Refreshed the post-insmod hook"

setup; printf 'OLD PRISTINE\n' > "$T/lkm/post-insmod.sh"; runblock
chk "stale and unmarked: keep, say why" "OLD PRISTINE" none "nothing recorded what armed it"

setup; printf 'MY EDITS\n' > "$T/lkm/post-insmod.sh"
printf '%s\n' "$OLDSUM" > "$T/lkm/post-insmod.sha256"; runblock
chk "EDITED: keep it, say why" "MY EDITS" OLD "has been edited"

setup; printf 'NEW TEMPLATE\n' > "$T/lkm/post-insmod.sh"
sha256sum "$T/mod/post-insmod.sh.susfs" | cut -d' ' -f1 > "$T/lkm/post-insmod.sha256"; runblock
chk "current and marked: idempotent" "NEW TEMPLATE" TEMPLATE
if grep -qE 'Refreshed|NOTE:' "$T/lkm/log" 2>/dev/null; then
    fail=$((fail + 1)); echo "  FAIL current and marked: logged noise for a no-op"
else
    pass=$((pass + 1)); echo "  ok   current and marked: silent"
fi

setup; printf 'OLD PRISTINE\n' > "$T/lkm/post-insmod.sh"
printf '%s\n' "$OLDSUM" > "$T/lkm/post-insmod.sha256"
runblock; : > "$T/lkm/log"; runblock
chk "a second boot changes nothing" "NEW TEMPLATE" TEMPLATE

echo
if [ "$fail" != 0 ]; then
    echo "$fail hook-refresh case(s) failed"
    exit 1
fi
echo "all hook-refresh cases passed"
