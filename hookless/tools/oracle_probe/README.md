# Active root/hiding-framework oracle probes

Beyond "does syscall N exist", detectors fingerprint frameworks by their
*control channels*. These run as an ordinary process and report which answer —
what a hostile app can see.

## Probes

- **`rootprobe.c`** (freestanding, needs `small_rt.h`) — the classic **KernelSU
  prctl oracle** `prctl(0xDEADBEEF, CMD_GET_VERSION=2, &out)` and the **susfs**
  command-range variant. Build like the other freestanding tools
  (`zig cc -target aarch64-linux ... -Wl,--entry=__start`, then `sstrip`).
- **`genlprobe.c`** (libc) — resolves **generic-netlink family names** via
  `CTRL_CMD_GETFAMILY`. Build: `aarch64-linux-android24-clang -O2 genlprobe.c -o genlprobe`.

## Findings on OP15 (ReSukiSU + NoMount, 6.12.23-android16)

| oracle | result | meaning |
|--------|--------|---------|
| KSU `prctl 0xDEADBEEF`/GET_VERSION | **no response** (root & shell; confirmed with a libc probe too) | the best-known KernelSU detection vector is **closed** here (ReSukiSU hardening) |
| susfs `prctl` SHOW_VERSION | no response | no susfs (NoMount replaces it) |
| genl family `nlctrl` | PRESENT id=16 (positive control) | probe works |
| **genl family `nomount`** | **PRESENT id=23 ver=1, from uid 2000** | ⚠️ **NoMount is directly discoverable** by its own control-channel name |
| genl family (bogus) | absent (negative control) | — |

## ⚠️ The `nomount` genl-family leak

`NOMOUNT_GENL_NAME "nomount"` (`hookless/src/nomount.h`) registers a named
generic-netlink family. Any process that can open `NETLINK_GENERIC` can resolve
that name and confirm NoMount is loaded — no mounts, files, or syscalls involved.
This is the one active oracle that fires on an otherwise-clean device, and it
undercuts the zero-mount / Holmes-Normal invisibility goal.

**Severity depends on SELinux:** reachable from the `shell` domain (proven). Whether
the `untrusted_app` domain (a Play-store app) may create a `netlink_generic_socket`
was **not verified** here (no `sesearch` on-device); AOSP base policy tends to deny
it to `untrusted_app`, which would limit the oracle to shell/root/system contexts —
but OEM policy and ADB/system-side detectors are unconfirmed. Confirm with a probe
run from an actual `untrusted_app`-context APK.

**Mitigation options** (kernel + `nm` client must change together):
- Rename the family to something innocuous, or randomize it per-build and pass the
  name to the client out-of-band.
- Drop the *named* genl family entirely — use a private raw-netlink protocol number,
  or gate `CTRL_CMD_GETFAMILY` visibility.
