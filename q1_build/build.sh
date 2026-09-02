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
  libncurses-dev qemu-system-arm qemu-efi-aarch64 gcc-12 g++-12

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

# The real /system dm-verity signing cert (verity.x509.pem) is proprietary
# and was never published upstream - without it, CONFIG_SYSTEM_TRUSTED_KEYS
# has to be blanked (below), which leaves the kernel's trusted keyring
# empty. That's not cosmetic: drivers/md/dm-android-verity.c verifies
# /system's dm-verity signature against that keyring unconditionally (the
# unlocked-bootloader bypass only covers malformed verity *metadata*, not
# a failed signature check) - an empty keyring makes /system's verity
# target creation fail outright and init hangs forever waiting for it to
# mount, silently, with nothing in pstore to explain why.
#
# The certificate is public (Meta's signing public key, not the private
# key) and recoverable from any real device's own boot partition - see
# extract_verity_cert.py. If REAL_BOOT_IMG points at a boot_a/boot_b dump
# and verity.x509.pem doesn't already exist, extract it automatically:
if [ -n "${REAL_BOOT_IMG:-}" ] && [ ! -f "$WORK_DIR/verity.x509.pem" ]; then
  log "Extracting the real verity cert from \$REAL_BOOT_IMG"
  python3 "$WORK_DIR/extract_verity_cert.py" --boot-img "$REAL_BOOT_IMG" \
    ${REAL_VMLINUX:+--vmlinux "$REAL_VMLINUX"} \
    -o "$WORK_DIR/verity.x509.pem"
fi

# certs/Makefile resolves CONFIG_SYSTEM_TRUSTED_KEYS relative to $(srctree)
# directly (a bare filename means source ROOT, not certs/).
if [ -f "$WORK_DIR/verity.x509.pem" ]; then
  cp "$WORK_DIR/verity.x509.pem" verity.x509.pem
fi

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
# The real verity signing cert is proprietary and was never published -
# CONFIG_SYSTEM_TRUSTED_KEYS defaults to blanking it out so the tree
# builds at all. If a real cert has been placed at the kernel source
# ROOT as verity.x509.pem (certs/Makefile resolves CONFIG_SYSTEM_TRUSTED_KEYS
# relative to $(srctree), NOT relative to certs/ - a plain filename with
# no directory prefix means top-level; see extract_verity_cert.py),
# keep the config pointing at it instead, since an empty trusted keyring
# makes /system's dm-verity check fail unconditionally (even on an
# unlocked bootloader) and hangs init.
if [ -f verity.x509.pem ]; then
  echo "Using real verity.x509.pem (found at source root) - not blanking CONFIG_SYSTEM_TRUSTED_KEYS"
else
  sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
fi
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
echo "QEMU-variant kernel:  $BUILD_DIR/qemu-kernel/Image"
echo "Buildroot rootfs:     $BUILDROOT_DIR/output/images/rootfs.ext4"
echo "Run under QEMU:       $BUILD_DIR/run_qemu.sh"
