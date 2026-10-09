#!/bin/sh
# Exercises customize.sh's adoption decision without a device or a real kernel.
#
# It rewrites three things in a copy of the script: the kernel release it compares
# against, the directories it scans, and where it writes. Everything else - the vermagic
# read, the content dedup, the two passes, the refusal rules - runs as shipped.
#
# These cases exist because two of them were real bugs: a flat file count made the
# ORDINARY post-flash state (module + the zip it came from) look ambiguous and refuse,
# and scanning a developer's /data/local/tmp made every install ambiguous forever.
set -eu
SRC=${1:-customize.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
KREL="6.12.58-test-kernel"
fail=0

mkko() { printf 'junk\0vermagic=%s SMP preempt mod_unload modversions aarch64\0name=%s\0junk' "$2" "${3:-susfs_guard_lkm}" > "$1"; }

run() {  # run <scandir> <rootdir>
  sed -e "s#^ROOT=/data/adb/lkm#ROOT=$2#" \
      -e "s#KREL=\$(uname -r)#KREL=$KREL#" \
      -e "s#/sdcard/Download /storage/emulated/0/Download /sdcard /data/local/tmp#$1#g" \
      "$SRC" > "$T/run.sh"
  ui_print() { :; }
  . "$T/run.sh"
}

check() { # check <name> <expected: adopt|refuse> <rootdir> [expected-sha-source]
  got=refuse; [ -s "$3/persistent.ko" ] && got=adopt
  if [ "$got" != "$2" ]; then echo "  FAIL $1: expected $2, got $got"; fail=$((fail+1)); return; fi
  if [ "$2" = adopt ] && [ -n "${4:-}" ]; then
    a=$(sha256sum "$3/persistent.ko" | cut -d' ' -f1); b=$(sha256sum "$4" | cut -d' ' -f1)
    [ "$a" = "$b" ] || { echo "  FAIL $1: adopted the wrong bytes"; fail=$((fail+1)); return; }
  fi
  echo "  ok   $1 ($got)"
}

# A: the ordinary post-flash state - the module AND the zip that carried it.
S=$T/a; R=$T/ar; mkdir -p "$S"
mkko "$S/susfs_guard_lkm.ko" "$KREL"
(cd "$S" && cp susfs_guard_lkm.ko x.ko && zip -q AK3_k.zip susfs_guard_lkm.ko && rm x.ko)
run "$S" "$R"; check "post-flash: one module, two names" adopt "$R" "$S/susfs_guard_lkm.ko"

# B: two genuinely different modules that both fit this kernel - must not guess.
S=$T/b; R=$T/br; mkdir -p "$S"
mkko "$S/one.ko" "$KREL"; mkko "$S/two.ko" "$KREL"; printf 'extra' >> "$S/two.ko"
run "$S" "$R"; check "two different modules" refuse "$R"

# C: undecrypted recovery - no loose .ko, only the zip.
S=$T/c; R=$T/cr; mkdir -p "$S/z"
mkko "$S/z/susfs_guard_lkm.ko" "$KREL"
(cd "$S/z" && zip -q ../AK3_k.zip susfs_guard_lkm.ko); rm -rf "$S/z"
run "$S" "$R"; check "zip only" adopt "$R"

# D: a module built for a different kernel must be ignored.
S=$T/d; R=$T/dr; mkdir -p "$S"
mkko "$S/other.ko" "6.12.23-some-other-kernel"
run "$S" "$R"; check "wrong vermagic" refuse "$R"

# E: never clobber a module the user already configured.
S=$T/e; R=$T/er; mkdir -p "$S" "$R"
mkko "$S/new.ko" "$KREL"; printf 'ALREADY' > "$R/persistent.ko"
run "$S" "$R"
[ "$(cat "$R/persistent.ko")" = "ALREADY" ] && echo "  ok   existing config untouched" \
  || { echo "  FAIL existing config was overwritten"; fail=$((fail+1)); }

# F: nothing to find.
S=$T/f; R=$T/fr; mkdir -p "$S"
run "$S" "$R"; check "empty storage" refuse "$R"

# G: Download holds the answer while a scratch directory holds other matching builds.
# Without "the first directory that yields anything wins", a developer's /data/local/tmp
# makes every install ambiguous forever - measured on a real device: 4 stale builds there.
S=$T/g; R=$T/gr; mkdir -p "$S/dl" "$S/tmp"
mkko "$S/dl/susfs_guard_lkm.ko" "$KREL"
mkko "$S/tmp/old1.ko" "$KREL"; printf 'a' >> "$S/tmp/old1.ko"
mkko "$S/tmp/old2.ko" "$KREL"; printf 'bb' >> "$S/tmp/old2.ko"
run "$S/dl $S/tmp" "$R"; check "Download wins over a cluttered scratch dir" adopt "$R" "$S/dl/susfs_guard_lkm.ko"

[ "$fail" -eq 0 ] && echo "all adoption cases passed" || { echo "$fail case(s) failed"; exit 1; }
