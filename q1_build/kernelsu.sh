#!/bin/bash
# Cross-compiles oculus-linux-kernel (oculus-quest-kernel-master) for real
# Quest 1 hardware from a supplied kernel.config, optionally with KernelSU-Next
# (KSU=1). See README-REPRODUCE.md for the *why* behind every step here.
#
# Usage:
#   Put your kernel.config next to this script, then:
#     KSU=1 ./kernelsu.sh        # build with KernelSU-Next (what the fork ships)
#     KSU=1 KSU_VARIANT=ksu ./kernelsu.sh   # swap in original tiann/KernelSU v0.9.5
#     ./kernelsu.sh              # baseline build (CONFIG_KSU must be off)
#   (a legacy "device-only" argument is still accepted and ignored)
#
#   To also get an image you can actually boot on the headset, drop a stock
#   boot.img pulled from that headset next to this script (or point
#   REAL_BOOT_IMG at one) - step 5b repacks it around the new kernel:
#     REAL_BOOT_IMG=/path/to/boot.img KSU=1 ./kernelsu.sh
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
BUILD_DIR="$WORK_DIR/build"
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
KGDB="${KGDB:-${KGDB_USB:-0}}"
KSU="${KSU:-0}"

# KSU_VARIANT picks which KernelSU flavour is built when KSU=1:
#   next (default) - KernelSU-Next, exactly as integrated in the kernel fork.
#   ksu            - original tiann/KernelSU, tag v0.9.5. The fork's tree is
#                    switched over at build time: drivers/kernelsu is repointed
#                    at a fresh KernelSU checkout and ksu-vanilla-hooks.patch is
#                    applied (see that file / the step 4b comment below).
# Why v0.9.5: current mainline KernelSU is GKI-only; v0.9.5 is the last line
# that still supports old non-GKI kernels, and it handles 4.4 natively (its
# core_hook.c has the < 4.10 key_permission path and LSM hook registration, so
# no kprobes are needed - this kernel has CONFIG_KPROBES unset).
KSU_VARIANT="${KSU_VARIANT:-next}"
KSU_VANILLA_REPO="${KSU_VANILLA_REPO:-https://github.com/tiann/KernelSU.git}"
KSU_VANILLA_REF="${KSU_VANILLA_REF:-b766b98513b5a7eb33bc1c4a76b5702bf1288f07}"   # v0.9.5
case "$KSU_VARIANT" in
  next|ksu) ;;
  *) echo "ERROR: KSU_VARIANT must be 'next' or 'ksu' (got '$KSU_VARIANT')" >&2; exit 1 ;;
esac

# KGDB=1 only: disable the watchdogs, so the CPUs can stay stopped.
#
# There are TWO on this device and both have to go - disabling only the
# first still resets the headset, which is exactly how this was found:
#
#  1. watchdog_v2.enable=0 - the SoC watchdog. watchdog_v2.c documents its
#     own interface ("specify watchdog_v2.enable=1 to enable the watchdog").
#  2. softdog.soft_noboot=1 - the SOFTWARE watchdog. CONFIG_SOFT_WATCHDOG=y
#     and Android's watchdogd opens /dev/watchdog at boot with a 30s margin
#     ("watchdogd started (interval 1, margin 30)"), and nothing pets it
#     while kgdb has the machine stopped. The stock cmdline carries
#     softdog.soft_panic=1, so it panics the kernel:
#         softdog: Initiating panic
#         Kernel panic - not syncing: Software Watchdog Timer expired
#     Measured on a 60s halt: died ~69s after entering kgdb, and pstore had
#     the whole story. soft_noboot=1 changes the ACTION to a warning
#     (drivers/watchdog/softdog.c), which is robust; raising soft_margin is
#     not, because watchdogd overrides the timeout via ioctl at runtime.
#     CONFIG_WATCHDOG_NOWAYOUT=y, so stopping watchdogd would not disarm it
#     either.
#
# Off by default because a watchdog-disabled kernel cannot self-recover from
# a wedge - it needs a physical power cycle. Leave it off while iterating;
# turn it on for long inspection sessions.
KGDB_DISABLE_WDT="${KGDB_DISABLE_WDT:-0}"

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

# Disable Google Chrome APT repositories.
# Chrome is not needed for building the kernel, and a stale/mismatched
# Chrome Packages index can make apt-get update fail.
for chrome_list in /etc/apt/sources.list.d/*google*chrome*; do
    if [ -f "$chrome_list" ]; then
        echo "Disabling Google Chrome APT repository: $chrome_list"
        sudo mv "$chrome_list" "${chrome_list}.disabled"
    fi
done

# Clear cached APT package indexes and download fresh ones.
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial
sudo apt-get clean

sudo DEBIAN_FRONTEND=noninteractive apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential bc bison flex libssl-dev libelf-dev \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  git wget cpio unzip rsync kmod device-tree-compiler python3-dev make \
  libncurses-dev gcc-12 g++-12 mkbootimg

# --- 2. Kernel source -----------------------------------------------------
if [ ! -d "$KERNEL_DIR" ]; then
  log "Cloning oculus-linux-kernel (oculus-quest-kernel-master)"
  git clone --depth 1 --branch oculus-quest-kernel-master \
    https://github.com/URFAVF3MBOY/monterey-kernelsu-next.git "$KERNEL_DIR"
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

# --- 4b. KSU_VARIANT=ksu: swap KernelSU-Next for original KernelSU ----------
# The fork ships KernelSU-Next in-tree (KernelSU-Next/ + the drivers/kernelsu
# symlink + manual hooks in fs/ and kernel/reboot.c + an SELinux NNP exception
# in security/selinux/hooks.c). Original KernelSU v0.9.5 uses the same hook
# sites (execveat, faccessat, stat, read) but differs in three ways, which
# ksu-vanilla-hooks.patch handles:
#   - it has no reboot-syscall hook, so the ksu_handle_sys_reboot call is
#     removed from kernel/reboot.c (it would be an undefined symbol);
#   - its root domain is u:r:su:s0, not u:r:ksu:s0, so the init->root NNP
#     exception in security/selinux/hooks.c is pointed at the right domain;
#   - it wants an input hook (safe mode / volume-key detection) in
#     drivers/input/input.c.
# This must run AFTER the oculus-kernel-fixes.patch step above: that step skips
# itself when the tree already has local modifications.
if [ "$KSU" = "1" ] && [ "$KSU_VARIANT" = "ksu" ]; then
  log "KSU_VARIANT=ksu: switching the tree to original KernelSU (${KSU_VANILLA_REF:0:12})"
  KSU_DIR="$KERNEL_DIR/KernelSU"
  if [ ! -d "$KSU_DIR/.git" ]; then
    # Full history on purpose: the version number comes from `git rev-list --count`.
    git clone "$KSU_VANILLA_REPO" "$KSU_DIR"
  fi
  git -C "$KSU_DIR" checkout --detach -f "$KSU_VANILLA_REF"
  if [ "$(git -C "$KSU_DIR" rev-parse HEAD)" != "$KSU_VANILLA_REF" ]; then
    echo "ERROR: KernelSU is not at the pinned commit $KSU_VANILLA_REF" >&2
    exit 1
  fi

  if git apply --check "$WORK_DIR/ksu-vanilla-hooks.patch" 2>/dev/null; then
    git apply "$WORK_DIR/ksu-vanilla-hooks.patch"
  elif git apply --check --reverse "$WORK_DIR/ksu-vanilla-hooks.patch" 2>/dev/null; then
    echo "ksu-vanilla-hooks.patch already applied, skipping."
  else
    echo "ERROR: ksu-vanilla-hooks.patch does not apply to this kernel source." >&2
    echo "       It was written against the fork's oculus-quest-kernel-master @ 1a5f2ec;" >&2
    echo "       if the fork changed the hook sites, regenerate the patch." >&2
    exit 1
  fi

  ln -sfn ../KernelSU/kernel drivers/kernelsu
  test -f drivers/kernelsu/Kconfig || { echo "ERROR: drivers/kernelsu symlink does not resolve" >&2; exit 1; }
  if grep -q '^config KSU_MANUAL_HOOK' drivers/kernelsu/Kconfig; then
    echo "ERROR: drivers/kernelsu still points at KernelSU-Next" >&2
    exit 1
  fi
fi

# KGDB=1: register a private struct kgdb_io driving the USB gadget's bulk
# endpoints. Separate from oculus-kernel-fixes.patch because it is
# opt-in and self-checking (anchor-verified and idempotent), so it can be
# re-run over an already-patched tree without a --check dance.
if [ "$KGDB" = "1" ]; then
  log "Applying kgdb-over-USB transport patch"
  python3 "$WORK_DIR/kgdb/apply-kgdb-usb-transport.py"
fi

# --- 5. Build the real Quest 1 device kernel -------------------------------
log "Building real-device kernel (your kernel.config)"
cp "$KERNEL_CONFIG" .config
# CONFIG_SYSTEM_TRUSTED_KEYS points at Meta's proprietary verity signing
# certificate, which is not in this tree - the build cannot even link
# without blanking it. Nothing here needs a populated trusted keyring:
# CONFIG_MODULE_SIG is off, and /system's verity check is bypassed on the
# cmdline instead (see VERITY_BYPASS at the top of this file).
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
if [ "$KGDB" = "1" ]; then
  # The whole config delta for kgdb. Written before olddefconfig, which
  # keeps values already present in .config and only fills in what is
  # missing - so the explicit "is not set" lines below survive it.
  #
  # KGDB_SERIAL_CONSOLE is "default y" in lib/Kconfig.kgdb and must be
  # turned off explicitly. It builds kgdboc, which cannot drive a gadget
  # serial port anyway (u_serial implements no poll_get_char/poll_put_char),
  # and it selects CONSOLE_POLL, which adds members to struct tty_operations
  # and struct uart_ops. That is harmless on this headset - Quest 1 loads no
  # modules - but it broke boot outright on Quest 3, and we do not need it.
  #
  # USB_CONFIGFS_ACM selects USB_U_SERIAL and USB_F_ACM, neither of which is
  # in the stock config: the transport lives in u_serial.c, and the ACM
  # function is what gives the host a /dev/ttyACM* to point gdb at.
  log "KGDB=1: adding kgdb config fragment"
  cat >> .config << 'KGDBCFG'
CONFIG_KGDB=y
# CONFIG_KGDB_SERIAL_CONSOLE is not set
# CONFIG_KGDB_KDB is not set
# CONFIG_KGDB_TESTS is not set
CONFIG_USB_CONFIGFS_ACM=y
KGDBCFG
fi

# ---------------------------------------------------------------------------
# Optional KernelSU-Next configuration
# ---------------------------------------------------------------------------

if [ "$KSU" = "1" ]; then

    echo
    if [ "$KSU_VARIANT" = "ksu" ]; then
        echo "=== Building WITH KernelSU (original, v0.9.5) ==="
    else
        echo "=== Building WITH KernelSU-Next ==="
    fi
    echo

    echo "Enabling KernelSU..."

    cat >> .config << 'EOF'

CONFIG_KSU=y
CONFIG_OVERLAY_FS=y
EOF

fi

make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig

echo
echo "Final KernelSU config state:"
grep -E '^CONFIG_KSU=|^# CONFIG_KSU' .config || true

if [ "$KSU" = "1" ]; then

    if ! grep -qx 'CONFIG_KSU=y' .config; then
        echo "ERROR: CONFIG_KSU was disabled by Kconfig"
        exit 1
    fi

    echo "CONFIG_KSU=y confirmed — continuing with KernelSU build"

else

    if grep -qx 'CONFIG_KSU=y' .config; then
        echo "ERROR: CONFIG_KSU is still enabled in the baseline build"
        exit 1
    fi

    echo "CONFIG_KSU disabled — continuing with baseline build"

fi

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

log "Verifying KernelSU was compiled into vmlinux"

echo "CONFIG_KSU from final config:"
grep '^CONFIG_KSU=' .config || true

echo
echo "KernelSU symbols in vmlinux:"
nm vmlinux | grep -E 'ksu_handle_|ksu_vfs_read_hook|ksu_execve|ksu_' | head -100 || true

echo
echo "KernelSU source/object files:"
find -L drivers/kernelsu -maxdepth 2 -type f \( -name 'ksud.c' -o -name 'ksud.o' \) -print

if [ "$KSU" = "1" ]; then
  # Count instead of `grep -q`: with `set -o pipefail`, grep -q exits early,
  # nm dies of SIGPIPE and the pipeline reports failure even on a match.
  KSU_SYM_COUNT="$(nm vmlinux | grep -c ' [tT] ksu_' || true)"
  if [ "${KSU_SYM_COUNT:-0}" -eq 0 ]; then
    echo "ERROR: CONFIG_KSU=y but no ksu_* symbols found in vmlinux" >&2
    exit 1
  fi
  echo "ksu_* text symbols in vmlinux: $KSU_SYM_COUNT"
fi

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
    if [ "$KGDB" = "1" ]; then
      # CONFIG_RANDOMIZE_BASE=y here, so without nokaslr gdb resolves
      # nothing - every frame is "?? ()" and data symbols cannot be read,
      # which makes the debugger close to useless. The boot.img cmdline IS
      # honoured on this device (verified: buildvariant=eng showed up in
      # /proc/cmdline).
      REPACK_CMDLINE="$REPACK_CMDLINE nokaslr"
      if [ "$KGDB_DISABLE_WDT" = "1" ]; then
        REPACK_CMDLINE="$REPACK_CMDLINE watchdog_v2.enable=0 softdog.soft_noboot=1"
        log "KGDB_DISABLE_WDT=1 - both watchdogs off (no self-recovery from a wedge)"
      fi
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

log "Done."
echo "Real Quest 1 kernel:  $OUT_DEVICE/"
if [ -f "${NEW_BOOT_IMG:-}" ]; then
  echo "Repacked boot.img:    $NEW_BOOT_IMG   (fastboot boot \"$NEW_BOOT_IMG\")"
fi
