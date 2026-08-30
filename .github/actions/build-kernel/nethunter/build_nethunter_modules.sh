#!/usr/bin/env bash
# External-module build step for Nethunter Wi-Fi injection drivers.
# Runs AFTER the kernel build, against its O= out dir, so vermagic +
# modversion CRCs + signature match the flashed kernel by construction.
# Config-agnostic: inherits the kernel's own .config / toolchain / signing key.
set -euo pipefail

# --- inputs (export before calling) -----------------------------------------
: "${KERNEL_SRC:?KBUILD dir with .config + Module.symvers (the O= out dir)}"
: "${OUT_DIR:=$PWD/nethunter_modules}"          # where signed .ko land
: "${ARCH:=arm64}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${KMAKE:=}"                                   # match the kernel job, e.g. "LLVM=1 LLVM_IAS=1"
: "${STRIP:=${CROSS_COMPILE}strip}"             # llvm-strip when building with LLVM=1
# Module.symvers of on-device modules the drivers link against (cfg80211). This
# supplies the DEVICE's real CRCs so the .ko loads on the running kernel WITHOUT
# adding cfg80211 to the common kernel (which bootloops OP15).
: "${EXTRA_SYMVERS:=}"
# driver list: "clone_url@git_sha". Pin SHAs — never a moving branch.
: "${DRIVERS:?space-separated list of url@sha}"
# per-driver source patches: $PATCH_DIR/<repo-name>/*.patch, applied in sort order.
: "${PATCH_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches}"

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- resolve signing params from the KERNEL's config (not hardcoded) --------
cfg="$KERNEL_SRC/.config"
sig_hash="$(sed -n 's/^CONFIG_MODULE_SIG_HASH="\(.*\)"/\1/p' "$cfg")"; sig_hash="${sig_hash:-sha256}"
sig_key="$KERNEL_SRC/$(sed -n 's/^CONFIG_MODULE_SIG_KEY="\(.*\)"/\1/p' "$cfg")"
sig_crt="${sig_key%.pem}.x509"
kver="$(cat "$KERNEL_SRC/include/config/kernel.release")"
echo ":: target kernelrelease=$kver  sig_hash=$sig_hash"

manifest="$OUT_DIR/manifest.txt"; : > "$manifest"

for spec in $DRIVERS; do
  url="${spec%@*}"; sha="${spec##*@}"; name="$(basename "$url" .git)"
  src="$WORK/$name"
  echo "==> $name @ $sha"
  git clone --quiet "$url" "$src"
  ( cd "$src" && [ "$sha" != HEAD ] && git checkout --quiet "$sha" || true )

  # Source patches for this driver, if any. Unlike a build failure this is FATAL:
  # a patch that no longer applies means the pinned SHA moved out from under it,
  # and silently shipping the unpatched driver is the bug we are fixing.
  if [ -d "$PATCH_DIR/$name" ]; then
    for patch in "$PATCH_DIR/$name"/*.patch; do
      [ -e "$patch" ] || continue
      echo "   patch: $(basename "$patch")"
      git -C "$src" apply "$patch" \
        || { echo "!! patch $(basename "$patch") does not apply to $name@$sha" >&2; exit 1; }
    done
  fi

  # These out-of-tree Realtek Makefiles hardcode GCC-only warning flags; clang
  # rejects them under -Werror,-Wunknown-warning-option. Strip the known ones
  # and add a backstop so any remaining unknown warning flag can't fail the build.
  find "$src" -name 'Makefile' -exec sed -i \
    -e 's/-Wno-enum-int-mismatch//g' \
    -e 's/-Wno-stringop-overread//g' \
    -e 's/-Wno-restrict//g' \
    -e 's/-Wno-maybe-uninitialized//g' {} +

  # Non-fatal per driver: one bad driver must not sink the whole build.
  if ! make -j"$(nproc)" -C "$src" \
       ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" $KMAKE \
       KCFLAGS="-Wno-unknown-warning-option -Wno-error" \
       KBUILD_EXTRA_SYMBOLS="$EXTRA_SYMVERS" \
       KSRC="$KERNEL_SRC" KVER="$kver" modules; then
    echo "!! $name failed to build — skipping (non-fatal)" >&2; continue
  fi

  ko="$(find "$src" -maxdepth 1 -name '*.ko' | head -1)"
  [ -n "$ko" ] || { echo "!! no .ko produced for $name — skipping" >&2; continue; }

  # ORDER MATTERS: strip first, then sign (signature is appended last).
  "$STRIP" --strip-debug "$ko"
  if [ -x "$KERNEL_SRC/scripts/sign-file" ] && [ -f "$sig_key" ]; then
    "$KERNEL_SRC/scripts/sign-file" "$sig_hash" "$sig_key" "$sig_crt" "$ko"
    echo "   signed with $sig_hash"
  else
    echo "   ⚠️ signing key/tool absent — shipping unsigned (loads with taint if MODULE_SIG_FORCE off)"
  fi

  cp "$ko" "$OUT_DIR/"
  b="$(basename "$ko")"
  printf '%s\t%s\t%s\n' "$b" "$sha" "$(sha256sum "$OUT_DIR/$b" | cut -d" " -f1)" >> "$manifest"
  echo "   -> $OUT_DIR/$b"
done

echo ":: done. modules in $OUT_DIR"; cat "$manifest"
