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

# Set DEBUG=1 in the environment for full shell tracing (set -x).
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

# ---------------------------------------------------------------------------
# Show exactly where and why the script died. Without this, a failure deep
# inside a function (or after a called function like die() has already
# printed something) is very hard to trace back to a line number from CI
# logs alone.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Self syntax-check. If this file has ever been corrupted (stray characters,
# unmatched braces/quotes, leftover markdown fences from a copy/paste, etc.)
# this catches it immediately with a clear message instead of failing at
# some unrelated point mid-build, hours later.
# ---------------------------------------------------------------------------
if ! bash -n "${BASH_SOURCE[0]}"; then
    die "This script has a syntax error (see above). Not running anything."
fi

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
    # Android build environment
    #
    # Android 10 envsetup/lunch uses variables that can be unset.
    # Keep nounset disabled for the Android environment setup.
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

    # lunch is a shell function from envsetup.sh. Capture its status
    # explicitly: with `set -e` active, letting `lunch` fail as a bare
    # statement would abort the script immediately, before any status
    # check below ever ran.
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
            ./out/*)   continue ;;
            ./.repo/*) continue ;;
        esac

        if ! grep -q "LOCAL_TARGET_REQUIRED_MODULES" "${android_mk}" 2>/dev/null; then
            continue
        fi

        local is_host_test=false

        if grep -q \
            "LOCAL_MODULE_HOST_BUILD[[:space:]]*:[[:space:]]*=[[:space:]]*true" \
            "${android_mk}" 2>/dev/null; then
            is_host_test=true
        fi

        if grep -Eq \
            '^LOCAL_MODULE[[:space:]]*:=.*(HostTest|OverlayHostTests)' \
            "${android_mk}" 2>/dev/null; then
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
            . 2>/dev/null || true
    )

    echo
    echo "Host-test compatibility patches applied: ${patch_count}"

    ###########################################################################
    # Build
    #
    # Quest 1 uses:
    #
    #     BOARD_USES_RECOVERY_AS_BOOT := true
    #
    # Therefore there is no separate recovery partition.
    # TWRP recovery is packaged into boot.img.
    ###########################################################################

    info "Building Quest 1 TWRP boot/recovery image"

    local build_log="${LOG_DIR}/twrp-mka-bootimage-$(date -u '+%Y%m%dT%H%M%SZ').log"
    echo "Full build log will be saved to: ${build_log}"

    # Capture full build output to a log file regardless of outcome, and
    # surface the tail of it (plus any error: lines) immediately on
    # failure, instead of just a bare "build failed" message.
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
        grep -i "error" "${build_log}" >&2 || echo "(no lines matched 'error')" >&2

        die "TWRP bootimage build failed — full log at ${build_log}"
    fi

    info "mka bootimage completed successfully"

    ###########################################################################
    # Quest 1 output
    ###########################################################################

    local boot_image="${TWRP_SRC}/out/target/product/monterey/boot.img"

    if [[ ! -f "${boot_image}" ]]; then
        echo
        echo "ERROR: TWRP build completed but boot.img was not produced:" >&2
        echo >&2
        echo "  ${boot_image}" >&2
        echo >&2
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
    # Copy final artifacts
    ###########################################################################

    local output="${ROOT_DIR}/build/recovery/twrp"

    rm -rf "${output}"
    mkdir -p "${output}"

    cp "${boot_image}" "${output}/boot.img"

    # Convenience copy.
    #
    # This is NOT a separate recovery partition image.
    # It is the exact same boot image containing TWRP recovery.
    cp "${boot_image}" "${output}/recovery.img"

    sha256sum "${output}/boot.img"      > "${output}/boot.img.sha256"
    sha256sum "${output}/recovery.img"  > "${output}/recovery.img.sha256"

    local device_commit
    device_commit="$(git -C "${device_tree_tmp}" rev-parse HEAD 2>/dev/null || echo unknown)"

    cat > "${output}/build-info.txt" <<EOF
Quest 1 Recovery Build
=======================

Recovery:            TWRP
Device:               monterey
SoC:                  Qualcomm Snapdragon 835 / MSM8998
Architecture:         arm64
Android base:         10 / API 29
Recovery layout:      BOARD_USES_RECOVERY_AS_BOOT
Recovery partition:   None
Recovery image:       boot.img

Device tree:          ${DEVICE_REPO}
Device tree branch:   ${DEVICE_BRANCH}
Device tree commit:   ${device_commit}

TWRP manifest:        ${TWRP_MANIFEST}
TWRP branch:           ${TWRP_BRANCH}

Build log:            ${build_log}
Build date:            $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF

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

prepare_lineage() {
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

    local output="${ROOT_DIR}/build/recovery/lineage-source"

    rm -rf "${output}"
    mkdir -p "${output}"

    local device_commit
    device_commit="$(git -C "${device_tree_tmp}" rev-parse HEAD 2>/dev/null || echo unknown)"

    local recovery_commit
    recovery_commit="$(git -C bootable/recovery rev-parse HEAD 2>/dev/null || echo unknown)"

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

case "${TARGET}" in
    twrp)
        build_twrp
        ;;
    lineage)
        prepare_lineage
        ;;
esac

info "Done in ${SECONDS}s"
