#!/usr/bin/env bash
#
# flash_iot_macos.sh - Flash balenaOS to iot-gate-imx8plus on macOS
#
# Replaces the Linux Docker-container-based flashing tool with a native
# macOS script using NXP's uuu (Universal Update Utility).
#
# Usage: sudo ./flash_iot_macos.sh -i <balena-image.img[.gz|.zip]>
#

set -euo pipefail

###############################################################################
# Section 1: Constants & Globals
###############################################################################

readonly UUU_VERSION="1.5.243"
readonly UUU_RELEASE_URL="https://github.com/nxp-imx/mfgtools/releases/download/uuu_${UUU_VERSION}"
readonly UUU_MAC_ARM_SHA256="7f2ce10d5e738af635b339696709e2c3df4984801cc6c3764cd1c207c7aac9b0"
readonly NXP_USB_VID="0x1fc9"  # i.MX8M Plus (PID: 0x0146)
readonly DEVICE_DETECT_TIMEOUT=60
readonly DEVICE_DETECT_INTERVAL=2
readonly UBOOT_INIT_WAIT=5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR=""
MOUNT_POINT=""
ATTACHED_DISK=""
VERBOSE=0
BALENA_IMAGE=""
CUSTOM_BOOTLOADER=""
INSTALL_DEPS_ONLY=0
UUU_BIN=""
BREW_PREFIX=""

###############################################################################
# Section 2: Cleanup & Signal Handling
###############################################################################

cleanup() {
    log_warn "Cleaning up..."

    # hdiutil detach handles unmounting automatically
    if [[ -n "${ATTACHED_DISK}" ]]; then
        hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
    fi

    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

###############################################################################
# Section 3: Utility Functions
###############################################################################

log_info() {
    echo -e "\033[1;32m[INFO]\033[0m $*" >&2
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
    exit 1
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        arm64|aarch64) echo "arm64" ;;
        x86_64)        echo "x86_64" ;;
        *)             log_error "Unsupported architecture: ${arch}" ;;
    esac
}

###############################################################################
# Section 4: Root Privilege Check
###############################################################################

ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_warn "Root privileges required for USB device access. Re-running with sudo..."
        exec sudo "$0" "${ORIG_ARGS[@]}"
    fi
}

###############################################################################
# Section 5: Dependency Management
###############################################################################

check_homebrew() {
    if ! command -v brew &>/dev/null; then
        # Resolve brew from common install locations (may not be in root's PATH)
        local brew_bin=""
        if [[ -x "/opt/homebrew/bin/brew" ]]; then
            brew_bin="/opt/homebrew/bin/brew"
        elif [[ -x "/usr/local/bin/brew" ]]; then
            brew_bin="/usr/local/bin/brew"
        else
            log_error "Homebrew is required but not installed.\nInstall it from: https://brew.sh"
        fi
        # Add brew to PATH so subsequent brew calls work
        eval "$("${brew_bin}" shellenv)"
    fi
    BREW_PREFIX="$(brew --prefix)"
    log_info "Homebrew found (${BREW_PREFIX})."
}

# Brew formulae the pre-built uuu binary links against at runtime.
# (Verify with: otool -L ./uuu)
readonly UUU_RUNTIME_DEPS=(libusb tinyxml2 openssl@3)

check_runtime_libs() {
    # Use filesystem check — `brew list` refuses to run as root
    local missing=()
    local dep
    for dep in "${UUU_RUNTIME_DEPS[@]}"; do
        if [[ -d "${BREW_PREFIX}/opt/${dep}/lib" ]] || [[ -d "${BREW_PREFIX}/Cellar/${dep}" ]]; then
            continue
        fi
        missing+=("${dep}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Runtime libraries found (${UUU_RUNTIME_DEPS[*]})."
        return 0
    fi

    # Cannot install via Homebrew as root
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "Missing runtime libraries: ${missing[*]}. Homebrew cannot install packages as root.\nRun first: ./flash_iot_macos.sh --install-deps"
    fi

    log_warn "Missing runtime libraries: ${missing[*]}"
    read -rp "Install via Homebrew? [Y/n] " answer
    case "${answer}" in
        [nN]*)
            log_error "These libraries are required for uuu to communicate with the device."
            ;;
        *)
            log_info "Installing: ${missing[*]}"
            brew install "${missing[@]}"
            log_info "Runtime libraries installed successfully."
            ;;
    esac
}

download_uuu() {
    local arch
    arch="$(detect_arch)"

    # NXP only provides a pre-built macOS binary for ARM (Apple Silicon)
    if [[ "${arch}" != "arm64" ]]; then
        log_warn "No pre-built uuu binary available for macOS ${arch}. Will build from source."
        return 1
    fi

    local url="${UUU_RELEASE_URL}/uuu_mac_arm"
    # Save to script directory so it persists across runs
    local dest="${SCRIPT_DIR}/uuu"

    log_info "Downloading uuu ${UUU_VERSION} for ${arch}..."
    if ! curl -fL -o "${dest}" "${url}"; then
        log_warn "Failed to download uuu binary."
        return 1
    fi

    # Verify integrity against pinned SHA256
    local actual_sha256
    actual_sha256="$(shasum -a 256 "${dest}" | awk '{print $1}')"
    if [[ "${actual_sha256}" != "${UUU_MAC_ARM_SHA256}" ]]; then
        log_warn "SHA256 checksum mismatch for downloaded uuu binary."
        log_warn "  Expected: ${UUU_MAC_ARM_SHA256}"
        log_warn "  Got:      ${actual_sha256}"
        rm -f "${dest}"
        return 1
    fi
    log_info "SHA256 checksum verified."

    chmod +x "${dest}"
    # Remove quarantine flag and ad-hoc codesign for macOS Gatekeeper
    xattr -d com.apple.quarantine "${dest}" 2>/dev/null || true
    codesign --force --sign - "${dest}" 2>/dev/null || true

    UUU_BIN="${dest}"
    log_info "uuu ${UUU_VERSION} downloaded and installed to ${dest}"
    return 0
}

build_uuu_from_source() {
    log_info "Building uuu from source (this may take a few minutes)..."

    # Xcode Command Line Tools are required for git, make, and C++ headers
    if ! xcode-select -p &>/dev/null; then
        log_error "Xcode Command Line Tools are required to build uuu from source.\nInstall them with: xcode-select --install"
    fi

    # Install build dependencies
    local deps=(cmake libusb openssl pkg-config tinyxml2)
    for dep in "${deps[@]}"; do
        if ! brew list "${dep}" &>/dev/null; then
            log_info "Installing build dependency: ${dep}"
            brew install "${dep}"
        fi
    done

    local build_dir="${TEMP_DIR}/mfgtools"
    git clone --depth 1 --branch "uuu_${UUU_VERSION}" \
        https://github.com/nxp-imx/mfgtools.git "${build_dir}"

    mkdir -p "${build_dir}/build"
    pushd "${build_dir}/build" >/dev/null

    # Set macOS SDK path so C++ standard library headers are found
    local sdk_path
    sdk_path="$(xcrun --show-sdk-path 2>/dev/null)" || true
    local cmake_extra_args=()
    if [[ -n "${sdk_path}" ]]; then
        cmake_extra_args+=("-DCMAKE_OSX_SYSROOT=${sdk_path}")
    fi

    cmake .. -DCMAKE_BUILD_TYPE=Release "${cmake_extra_args[@]}"
    make -j"$(sysctl -n hw.ncpu)"
    popd >/dev/null

    local built="${build_dir}/build/uuu/uuu"
    if [[ -x "${built}" ]]; then
        cp "${built}" "${SCRIPT_DIR}/uuu"
        UUU_BIN="${SCRIPT_DIR}/uuu"
        log_info "uuu built and installed to ${UUU_BIN}"
        return 0
    else
        log_error "Failed to build uuu from source."
    fi
}

check_uuu() {
    # Check if uuu is already available
    if command -v uuu &>/dev/null; then
        UUU_BIN="$(command -v uuu)"
        log_info "uuu found at ${UUU_BIN}"
        return 0
    fi

    if [[ -x "${SCRIPT_DIR}/uuu" ]]; then
        UUU_BIN="${SCRIPT_DIR}/uuu"
        log_info "uuu found at ${UUU_BIN}"
        return 0
    fi

    # Cannot download/build as root (Homebrew + write permissions)
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "uuu is not installed.\nRun first: ./flash_iot_macos.sh --install-deps"
    fi

    log_warn "uuu not found. Attempting to install..."

    # Try downloading pre-built binary first
    if download_uuu; then
        return 0
    fi

    # Fallback: build from source
    log_warn "Pre-built binary unavailable. Falling back to building from source..."
    build_uuu_from_source
}

install_dependencies() {
    check_homebrew
    check_runtime_libs
    check_uuu
    log_info "All dependencies are satisfied."
}

###############################################################################
# Section 6: Device Detection
###############################################################################

detect_device() {
    # macOS 26 (Tahoe) renamed the USB profiler datatype to SPUSBHostDataType;
    # earlier macOS versions use SPUSBDataType. Query both for compatibility —
    # system_profiler silently ignores an unknown datatype (exit 0, no output).
    if system_profiler SPUSBHostDataType SPUSBDataType 2>/dev/null \
        | grep -qi "${NXP_USB_VID#0x}"; then
        return 0
    fi
    return 1
}

wait_for_device() {
    if detect_device; then
        log_info "NXP USB device detected."
        return 0
    fi

    echo ""
    log_warn "No NXP USB device detected."
    echo ""
    echo "To put the iot-gate-imx8plus into recovery (serial download) mode:"
    echo "  1. Power OFF the device"
    echo "  2. Connect a micro-USB cable from the PROG port to your Mac"
    echo "  3. Power ON the device"
    echo ""
    read -rp "Press Enter to start scanning for the device (timeout: ${DEVICE_DETECT_TIMEOUT}s)... "

    local elapsed=0
    while [[ ${elapsed} -lt ${DEVICE_DETECT_TIMEOUT} ]]; do
        if detect_device; then
            log_info "NXP USB device detected!"
            return 0
        fi
        printf "\r  Scanning... (%ds / %ds)" "${elapsed}" "${DEVICE_DETECT_TIMEOUT}"
        sleep "${DEVICE_DETECT_INTERVAL}"
        elapsed=$((elapsed + DEVICE_DETECT_INTERVAL))
    done

    echo ""
    log_error "Timed out waiting for NXP USB device. Ensure the device is in recovery mode and connected via the PROG USB port."
}

###############################################################################
# Section 7: Image Handling (macOS-specific)
###############################################################################

decompress_image() {
    local image_path="$1"
    local decompressed=""

    case "${image_path}" in
        *.img.gz)
            log_info "Decompressing gzipped image..."
            decompressed="${TEMP_DIR}/$(basename "${image_path}" .gz)"
            gunzip -k -c "${image_path}" > "${decompressed}"
            ;;
        *.img.zip)
            log_info "Decompressing zipped image..."
            unzip -o "${image_path}" -d "${TEMP_DIR}"
            decompressed="$(find "${TEMP_DIR}" -name '*.img' -maxdepth 1 | head -1)"
            if [[ -z "${decompressed}" ]]; then
                log_error "No .img file found inside zip archive."
            fi
            ;;
        *.img)
            decompressed="${image_path}"
            ;;
        *)
            log_error "Unsupported image format: ${image_path}\nSupported formats: .img, .img.gz, .img.zip"
            ;;
    esac

    echo "${decompressed}"
}

extract_bootloader() {
    local image_path="$1"

    log_info "Attaching image as virtual disk..."

    # Detach any stale attachment of this image from a previous failed run
    local stale_disk
    stale_disk="$(hdiutil info 2>/dev/null | grep -B20 "${image_path}" | grep -oE '/dev/disk[0-9]+' | head -1)" || true
    if [[ -n "${stale_disk}" ]]; then
        log_warn "Image already attached as ${stale_disk} (stale). Detaching..."
        hdiutil detach "${stale_disk}" -force >/dev/null 2>&1 || true
    fi

    # Let macOS attach and auto-mount partitions (like losetup + kpartx on Linux)
    local attach_output
    if ! attach_output=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage \
                          -readonly "${image_path}" 2>&1); then
        log_warn "hdiutil attach failed:"
        echo "${attach_output}" >&2
        log_error "Could not attach disk image. Use -b to provide a bootloader binary manually."
    fi

    # Parse the base disk device for cleanup
    ATTACHED_DISK="$(echo "${attach_output}" | grep -oE '/dev/disk[0-9]+' | head -1)"
    log_info "Image attached as ${ATTACHED_DISK}"
    log_info "Mount output:"
    echo "${attach_output}" >&2

    # Find the auto-mounted boot partition volume
    # hdiutil output shows mount points like: /dev/disk4s1  Windows_FAT_32  /Volumes/resin-boot
    local boot_volume
    boot_volume="$(echo "${attach_output}" | awk -F'\t' '/Volumes/{print $NF}' | head -1)"

    if [[ -z "${boot_volume}" ]]; then
        # Try alternative: look for any mounted volume from this disk
        boot_volume="$(echo "${attach_output}" | grep -oE '/Volumes/[^ ]+' | head -1)"
    fi

    if [[ -z "${boot_volume}" ]]; then
        hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
        ATTACHED_DISK=""
        log_error "No partition was auto-mounted from the image. Use -b to provide a bootloader binary manually."
    fi

    MOUNT_POINT="${boot_volume}"
    log_info "Boot partition mounted at ${MOUNT_POINT}"

    # Find the imx-boot binary
    local boot_binary
    boot_binary="$(find "${MOUNT_POINT}" -name 'imx-boot-*' -o -name 'imx-boot' 2>/dev/null | head -1)"

    if [[ -z "${boot_binary}" ]]; then
        hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
        ATTACHED_DISK=""
        MOUNT_POINT=""
        log_error "Could not find imx-boot binary in boot partition. Use -b to provide one manually."
    fi

    # Copy bootloader to temp dir
    local dest
    dest="${TEMP_DIR}/$(basename "${boot_binary}")"
    cp "${boot_binary}" "${dest}"
    log_info "Extracted bootloader: $(basename "${boot_binary}")"

    # Cleanup: detach handles unmount automatically
    hdiutil detach "${ATTACHED_DISK}" -force >/dev/null 2>&1 || true
    ATTACHED_DISK=""
    MOUNT_POINT=""

    echo "${dest}"
}

###############################################################################
# Section 8: Flash Execution
###############################################################################

flash_device() {
    local imx_boot_bin="$1"
    local balena_image="$2"
    local verbose_flag=""

    if [[ "${VERBOSE}" -eq 1 ]]; then
        verbose_flag="-v"
    fi

    echo ""
    log_info "========================================="
    log_info "  Starting flash process"
    log_info "========================================="
    echo ""

    # Step 1: Load bootloader via USB (SDPS mode)
    log_info "Step 1/2: Loading bootloader via USB..."
    if ! "${UUU_BIN}" ${verbose_flag} "${imx_boot_bin}"; then
        echo ""
        log_warn "If you see a USB permissions error, you may need to unload the Apple USB HID driver:"
        echo "  sudo kextunload -b com.apple.driver.usb.IOUSBHostHIDDevice"
        echo "  (Re-run this script after unloading)"
        echo ""
        log_error "Failed to load bootloader via USB."
    fi

    # Wait for u-boot to initialize
    log_info "Waiting ${UBOOT_INIT_WAIT}s for U-Boot initialization..."
    sleep "${UBOOT_INIT_WAIT}"

    # Step 2: Flash full image to eMMC
    log_info "Step 2/2: Flashing full image to eMMC (this will take several minutes)..."
    if ! "${UUU_BIN}" ${verbose_flag} -b emmc_all "${imx_boot_bin}" "${balena_image}"; then
        log_error "Failed to flash image to eMMC."
    fi

    echo ""
    log_info "========================================="
    log_info "  Flash completed successfully!"
    log_info "========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Disconnect the micro-USB cable from the PROG port"
    echo "  2. Power cycle the device"
    echo "  3. The device should boot from eMMC into balenaOS"
    echo ""
}

###############################################################################
# Section 9: Main / Argument Parsing
###############################################################################

usage() {
    cat <<'USAGE'
Usage: sudo ./flash_iot_macos.sh -i <image> [options]

Flash a balenaOS image to the iot-gate-imx8plus via USB on macOS.

Required:
  -i <path>         Path to balenaOS image (.img, .img.gz, or .img.zip)

Options:
  -b <path>         Custom imx-boot binary (skips extraction from image)
  -v                Verbose uuu output
  --install-deps    Install/verify dependencies and exit
  -h, --help        Show this help message

Recovery mode instructions:
  To put the iot-gate-imx8plus into serial download (recovery) mode:
    1. Power OFF the device completely
    2. Connect a micro-USB cable from the PROG port on the device to your Mac
    3. Power ON the device

  The device should appear as an NXP USB device (VID 0x1FC9).

Examples:
  # Flash with automatic bootloader extraction
  sudo ./flash_iot_macos.sh -i balena-cloud-iot-gate-imx8plus-2.x.x.img.gz

  # Flash with a custom bootloader binary
  sudo ./flash_iot_macos.sh -i balena.img -b imx-boot-iot-gate-imx8plus

  # Install dependencies only
  ./flash_iot_macos.sh --install-deps
USAGE
}

main() {
    # Save original args before parsing shifts them away
    ORIG_ARGS=("$@")

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i)
                shift
                BALENA_IMAGE="${1:-}"
                [[ -z "${BALENA_IMAGE}" ]] && log_error "Missing argument for -i"
                ;;
            -b)
                shift
                CUSTOM_BOOTLOADER="${1:-}"
                [[ -z "${CUSTOM_BOOTLOADER}" ]] && log_error "Missing argument for -b"
                ;;
            -v)
                VERBOSE=1
                ;;
            --install-deps)
                INSTALL_DEPS_ONLY=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1\nRun with -h for usage."
                ;;
        esac
        shift
    done

    # Deps-only mode must NOT run as root (Homebrew refuses)
    if [[ "${INSTALL_DEPS_ONLY}" -eq 1 ]]; then
        if [[ "${EUID}" -eq 0 ]]; then
            log_error "Do not run --install-deps with sudo. Homebrew refuses to run as root.\nRun as: ./flash_iot_macos.sh --install-deps"
        fi
        TEMP_DIR="$(mktemp -d -t flash_iot_macos.XXXXXX)"
        install_dependencies
        log_info "Dependencies installed. You can now run the flash script."
        exit 0
    fi

    # Validate image argument
    if [[ -z "${BALENA_IMAGE}" ]]; then
        log_error "No image specified. Use -i <path> to provide a balenaOS image.\nRun with -h for usage."
    fi

    if [[ ! -f "${BALENA_IMAGE}" ]]; then
        log_error "Image file not found: ${BALENA_IMAGE}"
    fi

    # Ensure root for USB access (before allocating temp resources so
    # exec sudo doesn't leak a temp dir from the non-root process)
    ensure_root

    # Create temp directory (after privilege escalation)
    TEMP_DIR="$(mktemp -d -t flash_iot_macos.XXXXXX)"

    # Check/install dependencies
    install_dependencies

    # Validate/resolve image path to absolute
    BALENA_IMAGE="$(cd "$(dirname "${BALENA_IMAGE}")" && pwd)/$(basename "${BALENA_IMAGE}")"

    # Decompress if needed
    local working_image
    working_image="$(decompress_image "${BALENA_IMAGE}")"

    # Detect device
    wait_for_device

    # Get bootloader
    local imx_boot_bin
    if [[ -n "${CUSTOM_BOOTLOADER}" ]]; then
        if [[ ! -f "${CUSTOM_BOOTLOADER}" ]]; then
            log_error "Custom bootloader not found: ${CUSTOM_BOOTLOADER}"
        fi
        imx_boot_bin="${CUSTOM_BOOTLOADER}"
        log_info "Using custom bootloader: ${imx_boot_bin}"
    else
        imx_boot_bin="$(extract_bootloader "${working_image}")"
        if [[ -z "${imx_boot_bin}" ]]; then
            log_error "Failed to extract bootloader from image."
        fi
    fi

    # Flash
    flash_device "${imx_boot_bin}" "${working_image}"
}

main "$@"
