# NoMount syscall-footprint tools & regression gate

NoMount is **hookless**: it hijacks per-inode/dentry operation vtables, it never
adds a syscall or touches `sys_call_table`. These tools prove and guard that
"zero added syscall" invariant — the syscall-table analogue of NoMount's
zero-mount goal (a clean syscall table is one less oracle a detector can probe).

## Regression gate — `.github/workflows/syscall-table-gate.yml`

| job | when | what it does |
|-----|------|--------------|
| **source-gate** | every push touching `hookless/**` | Fails if NoMount source/patches add `SYSCALL_DEFINE`, write `sys_call_table`, or introduce `__NR_*`. Fast, deterministic, no build — the enforcing gate. |
| **scanner-build** | same | Builds the freestanding on-device scanner (`scan-arm64`, `sctest-arm64`, `sctest-arm`) with Zig + `sstrip`, uploads as artifacts. |
| **vmlinux-audit** | `workflow_dispatch` with `vmlinux_url` | Downloads a real vmlinux (from the debug builder) and fails on any injected custom syscall wrapper. Empirical confirmation. |

## Tools

- **`syscall_table_dump.sh <vmlinux> [--fail-on-custom] [--out MAP]`** — audits a
  built kernel by inspecting syscall *wrapper symbols* (`__arm64_sys_<name>`): any
  wrapper not in the canonical arm64 table is an injected syscall. Relocation-proof
  (no KASLR/RELA parsing). Best-effort present-map via `sys_call_table` RELA addends.
- **`syscall_names_arm64.txt`** — canonical `num name` table (from `asm-generic/unistd.h`),
  bundled so the gate is self-contained.
- **`syscall_scan/`** — the on-device tooling (freestanding, from backslashxx's
  `small_rt`):
  - `sctest N` — is syscall N present? (single probe; arm64 + arm)
  - `scan START END` — print the kernel's present-set (range scan; arm64 only —
    uses hardware division). Skips hazardous nullary syscalls (`vhangup`, `ppoll`,
    `rt_sigreturn`→SIGSEGV, `seccomp`→self-SIGKILL, …).
  - `sstrip.c` — portable super-strip (drops the section-header table `-s` leaves).
  - `fingerprint.sh` — audit one present-map (flags unnamed/custom) or diff two
    (stock vs modded) with syscall names; empty diff ⇒ zero syscall-table footprint.

## Device usage

```bash
adb push scan-arm64 /data/local/tmp/scan && adb shell chmod 755 /data/local/tmp/scan
adb shell /data/local/tmp/scan 0 600 > nomount.map      # this kernel's present-set
bash syscall_scan/fingerprint.sh stock.map nomount.map  # labelled diff
```

`baseline/` holds reference present-maps for diffing (see its README).
