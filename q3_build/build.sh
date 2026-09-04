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
#   To build the real-device kernel with kgdb reachable over USB (a gadget
#   serial function; no UART hardware needed):
#     KGDB=1 ./build.sh device-only
#
#   Everything kgdb lives in kgdb/ and is used from there - see
#   kgdb/README.md. Nothing kgdb-related is written into the build output.
#   KGDB=1 defaults the cmdline to "nokaslr" (needed for gdb symbols);
#   set KERNEL_CMDLINE explicitly to override, or to "" to suppress it.
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
# Everything kgdb-specific (kernel patch, on-device helpers, KABI checker)
# lives here; nothing outside it is needed for a non-KGDB build.
KGDB_DIR="$WORK_DIR/kgdb"
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
#
# Worth pinning per-invocation when it matters: the kernel has to stay
# ABI-compatible with the ~270 prebuilt vendor modules on the device (see
# kgdb/check-vendor-kabi.py), and a moving branch HEAD can silently drift
# into CRC mismatches that make the device fall back to the stock kernel
# with no error. E.g.:
#   KERNEL_COMMIT=bbb8e0cff7f048bdf011ab3e7fd686886879d80f KGDB=1 ./build.sh
KERNEL_COMMIT="${KERNEL_COMMIT:-}"
# Stock boot.img pulled from a real device (e.g. `adb pull /dev/block/bootdevice/by-name/boot boot.img`).
# If present, it gets unpacked and repacked with the kernel we just built,
# using the distro's mkbootimg package (mkbootimg / unpack_bootimg
# commands), not a hand-cloned copy of the AOSP python sources.
REAL_BOOT_IMG="${REAL_BOOT_IMG:-$WORK_DIR/boot.img}"
# Opt-in: build the device kernel with kgdb reachable over a USB gadget
# serial function (see step 5, and kgdb/README.md). Off
# by default: a kernel debugger reachable over the USB cable is a large
# debug-only attack surface.
# KGDB_USB is accepted as an alias for KGDB. Careful: if KGDB_USB is
# exported in your shell it silently turns this on - that happened during
# development and quietly invalidated a "baseline" control build.
KGDB="${KGDB:-${KGDB_USB:-0}}"
# Kernel cmdline to bake into the repacked boot.img. The stock Quest 3
# boot.img ships an EMPTY cmdline (confirmed via unpack_bootimg), so
# anything we need has to be added here. Empty (the default) = leave the
# stock empty cmdline untouched.
# When KGDB=1 and KERNEL_CMDLINE was never set, default it to "nokaslr".
# CONFIG_RANDOMIZE_BASE=y here, so without it gdb resolves nothing - every
# frame is "?? ()" and data symbols cannot be read at all, which makes the
# debugger close to useless. The boot.img cmdline IS honoured on this
# device (verified: nokaslr shows up in /proc/cmdline).
#
# Tested for UNSET, not empty, so an explicit KERNEL_CMDLINE="" still means
# "leave the stock empty cmdline alone" and any explicit value wins.
# The transport itself needs no cmdline: it is armed at runtime by writing
# the ttyGS index to /sys/module/u_serial/parameters/kgdb_port, so a KGDB=1
# kernel still boots like a stock one until you ask for the debugger.
if [ -z "${KERNEL_CMDLINE+set}" ] && [ "$KGDB" = "1" ]; then
  KERNEL_CMDLINE="nokaslr"
else
  KERNEL_CMDLINE="${KERNEL_CMDLINE-}"
fi

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

if [ "$KGDB" = "1" ]; then
  log "Enabling KGDB with a USB-gadget-serial transport"
  # MEASURED ON THIS DEVICE - the two facts that drive everything here:
  #
  #   CONFIG_KGDB=y                                  -> boots fine
  #   CONFIG_KGDB=y + CONFIG_KGDB_SERIAL_CONSOLE=y   -> does NOT boot
  #
  # (Verified by building both and fastboot-booting them; the failing one
  # silently falls back to the stock kernel, i.e. uname loses -DARK. Also
  # independently confirmed by the device owner. Ruled out along the way:
  # the geni earlycon, binding the debug-UART DT node, and kernel
  # size/load layout - a known-good kernel padded to the failing kernel's
  # exact size and image_size still booted.)
  #
  # KGDB_SERIAL_CONSOLE is what builds drivers/tty/serial/kgdboc.c and
  # what selects CONSOLE_POLL. We do not need either, because kgdboc is
  # only ONE implementation of struct kgdb_io:
  #
  #   * kgdb_register_io_module() is exported and available with plain
  #     CONFIG_KGDB=y. It needs a read_char/write_char pair - no tty, no
  #     CONSOLE_POLL.
  #   * sysrq-g is registered by debug_core itself
  #     (register_sysrq_key('g', &sysrq_dbg_op) in kernel/debug/debug_core.c),
  #     gated only on CONFIG_MAGIC_SYSRQ, which is already =y.
  #
  # And kgdboc could never have worked over USB anyway: it only accepts a
  # tty whose ops provide poll_get_char/poll_put_char, and u_serial.c
  # implements neither (nothing under drivers/usb/gadget/ does).
  #
  # So: KGDB=y, KGDB_SERIAL_CONSOLE=n, plus our own kgdb_io module that
  # drives the gadget's bulk endpoints directly. See
  # apply-kgdb-usb-transport.py for the transport itself.
  #
  # KGDB_KDB is left OFF: it is optional (gdb is the goal, and kdb is just
  # an alternative frontend on the same kgdb_io), and it has not been
  # boot-tested on this device. Turn it on only as its own experiment.
  #
  # Everything else the transport needs - USB_U_SERIAL, USB_F_SERIAL,
  # USB_F_ACM, USB_DWC3, MAGIC_SYSRQ, DEBUG_KERNEL - is already =y in the
  # stock kernel.config, so the whole config delta is one symbol.
  ./scripts/config --file .config \
    -e KGDB \
    -d KGDB_SERIAL_CONSOLE \
    -d KGDB_KDB \
    -e MAGIC_SYSRQ \
    -e DEBUG_INFO
  make ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang olddefconfig

  # KGDB_SERIAL_CONSOLE is "default y", so it comes back on its own every
  # time olddefconfig runs unless it is explicitly disabled above. Fail
  # loudly rather than shipping a kernel that silently will not boot.
  if ! grep -q "^CONFIG_KGDB=y" .config; then
    echo "ERROR: CONFIG_KGDB did not resolve to y (needs DEBUG_KERNEL + HAVE_ARCH_KGDB)." >&2
    exit 1
  fi
  for sym in KGDB_SERIAL_CONSOLE CONSOLE_POLL; do
    if grep -q "^CONFIG_$sym=y" .config; then
      echo "ERROR: CONFIG_$sym is enabled; this kernel will not boot on this device." >&2
      echo "It is 'default y' under KGDB - it must be explicitly disabled." >&2
      exit 1
    fi
  done

  log "Applying the KGDB-over-USB transport patch"
  python3 "$KGDB_DIR/apply-kgdb-usb-transport.py"
fi

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

if [ "$KGDB" = "1" ]; then
  # Nothing kgdb-related is copied into the build output on purpose: the
  # helpers are self-contained in kgdb/ and are pushed to the device
  # straight from there by kgdb/arm.sh. Keeping one copy avoids the build
  # output and kgdb/ drifting apart.
  log "KGDB transport built in"
  echo "Next:"
  echo "  $KGDB_DIR/check-vendor-kabi.py            # must PASS before booting"
  echo "  fastboot boot $OUT_DEVICE/boot-repacked.img"
  echo "  $KGDB_DIR/arm.sh                          # compose gadget + arm kgdb"
  echo "See $KGDB_DIR/README.md"
fi

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

  log "Captured boot.img header args (repack command line)"
  cat "$BOOTIMG_UNPACK_DIR/bootimg_args.txt"

  NEW_BOOT_IMG="$OUT_DEVICE/boot-repacked.img"

  # The captured args are shell-quoted (the cmdline value in particular),
  # so this has to go through eval rather than a naive array/word-split.
  # argparse keeps the LAST occurrence of a repeated flag, so appending our
  # own --kernel (and optionally --cmdline) after the captured args
  # overrides just those and leaves every other original header
  # field/component untouched.
  # KGDB=1: append a modules.options segment disabling the SoC watchdog.
  # Nothing pets qcom_wdt_core while kgdb has the CPUs stopped, so without
  # this a halt longer than ~10-30s resets the headset. The param is 0444,
  # i.e. load-time only, but first-stage init uses Android's libmodprobe
  # which honours /lib/modules/modules.options. The ramdisk is concatenated
  # compressed cpio archives, so appending one preserves the originals.
  #
  # Off by default (KGDB_DISABLE_WDT=0) because a watchdog-disabled kernel
  # cannot self-recover from a wedge - it needs a physical power cycle.
  # Leave it off while iterating; turn it on for long inspection sessions.
  REPACK_RAMDISK=""
  if [ "$KGDB" = "1" ] && [ "${KGDB_DISABLE_WDT:-0}" = "1" ]; then
    log "Appending modules.options (qcom_wdt_core.disable_wdt=1)"
    WDT_TMP="$BUILD_DIR/wdt-extra"
    rm -rf "$WDT_TMP"; mkdir -p "$WDT_TMP/lib/modules"
    printf 'options qcom_wdt_core disable_wdt=1\n' > "$WDT_TMP/lib/modules/modules.options"
    ( cd "$WDT_TMP" && find . | cpio -o -H newc --quiet | lz4 -l -9 -q > "$BUILD_DIR/wdt-extra.lz4" )
    cat "$BOOTIMG_UNPACK_DIR/ramdisk" "$BUILD_DIR/wdt-extra.lz4" > "$BUILD_DIR/ramdisk-nowdt"
    REPACK_RAMDISK="--ramdisk \"$BUILD_DIR/ramdisk-nowdt\""
  fi

  BOOTIMG_CMDLINE_ARG=""
  if [ -n "$KERNEL_CMDLINE" ]; then
    log "Overriding kernel cmdline: $KERNEL_CMDLINE"
    BOOTIMG_CMDLINE_ARG="--cmdline \"$KERNEL_CMDLINE\""
  fi

  eval mkbootimg \
    "$(cat "$BOOTIMG_UNPACK_DIR/bootimg_args.txt")" \
    --kernel "\"$OUT_DEVICE/Image\"" \
    $REPACK_RAMDISK \
    $BOOTIMG_CMDLINE_ARG \
    -o "\"$NEW_BOOT_IMG\""

  log "Repacked boot image saved to $NEW_BOOT_IMG"
  echo "Boot it (non-destructive, does NOT touch the boot partition):"
  echo "  fastboot boot $NEW_BOOT_IMG"
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
  if [ "$KGDB" = "1" ]; then
    echo "KGDB helpers + docs:  $KGDB_DIR/  (README.md, arm.sh)"
  fi
fi
if [ "$MODE" = "qemu" ] || [ "$MODE" = "all" ]; then
  echo "QEMU-variant kernel:  $BUILD_DIR/qemu-kernel/Image"
  echo "Buildroot rootfs:     $BUILDROOT_DIR/output/images/rootfs.ext4"
  echo "Run under QEMU:       $BUILD_DIR/run_qemu.sh"
fi