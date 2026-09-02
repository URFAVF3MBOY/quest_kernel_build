#!/bin/bash
# Reproduces: cross-compiling oculus-linux-kernel (oculus-quest3-kernel-master)
# for real Quest 3 hardware from a supplied kernel.config, plus a QEMU-bootable
# variant of the same tree booted under qemu-system-aarch64 with a Buildroot
# rootfs. See README-REPRODUCE.md for the *why* behind every step here.
#
# Usage:
#   Put your kernel.config next to this script, then:
#     ./build.sh                 # default: only build the real-device kernel (+ repack)
#     ./build.sh device-only     # same as above, explicit
#     ./build.sh qemu            # only build the QEMU-bootable variant + Buildroot rootfs
#     ./build.sh all             # build both the device kernel and the QEMU variant
#
#   To also repack a stock boot.img with the freshly built kernel, put a
#   real boot.img pulled from the device next to this script (or point
#   REAL_BOOT_IMG at it):
#     REAL_BOOT_IMG=/path/to/boot.img ./build.sh device-only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR"
KERNEL_CONFIG="$WORK_DIR/kernel.config"
KERNEL_DIR="$WORK_DIR/oculus-linux-kernel"
TOOLCHAIN_DIR="$WORK_DIR/toolchain"
CLANG_DIR="$TOOLCHAIN_DIR/clang-r450784e"
BUILDROOT_DIR="$WORK_DIR/buildroot"
BUILD_DIR="$WORK_DIR/build"
# Default is device-only: most iteration is "change kernel.config / patch,
# reflash the real headset" and doesn't need a QEMU+Buildroot rootfs rebuilt
# every time. Ask for "qemu" or "all" explicitly when you need those.
MODE="${1:-device-only}"
case "$MODE" in
  device-only|qemu|all) ;;
  *)
    echo "ERROR: unknown mode '$MODE' (expected device-only, qemu, or all)" >&2
    exit 1
    ;;
esac
# Pin to a specific commit instead of tracking branch HEAD. Empty = branch
# HEAD (whatever oculus-quest3-kernel-master currently points at).
KERNEL_COMMIT="${KERNEL_COMMIT:-}"
# Stock boot.img pulled from a real device (e.g. `adb pull /dev/block/bootdevice/by-name/boot boot.img`).
# If present, it gets unpacked and repacked with the kernel we just built,
# using the distro's mkbootimg package (mkbootimg / unpack_bootimg
# commands), not a hand-cloned copy of the AOSP python sources.
REAL_BOOT_IMG="${REAL_BOOT_IMG:-$WORK_DIR/boot.img}"

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
  libncurses-dev qemu-system-arm qemu-efi-aarch64 gcc-12 g++-12 \
  dwarves expect mkbootimg

# --- 2. Kernel source -----------------------------------------------------
if [ ! -d "$KERNEL_DIR" ]; then
  log "Cloning oculus-linux-kernel (oculus-quest3-kernel-master)"
  git clone --depth 1 --branch oculus-quest3-kernel-master \
    https://github.com/facebookincubator/oculus-linux-kernel.git "$KERNEL_DIR"
fi
if [ -n "$KERNEL_COMMIT" ]; then
  cd "$KERNEL_DIR"
  if [ "$(git rev-parse HEAD)" != "$KERNEL_COMMIT" ]; then
    log "Pinning kernel source to $KERNEL_COMMIT"
    git fetch --depth 1 origin "$KERNEL_COMMIT"
    git checkout "$KERNEL_COMMIT"
  fi
  cd "$WORK_DIR"
fi


# --- 3. Vendor toolchain (AOSP prebuilt Clang r450784e / 14.0.7) -----------
# Matches this kernel.config's own CONFIG_CC_VERSION_TEXT exactly. AOSP's
# gitiles instance prunes old clang versions off the tip of its "master"
# branch as new ones ship, so the exact commit that still has this version
# checked in has to be found via one of its long-lived
# "master-kernel-build-YYYY" branches rather than "master" itself.
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
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
# This tree's top-level Makefile does `CC := $(REAL_CC)` unconditionally
# (see README-REPRODUCE.md) — it expects Google's Kleaf/Bazel build to set
# REAL_CC to the real compiler binary. We're not going through Kleaf, so we
# have to supply it ourselves on every invocation or CC silently becomes empty.
export REAL_CC=clang

# --- 4. Apply source-tree fixes --------------------------------------------
log "Applying kernel source fixes (oculus-kernel-fixes.patch)"
cd "$KERNEL_DIR"
if ! git diff --quiet -- . 2>/dev/null || [ -n "$(git status --short --untracked-files=no)" ]; then
  echo "Tree already has local modifications; skipping patch apply (assuming already applied)."
else
  git apply --check "$WORK_DIR/oculus-kernel-fixes.patch"
  git apply "$WORK_DIR/oculus-kernel-fixes.patch"
fi

if [ "$MODE" = "device-only" ] || [ "$MODE" = "all" ]; then

# --- 5. Build the real Quest 3 device kernel -------------------------------
log "Building real-device kernel (your kernel.config)"
cp "$KERNEL_CONFIG" .config
make ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang olddefconfig

# Full LTO (this kernel.config's default) needs far more RAM than a typical
# dev machine has for a single-threaded whole-kernel link and gets silently
# OOM-killed mid-build with zero explanation in the log. ThinLTO parallelizes
# the link with bounded memory per thread and produces an equally-valid,
# still-LTO'd kernel.
./scripts/config --file .config -d LTO_CLANG_FULL -e LTO_CLANG_THIN
make ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang olddefconfig

make ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang \
  -j"$(nproc)" Image dtbs

OUT_DEVICE="$BUILD_DIR/oculus-quest3-device-kernel"
mkdir -p "$OUT_DEVICE/dtbs"
cp arch/arm64/boot/Image "$OUT_DEVICE/Image"
cp vmlinux "$OUT_DEVICE/vmlinux"
cp System.map "$OUT_DEVICE/System.map"
cp .config "$OUT_DEVICE/.config"
find arch/arm64/boot/dts -iname "*.dtb" -exec cp {} "$OUT_DEVICE/dtbs/" \;
find arch/arm64/boot/dts -iname "*.dtbo" -exec cp {} "$OUT_DEVICE/dtbs/" \;
log "Real-device kernel saved to $OUT_DEVICE"

cd "$WORK_DIR"

# --- 5b. Repack a real boot.img with the freshly built kernel --------------
# Uses the distro mkbootimg package (installed in step 1: apt package
# "mkbootimg", 1:34.0.5-12build1 on Ubuntu 24.04 — provides the
# `mkbootimg` and `unpack_bootimg` commands directly on PATH, no AOSP
# source checkout needed) so the header format/version matches whatever
# actually produced the stock image.
if [ -f "$REAL_BOOT_IMG" ]; then
  log "Repacking $REAL_BOOT_IMG with the newly built kernel via mkbootimg"

  command -v mkbootimg >/dev/null 2>&1 || { echo "ERROR: mkbootimg not found on PATH (apt package 'mkbootimg' should have installed it)" >&2; exit 1; }
  command -v unpack_bootimg >/dev/null 2>&1 || { echo "ERROR: unpack_bootimg not found on PATH (apt package 'mkbootimg' should have installed it)" >&2; exit 1; }

  BOOTIMG_UNPACK_DIR="$BUILD_DIR/bootimg-unpacked"
  rm -rf "$BOOTIMG_UNPACK_DIR"
  mkdir -p "$BOOTIMG_UNPACK_DIR"

  # unpack_bootimg --format=mkbootimg dumps every component (kernel,
  # ramdisk(s), second, recovery_dtbo, dtb, ...) into --out AND, instead of
  # printing a human summary, prints an already shell-quoted mkbootimg
  # command line that reproduces this image's exact header (cmdline, base,
  # offsets, pagesize, os_version/patch_level, header version, etc.) —
  # including --kernel/--ramdisk/--dtb flags pointing at the files it just
  # extracted. We capture that verbatim.
  unpack_bootimg \
    --boot_img "$REAL_BOOT_IMG" \
    --out "$BOOTIMG_UNPACK_DIR" \
    --format=mkbootimg > "$BOOTIMG_UNPACK_DIR/bootimg_args.txt"

  log "Captured original boot.img header args"
  cat "$BOOTIMG_UNPACK_DIR/bootimg_args.txt"

  NEW_BOOT_IMG="$OUT_DEVICE/boot-repacked.img"

  # argparse keeps the LAST occurrence of a repeated flag, so appending our
  # own --kernel after the captured args overrides just the kernel image
  # and leaves every other original header field/component untouched. The
  # captured args are shell-quoted (the cmdline value in particular), so
  # this has to go through eval rather than a naive array/word-split.
  eval mkbootimg \
    "$(cat "$BOOTIMG_UNPACK_DIR/bootimg_args.txt")" \
    --kernel "\"$OUT_DEVICE/Image\"" \
    -o "\"$NEW_BOOT_IMG\""

  log "Repacked boot image saved to $NEW_BOOT_IMG"
  echo "Flash with: fastboot flash boot $NEW_BOOT_IMG"
else
  log "No REAL_BOOT_IMG found at $REAL_BOOT_IMG — skipping boot.img repack"
  echo "Set REAL_BOOT_IMG=/path/to/stock/boot.img to enable this step."
fi

cd "$KERNEL_DIR"

fi # device-only || all

if [ "$MODE" = "qemu" ] || [ "$MODE" = "all" ]; then

# --- 6. Build the QEMU-bootable variant ------------------------------------
log "Building QEMU-bootable kernel variant"
cp "$KERNEL_CONFIG" .config
./scripts/config --file .config \
  -d LTO_CLANG_FULL -e LTO_CLANG_THIN \
  -e DEVTMPFS -e DEVTMPFS_MOUNT \
  -e SERIAL_AMBA_PL011 -e SERIAL_AMBA_PL011_CONSOLE \
  -e VIRTIO -e VIRTIO_MENU -e VIRTIO_MMIO -e VIRTIO_MMIO_CMDLINE_DEVICES \
  -e VIRTIO_BLK -e VIRTIO_NET -e VIRTIO_CONSOLE -e HW_RANDOM -e HW_RANDOM_VIRTIO \
  -e RTC_CLASS -e RTC_DRV_PL031
make ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang olddefconfig

make ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang \
  -j"$(nproc)" Image

mkdir -p "$BUILD_DIR/qemu-kernel"
cp arch/arm64/boot/Image "$BUILD_DIR/qemu-kernel/Image"
cp vmlinux "$BUILD_DIR/qemu-kernel/vmlinux"
cp System.map "$BUILD_DIR/qemu-kernel/System.map"
cp .config "$BUILD_DIR/qemu-kernel/.config"
log "QEMU-variant kernel saved to $BUILD_DIR/qemu-kernel/Image"

# Note: unlike the Quest 1 kit, no QEMU device-tree patching step is needed
# here. This kernel's arch/arm64/Kconfig selects COMMON_CLK unconditionally
# (no "if !ARCH_QCOM" exclusion), so QEMU's generic virt-board clock/AMBA
# devices bind normally — and QEMU's own auto-generated DTB is used (no
# -dtb flag at all; see README-REPRODUCE.md for why a pre-dumped DTB
# actually breaks boot on this kernel).

# --- 7. Buildroot rootfs ----------------------------------------------------
log "Setting up Buildroot"
if [ ! -d "$BUILDROOT_DIR" ]; then
  git clone --depth 1 --branch 2024.02.x https://github.com/buildroot/buildroot.git "$BUILDROOT_DIR"
fi

cat > "$BUILDROOT_DIR/configs/oculus_quest3_qemu_defconfig" << 'EOF'
# Architecture
BR2_aarch64=y
BR2_cortex_a53=y

# System
BR2_SYSTEM_DHCP="eth0"
BR2_TARGET_GENERIC_GETTY=y
BR2_TARGET_GENERIC_GETTY_PORT="ttyAMA0"

# Filesystem
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
# BR2_TARGET_ROOTFS_TAR is not set

# Linux headers: matches the real Quest 3 kernel tree (5.10.240).
BR2_KERNEL_HEADERS_5_10=y

# We build our own kernel outside Buildroot (oculus-linux-kernel), so
# don't have Buildroot build/manage a kernel.
# BR2_LINUX_KERNEL is not set

# host-qemu not needed, qemu-system-aarch64 is already installed on the host
# BR2_PACKAGE_HOST_QEMU is not set
EOF

cd "$BUILDROOT_DIR"
make O=output oculus_quest3_qemu_defconfig

# WSL/Windows PATH entries (e.g. "Program Files") contain spaces, which
# Buildroot's dependency check rejects outright. Also: GCC 15 default
# -Werror=implicit-function-declaration breaks host-m4's gnulib code
# (a GCC-14+ regression for old code) — build host tools with gcc-12 instead.
CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
PATH="$CLEAN_PATH" CC=gcc-12 CXX=g++-12 HOSTCC=gcc-12 HOSTCXX=g++-12 \
  make O=output -j"$(nproc)"

log "Buildroot rootfs built: $BUILDROOT_DIR/output/images/rootfs.ext4"

# --- 8. Fix the rootfs inittab for a working boot ---------------------------
log "Patching rootfs inittab (busybox-init multi-sysinit-line hang workaround)"
ROOTFS="$BUILDROOT_DIR/output/images/rootfs.ext4"
MNT="$(mktemp -d)"
sudo mount -o loop "$ROOTFS" "$MNT"

sudo tee "$MNT/etc/init.d/rc.sysinit" > /dev/null << 'EOF'
#!/bin/sh
# PID 1's stdio is unusable: the kernel's own /dev/console auto-open at
# boot runs before devtmpfs is mounted, so it silently fails and nothing
# in the boot chain inherits a working stdin/stdout/stderr. Point this
# script's output at the kernel log ring buffer instead, which is always
# writable, so boot progress stays visible.
exec 2>/dev/kmsg

mkdir -p /dev/pts /dev/shm
mount -a
mkdir -p /run/lock/subsys
swapon -a
ln -sf /proc/self/fd /dev/fd
ln -sf /proc/self/fd/0 /dev/stdin
ln -sf /proc/self/fd/1 /dev/stdout
ln -sf /proc/self/fd/2 /dev/stderr
hostname -F /etc/hostname
/etc/init.d/rcS
EOF
sudo chmod +x "$MNT/etc/init.d/rc.sysinit"

sudo tee "$MNT/etc/inittab" > /dev/null << 'EOF'
# /etc/inittab
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -o remount,rw /
::sysinit:/etc/init.d/rc.sysinit

# Put a getty on the serial port
ttyAMA0::respawn:/sbin/getty -L  ttyAMA0 0 vt100 # GENERIC_SERIAL

::shutdown:/etc/init.d/rcK
::shutdown:/sbin/swapoff -a
::shutdown:/bin/umount -a -r
EOF

sync
sudo umount "$MNT"
rmdir "$MNT"

# --- 9. Run script -----------------------------------------------------
mkdir -p "$BUILD_DIR"
cat > "$BUILD_DIR/run_qemu.sh" << EOF
#!/bin/bash
# Boot the QEMU-bootable Oculus Quest 3 kernel variant with the Buildroot
# rootfs under qemu-system-aarch64 (virt board).
#
# Run this in a real interactive terminal for a usable login prompt.
# Login: root (no password). Quit: Ctrl-A then X.
set -e
cd "\$(dirname "\$0")"
exec qemu-system-aarch64 -M virt -cpu cortex-a710 -m 8192 -nographic -smp 6 \\
  -kernel qemu-kernel/Image \\
  -append "earlycon rootwait root=/dev/vda console=ttyAMA0" \\
  -netdev user,id=eth0 -device virtio-net-device,netdev=eth0 \\
  -drive file=$BUILDROOT_DIR/output/images/rootfs.ext4,if=none,format=raw,id=hd0 \\
  -device virtio-blk-device,drive=hd0 \\
  -device virtio-rng-device \\
  -no-reboot
EOF
chmod +x "$BUILD_DIR/run_qemu.sh"

fi # qemu || all

log "Done."
if [ "$MODE" = "device-only" ] || [ "$MODE" = "all" ]; then
  echo "Real Quest 3 kernel:  $BUILD_DIR/oculus-quest3-device-kernel/"
  if [ -f "$REAL_BOOT_IMG" ]; then
    echo "Repacked boot.img:    $BUILD_DIR/oculus-quest3-device-kernel/boot-repacked.img"
  fi
fi
if [ "$MODE" = "qemu" ] || [ "$MODE" = "all" ]; then
  echo "QEMU-variant kernel:  $BUILD_DIR/qemu-kernel/Image"
  echo "Buildroot rootfs:     $BUILDROOT_DIR/output/images/rootfs.ext4"
  echo "Run under QEMU:       $BUILD_DIR/run_qemu.sh"
fi