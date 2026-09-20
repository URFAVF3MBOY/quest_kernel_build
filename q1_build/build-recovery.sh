#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${ROOT_DIR}/build/recovery"
LOG_DIR="${BUILD_ROOT}/logs"

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

# Set DEBUG=1 in the environment for full shell tracing.
if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
fi

SECONDS=0

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

warn() {
    echo
    echo "WARNING: $*" >&2
}

###############################################################################
# Show exactly where and why the script died.
###############################################################################

on_error() {
    local exit_code=$?
    local line_no=$1

    echo
    echo "============================================================" >&2
    echo "SCRIPT FAILED" >&2
    echo "  line:        ${line_no}" >&2
    echo "  command:     ${BASH_COMMAND}" >&2
    echo "  exit code:   ${exit_code}" >&2
    echo "============================================================" >&2

    exit "${exit_code}"
}

trap 'on_error ${LINENO}' ERR

###############################################################################
# Self syntax-check.
###############################################################################

if ! bash -n "${BASH_SOURCE[0]}"; then
    die "This script has a syntax error (see above). Not running anything."
fi

###############################################################################
# Arguments / dependencies.
###############################################################################

case "${TARGET}" in
    twrp|lineage)
        ;;
    *)
        die "Usage: $0 [twrp|lineage]"
        ;;
esac

command -v git  >/dev/null 2>&1 || die "git is required"
command -v repo >/dev/null 2>&1 || die "repo is required"
command -v sed  >/dev/null 2>&1 || die "sed is required"
command -v grep >/dev/null 2>&1 || die "grep is required"

export LC_ALL=C
export LANG=C
export TZ=UTC

export ALLOW_MISSING_DEPENDENCIES=true
export BUILD_BROKEN_DUP_RULES=true
export BUILD_BROKEN_PHONY_TARGETS=true
export WITH_DEXPREOPT=false

mkdir -p "${LOG_DIR}"

###############################################################################
# Header.
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
echo "Quest 1 kernel:"
echo "  ${ROOT_DIR}/Image.gz-dtb"
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

###############################################################################
# TWRP BUILD
###############################################################################

build_twrp() {
    info "Preparing TWRP Android source"

    mkdir -p "${BUILD_ROOT}"

    ###########################################################################
    # Make sure our kernel exists before spending time syncing/building TWRP.
    ###########################################################################

    local kernel_prebuilt_src="${ROOT_DIR}/Image.gz-dtb"

    if [[ ! -f "${kernel_prebuilt_src}" ]]; then
        die "Quest 1 kernel not found: ${kernel_prebuilt_src}"
    fi

    echo
    echo "Quest 1 KernelSU kernel:"
    echo "  ${kernel_prebuilt_src}"
    echo "  Size: $(stat -c '%s' "${kernel_prebuilt_src}") bytes"
    echo

    ###########################################################################
    # Initialize TWRP source.
    ###########################################################################

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

    ###########################################################################
    # Sync TWRP source.
    ###########################################################################

    info "Syncing TWRP source"

    repo sync \
        -c \
        --force-sync \
        --no-clone-bundle \
        --no-tags \
        -j"${JOBS}"

    ###########################################################################
    # Fetch Quest device tree.
    ###########################################################################

    info "Fetching Quest 1 device tree"

    local device_tree_tmp="${BUILD_ROOT}/device_oculus_monterey"

    rm -rf "${device_tree_tmp}"
    rm -rf "${DEVICE_PATH}"

    mkdir -p "$(dirname "${DEVICE_PATH}")"

    git clone \
        --depth=1 \
        --branch "${DEVICE_BRANCH}" \
        "${DEVICE_REPO}" \
        "${device_tree_tmp}"

    [[ -d "${device_tree_tmp}/device/oculus/monterey" ]] || \
        die "TheCez device tree directory was not found in repository"

    ###########################################################################
    # Install the actual nested device tree.
    ###########################################################################

    info "Installing Quest 1 device tree"

    cp -a \
        "${device_tree_tmp}/device/oculus/monterey" \
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
    # Install our KernelSU kernel into the device tree.
    #
    # Source:
    #
    #   q1_build/Image.gz-dtb
    #
    # Destination:
    #
    #   device/oculus/monterey/prebuilt/kernel/Image.gz-dtb
    #
    # The build system will then use this instead of the stale TheCez
    # expected_patched_kernel_component.bin.
    ###########################################################################

    info "Installing Quest 1 KernelSU prebuilt kernel"

    local kernel_prebuilt_dir="${DEVICE_PATH}/prebuilt/kernel"
    local kernel_prebuilt="${kernel_prebuilt_dir}/Image.gz-dtb"

    mkdir -p "${kernel_prebuilt_dir}"

    cp -f \
        "${kernel_prebuilt_src}" \
        "${kernel_prebuilt}"

    echo
    echo "Quest 1 kernel installed:"
    echo "  Source:"
    echo "    ${kernel_prebuilt_src}"
    echo
    echo "  Destination:"
    echo "    ${kernel_prebuilt}"
    echo
    echo "  Size:"
    echo "    $(stat -c '%s' "${kernel_prebuilt}") bytes"
    echo

    ###########################################################################
    # Configure BoardConfig.mk.
    #
    # The original TheCez tree contains a stale prebuilt kernel configuration
    # pointing at a machine-specific file:
    #
    #   expected_patched_kernel_component.bin
    #
    # Replace that configuration with our own Image.gz-dtb.
    ###########################################################################

    info "Configuring BoardConfig.mk for our KernelSU kernel"

    local board_config="${DEVICE_PATH}/BoardConfig.mk"

    [[ -f "${board_config}" ]] || \
        die "BoardConfig.mk missing: ${board_config}"

    cp -f \
        "${board_config}" \
        "${board_config}.quest1-original"

    ###########################################################################
    # Remove existing prebuilt-kernel definitions.
    ###########################################################################

    sed -i \
        '/^[[:space:]]*TARGET_FORCE_PREBUILT_KERNEL[[:space:]]*:=/d' \
        "${board_config}"

    sed -i \
        '/^[[:space:]]*TARGET_PREBUILT_KERNEL[[:space:]]*:=/d' \
        "${board_config}"

    sed -i \
        '/^[[:space:]]*BOARD_PREBUILT_KERNEL[[:space:]]*:=/d' \
        "${board_config}"

    ###########################################################################
    # Remove any direct reference to the old TheCez kernel component.
    ###########################################################################

    sed -i \
        '/expected_patched_kernel_component\.bin/d' \
        "${board_config}"

    ###########################################################################
    # Add our kernel configuration.
    #
    # Use $(TOP) so this works correctly on GitHub Actions regardless of the
    # absolute workspace path.
    ###########################################################################

    cat >> "${board_config}" <<'EOF'

###############################################################################
# Quest 1 CI kernel override
#
# Use the KernelSU kernel supplied by:
#
#   q1_build/Image.gz-dtb
#
# It is copied into:
#
#   device/oculus/monterey/prebuilt/kernel/Image.gz-dtb
###############################################################################

TARGET_FORCE_PREBUILT_KERNEL := true
TARGET_PREBUILT_KERNEL := $(TOP)/device/oculus/monterey/prebuilt/kernel/Image.gz-dtb
EOF

    echo
    echo "Final kernel configuration in BoardConfig.mk:"
    echo "------------------------------------------------------------"

    grep -nE \
        'TARGET_FORCE_PREBUILT_KERNEL|TARGET_PREBUILT_KERNEL|BOARD_PREBUILT_KERNEL|expected_patched_kernel_component' \
        "${board_config}" || true

    echo "------------------------------------------------------------"
    echo

    ###########################################################################
    # Check the entire Quest device tree for the stale kernel component.
    #
    # We do this after modifying BoardConfig.mk because the old reference may
    # theoretically live in another .mk file.
    ###########################################################################

    info "Checking for stale TheCez kernel references"

    local stale_kernel_refs

    stale_kernel_refs="$(
        grep -RIn \
            "expected_patched_kernel_component" \
            "${DEVICE_PATH}" \
            2>/dev/null || true
    )"

    if [[ -n "${stale_kernel_refs}" ]]; then
        echo
        echo "Found stale TheCez kernel references:"
        echo
        echo "${stale_kernel_refs}"
        echo

        die "Stale expected_patched_kernel_component reference remains in the Quest device tree"
    fi

    echo "No stale expected_patched_kernel_component references found."

    ###########################################################################
    # Android build environment.
    #
    # Android 10 envsetup/lunch uses variables that can be unset.
    ###########################################################################

    info "Loading Android build environment"

    set +u

    export TOP="${TWRP_SRC}"

    [[ -f "${TWRP_SRC}/build/envsetup.sh" ]] || \
        die "envsetup.sh not found under ${TWRP_SRC}/build — repo sync likely incomplete"

    # shellcheck disable=SC1091
    source "${TWRP_SRC}/build/envsetup.sh"

    echo
    echo "============================================================"
    echo "==> Selecting Quest 1 recovery target"
    echo "============================================================"

    ###########################################################################
    # lunch is a shell function from envsetup.sh.
    ###########################################################################

    set +e

    lunch omni_monterey-eng

    local lunch_status=$?

    set -e

    if [[ "${lunch_status}" -ne 0 ]]; then
        die "lunch omni_monterey-eng failed with exit code ${lunch_status}"
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
    ###########################################################################

    info "Checking Android 10 host-test build definitions"

    local patch_count=0
    local android_mk

    while IFS= read -r android_mk; do
        [[ -n "${android_mk}" ]] || continue

        case "${android_mk}" in
            ./out/*)
                continue
                ;;
            ./.repo/*)
                continue
                ;;
        esac

        if ! grep -q \
            "LOCAL_TARGET_REQUIRED_MODULES" \
            "${android_mk}" \
            2>/dev/null; then
            continue
        fi

        local is_host_test=false

        if grep -q \
            "LOCAL_MODULE_HOST_BUILD[[:space:]]*:[[:space:]]*=[[:space:]]*true" \
            "${android_mk}" \
            2>/dev/null; then
            is_host_test=true
        fi

        if grep -Eq \
            '^LOCAL_MODULE[[:space:]]*:=.*(HostTest|OverlayHostTests)' \
            "${android_mk}" \
            2>/dev/null; then
            is_host_test=true
        fi

        if [[ "${is_host_test}" != "true" ]]; then
            continue
        fi

        echo
        echo "Patching host-test definition:"
        echo "  ${android_mk}"

        local backup="${android_mk}.quest1-backup"

        if [[ ! -f "${backup}" ]]; then
            cp "${android_mk}" "${backup}"
        fi

        sed -i \
            's/LOCAL_TARGET_REQUIRED_MODULES/LOCAL_REQUIRED_MODULES/g' \
            "${android_mk}"

        patch_count=$((patch_count + 1))

    done < <(
        grep -R -l \
            --include='Android.mk' \
            "LOCAL_TARGET_REQUIRED_MODULES" \
            . \
            2>/dev/null || true
    )

    echo
    echo "Host-test compatibility patches applied: ${patch_count}"

    ###########################################################################
    # Verify that the actual kernel file still exists after lunch.
    ###########################################################################

    info "Verifying Quest 1 prebuilt kernel"

    if [[ ! -f "${kernel_prebuilt}" ]]; then
        die "Prebuilt kernel disappeared: ${kernel_prebuilt}"
    fi

    echo
    echo "Kernel:"
    echo "  ${kernel_prebuilt}"
    echo
    echo "Size:"
    stat -c '%s bytes' "${kernel_prebuilt}"
    echo
    echo "File type:"
    file "${kernel_prebuilt}"
    echo

    ###########################################################################
    # Show the relevant resolved BoardConfig settings.
    ###########################################################################

    echo "BoardConfig kernel settings:"
    grep -nE \
        'TARGET_FORCE_PREBUILT_KERNEL|TARGET_PREBUILT_KERNEL|BOARD_PREBUILT_KERNEL' \
        "${board_config}" \
        || true

    ###########################################################################
    # Build.
    #
    # Quest 1 uses:
    #
    #   BOARD_USES_RECOVERY_AS_BOOT := true
    #
    # Therefore TWRP is packaged into boot.img.
    ###########################################################################

    info "Building Quest 1 TWRP boot/recovery image"

    local build_log="${LOG_DIR}/twrp-mka-bootimage-$(date -u '+%Y%m%dT%H%M%SZ').log"

    echo "Full build log will be saved to:"
    echo "  ${build_log}"
    echo

    ###########################################################################
    # Capture full build output to the log regardless of outcome.
    ###########################################################################

    if ! mka bootimage -j"${JOBS}" 2>&1 | tee "${build_log}"; then

        echo
        echo "============================================================" >&2
        echo "mka bootimage FAILED — last 200 lines of log:" >&2
        echo "============================================================" >&2

        tail -n 200 "${build_log}" >&2

        echo
        echo "============================================================" >&2
        echo "Lines containing 'error' in the log:" >&2
        echo "============================================================" >&2

        grep -i "error" "${build_log}" >&2 || \
            echo "(no lines matched 'error')" >&2

        die "TWRP bootimage build failed — full log at ${build_log}"
    fi

    info "mka bootimage completed successfully"

    ###########################################################################
    # Quest 1 output.
    ###########################################################################

    local boot_image="${TWRP_SRC}/out/target/product/monterey/boot.img"

    if [[ ! -f "${boot_image}" ]]; then

        echo
        echo "ERROR: TWRP build completed but boot.img was not produced:" >&2
        echo
        echo "  ${boot_image}" >&2
        echo

        echo "Available monterey image files:" >&2

        find "${TWRP_SRC}/out/target/product/monterey" \
            -maxdepth 1 \
            -type f \
            -name '*.img' \
            -print \
            2>/dev/null || true

        echo >&2

        die "Expected boot image missing after a reported-successful build"
    fi

    ###########################################################################
    # Copy final artifacts.
    ###########################################################################

    local output="${ROOT_DIR}/build/recovery/twrp"

    rm -rf "${output}"
    mkdir -p "${output}"

    cp \
        "${boot_image}" \
        "${output}/boot.img"

    # Convenience copy.
    #
    # This is NOT a separate recovery partition image.
    # It is the exact same boot image containing TWRP recovery.

    cp \
        "${boot_image}" \
        "${output}/recovery.img"

    sha256sum \
        "${output}/boot.img" \
        > "${output}/boot.img.sha256"

    sha256sum \
        "${output}/recovery.img" \
        > "${output}/recovery.img.sha256"

    ###########################################################################
    # Build metadata.
    ###########################################################################

    local device_commit

    device_commit="$(
        git -C "${device_tree_tmp}" rev-parse HEAD 2>/dev/null || \
            echo unknown
    )"

    cat > "${output}/build-info.txt" <<EOF
Quest 1 Recovery Build
======================

Recovery:            TWRP
Device:              monterey
SoC:                  Qualcomm Snapdragon 835 / MSM8998
Architecture:         arm64
Android base:         10 / API 29
Recovery layout:      BOARD_USES_RECOVERY_AS_BOOT
Recovery partition:   None
Recovery image:       boot.img

Kernel:
Kernel source artifact: ${kernel_prebuilt_src}
Kernel installed as:    ${kernel_prebuilt}
Kernel size:            $(stat -c '%s' "${kernel_prebuilt}") bytes

Device tree:          ${DEVICE_REPO}
Device tree branch:   ${DEVICE_BRANCH}
Device tree commit:   ${device_commit}

TWRP manifest:        ${TWRP_MANIFEST}
TWRP branch:           ${TWRP_BRANCH}

Build log:             ${build_log}
Build date:            $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF

    ###########################################################################
    # Success.
    ###########################################################################

    echo
    echo "============================================================"
    echo "TWRP BUILD SUCCESSFUL"
    echo "============================================================"
    echo

    echo "Quest 1 recovery is packaged as:"
    echo
    echo "  ${output}/boot.img"
    echo

    echo "Convenience recovery.img copy:"
    echo
    echo "  ${output}/recovery.img"
    echo

    echo "Kernel used:"
    echo
    echo "  ${kernel_prebuilt}"
    echo

    echo "SHA256:"
    cat "${output}/boot.img.sha256"

    echo
    echo "Full build log:"
    echo "  ${build_log}"

    echo
    echo "Test without flashing:"
    echo
    echo "  fastboot boot ${output}/boot.img"

    echo
    echo "============================================================"
}

###############################################################################
# LINEAGE SOURCE PREPARATION
###############################################################################

prepare_lineage() {
    info "Preparing LineageOS Android 10 source"

    mkdir -p "${BUILD_ROOT}"

    ###########################################################################
    # Initialize LineageOS source.
    ###########################################################################

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

    ###########################################################################
    # Sync LineageOS source.
    ###########################################################################

    info "Syncing LineageOS source"

    repo sync \
        -c \
        --force-sync \
        --no-clone-bundle \
        --no-tags \
        -j"${JOBS}"

    ###########################################################################
    # Fetch Quest device tree.
    ###########################################################################

    info "Fetching Quest 1 device tree"

    local device_tree_tmp="${BUILD_ROOT}/lineage_device_oculus_monterey"

    rm -rf "${device_tree_tmp}"
    rm -rf "${DEVICE_PATH}"

    mkdir -p "$(dirname "${DEVICE_PATH}")"

    git clone \
        --depth=1 \
        --branch "${DEVICE_BRANCH}" \
        "${DEVICE_REPO}" \
        "${device_tree_tmp}"

    [[ -d "${device_tree_tmp}/device/oculus/monterey" ]] || \
        die "TheCez device tree directory was not found in repository"

    cp -a \
        "${device_tree_tmp}/device/oculus/monterey" \
        "${DEVICE_PATH}"

    [[ -f "${DEVICE_PATH}/BoardConfig.mk" ]] || \
        die "Quest BoardConfig.mk missing"

    ###########################################################################
    # Fetch Lineage recovery source.
    ###########################################################################

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

    ###########################################################################
    # Save source preparation metadata.
    ###########################################################################

    local output="${ROOT_DIR}/build/recovery/lineage-source"

    rm -rf "${output}"
    mkdir -p "${output}"

    local device_commit

    device_commit="$(
        git -C "${device_tree_tmp}" rev-parse HEAD 2>/dev/null || \
            echo unknown
    )"

    local recovery_commit

    recovery_commit="$(
        git -C bootable/recovery rev-parse HEAD 2>/dev/null || \
            echo unknown
    )"

    cat > "${output}/build-info.txt" <<EOF
Quest 1 Lineage Recovery Port
==============================

Device:                     monterey
SoC:                        Qualcomm Snapdragon 835 / MSM8998
Architecture:               arm64
Android generation:         Android 10 / API 29

Lineage branch:             ${LINEAGE_BRANCH}
Lineage recovery:           ${LINEAGE_RECOVERY_REPO}
Lineage recovery branch:    ${LINEAGE_RECOVERY_BRANCH}
Lineage recovery commit:    ${recovery_commit}

Quest device tree:          ${DEVICE_REPO}
Quest device tree branch:   ${DEVICE_BRANCH}
Quest device tree commit:   ${device_commit}

Prepared:                   $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF

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
}

###############################################################################
# Main.
###############################################################################

case "${TARGET}" in
    twrp)
        build_twrp
        ;;
    lineage)
        prepare_lineage
        ;;
esac

info "Done in ${SECONDS}s"
