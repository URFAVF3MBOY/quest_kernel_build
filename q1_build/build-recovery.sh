#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Quest 1 Recovery Builder
#
# Location:
#   quest_kernel_build/q1_build/build-recovery.sh
#
# Usage:
#   ./build-recovery.sh
#   ./build-recovery.sh twrp
#   ./build-recovery.sh lineage
###############################################################################

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${ROOT_DIR}/build/recovery"

TWRP_SRC="${BUILD_ROOT}/android-twrp"
LINEAGE_SRC="${BUILD_ROOT}/android-lineage"

###############################################################################
# Quest 1 device tree
###############################################################################

DEVICE_REPO="https://github.com/TheCez/device_oculus_monterey.git"
DEVICE_BRANCH="${DEVICE_BRANCH:-main}"

DEVICE_PATH="device/oculus/monterey"

###############################################################################
# TWRP Android 10 build graph
###############################################################################

TWRP_MANIFEST="https://github.com/minimal-manifest-twrp/platform_manifest_twrp_omni.git"
TWRP_BRANCH="${TWRP_BRANCH:-twrp-10.0-deprecated}"

###############################################################################
# LineageOS Android 10
###############################################################################

LINEAGE_MANIFEST="https://github.com/LineageOS/android.git"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-17.1}"

LINEAGE_RECOVERY_REPO="https://github.com/LineageOS/android_bootable_recovery.git"
LINEAGE_RECOVERY_BRANCH="${LINEAGE_RECOVERY_BRANCH:-lineage-17.1}"

###############################################################################
# Build configuration
###############################################################################

JOBS="${JOBS:-$(nproc)}"
TARGET="${1:-twrp}"

###############################################################################
# Helpers
###############################################################################

die()
{
    echo
    echo "ERROR: $*" >&2
    exit 1
}

info()
{
    echo
    echo "============================================================"
    echo "==> $*"
    echo "============================================================"
}

###############################################################################
# Validate target
###############################################################################

case "$TARGET" in
    twrp|lineage)
        ;;
    *)
        die "Usage: $0 [twrp|lineage]"
        ;;
esac

###############################################################################
# Check dependencies
###############################################################################

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v repo >/dev/null 2>&1 || die "repo is required"

###############################################################################
# Environment
###############################################################################

export LC_ALL=C
export LANG=C
export TZ=UTC

export ALLOW_MISSING_DEPENDENCIES=true
export BUILD_BROKEN_DUP_RULES=true
export BUILD_BROKEN_PHONY_TARGETS=true
export WITH_DEXPREOPT=false

###############################################################################
# Banner
###############################################################################

echo
echo "============================================================"
echo "        Quest 1 Recovery Builder"
echo "============================================================"
echo
echo "Device:          monterey"
echo "SoC:             Snapdragon 835 / MSM8998"
echo "Architecture:    arm64"
echo "Android base:    10 / API 29"
echo "Recovery target: ${TARGET}"
echo "Build jobs:      ${JOBS}"
echo
echo "Device tree:"
echo "  ${DEVICE_REPO}"
echo "  branch: ${DEVICE_BRANCH}"
echo

if [[ "$TARGET" == "twrp" ]]; then
    echo "Build graph:"
    echo "  ${TWRP_MANIFEST}"
    echo "  branch: ${TWRP_BRANCH}"
else
    echo "Lineage manifest:"
    echo "  ${LINEAGE_MANIFEST}"
    echo "  branch: ${LINEAGE_BRANCH}"
    echo
    echo "Recovery source:"
    echo "  ${LINEAGE_RECOVERY_REPO}"
    echo "  branch: ${LINEAGE_RECOVERY_BRANCH}"
fi

echo
echo "============================================================"

###############################################################################
# TWRP BUILD
###############################################################################

build_twrp()
{
    info "Preparing TWRP Android source"

    mkdir -p "$BUILD_ROOT"

    if [[ ! -d "${TWRP_SRC}/.repo" ]]; then

        rm -rf "$TWRP_SRC"
        mkdir -p "$TWRP_SRC"

        cd "$TWRP_SRC"

        info "Initializing TWRP manifest"

        repo init \
            --depth=1 \
            -u "$TWRP_MANIFEST" \
            -b "$TWRP_BRANCH"

    else

        cd "$TWRP_SRC"

        info "Existing TWRP source tree found"

    fi

    ###########################################################################
    # Sync TWRP base tree
    ###########################################################################

    info "Syncing TWRP source"

    repo sync \
        -c \
        --force-sync \
        --no-clone-bundle \
        --no-tags \
        -j"${JOBS}"

    ###########################################################################
    # Clone Quest 1 device tree
    ###########################################################################

    info "Fetching Quest 1 device tree"

    DEVICE_TREE_TMP="${BUILD_ROOT}/device_oculus_monterey"

    rm -rf "${DEVICE_TREE_TMP}"
    rm -rf "${DEVICE_PATH}"

    mkdir -p "$(dirname "${DEVICE_PATH}")"

    git clone \
        --depth=1 \
        --branch "${DEVICE_BRANCH}" \
        "${DEVICE_REPO}" \
        "${DEVICE_TREE_TMP}"

    ###########################################################################
    # TheCez repository layout:
    #
    # device_oculus_monterey/
    # └── device/
    #     └── oculus/
    #         └── monterey/
    #
    # Copy only the actual Android device tree into the TWRP source tree.
    ###########################################################################

    [[ -d "${DEVICE_TREE_TMP}/device/oculus/monterey" ]] || \
        die "TheCez device tree directory was not found in repository"

    cp -a \
        "${DEVICE_TREE_TMP}/device/oculus/monterey" \
        "${DEVICE_PATH}"

    ###########################################################################
    # Verify Quest device tree
    ###########################################################################

    echo
    echo "Quest device tree contents:"
    find "${DEVICE_PATH}" -maxdepth 2 -type f | sort | head -100
    echo

    [[ -f "${DEVICE_PATH}/BoardConfig.mk" ]] || \
        die "Quest BoardConfig.mk missing"

    [[ -f "${DEVICE_PATH}/recovery.fstab" ]] || \
        die "Quest recovery.fstab missing"

    [[ -f "${DEVICE_PATH}/recovery/root/init.recovery.monterey.rc" ]] || \
        die "Quest recovery init script missing"

    info "Quest 1 device tree successfully installed"

    ###########################################################################
    # Build
    ###########################################################################

    info "Loading Android build environment"

    # Android 10/TWRP build scripts are not nounset-safe.
    # Keep nounset disabled through envsetup, lunch, and the actual build.
    set +u

    source build/envsetup.sh

    info "Selecting Quest 1 recovery target"

    lunch omni_monterey-eng

    ###########################################################################
    # Build recovery
    ###########################################################################

    info "Building Quest 1 recovery"

    mka recoveryimage -j"${JOBS}"

    # Restore nounset after the Android build system is finished.
    set -u

    RECOVERY_IMAGE="${TWRP_SRC}/out/target/product/monterey/recovery.img"

    [[ -f "$RECOVERY_IMAGE" ]] || \
        die "TWRP build completed but recovery.img was not produced"

    ###########################################################################
    # Collect output
    ###########################################################################

    OUTPUT="${ROOT_DIR}/build/recovery/twrp"

    rm -rf "$OUTPUT"
    mkdir -p "$OUTPUT"

    cp "$RECOVERY_IMAGE" "$OUTPUT/recovery.img"

    sha256sum \
        "$OUTPUT/recovery.img" \
        > "$OUTPUT/recovery.img.sha256"

    ###########################################################################
    # Device tree commit
    ###########################################################################

    DEVICE_COMMIT="$(
        git -C "${DEVICE_TREE_TMP}" rev-parse HEAD 2>/dev/null || echo unknown
    )"

    ###########################################################################
    # Build information
    ###########################################################################

    cat > "$OUTPUT/build-info.txt" <<EOF
Quest 1 Recovery Build
======================

Recovery:
TWRP

Device:
monterey

SoC:
Qualcomm Snapdragon 835 / MSM8998

Architecture:
arm64

Android base:
10 / API 29

Device tree:
${DEVICE_REPO}

Device tree branch:
${DEVICE_BRANCH}

Device tree commit:
${DEVICE_COMMIT}

TWRP manifest:
${TWRP_MANIFEST}

TWRP branch:
${TWRP_BRANCH}

Build date:
$(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF

    ###########################################################################
    # Optional custom kernel detection
    ###########################################################################

    CUSTOM_KERNEL="${ROOT_DIR}/build/oculus-quest1-device-kernel/Image.gz-dtb"

    if [[ -f "$CUSTOM_KERNEL" ]]; then
        echo
        echo "Custom Quest kernel detected:"
        echo "  $CUSTOM_KERNEL"
        echo
        echo "NOTE:"
        echo "The recovery build above uses the kernel configuration defined"
        echo "by the Quest recovery device tree."
        echo
        echo "Custom KernelSU kernel integration is kept separate until the"
        echo "recovery kernel/image layout is explicitly matched."
    fi

    ###########################################################################
    # Done
    ###########################################################################

    echo
    echo "============================================================"
    echo " TWRP BUILD SUCCESSFUL"
    echo "============================================================"
    echo
    echo "Recovery:"
    echo "  ${OUTPUT}/recovery.img"
    echo
    echo "SHA256:"
    cat "${OUTPUT}/recovery.img.sha256"
    echo
    echo "Test without flashing:"
    echo
    echo "  fastboot boot ${OUTPUT}/recovery.img"
    echo
    echo "============================================================"
}

###############################################################################
# LINEAGE RECOVERY SOURCE PREPARATION
###############################################################################

prepare_lineage()
{
    info "Preparing LineageOS Android 10 source"

    mkdir -p "$BUILD_ROOT"

    if [[ ! -d "${LINEAGE_SRC}/.repo" ]]; then

        rm -rf "$LINEAGE_SRC"
        mkdir -p "$LINEAGE_SRC"

        cd "$LINEAGE_SRC"

        info "Initializing LineageOS 17.1"

        repo init \
            --depth=1 \
            -u "$LINEAGE_MANIFEST" \
            -b "$LINEAGE_BRANCH"

    else

        cd "$LINEAGE_SRC"

        info "Existing LineageOS source tree found"

    fi

    ###########################################################################
    # Sync base LineageOS tree
    ###########################################################################

    info "Syncing LineageOS source"

    repo sync \
        -c \
        --force-sync \
        --no-clone-bundle \
        --no-tags \
        -j"${JOBS}"

    ###########################################################################
    # Clone Quest 1 device tree
    ###########################################################################

    info "Fetching Quest 1 device tree"

    DEVICE_TREE_TMP="${BUILD_ROOT}/lineage_device_oculus_monterey"

    rm -rf "${DEVICE_TREE_TMP}"
    rm -rf "${DEVICE_PATH}"

    mkdir -p "$(dirname "${DEVICE_PATH}")"

    git clone \
        --depth=1 \
        --branch "${DEVICE_BRANCH}" \
        "${DEVICE_REPO}" \
        "${DEVICE_TREE_TMP}"

    ###########################################################################
    # Install actual nested Android device tree
    ###########################################################################

    [[ -d "${DEVICE_TREE_TMP}/device/oculus/monterey" ]] || \
        die "TheCez device tree directory was not found in repository"

    cp -a \
        "${DEVICE_TREE_TMP}/device/oculus/monterey" \
        "${DEVICE_PATH}"

    ###########################################################################
    # Verify
    ###########################################################################

    [[ -f "${DEVICE_PATH}/BoardConfig.mk" ]] || \
        die "Quest BoardConfig.mk missing"

    [[ -d "${DEVICE_PATH}" ]] || \
        die "Quest device tree missing"

    ###########################################################################
    # Pull Lineage recovery implementation
    ###########################################################################

    info "Fetching LineageOS recovery source"

    rm -rf bootable/recovery

    mkdir -p bootable

    git clone \
        --depth=1 \
        --branch "${LINEAGE_RECOVERY_BRANCH}" \
        "${LINEAGE_RECOVERY_REPO}" \
        bootable/recovery

    ###########################################################################
    # Verify recovery source
    ###########################################################################

    [[ -f bootable/recovery/Android.bp ]] || \
        die "Lineage recovery Android.bp missing"

    ###########################################################################
    # Collect source tree information
    ###########################################################################

    OUTPUT="${ROOT_DIR}/build/recovery/lineage-source"

    rm -rf "$OUTPUT"
    mkdir -p "$OUTPUT"

    DEVICE_COMMIT="$(
        git -C "${DEVICE_TREE_TMP}" rev-parse HEAD 2>/dev/null || echo unknown
    )"

    RECOVERY_COMMIT="$(
        git -C bootable/recovery rev-parse HEAD 2>/dev/null || echo unknown
    )"

    cat > "$OUTPUT/build-info.txt" <<EOF
Quest 1 Lineage Recovery Port
=============================

Device:
monterey

SoC:
Qualcomm Snapdragon 835 / MSM8998

Architecture:
arm64

Android generation:
Android 10 / API 29

Lineage branch:
${LINEAGE_BRANCH}

Lineage recovery:
${LINEAGE_RECOVERY_REPO}

Lineage recovery branch:
${LINEAGE_RECOVERY_BRANCH}

Lineage recovery commit:
${RECOVERY_COMMIT}

Quest device tree:
${DEVICE_REPO}

Quest device tree branch:
${DEVICE_BRANCH}

Quest device tree commit:
${DEVICE_COMMIT}

Prepared:
$(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF

    ###########################################################################
    # IMPORTANT
    #
    # Do not pretend this is a finished recovery image.
    #
    # TheCez's tree currently targets the TWRP/Omni Android-10 build graph.
    # A proper Lineage Recovery product needs Quest-specific Lineage product
    # definitions before recoveryimage can be built reliably.
    ###########################################################################

    echo
    echo "============================================================"
    echo " LINEAGE RECOVERY SOURCE PREPARED"
    echo "============================================================"
    echo
    echo "Source:"
    echo "  ${LINEAGE_SRC}"
    echo
    echo "Recovery source:"
    echo "  ${LINEAGE_SRC}/bootable/recovery"
    echo
    echo "Quest device tree:"
    echo "  ${LINEAGE_SRC}/${DEVICE_PATH}"
    echo
    echo "No fake recovery.img was produced."
    echo
    echo "The remaining port is the Quest-specific Lineage Recovery"
    echo "product configuration."
    echo
    echo "============================================================"
}

###############################################################################
# Main
###############################################################################

case "$TARGET" in
    twrp)
        build_twrp
        ;;

    lineage)
        prepare_lineage
        ;;
esac
