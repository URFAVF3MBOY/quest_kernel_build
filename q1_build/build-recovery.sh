#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${ROOT_DIR}/build/recovery"

TWRP_SRC="${BUILD_ROOT}/android-twrp"
LINEAGE_SRC="${BUILD_ROOT}/android-lineage"

DEVICE_REPO="https://github.com/TheCez/device_oculus_monterey.git"
DEVICE_BRANCH="${DEVICE_BRANCH:-main}"
DEVICE_PATH="device/oculus/monterey"

TWRP_MANIFEST="https://github.com/minimal-manifest-twrp/platform_manifest_twrp_omni.git"
TWRP_BRANCH="${TWRP_BRANCH:-twrp-10.0-deprecated}"

LINEAGE_MANIFEST="https://github.com/LineageOS/android.git"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-17.1}"

LINEAGE_RECOVERY_REPO="https://github.com/LineageOS/android_bootable_recovery.git"
LINEAGE_RECOVERY_BRANCH="${LINEAGE_RECOVERY_BRANCH:-lineage-17.1}"

JOBS="${JOBS:-$(nproc)}"
TARGET="${1:-twrp}"

die() {
echo
echo "ERROR: $*" >&2
exit 1
}

info() {
echo
echo "============================================================"
echo "==> $*"
echo "============================================================"
}

case "${TARGET}" in
twrp|lineage)
;;
*)
die "Usage: $0 [twrp|lineage]"
;;
esac

command -v git >/dev/null 2>&1 || die "git is required"
command -v repo >/dev/null 2>&1 || die "repo is required"
command -v sed >/dev/null 2>&1 || die "sed is required"
command -v grep >/dev/null 2>&1 || die "grep is required"

export LC_ALL=C
export LANG=C
export TZ=UTC

export ALLOW_MISSING_DEPENDENCIES=true
export BUILD_BROKEN_DUP_RULES=true
export BUILD_BROKEN_PHONY_TARGETS=true
export WITH_DEXPREOPT=false

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

if [[ "${TARGET}" == "twrp" ]]; then
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

build_twrp() {

```
info "Preparing TWRP Android source"

mkdir -p "${BUILD_ROOT}"


if [[ ! -d "${TWRP_SRC}/.repo" ]]; then

    rm -rf "${TWRP_SRC}"
    mkdir -p "${TWRP_SRC}"

    cd "${TWRP_SRC}"

    info "Initializing TWRP manifest"

    repo init \
        --depth=1 \
        -u "${TWRP_MANIFEST}" \
        -b "${TWRP_BRANCH}"

else

    cd "${TWRP_SRC}"

    info "Existing TWRP source tree found"

fi


info "Syncing TWRP source"

repo sync \
    -c \
    --force-sync \
    --no-clone-bundle \
    --no-tags \
    -j"${JOBS}"


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


[[ -d "${DEVICE_TREE_TMP}/device/oculus/monterey" ]] || \
    die "TheCez device tree directory was not found in repository"


info "Installing Quest 1 device tree"

cp -a \
    "${DEVICE_TREE_TMP}/device/oculus/monterey" \
    "${DEVICE_PATH}"


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
# Android build environment
#
# Android 10 envsetup/lunch uses variables that can be unset.
# Keep nounset disabled for the Android environment setup.
###########################################################################

info "Loading Android build environment"

set +u

export TOP="${TWRP_SRC}"

source "${TWRP_SRC}/build/envsetup.sh"

echo
echo "============================================================"
echo "==> Selecting Quest 1 recovery target"
echo "============================================================"

lunch omni_monterey-eng

LUNCH_STATUS=$?

if [[ "${LUNCH_STATUS}" -ne 0 ]]; then
    echo
    echo "ERROR: lunch omni_monterey-eng failed"
    exit "${LUNCH_STATUS}"
fi

echo
echo "============================================================"
echo "==> Android build environment ready"
echo "============================================================"

echo "TOP=${TOP:-unset}"
echo "TARGET_PRODUCT=${TARGET_PRODUCT:-unset}"
echo "TARGET_BUILD_VARIANT=${TARGET_BUILD_VARIANT:-unset}"
echo "TARGET_DEVICE=${TARGET_DEVICE:-unset}"


###########################################################################
# Keep nounset disabled for the Android build itself.
#
# The old Android 10/TWRP make environment contains shell fragments that
# expect unset variables to be allowed.
###########################################################################

info "Checking Android 10 host-test build definitions"

PATCH_COUNT=0


while IFS= read -r ANDROID_MK; do

    [[ -n "${ANDROID_MK}" ]] || continue

    case "${ANDROID_MK}" in
        ./out/*)
            continue
            ;;
        ./.repo/*)
            continue
            ;;
    esac


    if ! grep -q "LOCAL_TARGET_REQUIRED_MODULES" \
        "${ANDROID_MK}" 2>/dev/null; then
        continue
    fi


    IS_HOST_TEST=false


    if grep -q \
        "LOCAL_MODULE_HOST_BUILD[[:space:]]*:=\?[[:space:]]*true" \
        "${ANDROID_MK}" 2>/dev/null; then

        IS_HOST_TEST=true

    fi


    if grep -Eq \
        '^LOCAL_MODULE[[:space:]]*:=.*(HostTest|OverlayHostTests)' \
        "${ANDROID_MK}" 2>/dev/null; then

        IS_HOST_TEST=true

    fi


    if [[ "${IS_HOST_TEST}" != "true" ]]; then
        continue
    fi


    echo
    echo "Patching host-test definition:"
    echo "  ${ANDROID_MK}"


    BACKUP="${ANDROID_MK}.quest1-backup"


    if [[ ! -f "${BACKUP}" ]]; then
        cp "${ANDROID_MK}" "${BACKUP}"
    fi


    sed -i \
        's/LOCAL_TARGET_REQUIRED_MODULES/LOCAL_REQUIRED_MODULES/g' \
        "${ANDROID_MK}"


    PATCH_COUNT=$((PATCH_COUNT + 1))

done < <(
    grep -R -l \
        --include='Android.mk' \
        "LOCAL_TARGET_REQUIRED_MODULES" \
        . 2>/dev/null || true
)


echo
echo "Host-test compatibility patches applied: ${PATCH_COUNT}"


###########################################################################
# Build
#
# Quest 1 uses:
#
#     BOARD_USES_RECOVERY_AS_BOOT := true
#
# Therefore there is NO separate recovery partition.
# TWRP recovery is packaged into boot.img.
#
# IMPORTANT:
#
#     mka recoveryimage
#
# is not the correct target for this device. It can report success without
# producing recovery.img because the device uses recovery-as-boot.
#
#     mka bootimage
#
# builds the actual image containing the recovery ramdisk.
###########################################################################

info "Building Quest 1 TWRP boot/recovery image"

if ! mka bootimage -j"${JOBS}"; then
    die "TWRP bootimage build failed"
fi


###########################################################################
# Quest 1 output
###########################################################################

BOOT_IMAGE="${TWRP_SRC}/out/target/product/monterey/boot.img"


if [[ ! -f "${BOOT_IMAGE}" ]]; then

    echo
    echo "ERROR: TWRP build completed but boot.img was not produced:"
    echo
    echo "  ${BOOT_IMAGE}"
    echo
    echo "Available monterey image files:"
    find "${TWRP_SRC}/out/target/product/monterey" \
        -maxdepth 1 \
        -type f \
        -name '*.img' \
        -print \
        2>/dev/null || true
    echo

    exit 1

fi


###########################################################################
# Copy final artifacts
###########################################################################

OUTPUT="${ROOT_DIR}/build/recovery/twrp"

rm -rf "${OUTPUT}"
mkdir -p "${OUTPUT}"


cp \
    "${BOOT_IMAGE}" \
    "${OUTPUT}/boot.img"


# Convenience copy.
#
# This is NOT a separate recovery partition image.
# It is the exact same boot image containing TWRP recovery.
cp \
    "${BOOT_IMAGE}" \
    "${OUTPUT}/recovery.img"


sha256sum \
    "${OUTPUT}/boot.img" \
    > "${OUTPUT}/boot.img.sha256"


sha256sum \
    "${OUTPUT}/recovery.img" \
    > "${OUTPUT}/recovery.img.sha256"


DEVICE_COMMIT="$(
    git -C "${DEVICE_TREE_TMP}" rev-parse HEAD 2>/dev/null || echo unknown
)"


cat > "${OUTPUT}/build-info.txt" <<EOF
```

# Quest 1 Recovery Build

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

Recovery layout:
BOARD_USES_RECOVERY_AS_BOOT

Recovery partition:
None

Recovery image:
boot.img

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

```
echo
echo "============================================================"
echo "TWRP BUILD SUCCESSFUL"
echo "============================================================"
echo
echo "Quest 1 recovery is packaged as:"
echo
echo "  ${OUTPUT}/boot.img"
echo
echo "Convenience recovery.img copy:"
echo
echo "  ${OUTPUT}/recovery.img"
echo
echo "SHA256:"
cat "${OUTPUT}/boot.img.sha256"
echo
echo "Test without flashing:"
echo
echo "  fastboot boot ${OUTPUT}/boot.img"
echo
echo "============================================================"
```

}

prepare_lineage() {

```
info "Preparing LineageOS Android 10 source"

mkdir -p "${BUILD_ROOT}"


if [[ ! -d "${LINEAGE_SRC}/.repo" ]]; then

    rm -rf "${LINEAGE_SRC}"
    mkdir -p "${LINEAGE_SRC}"

    cd "${LINEAGE_SRC}"

    info "Initializing LineageOS 17.1"

    repo init \
        --depth=1 \
        -u "${LINEAGE_MANIFEST}" \
        -b "${LINEAGE_BRANCH}"

else

    cd "${LINEAGE_SRC}"

    info "Existing LineageOS source tree found"

fi


info "Syncing LineageOS source"

repo sync \
    -c \
    --force-sync \
    --no-clone-bundle \
    --no-tags \
    -j"${JOBS}"


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


[[ -d "${DEVICE_TREE_TMP}/device/oculus/monterey" ]] || \
    die "TheCez device tree directory was not found in repository"


cp -a \
    "${DEVICE_TREE_TMP}/device/oculus/monterey" \
    "${DEVICE_PATH}"


[[ -f "${DEVICE_PATH}/BoardConfig.mk" ]] || \
    die "Quest BoardConfig.mk missing"


info "Fetching LineageOS recovery source"

rm -rf bootable/recovery

mkdir -p bootable


git clone \
    --depth=1 \
    --branch "${LINEAGE_RECOVERY_BRANCH}" \
    "${LINEAGE_RECOVERY_REPO}" \
    bootable/recovery


[[ -f bootable/recovery/Android.bp ]] || \
    die "Lineage recovery Android.bp missing"


OUTPUT="${ROOT_DIR}/build/recovery/lineage-source"

rm -rf "${OUTPUT}"
mkdir -p "${OUTPUT}"


DEVICE_COMMIT="$(
    git -C "${DEVICE_TREE_TMP}" rev-parse HEAD 2>/dev/null || echo unknown
)"


RECOVERY_COMMIT="$(
    git -C bootable/recovery rev-parse HEAD 2>/dev/null || echo unknown
)"


cat > "${OUTPUT}/build-info.txt" <<EOF
```

# Quest 1 Lineage Recovery Port

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

```
echo
echo "============================================================"
echo "LINEAGE RECOVERY SOURCE PREPARED"
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
echo "The remaining work is the Quest-specific Lineage"
echo "Recovery product configuration."
echo
echo "============================================================"
```

}

case "${TARGET}" in

```
twrp)
    build_twrp
    ;;

lineage)
    prepare_lineage
    ;;
```

esac
