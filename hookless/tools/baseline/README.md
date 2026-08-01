# Baseline present-maps

Reference syscall present-sets (one syscall number per line, from `scan START END`)
for diffing with `../syscall_scan/fingerprint.sh STOCK MODDED`.

- **`op15-6.12-stock.map`** — bone-stock OnePlus 15 GKI kernel
  (`6.12.23-android16-5-gb2a876903b49-ab14541642-4k`, stock `boot.img`, NoMount
  absent). 264 present, highest = 462 (`mseal`).
- **`op15-6.12-nomount-device.map`** — same device running the ReSukiSU/NoMount
  kernel.

**Result:** the two are byte-identical —
`fingerprint.sh op15-6.12-stock.map op15-6.12-nomount-device.map` reports
`+0 / -0` → **NoMount adds zero syscall-table footprint** (empirically verified
on-device, same GKI version). KSU/susfs (LKM via init_boot) likewise add no
syscall — they use a magic `prctl`, not a new syscall number.
