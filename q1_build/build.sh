#!/bin/bash
# Reproduces: cross-compiling oculus-linux-kernel (oculus-quest-kernel-master)
# for real Quest 1 hardware from a supplied kernel.config, plus a QEMU-bootable
# variant of the same tree booted under qemu-system-aarch64 with a Buildroot
# rootfs. See README-REPRODUCE.md for the *why* behind every step here.
#
# Usage:
#   Put your kernel.config next to this script, then:
#     ./build.sh                 # do everything
#     ./build.sh device-only     # only build the real-device kernel
#
#   To also get an image you can actually boot on the headset, drop a stock
#   boot.img pulled from that headset next to this script (or point
#   REAL_BOOT_IMG at one) - step 5b repacks it around the new kernel:
#     REAL_BOOT_IMG=/path/to/boot.img ./build.sh device-only
#     fastboot boot build/oculus-quest1-device-kernel/boot-repacked.img
#   `fastboot boot` is one-shot and non-destructive; it does not write the
#   boot partition. Never `fastboot flash boot` a kernel built here.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR"
KERNEL_CONFIG="$WORK_DIR/kernel.config"
KERNEL_DIR="$WORK_DIR/oculus-linux-kernel"
TOOLCHAIN_DIR="$WORK_DIR/toolchain"
AARCH64_GCC="$TOOLCHAIN_DIR/aarch64-linux-android-4.9"
ARM_GCC="$TOOLCHAIN_DIR/arm-linux-androideabi-4.9"
BUILDROOT_DIR="$WORK_DIR/buildroot"
BUILD_DIR="$WORK_DIR/build"
MODE="${1:-all}"
# Pin to a specific commit instead of tracking branch HEAD. Empty = branch
# HEAD (whatever oculus-quest-kernel-master currently points at). Tested:
# building from a commit close to a real device's actual build date vs.
# current HEAD produced identical boot behavior on real Quest 1 hardware
# (the branch sees very little churn), so pinning isn't necessary by
# default - available if you ever do need to bisect a regression.
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
# (androidboot.hardware, bootver/cursysver/minsysver, veritykeyid, ...)
# that must survive, so it is edited rather than replaced. Empty counts as
# unset here - unlike Quest 3, this device's stock cmdline is non-empty and
# load-bearing, so "boot with no cmdline at all" is never what you want.
# Any non-empty value wins and is used verbatim.
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
  libncurses-dev qemu-system-arm qemu-efi-aarch64 gcc-12 g++-12 mkbootimg

# --- 2. Kernel source -----------------------------------------------------
if [ ! -d "$KERNEL_DIR" ]; then
  log "Cloning oculus-linux-kernel (oculus-quest-kernel-master)"
  git clone --depth 1 --branch oculus-quest-kernel-master \
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

# --- 3. Vendor toolchains (AOSP prebuilt GCC 4.9) --------------------------
mkdir -p "$TOOLCHAIN_DIR"
if [ ! -x "$AARCH64_GCC/bin/aarch64-linux-androidkernel-gcc" ]; then
  log "Fetching aarch64-linux-android-4.9 toolchain"
  rm -rf "$AARCH64_GCC"
  git clone --depth 1 --branch oreo-release \
    https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 \
    "$AARCH64_GCC"
  # Wrapper scripts have a python2 shebang; the source is python3-compatible.
  sed -i '1s|.*|#!/usr/bin/env python3|' \
    "$AARCH64_GCC/bin/aarch64-linux-android-gcc" \
    "$AARCH64_GCC/bin/aarch64-linux-android-g++"
fi
if [ ! -x "$ARM_GCC/bin/arm-linux-androideabi-gcc" ]; then
  log "Fetching arm-linux-androideabi-4.9 toolchain (needed for CONFIG_COMPAT_VDSO)"
  rm -rf "$ARM_GCC"
  git clone --depth 1 --branch oreo-release \
    https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9 \
    "$ARM_GCC"
  sed -i '1s|.*|#!/usr/bin/env python3|' \
    "$ARM_GCC/bin/arm-linux-androideabi-gcc" \
    "$ARM_GCC/bin/arm-linux-androideabi-g++"
fi

export PATH="$AARCH64_GCC/bin:$ARM_GCC/bin:$PATH"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-androidkernel-
export CROSS_COMPILE_ARM32=arm-linux-androideabi-

# --- 4. Apply source-tree fixes --------------------------------------------
log "Applying kernel source fixes (oculus-kernel-fixes.patch)"
cd "$KERNEL_DIR"

if ! git diff --quiet -- . 2>/dev/null || [ -n "$(git status --short --untracked-files=no)" ]; then
  echo "Tree already has local modifications; skipping patch apply (assuming already applied)."
else
  git apply --check "$WORK_DIR/oculus-kernel-fixes.patch"
  git apply "$WORK_DIR/oculus-kernel-fixes.patch"
fi

# drivers/staging/oculus/internal/ is .gitignore'd (it's the never-published
# proprietary tree) so the patch can't carry it — recreate the stub directly.
mkdir -p drivers/staging/oculus/internal
cat > drivers/staging/oculus/internal/Kconfig << 'EOF'
# Stub: the upstream facebookincubator/oculus-linux-kernel repo does not
# publish drivers/staging/oculus/internal/ (proprietary/internal-only tree).
# This empty Kconfig lets the build proceed without those drivers.
EOF
# Note: the patch already removed "obj-y += internal/" from
# drivers/staging/oculus/Makefile, so no Makefile stub is needed here.

# --- 5. Build the real Quest 1 device kernel -------------------------------
log "Building real-device kernel (your kernel.config)"
cp "$KERNEL_CONFIG" .config
# CONFIG_SYSTEM_TRUSTED_KEYS points at Meta's proprietary verity signing
# certificate, which is not in this tree - the build cannot even link
# without blanking it. Nothing here needs a populated trusted keyring:
# CONFIG_MODULE_SIG is off, and /system's verity check is bypassed on the
# cmdline instead (see VERITY_BYPASS at the top of this file).
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  HOSTCFLAGS="-fcommon" -j"$(nproc)" Image dtbs
# CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y in the real device's config: the real
# kernelimage.gz is gzip(Image) with all board-revision DTBs concatenated raw
# after it (no wrapper table) - Image.gz-dtb is the kbuild target that produces
# exactly that layout, so build it too for a real flashable-equivalent artifact.
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  HOSTCFLAGS="-fcommon" -j"$(nproc)" Image.gz-dtb

OUT_DEVICE="$BUILD_DIR/oculus-quest1-device-kernel"
mkdir -p "$OUT_DEVICE/dtbs"
cp arch/arm64/boot/Image "$OUT_DEVICE/Image"
if [ -f arch/arm64/boot/Image.gz-dtb ]; then
  cp arch/arm64/boot/Image.gz-dtb "$OUT_DEVICE/Image.gz-dtb"
fi
cp vmlinux "$OUT_DEVICE/vmlinux"
cp System.map "$OUT_DEVICE/System.map"
cp .config "$OUT_DEVICE/.config"
cp arch/arm64/boot/dts/oculus/*.dtb "$OUT_DEVICE/dtbs/"
log "Real-device kernel saved to $OUT_DEVICE"

# --- 5b. Repack a real boot.img around the kernel just built ---------------
# A bare Image.gz-dtb is not bootable on its own: the device needs the
# stock ramdisk and the stock header (load offsets, page size, os_version)
# alongside it. Uses the distro `mkbootimg` package (apt "mkbootimg",
# installed in step 1 - it puts `mkbootimg` and `unpack_bootimg` straight
# on PATH), so the header format matches whatever produced the stock image.
if [ -f "$REAL_BOOT_IMG" ]; then
  log "Repacking $REAL_BOOT_IMG with the newly built kernel via mkbootimg"

  command -v mkbootimg >/dev/null 2>&1 || { echo "ERROR: mkbootimg not found on PATH (apt package 'mkbootimg' should have installed it)" >&2; exit 1; }
  command -v unpack_bootimg >/dev/null 2>&1 || { echo "ERROR: unpack_bootimg not found on PATH (apt package 'mkbootimg' should have installed it)" >&2; exit 1; }

  BOOTIMG_UNPACK_DIR="$BUILD_DIR/bootimg-unpacked"
  rm -rf "$BOOTIMG_UNPACK_DIR"
  mkdir -p "$BOOTIMG_UNPACK_DIR"

  # unpack_bootimg --format=mkbootimg extracts every component into --out
  # AND prints an already shell-quoted mkbootimg command line reproducing
  # this image's exact header - cmdline, base, all four offsets, pagesize,
  # os_version/os_patch_level, header version - with --kernel/--ramdisk
  # pointing at what it just extracted. Capture that verbatim so nothing
  # has to be hand-transcribed.
  unpack_bootimg \
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

  # The captured args are shell-quoted (the cmdline value especially), so
  # this has to go through eval rather than a naive word-split. argparse
  # keeps the LAST occurrence of a repeated flag, so appending our own
  # --kernel/--cmdline after the captured args overrides exactly those two
  # and leaves every other header field and component untouched.
  eval mkbootimg \
    "$(cat "$BOOTIMG_UNPACK_DIR/bootimg_args.txt")" \
    --kernel "\"$OUT_DEVICE/Image.gz-dtb\"" \
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

if [ "$MODE" = "device-only" ]; then
  log "device-only mode requested, stopping here"
  exit 0
fi

# --- 6. Build the QEMU-bootable variant ------------------------------------
log "Building QEMU-bootable kernel variant"
cp "$KERNEL_CONFIG" .config
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
cat >> .config << 'EOF'
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_PCI_HOST_GENERIC=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_9P_FS=y
CONFIG_NET_9P=y
CONFIG_NET_9P_VIRTIO=y
EOF
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
# Disable real-hardware-only Qualcomm SMC/TrustZone calls that crash or hang
# under QEMU (no real Qualcomm secure-monitor firmware exists there).
sed -i \
  -e 's/^CONFIG_QCOM_EARLY_RANDOM=y/# CONFIG_QCOM_EARLY_RANDOM is not set/' \
  -e 's/^CONFIG_MSM_APM=y/# CONFIG_MSM_APM is not set/' \
  -e 's/^CONFIG_QCOM_SCM=y/# CONFIG_QCOM_SCM is not set/' \
  -e 's/^CONFIG_QCOM_SCM_64=y/# CONFIG_QCOM_SCM_64 is not set/' \
  -e 's/^CONFIG_MSM_PM=y/# CONFIG_MSM_PM is not set/' \
  -e 's/^CONFIG_MSM_IPC_ROUTER_SMD_XPRT=y/# CONFIG_MSM_IPC_ROUTER_SMD_XPRT is not set/' \
  -e 's/^CONFIG_MSM_IPC_ROUTER_GLINK_XPRT=y/# CONFIG_MSM_IPC_ROUTER_GLINK_XPRT is not set/' \
  .config
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
  HOSTCFLAGS="-fcommon" -j"$(nproc)" Image

mkdir -p "$BUILD_DIR/qemu-kernel"
cp arch/arm64/boot/Image "$BUILD_DIR/qemu-kernel/Image"
cp vmlinux "$BUILD_DIR/qemu-kernel/vmlinux"
cp System.map "$BUILD_DIR/qemu-kernel/System.map"
cp .config "$BUILD_DIR/qemu-kernel/.config"
log "QEMU-variant kernel saved to $BUILD_DIR/qemu-kernel/Image"

# --- 6b. Fix QEMU's device tree so the PL011/PL061/PL031 AMBA devices
# actually bind (see README-REPRODUCE.md: this kernel's active clock
# provider, COMMON_CLK_MSM, can never resolve QEMU's generic DT
# "fixed-clock" phandle, so amba_device_add() defers those three devices
# forever without this). Dump QEMU's default virt DT, then set the
# standard ARM PrimeCell peripheral ID on each node directly (fdtput),
# which makes amba_device_add() skip its clock-based ID auto-detection
# entirely.
log "Patching QEMU's device tree (AMBA PrimeCell ID override)"
qemu-system-aarch64 -M virt,dumpdtb="$BUILD_DIR/qemu-kernel/virt.dtb" -cpu cortex-a72 \
  -m 4096 -nographic -smp 8 -kernel "$BUILD_DIR/qemu-kernel/Image" -no-reboot \
  < /dev/null > /dev/null 2>&1 || true
fdtput -t x "$BUILD_DIR/qemu-kernel/virt.dtb" /pl011@9000000 arm,primecell-periphid 0x00041011
fdtput -t x "$BUILD_DIR/qemu-kernel/virt.dtb" /pl061@9030000 arm,primecell-periphid 0x00041061
fdtput -t x "$BUILD_DIR/qemu-kernel/virt.dtb" /pl031@9010000 arm,primecell-periphid 0x00041031

# --- 7. Buildroot rootfs ----------------------------------------------------
log "Setting up Buildroot"
if [ ! -d "$BUILDROOT_DIR" ]; then
  git clone --depth 1 --branch 2024.02.x https://github.com/buildroot/buildroot.git "$BUILDROOT_DIR"
fi

cat > "$BUILDROOT_DIR/configs/oculus_qemu_defconfig" << 'EOF'
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

# Linux headers: kernel we're pairing with is a real device's 4.4 tree;
# use closest available fixed header series rather than building our own.
BR2_KERNEL_HEADERS_4_19=y

# We build our own kernel outside Buildroot (oculus-linux-kernel), so
# don't have Buildroot build/manage a kernel.
# BR2_LINUX_KERNEL is not set

# host-qemu not needed, qemu-system-aarch64 is already installed on the host
# BR2_PACKAGE_HOST_QEMU is not set
EOF

cd "$BUILDROOT_DIR"
make oculus_qemu_defconfig

# WSL/Windows PATH entries (e.g. "Program Files") contain spaces, which
# Buildroot's dependency check rejects outright. Also: GCC 15 default
# -Werror=implicit-function-declaration breaks host-m4's gnulib code
# (a GCC-14+ regression for old code) — build host tools with gcc-12 instead.
CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
PATH="$CLEAN_PATH" make -j"$(nproc)" HOSTCC=gcc-12 HOSTCXX=g++-12

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
# Boot the QEMU-bootable Oculus Quest 1 kernel variant with the Buildroot
# rootfs under qemu-system-aarch64 (virt board).
#
# Run this in a real interactive terminal for a usable login prompt.
# Login: root (no password). Quit: Ctrl-A then X.
set -e
cd "\$(dirname "\$0")"
exec qemu-system-aarch64 -M virt -cpu cortex-a72 -m 4096 -nographic -smp 8 \\
  -kernel qemu-kernel/Image \\
  -dtb qemu-kernel/virt.dtb \\
  -append "earlycon rootwait root=/dev/vda console=ttyAMA0" \\
  -netdev user,id=eth0 -device virtio-net-device,netdev=eth0 \\
  -drive file=$BUILDROOT_DIR/output/images/rootfs.ext4,if=none,format=raw,id=hd0 \\
  -device virtio-blk-device,drive=hd0 \\
  -device virtio-rng-device \\
  -no-reboot
EOF
chmod +x "$BUILD_DIR/run_qemu.sh"

log "Done."
echo "Real Quest 1 kernel:  $OUT_DEVICE/"
if [ -f "${NEW_BOOT_IMG:-}" ]; then
  echo "Repacked boot.img:    $NEW_BOOT_IMG   (fastboot boot \"$NEW_BOOT_IMG\")"
fi
echo "QEMU-variant kernel:  $BUILD_DIR/qemu-kernel/Image"
echo "Buildroot rootfs:     $BUILDROOT_DIR/output/images/rootfs.ext4"
echo "Run under QEMU:       $BUILD_DIR/run_qemu.sh"
