# Kernel module loader

The loader half of the susfs-with-every-kernel setup: a KernelSU module that loads a
`.ko` at boot, with bootloop protection and a WebUI.

The builders bundle `susfs_guard_lkm.ko` inside each kernel's AnyKernel3 zip, and
`anykernel.sh` drops it in `/sdcard/Download` while flashing. Installing this module
then adopts it automatically, if exactly one module on storage matches `uname -r`.

- `customize.sh` - adopts a matching `.ko` at install (loose file, or out of an AK3 zip)
- `post-fs-data.sh` - loads it at boot; arms a marker first so a module that panics
  inside `insmod` is disabled on the next boot instead of being retried forever
- `post-insmod.sh.susfs` - optional susfs rules, applied after the module is really in
  the kernel, which is the only correctly-ordered place for a module's own configuration
- `webroot/` - pick/load/unload/reload without a reboot

Pack the contents of this branch (not the branch directory itself) into a zip to install.
