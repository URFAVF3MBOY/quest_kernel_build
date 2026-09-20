#!/bin/bash
# Cross-compiles oculus-linux-kernel (oculus-quest2-kernel-master) for real
# Quest 2 hardware from a supplied kernel.config.
#
# Usage:
#   Put your kernel.config next to this script, then:
#     ./build.sh
#
#   To also get an image you can actually boot on the headset, drop a stock
#   boot.img pulled from that headset next to this script (or point
#   REAL_BOOT_IMG at one) - step 5b repacks it around the new kernel:
#     REAL_BOOT_IMG=/path/to/boot.img ./build.sh
#     fastboot boot build/oculus-quest2-device-kernel/boot-repacked.img
#   `fastboot boot` is one-shot and non-destructive; it does not write the
#   boot partition. Never `fastboot flash boot` a kernel built here.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR"
KERNEL_CONFIG="$WORK_DIR/kernel.config"
KERNEL_DIR="$WORK_DIR/oculus-linux-kernel"
TOOLCHAIN_DIR="$WORK_DIR/toolchain"
CLANG_DIR="$TOOLCHAIN_DIR/clang-r450784e"
BUILD_DIR="$WORK_DIR/build"
# Pin to a specific commit instead of tracking branch HEAD. Empty = branch
# HEAD (whatever oculus-quest2-kernel-master currently points at).
KERNEL_COMMIT="${KERNEL_COMMIT:-}"

# Stock boot.img pulled from the device you are going to boot on, e.g.
#   adb root && adb shell dd if=/dev/block/bootdevice/by-name/boot_a of=/data/local/tmp/boot.img
#   adb pull /data/local/tmp/boot.img
# If present, step 5b repacks it around the kernel built here (keeping its
# ramdisk and every header field) into a `fastboot boot`-able image. If
# absent, that step is skipped and only the raw kernel artifacts are built.
REAL_BOOT_IMG="${REAL_BOOT_IMG:-$WORK_DIR/boot.img}"

# --- How a self-built kernel gets past /system's dm-verity ------------------
# The stock cmdline carries `buildvariant=user`. With that,
# drivers/md/dm-android-verity.c verifies /system's verity metadata
# signature against the kernel's *built-in* trusted keyring
# (CONFIG_SYSTEM_TRUSTED_KEYS) on every boot. That keyring can only be
# populated with Meta's own signing certificate, which is not in this
# source tree - so on any kernel built from public sources the check fails,
# `android_verity_ctr()` bails, /system never mounts, and init hangs
# forever with nothing in pstore to say why. Note the unlocked-bootloader
# escape hatch does NOT cover this: `is_unlocked()` is only consulted when
# the metadata is *malformed*, not when its signature fails to verify.
#
# `buildvariant=eng` is the supported way out, and it is a one-word cmdline
# change rather than a certificate hunt. It is checked much earlier, in
# android_verity_ctr():
#
#     if (is_eng())
#             return create_linear_device(ti, dev, target_device);
#
# i.e. before the metadata is read, before the key id is looked up and
# before the keyring is touched at all - /system is mapped as a plain
# linear device, which is exactly what an eng build does. `buildvariant=`
# is parsed by dm-android-verity.c and nothing else in the tree, so this
# affects no other subsystem, needs no source patch, and leaves
# CONFIG_SYSTEM_TRUSTED_KEYS empty.
#
# Trade-off, stated plainly: /system is then mounted without integrity
# checking. That is inherent to booting a kernel Meta did not sign - there
# is no configuration in which a self-built kernel both verifies /system
# and boots. Set VERITY_BYPASS=0 to keep the stock cmdline verbatim.
VERITY_BYPASS="${VERITY_BYPASS:-1}"

# Kernel cmdline to bake into the repacked boot.img. Unset (the default)
# means "take the stock image's own cmdline and apply the VERITY_BYPASS
# edit to it" - the stock cmdline carries board-specific parameters
# (androidboot.hardware, etc.) that must survive, so it is edited rather
# than replaced. Any non-empty value here wins and is used verbatim.
KERNEL_CMDLINE="${KERNEL_CMDLINE-}"

log() { echo -e "\n=== $* ===\n"; }

if [ ! -f "$KERNEL_CONFIG" ]; then
  echo "ERROR: expected kernel.config at $KERNEL_CONFIG" >&2
  exit 1
fi

# --- 1. Host dependencies -----------------------------------------------
log "Installing host build dependencies"
sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential bc bison flex libssl-dev libelf-dev \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  git wget cpio unzip rsync kmod device-tree-compiler python3-dev make \
  libncurses-dev gcc-12 g++-12 dwarves expect

# --- 2. Kernel source -----------------------------------------------------
if [ ! -d "$KERNEL_DIR/.git" ]; then
  log "Cloning oculus-linux-kernel"
  git clone https://github.com/facebookincubator/oculus-linux-kernel.git "$KERNEL_DIR"
fi

cd "$KERNEL_DIR"

sed -i '/source "drivers\/staging\/oculus\/internal\/Kconfig"/d' \
    "$KERNEL_DIR/drivers/staging/oculus/Kconfig"

sed -i '/obj-y[[:space:]]*+=[[:space:]]*internal\//d' \
    "$KERNEL_DIR/drivers/staging/oculus/Makefile"

cd "$WORK_DIR"

# --- 3. Vendor toolchain (AOSP prebuilt Clang r450784e / 14.0.7) -----------
mkdir -p "$TOOLCHAIN_DIR"
if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  log "Fetching clang-r450784e toolchain"
  rm -rf "$CLANG_DIR"
  mkdir -p "$CLANG_DIR"
  curl -sL -o "$TOOLCHAIN_DIR/clang-r450784e.tar.gz" \
    "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master-kernel-build-2022/clang-r450784e.tar.gz"
  tar -xzf "$TOOLCHAIN_DIR/clang-r450784e.tar.gz" -C "$CLANG_DIR"
  rm -f "$TOOLCHAIN_DIR/clang-r450784e.tar.gz"
fi

# --- 3b. mkbootimg/unpack_bootimg scripts (AOSP source, not the apt package) --
# Ubuntu 22.04's "mkbootimg" apt package is an old revision that predates
# unpack_bootimg's --format=mkbootimg flag - it errors with "unrecognized
# arguments: --format=mkbootimg". Pull the current scripts from AOSP directly
# instead of depending on whatever the distro happens to ship.
MKBOOTIMG_DIR="$TOOLCHAIN_DIR/mkbootimg-src"
if [ ! -d "$MKBOOTIMG_DIR/.git" ]; then
  log "Fetching mkbootimg/unpack_bootimg scripts from AOSP"
  rm -rf "$MKBOOTIMG_DIR"
  git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg "$MKBOOTIMG_DIR"
fi

export PATH="$CLANG_DIR/bin:$PATH"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=0
export CROSS_COMPILE=aarch64-linux-gnu-
export REAL_CC=clang
export KCFLAGS="-march=armv8.1-a"

# --- 4. Apply source-tree fixes --------------------------------------------
log "Applying kernel source fixes (oculus-kernel-fixes.patch)"
cd "$KERNEL_DIR"
if git apply --check "$WORK_DIR/oculus-kernel-fixes.patch" 2>/dev/null; then
  git apply "$WORK_DIR/oculus-kernel-fixes.patch"
elif git apply --check --reverse "$WORK_DIR/oculus-kernel-fixes.patch" 2>/dev/null; then
  echo "Patch already applied, skipping."
else
  echo "ERROR: oculus-kernel-fixes.patch does not apply cleanly and is not already applied." >&2
  exit 1
fi

# --- 5. Build the real Quest 2 device kernel -------------------------------
log "Building real-device kernel (your kernel.config)"
cp "$KERNEL_CONFIG" .config
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
make ARCH=$ARCH LLVM=1 LLVM_IAS=0 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang KCFLAGS="-march=armv8.1-a" olddefconfig

make ARCH=$ARCH LLVM=1 LLVM_IAS=0 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang KCFLAGS="-march=armv8.1-a" \
  -j"$(nproc)" Image dtbs
# Only produces output if this kernel.config has
# CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y; harmless no-op otherwise.
make ARCH=$ARCH LLVM=1 LLVM_IAS=0 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang KCFLAGS="-march=armv8.1-a" \
  -j"$(nproc)" Image.gz-dtb || true

OUT_DEVICE="$BUILD_DIR/oculus-quest2-device-kernel"
mkdir -p "$OUT_DEVICE/dtbs"
cp arch/arm64/boot/Image "$OUT_DEVICE/Image"
if [ -f arch/arm64/boot/Image.gz-dtb ]; then
  cp arch/arm64/boot/Image.gz-dtb "$OUT_DEVICE/Image.gz-dtb"
fi
cp vmlinux "$OUT_DEVICE/vmlinux"
cp System.map "$OUT_DEVICE/System.map"
cp .config "$OUT_DEVICE/.config"
find arch/arm64/boot/dts -iname "*.dtb" -exec cp {} "$OUT_DEVICE/dtbs/" \;
find arch/arm64/boot/dts -iname "*.dtbo" -exec cp {} "$OUT_DEVICE/dtbs/" \;
log "Real-device kernel saved to $OUT_DEVICE"

# --- 5b. Repack a real boot.img around the kernel just built ---------------
# A bare Image/Image.gz-dtb is not bootable on its own: the device needs the
# stock ramdisk and the stock header (load offsets, page size, os_version)
# alongside it. Uses the AOSP mkbootimg/unpack_bootimg scripts fetched in
# step 3b, so the header format matches whatever produced the stock image.
if [ -f "$REAL_BOOT_IMG" ]; then
  log "Repacking $REAL_BOOT_IMG with the newly built kernel via mkbootimg"

  [ -f "$MKBOOTIMG_DIR/mkbootimg.py" ] || { echo "ERROR: mkbootimg.py not found at $MKBOOTIMG_DIR" >&2; exit 1; }
  [ -f "$MKBOOTIMG_DIR/unpack_bootimg.py" ] || { echo "ERROR: unpack_bootimg.py not found at $MKBOOTIMG_DIR" >&2; exit 1; }

  BOOTIMG_UNPACK_DIR="$BUILD_DIR/bootimg-unpacked"
  rm -rf "$BOOTIMG_UNPACK_DIR"
  mkdir -p "$BOOTIMG_UNPACK_DIR"

  # unpack_bootimg --format=mkbootimg extracts every component into --out
  # AND prints an already shell-quoted mkbootimg command line reproducing
  # this image's exact header - cmdline, base, all four offsets, pagesize,
  # os_version/os_patch_level, header version - with --kernel/--ramdisk
  # pointing at what it just extracted. Capture that verbatim so nothing
  # has to be hand-transcribed.
  python3 "$MKBOOTIMG_DIR/unpack_bootimg.py" \
    --boot_img "$REAL_BOOT_IMG" \
    --out "$BOOTIMG_UNPACK_DIR" \
    --format=mkbootimg > "$BOOTIMG_UNPACK_DIR/bootimg_args.txt"

  log "Captured boot.img header args (repack command line)"
  cat "$BOOTIMG_UNPACK_DIR/bootimg_args.txt"

  # Work out the cmdline to bake in. Default: the stock one, with
  # buildvariant= rewritten to eng so dm-android-verity short-circuits
  # (see the VERITY_BYPASS comment at the top of this file).
  if [ -z "$KERNEL_CMDLINE" ]; then
    STOCK_CMDLINE="$(python3 - "$REAL_BOOT_IMG" << 'PYBOOTIMG'
import sys
# Android boot image header v0-v2: cmdline[512] at 0x40, extra_cmdline[1024]
# at 0x260. Both NUL-terminated; v0 images leave extra_cmdline empty.
b = open(sys.argv[1], "rb").read()
cmdline = b[0x40:0x40 + 512].split(b"\0")[0].decode()
extra = b[0x260:0x260 + 1024].split(b"\0")[0].decode()
print((cmdline + " " + extra).strip())
PYBOOTIMG
)"
    if [ "$VERITY_BYPASS" = "1" ]; then
      if printf '%s' "$STOCK_CMDLINE" | grep -q 'buildvariant='; then
        REPACK_CMDLINE="$(printf '%s' "$STOCK_CMDLINE" | sed 's/buildvariant=[^ ]*/buildvariant=eng/')"
      else
        REPACK_CMDLINE="$STOCK_CMDLINE buildvariant=eng"
      fi
      log "dm-android-verity bypass: buildvariant=eng (VERITY_BYPASS=0 keeps the stock cmdline)"
    else
      REPACK_CMDLINE="$STOCK_CMDLINE"
      log "VERITY_BYPASS=0 - keeping the stock cmdline verbatim"
    fi
  else
    REPACK_CMDLINE="$KERNEL_CMDLINE"
    log "Using explicit KERNEL_CMDLINE"
  fi
  echo "cmdline: $REPACK_CMDLINE"

  NEW_BOOT_IMG="$OUT_DEVICE/boot-repacked.img"

  # Prefer Image.gz-dtb if this config produced one; else fall back to the
  # bare Image (unpack_bootimg's captured args already carry the ramdisk
  # and every other header field either way).
  if [ -f "$OUT_DEVICE/Image.gz-dtb" ]; then
    REPACK_KERNEL="$OUT_DEVICE/Image.gz-dtb"
  else
    REPACK_KERNEL="$OUT_DEVICE/Image"
  fi

  # The captured args are shell-quoted (the cmdline value especially), so
  # this has to go through eval rather than a naive word-split. argparse
  # keeps the LAST occurrence of a repeated flag, so appending our own
  # --kernel/--cmdline after the captured args overrides exactly those two
  # and leaves every other header field and component untouched.
  eval python3 "\"$MKBOOTIMG_DIR/mkbootimg.py\"" \
    "$(cat "$BOOTIMG_UNPACK_DIR/bootimg_args.txt")" \
    --kernel "\"$REPACK_KERNEL\"" \
    --cmdline "\"$REPACK_CMDLINE\"" \
    -o "\"$NEW_BOOT_IMG\""

  log "Repacked boot image saved to $NEW_BOOT_IMG"
  echo "Boot it (non-destructive, one-shot, does NOT touch the boot partition):"
  echo "  fastboot boot $NEW_BOOT_IMG"
  echo "Then confirm it is your kernel and not a stock fallback:"
  echo "  adb shell uname -a           # build host/date should be yours"
  echo "  adb shell cat /proc/cmdline  # should show buildvariant=eng"
else
  log "No REAL_BOOT_IMG found at $REAL_BOOT_IMG - skipping boot.img repack"
  echo "Set REAL_BOOT_IMG=/path/to/stock/boot.img (or drop one at $WORK_DIR/boot.img)"
  echo "to also get a fastboot-bootable image."
fi

log "Done."
echo "Real Quest 2 kernel:  $OUT_DEVICE/"
if [ -f "${NEW_BOOT_IMG:-}" ]; then
  echo "Repacked boot.img:    $NEW_BOOT_IMG   (fastboot boot \"$NEW_BOOT_IMG\")"
fi
