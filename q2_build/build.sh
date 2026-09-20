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
#
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

# Stock boot.img pulled from the device you are going to boot on.
#
# Example:
#   adb root
#   adb shell dd if=/dev/block/bootdevice/by-name/boot_a \
#       of=/data/local/tmp/boot.img
#   adb pull /data/local/tmp/boot.img
#
# If present, step 5b repacks it around the newly built kernel.
REAL_BOOT_IMG="${REAL_BOOT_IMG:-$WORK_DIR/boot.img}"

# --- How a self-built kernel gets past /system's dm-verity ------------------
#
# The stock cmdline carries `buildvariant=user`. With that,
# drivers/md/dm-android-verity.c verifies /system's verity metadata
# signature against the kernel's built-in trusted keyring.
#
# `buildvariant=eng` causes dm-android-verity to bypass the verification
# path and create the linear device directly.
#
# Trade-off: /system is mounted without integrity checking.
#
# Set VERITY_BYPASS=0 to keep the stock cmdline verbatim.
VERITY_BYPASS="${VERITY_BYPASS:-1}"

# Kernel cmdline to bake into the repacked boot.img.
#
# Empty = take the stock image's cmdline and apply the VERITY_BYPASS edit.
# Non-empty = use this cmdline verbatim.
KERNEL_CMDLINE="${KERNEL_CMDLINE-}"

log() {
  echo -e "\n=== $* ===\n"
}

if [ ! -f "$KERNEL_CONFIG" ]; then
  echo "ERROR: expected kernel.config at $KERNEL_CONFIG" >&2
  exit 1
fi

# --- 1. Host dependencies ---------------------------------------------------
log "Installing host build dependencies"

sudo DEBIAN_FRONTEND=noninteractive apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential \
  bc \
  bison \
  flex \
  libssl-dev \
  libelf-dev \
  gcc-aarch64-linux-gnu \
  g++-aarch64-linux-gnu \
  git \
  wget \
  cpio \
  unzip \
  rsync \
  kmod \
  device-tree-compiler \
  python3-dev \
  make \
  libncurses-dev \
  gcc-12 \
  g++-12 \
  dwarves \
  expect

# --- 2. Kernel source -------------------------------------------------------
if [ ! -d "$KERNEL_DIR/.git" ]; then
  log "Cloning oculus-linux-kernel"

  git clone \
    https://github.com/facebookincubator/oculus-linux-kernel.git \
    "$KERNEL_DIR"
fi

cd "$KERNEL_DIR"

# ALWAYS use the latest commit currently pointed to by the upstream branch.
log "Fetching latest oculus-quest2-kernel-master"

git fetch --no-tags origin oculus-quest2-kernel-master

git checkout --detach origin/oculus-quest2-kernel-master

echo "Using kernel commit:"
git rev-parse HEAD

echo
echo "Kernel commit:"
git log -1 --oneline

# Remove references to Oculus internal kernel sources that are not included
# in the public repository.
sed -i \
  '/source "drivers\/staging\/oculus\/internal\/Kconfig"/d' \
  "$KERNEL_DIR/drivers/staging/oculus/Kconfig"

sed -i \
  '/obj-y[[:space:]]*+=[[:space:]]*internal\//d' \
  "$KERNEL_DIR/drivers/staging/oculus/Makefile"

cd "$WORK_DIR"

# --- 3. Vendor toolchain ----------------------------------------------------
# AOSP prebuilt Clang r450784e / 14.0.7

mkdir -p "$TOOLCHAIN_DIR"

if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  log "Fetching clang-r450784e toolchain"

  rm -rf "$CLANG_DIR"
  mkdir -p "$CLANG_DIR"

  curl -sL \
    -o "$TOOLCHAIN_DIR/clang-r450784e.tar.gz" \
    "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master-kernel-build-2022/clang-r450784e.tar.gz"

  tar -xzf \
    "$TOOLCHAIN_DIR/clang-r450784e.tar.gz" \
    -C "$CLANG_DIR"

  rm -f "$TOOLCHAIN_DIR/clang-r450784e.tar.gz"
fi

# --- 3b. mkbootimg/unpack_bootimg scripts ----------------------------------
#
# Ubuntu's packaged mkbootimg may be too old to support
# unpack_bootimg --format=mkbootimg, so fetch the AOSP scripts directly.

MKBOOTIMG_DIR="$TOOLCHAIN_DIR/mkbootimg-src"

if [ ! -d "$MKBOOTIMG_DIR/.git" ]; then
  log "Fetching mkbootimg/unpack_bootimg scripts from AOSP"

  rm -rf "$MKBOOTIMG_DIR"

  git clone \
    --depth 1 \
    https://android.googlesource.com/platform/system/tools/mkbootimg \
    "$MKBOOTIMG_DIR"
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

elif git apply \
  --check \
  --reverse \
  "$WORK_DIR/oculus-kernel-fixes.patch" 2>/dev/null; then

  echo "Patch already applied, skipping."

else

  echo "ERROR: oculus-kernel-fixes.patch does not apply cleanly and is not already applied." >&2
  exit 1

fi

# --- 5. Build the real Quest 2 device kernel -------------------------------
log "Building real-device kernel (your kernel.config)"

cp "$KERNEL_CONFIG" .config

# Do not require Meta's private signing certificate.
sed -i \
  's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' \
  .config

make \
  ARCH="$ARCH" \
  LLVM=1 \
  LLVM_IAS=0 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  REAL_CC=clang \
  KCFLAGS="-march=armv8.1-a" \
  olddefconfig

make \
  ARCH="$ARCH" \
  LLVM=1 \
  LLVM_IAS=0 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  REAL_CC=clang \
  KCFLAGS="-march=armv8.1-a" \
  -j"$(nproc)" \
  Image dtbs

# Only produces output if this kernel.config has
# CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y.
# Harmless no-op otherwise.
make \
  ARCH="$ARCH" \
  LLVM=1 \
  LLVM_IAS=0 \
  CROSS_COMPILE="$CROSS_COMPILE" \
  REAL_CC=clang \
  KCFLAGS="-march=armv8.1-a" \
  -j"$(nproc)" \
  Image.gz-dtb || true

OUT_DEVICE="$BUILD_DIR/oculus-quest2-device-kernel"

mkdir -p "$OUT_DEVICE/dtbs"

cp \
  arch/arm64/boot/Image \
  "$OUT_DEVICE/Image"

if [ -f arch/arm64/boot/Image.gz-dtb ]; then
  cp \
    arch/arm64/boot/Image.gz-dtb \
    "$OUT_DEVICE/Image.gz-dtb"
fi

cp vmlinux "$OUT_DEVICE_
