#!/bin/sh
# The WebUI's gate tile, run as SHIPPED: the classifier is sliced out of webroot/index.html
# and executed, so this tests the real code rather than a transcription of it.
#
# It exists because the tile silently mis-read the kernel's gate line twice - v2.6 against the
# 2026-10-10 rewording, v2.10 against the 10-11 one - and both times a working DenyList gate
# was reported as "Unknown".  Three wordings in two days is the reason the classifier tests the
# exceptional states and treats an unknown gate line as UNRECOGNISED rather than guessing.
set -u
cd "$(dirname "$0")/.." || exit 1

if ! command -v node >/dev/null 2>&1; then
    # Skipping silently is how a dead test pretends to pass, so CI must never take this path.
    if [ "${CI:-}" = "true" ]; then
        echo "  FAIL node is required to run the gate-tile test in CI"
        exit 1
    fi
    echo "  SKIP no node on this host - CI runs this for real"
    exit 0
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/--- BEGIN gate-tile classifier/,/--- END gate-tile classifier ---/p' \
    webroot/index.html > "$T/c.js"
if ! grep -q 'function classifyGate' "$T/c.js"; then
    echo "  FAIL could not slice classifyGate out of webroot/index.html (markers moved?)"
    exit 1
fi

cat >> "$T/c.js" <<'JS'
const cases = [
  // [ the kernel's line, expected label ]
  ["susfs_guard_lkm: hide gate: following KernelSU's DenyList (ksu_uid_should_umount at ffffffe2eac29618) - the manager and allow_su apps are NOT hidden from", "DenyList"],
  ["susfs_guard_lkm: ksu_umount_gate: KernelSU's ksu_uid_should_umount is present - the hide gates answer it (issue #34)", "DenyList"],
  ["susfs_guard_lkm: ksu_umount_gate: resolved ksu_uid_should_umount at ffffffedece29618 - the hide gates now answer KernelSU (issue #34)", "DenyList"],
  ["susfs_guard_lkm: hide gate: ksu_uid_should_umount is not resolvable (KernelSU built as a module, or absent) - falling back to uid >= 10000, which hides from EVERY app including the manager", "uid >= 10000"],
  ["susfs_guard_lkm: is_magisk=1 (passed by the loader) - KernelSU's ksu_uid_should_umount is never asked, so the hide gates keep the uid >= 10000 rule", "uid >= 10000"],
  ["susfs_guard_lkm: neither is_magisk=1 nor KernelSU's ksu_uid_should_umount is present - refusing to load rather than hiding from nobody", "Refused"],
  // a FOURTH wording nobody has written yet: must not be guessed at
  ["susfs_guard_lkm: ksu_umount_gate: some wording from a future release", "Unrecognised"],
  ["", "—"],
  ["susfs_guard_lkm: sus_path: hooks armed", "—"],
];
let bad = 0;
for (const [line, want] of cases) {
  const got = classifyGate(line).label;
  const ok = got === want;
  if (!ok) bad++;
  console.log((ok ? "  ok   " : "  FAIL ") + got.padEnd(14) + "(want " + want + ")  <- " + line.slice(0, 54));
}
// the dangerous state must never be reported as safe, whatever the wording
const fb = classifyGate("susfs_guard_lkm: ksu_umount_gate: is_magisk=1 and the hide gates answer KernelSU");
if (fb.label !== "uid >= 10000") { console.log("  FAIL a line with BOTH markers must report the fallback, not DenyList"); bad++; }
else console.log("  ok   fallback wins over a success marker in the same line");
if (bad) { console.log("\n" + bad + " gate-tile case(s) failed"); process.exit(1); }
console.log("\nall gate-tile cases passed");
JS

node "$T/c.js"
