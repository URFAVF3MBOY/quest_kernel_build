#!/bin/bash
# Cross-compiles oculus-linux-kernel (oculus-quest2-kernel-master) for real
# Quest 2 hardware from a supplied kernel.config.
#
# Usage:
#   Put your kernel.config next to this script, then:
#     ./build.sh
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

if [ -n "$KERNEL_COMMIT" ]; then
  log "Checking out exact kernel commit $KERNEL_COMMIT"

  git fetch --no-tags origin "$KERNEL_COMMIT"
  git checkout --detach "$KERNEL_COMMIT"

  ACTUAL_COMMIT="$(git rev-parse HEAD)"

  if [ "$ACTUAL_COMMIT" != "$KERNEL_COMMIT" ]; then
    echo "ERROR: kernel commit mismatch!" >&2
    echo "Expected: $KERNEL_COMMIT" >&2
    echo "Actual:   $ACTUAL_COMMIT" >&2
    exit 1
  fi

  echo "Kernel source verified at: $ACTUAL_COMMIT"
else
  log "No KERNEL_COMMIT specified; using oculus-quest2-kernel-master"

  git fetch --no-tags origin oculus-quest2-kernel-master
  git checkout --detach origin/oculus-quest2-kernel-master
fi

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

log "Done."
echo "Real Quest 2 kernel:  $OUT_DEVICE/"
