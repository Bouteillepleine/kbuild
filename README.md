# Kernel module loader

Allows to install Susfs4ksu module.

## How this works

This module does one job: load a kernel module at boot.

1. You flash a kernel. Its zip carries `susfs_guard_lkm.ko`, built against that exact
   kernel, and the flash drops it in `Download`.
2. You install this module. It finds that file, checks it matches the running kernel, and
   keeps it.

**One module per kernel.** It is compiled against the kernel it ships with, so a module
from another build or another device will not load. That is deliberate.

The WebUI lets you pick a different `.ko`, unload or reload without rebooting, and see
what is loaded now.

Pack the contents of this branch (not the branch directory itself) into a zip to install.
