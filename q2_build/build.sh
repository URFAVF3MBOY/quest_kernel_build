#!/bin/bash
# Cross-compiles oculus-linux-kernel (oculus-quest2-kernel-master) for real
# Quest 2 hardware from a supplied kernel.config.
#
# Usage:
#   Put your kernel.config next to this script, then:
#     ./build.sh
#
#   To build with KernelSU (see the KSU section below):
#     KSU=1 ./build.sh                    # KernelSU-Next (default variant)
#     KSU=1 KSU_VARIANT=ksu ./build.sh    # original tiann/KernelSU v0.9.5
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

# --- Optional: KernelSU / KernelSU-Next --------------------------------------
# KSU=1 integrates a KernelSU flavour into the tree and builds it in
# (CONFIG_KSU=y). Off by default so the baseline build stays byte-for-byte what
# it was. KSU_VARIANT picks the flavour:
#
#   KSU_VARIANT=next (default) - KernelSU-Next, `legacy` branch, pinned.
#       This is a 4.19 non-GKI kernel. KernelSU-Next offers three hook modes:
#         - KSU_KPROBES_HOOK       Kconfig help: "should not be used on kernel
#                                  below 5.10" (tracepoint + kretprobe).
#         - KSU_MANUAL_HOOK        needs hand-patching exec.c/open.c/...
#         - KSU_SYSCALL_TABLE_HOOK patches the arm64 sys_call_table at runtime;
#                                  its help text targets non-GKI kernels >= 4.17.
#       The syscall-table mode needs no source patches to the Oculus tree and
#       fits 4.19.x, so that is what is used. It resolves symbols at runtime
#       via kallsyms (CONFIG_KALLSYMS_ALL=y is already set in kernel.config).
#       Needs kernelsu-q2-compat.patch (strscpy_pad missing on this tree).
#
#   KSU_VARIANT=ksu - original tiann/KernelSU, tag v0.9.5.
#       Current mainline KernelSU (v2.x/v3.x) is GKI-only and does not build
#       on 4.19 (selinux_state internals, fsnotify, file_operations, ...).
#       v0.9.5 is the last release line that still supports non-GKI kernels;
#       it hooks execve/read/input via kprobes (CONFIG_KPROBES=y here) and
#       builds on this tree unmodified. Use a manager APK from the same era
#       (v0.9.x) - newer managers will not speak this kernel's protocol.
#
# Both are pinned to a commit for reproducibility; override KSU_REF to move it.
KSU="${KSU:-0}"
KSU_VARIANT="${KSU_VARIANT:-next}"
case "$KSU_VARIANT" in
  next)
    KSU_NAME="KernelSU-Next"
    KSU_REPO="${KSU_REPO:-https://github.com/KernelSU-Next/KernelSU-Next.git}"
    KSU_BRANCH="${KSU_BRANCH:-legacy}"
    KSU_REF="${KSU_REF:-8869bd768d6650198810f2395c2762fabefc8557}"
    ;;
  ksu)
    KSU_NAME="KernelSU"
    KSU_REPO="${KSU_REPO:-https://github.com/tiann/KernelSU.git}"
    KSU_BRANCH="${KSU_BRANCH:-}"   # v0.9.5 is a tag, not a branch tip
    KSU_REF="${KSU_REF:-b766b98513b5a7eb33bc1c4a76b5702bf1288f07}"   # v0.9.5
    ;;
  *)
    echo "ERROR: KSU_VARIANT must be 'next' or 'ksu' (got '$KSU_VARIANT')" >&2
    exit 1
    ;;
esac
KSU_DIRNAME="$KSU_NAME"

log() { echo -e "\n=== $* ===\n"; }

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

git apply "$WORK_DIR/oculus-kernel-fixes.patch"

cd "$WORK_DIR"

# --- 4b. KernelSU integration (KSU=1 only) -----------------------------------
# Same layout KernelSU's own setup.sh produces: the repo lives next to the
# kernel tree's drivers/, drivers/kernelsu is a symlink to its kernel/
# directory, and drivers/Makefile + drivers/Kconfig each get one line.
# Every step is idempotent so re-running over an already-prepared tree is fine.
if [ "$KSU" = "1" ]; then
  log "KSU=1: integrating $KSU_NAME (variant=$KSU_VARIANT @ ${KSU_REF:0:12})"
  KSU_DIR="$KERNEL_DIR/$KSU_DIRNAME"

  if [ ! -d "$KSU_DIR/.git" ]; then
    # Full history on purpose: both flavours derive their reported version from
    # `git rev-list --count HEAD`, which is wrong on a shallow clone.
    git clone ${KSU_BRANCH:+--branch "$KSU_BRANCH"} "$KSU_REPO" "$KSU_DIR"
  fi
  git -C "$KSU_DIR" fetch --no-tags origin ${KSU_BRANCH:+"$KSU_BRANCH"}
  git -C "$KSU_DIR" checkout --detach -f "$KSU_REF"   # -f drops our own compat patch from a previous run; it is re-applied below
  if [ "$(git -C "$KSU_DIR" rev-parse HEAD)" != "$KSU_REF" ]; then
    echo "ERROR: $KSU_NAME is not at the pinned commit $KSU_REF" >&2
    exit 1
  fi

  if [ "$KSU_VARIANT" = "next" ]; then
    # Small compat fix for this 4.19.325 tree (kernelsu-q2-compat.patch): the
    # pinned KernelSU-Next assumes strscpy_pad() exists from 4.14.222 on, but
    # this kernel does not have it, so every kernelsu object fails to compile
    # (implicit declaration of function 'strscpy_pad'). The patch only moves
    # that version gate so the strscpy()+memset() fallback is used instead.
    if git -C "$KSU_DIR" apply --check "$WORK_DIR/kernelsu-q2-compat.patch" 2>/dev/null; then
      git -C "$KSU_DIR" apply "$WORK_DIR/kernelsu-q2-compat.patch"
    elif git -C "$KSU_DIR" apply --check --reverse "$WORK_DIR/kernelsu-q2-compat.patch" 2>/dev/null; then
      echo "kernelsu-q2-compat.patch already applied, skipping."
    else
      echo "ERROR: kernelsu-q2-compat.patch does not apply to $KSU_NAME @ $KSU_REF" >&2
      exit 1
    fi
  fi

  ln -sfn "../$KSU_DIRNAME/kernel" "$KERNEL_DIR/drivers/kernelsu"
  grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
  grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
    sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"

  test -f "$KERNEL_DIR/drivers/kernelsu/Kconfig" || { echo "ERROR: drivers/kernelsu symlink does not resolve" >&2; exit 1; }
  grep -n 'kernelsu' "$KERNEL_DIR/drivers/Makefile" "$KERNEL_DIR/drivers/Kconfig"
fi

# --- 5. Build the real Quest 2 device kernel -------------------------------
log "Building real-device kernel (your kernel.config)"
cp "$KERNEL_CONFIG" .config
sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' .config
if [ "$KSU" = "1" ]; then
  # Written before olddefconfig, which keeps what is already in .config and
  # only fills in what is missing, so the explicit "is not set" lines survive.
  # KPROBES/KALLSYMS_ALL/OVERLAY_FS are already =y in kernel.config.
  log "KSU=1: adding $KSU_NAME config fragment"
  echo "CONFIG_KSU=y" >> .config
  echo "# CONFIG_KSU_DEBUG is not set" >> .config
  if [ "$KSU_VARIANT" = "next" ]; then
    cat >> .config << 'KSUCFG'
# CONFIG_KSU_MANUAL_HOOK is not set
# CONFIG_KSU_KPROBES_HOOK is not set
CONFIG_KSU_SYSCALL_TABLE_HOOK=y
KSUCFG
  fi
fi
make ARCH=$ARCH LLVM=1 LLVM_IAS=0 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang KCFLAGS="-march=armv8.1-a" olddefconfig

# Fail early (before an hour of compiling) if Kconfig silently dropped KSU or
# picked a different hook mode, and make sure a baseline build is really clean.
if [ "$KSU" = "1" ]; then
  KSU_EXPECT="CONFIG_KSU=y CONFIG_KPROBES=y CONFIG_OVERLAY_FS=y"
  [ "$KSU_VARIANT" = "next" ] && KSU_EXPECT="$KSU_EXPECT CONFIG_KSU_SYSCALL_TABLE_HOOK=y"
  for opt in $KSU_EXPECT; do
    grep -qx "$opt" .config || { echo "ERROR: $opt missing from final .config" >&2; grep -E '^(# )?CONFIG_KSU' .config >&2 || true; exit 1; }
  done
  echo "KernelSU config:"; grep -E '^CONFIG_KSU' .config
else
  if grep -qE '^CONFIG_KSU=[ym]' .config; then
    echo "ERROR: CONFIG_KSU is enabled in a KSU=0 build" >&2
    exit 1
  fi
fi

make ARCH=$ARCH LLVM=1 LLVM_IAS=0 CROSS_COMPILE=$CROSS_COMPILE REAL_CC=clang KCFLAGS="-march=armv8.1-a" \
  -j"$(nproc)" Image dtbs
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
  cp arch/arm64/boot/Image.gz-dtb "$OUT_DEVICE/Image.gz-dtb"
fi
cp vmlinux "$OUT_DEVICE/vmlinux"
if [ "$KSU" = "1" ]; then
  log "Verifying $KSU_NAME was compiled into vmlinux"
  if ! nm vmlinux | grep -q ' [tT] ksu_'; then
    echo "ERROR: CONFIG_KSU=y but no ksu_* symbols found in vmlinux" >&2
    exit 1
  fi
  nm vmlinux | grep -E ' [tT] ksu_' | head -40
fi
cp System.map "$OUT_DEVICE/System.map"
cp .config "$OUT_DEVICE/.config"
find arch/arm64/boot/dts -iname "*.dtb" -exec cp {} "$OUT_DEVICE/dtbs/" \;
find arch/arm64/boot/dts -iname "*.dtbo" -exec cp {} "$OUT_DEVICE/dtbs/" \;
log "Real-device kernel saved to $OUT_DEVICE"

# --- 5b. Repack a real boot.img around the kernel just built ---------------
# A bare Image/Image.gz-dtb is not bootable on its own: the device needs the
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
  eval mkbootimg \
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

cp vmlinux "$OUT_DEVICE_
