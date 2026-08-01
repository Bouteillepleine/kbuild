# Baseline present-maps

Reference syscall present-sets (one syscall number per line, from `scan START END`)
for diffing with `../syscall_scan/fingerprint.sh STOCK MODDED`.

- **`op15-6.12-nomount-device.map`** — runtime scan of a OnePlus 15 running the
  ReSukiSU/NoMount kernel (`6.12.23-android16`). Highest present = 462 (`mseal`),
  no syscall beyond the canonical arm64 table (no custom-syscall footprint).

TODO: add `op15-6.12-stock.map` — a scan of the bone-stock OOS kernel of the same
version — so the diff directly proves NoMount adds zero syscalls vs stock.
