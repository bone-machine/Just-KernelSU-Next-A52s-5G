#!/usr/bin/env bash
# ===================================================================================
# build_kernel_zip.sh
# Automated kernel build + flashable zip script for bone-machine's A52s 5G kernel
# Must be run from the kernel root directory (android_kernel_samsung_sm7325_a52s_5g/)
# ===================================================================================

set -euo pipefail

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}${BOLD}[ERR]${NC}   $*" >&2; exit 1; }

# ─── Trap: clean up any mktemp dirs on unexpected exit ────────────────────────
TMP_CLANG=""
TMP_MAGISK=""
cleanup_tmp() {
    [[ -n "$TMP_CLANG"  && -d "$TMP_CLANG"  ]] && rm -rf "$TMP_CLANG"
    [[ -n "$TMP_MAGISK" && -d "$TMP_MAGISK" ]] && rm -rf "$TMP_MAGISK"
}
trap cleanup_tmp EXIT

# ─── Hardcoded config ─────────────────────────────────────────────────────────
AUTHOR="bone-machine"
DEVICE="a52sxq"
KBUILD_BUILD_USER="bone-machine"
KBUILD_BUILD_HOST="rios"
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz"
MAGISK_APK_URL="https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk"

# Script lives in the kernel root — resolve its real location regardless of cwd
KERNEL_ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN_DIR="${KERNEL_ROOT}/toolchain"
CLANG_DIR="${TOOLCHAIN_DIR}/clang"
MAGISKBOOT_BIN="${TOOLCHAIN_DIR}/magiskboot/magiskboot"
OUT_DIR="${KERNEL_ROOT}/out"
MAGISKBOOT_BOOT_DIR="${TOOLCHAIN_DIR}/magiskboot/boot"
TEMPLATE_ZIP_DIR="${KERNEL_ROOT}/template-zip-file"
IMAGES_DIR="${TEMPLATE_ZIP_DIR}/images"
MAGISKBOOT_VENDOR_DIR="${TOOLCHAIN_DIR}/magiskboot/vendor_boot"
UPDATE_BINARY="${TEMPLATE_ZIP_DIR}/META-INF/com/google/android/update-binary"

# ─── Derived build metadata ───────────────────────────────────────────────────
BUILD_DATE="$(date +%Y-%m-%d)"

# Detect ROM type from current git branch
CURRENT_BRANCH="$(git -C "${KERNEL_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
case "$CURRENT_BRANCH" in
    main)      ROM_TYPE="One-UI" ;;
    *oneui*)   ROM_TYPE="One-UI" ;;
    *aosp*)    ROM_TYPE="AOSP"   ;;
    *)
        warn "Branch '$CURRENT_BRANCH' doesn't match any known ROM type — defaulting to AOSP"
        ROM_TYPE="AOSP"
        ;;
esac

# Detect KSU-Next version from submodule tags
# 'main' and plain 'aosp' branches do not ship KSU-Next
NO_KSU_BRANCHES=("main" "aosp")
if [[ " ${NO_KSU_BRANCHES[*]} " == *" ${CURRENT_BRANCH} "* ]]; then
    KSU_VERSION="none"
else
    KSU_VERSION="$(git -C "${KERNEL_ROOT}/KernelSU-Next" describe --tags --abbrev=0 2>/dev/null \
        || echo 'unknown')"
fi

# Display string for root solution
if [[ "$KSU_VERSION" == "none" ]]; then
    ROOT_DISPLAY="none"
else
    ROOT_DISPLAY="KernelSU-Next ${KSU_VERSION}"
fi

# ZIP name: drop the KSU-Next segment on branches that don't ship it
if [[ "$KSU_VERSION" == "none" ]]; then
    ZIP_NAME="${AUTHOR}_${BUILD_DATE}_${ROM_TYPE}_${DEVICE}.zip"
else
    ZIP_NAME="${AUTHOR}_${BUILD_DATE}_${ROM_TYPE}_KSU-Next-${KSU_VERSION}_${DEVICE}.zip"
fi

# ─── Sanity checks ────────────────────────────────────────────────────────────
[[ "$(basename "$KERNEL_ROOT")" == "android_kernel_samsung_sm7325_a52s_5g" ]] \
    || die "Run this script from the kernel root (android_kernel_samsung_sm7325_a52s_5g/)"

for cmd in curl unzip zip cpio find sed git uname tar grep nproc cp chmod depmod; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ─── Pre-flight checks ────────────────────────────────────────────────────────
info "Running pre-flight checks..."
PREFLIGHT_FAILED=0

# Helper: check a file exists
check_file() {
    local path="$1" desc="$2"
    if [[ ! -f "$path" ]]; then
        echo -e "${RED}${BOLD}[MISSING]${NC} ${desc}: ${path}"
        PREFLIGHT_FAILED=1
    fi
}

# Helper: check a directory exists
check_dir() {
    local path="$1" desc="$2"
    if [[ ! -d "$path" ]]; then
        echo -e "${RED}${BOLD}[MISSING]${NC} ${desc}: ${path}"
        PREFLIGHT_FAILED=1
    fi
}

# Helper: check a glob matches at least one file
check_glob() {
    local glob="$1" desc="$2"
    if ! compgen -G "$glob" > /dev/null 2>&1; then
        echo -e "${RED}${BOLD}[MISSING]${NC} ${desc}: ${glob}"
        PREFLIGHT_FAILED=1
    fi
}

# Stock boot images
check_file "${MAGISKBOOT_BOOT_DIR}/boot.img"             "Stock boot image"
check_file "${MAGISKBOOT_VENDOR_DIR}/vendor_boot.img"    "Stock vendor_boot image"

# Flashable zip template
check_file "${UPDATE_BINARY}"                            "update-binary"
check_dir  "${IMAGES_DIR}"                              "Flashable zip images dir"
check_dir  "${TEMPLATE_ZIP_DIR}/META-INF"               "Flashable zip META-INF dir"

# Firmware
check_dir  "${KERNEL_ROOT}/firmware/tsp_stm"            "Firmware source dir"
check_glob "${KERNEL_ROOT}/firmware/tsp_stm/fts5cu56a_a52sxq*" "TSP firmware file"

# KernelSU-Next submodule (only on KSU branches)
if [[ "$KSU_VERSION" != "none" ]]; then
    check_dir "${KERNEL_ROOT}/KernelSU-Next"            "KernelSU-Next submodule"
fi

# Kernel defconfig
check_file "${KERNEL_ROOT}/arch/arm64/configs/vendor/a52sxq_kor_single_defconfig" "Kernel defconfig"

(( PREFLIGHT_FAILED == 0 )) || die "Pre-flight checks failed — fix the above before building"
success "Pre-flight checks passed"

git -C "${KERNEL_ROOT}" rev-parse --git-dir >/dev/null 2>&1 \
    || die "Kernel root is not a git repository"

info "Updating git submodules..."
git -C "${KERNEL_ROOT}" submodule update --init --recursive
success "Submodules up to date"

# ─── Step 2: Clang toolchain ──────────────────────────────────────────────────
if [[ -x "${CLANG_DIR}/bin/clang" ]] &&
   "${CLANG_DIR}/bin/clang" --version >/dev/null 2>&1; then
    success "Clang already present and working at ${CLANG_DIR}, skipping download"
else
    info "Downloading Clang toolchain..."
    TMP_CLANG="$(mktemp -d)"
    curl -L --progress-meter "$CLANG_URL" -o "${TMP_CLANG}/clang.tar.gz" \
        || die "Failed to download Clang"
    info "Extracting Clang (this may take a while)..."
    rm -rf "$CLANG_DIR"
    mkdir -p "$CLANG_DIR"
    tar -xzf "${TMP_CLANG}/clang.tar.gz" -C "$CLANG_DIR" \
        || die "Failed to extract Clang"
    rm -rf "$TMP_CLANG"
    TMP_CLANG=""
    success "Clang installed to ${CLANG_DIR}"
fi

# Post-install sanity check — verify critical Clang binaries are functional
"${CLANG_DIR}/bin/clang" --version >/dev/null 2>&1 \
    || die "clang binary not functional at ${CLANG_DIR}/bin/clang"
"${CLANG_DIR}/bin/llvm-strip" --version >/dev/null 2>&1 \
    || die "llvm-strip not functional at ${CLANG_DIR}/bin/llvm-strip"
"${CLANG_DIR}/bin/ld.lld" --version >/dev/null 2>&1 \
    || die "ld.lld not functional at ${CLANG_DIR}/bin/ld.lld"
success "Clang toolchain verified"

# ─── Step 3: Magiskboot ───────────────────────────────────────────────────────
if [[ -x "$MAGISKBOOT_BIN" ]]; then
    success "magiskboot already present at ${MAGISKBOOT_BIN}, skipping"
else
    info "Downloading Magisk APK to extract magiskboot..."
    TMP_MAGISK="$(mktemp -d)"
    curl -L --progress-meter "$MAGISK_APK_URL" -o "${TMP_MAGISK}/Magisk.apk" \
        || die "Failed to download Magisk APK"
    info "Extracting Magisk APK..."
    unzip -q "${TMP_MAGISK}/Magisk.apk" -d "${TMP_MAGISK}/extracted" \
        || die "Failed to unzip Magisk APK"

    # Map host arch to the APK lib folder name
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        x86_64)  APK_ARCH="x86_64"    ;;
        aarch64) APK_ARCH="arm64-v8a" ;;
        armv7l)  APK_ARCH="armeabi-v7a" ;;
        i686)    APK_ARCH="x86"       ;;
        *) die "Unsupported host architecture: ${HOST_ARCH}" ;;
    esac

    MAGISKBOOT_SO="${TMP_MAGISK}/extracted/lib/${APK_ARCH}/libmagiskboot.so"
    [[ -f "$MAGISKBOOT_SO" ]] || die "libmagiskboot.so not found at ${MAGISKBOOT_SO}"

    mkdir -p "$(dirname "$MAGISKBOOT_BIN")"
    cp "$MAGISKBOOT_SO" "$MAGISKBOOT_BIN"
    chmod +x "$MAGISKBOOT_BIN"
    rm -rf "$TMP_MAGISK"
    TMP_MAGISK=""
    success "magiskboot installed to ${MAGISKBOOT_BIN}"
fi

# ─── Step 4: Export PATH ──────────────────────────────────────────────────────
export PATH="${CLANG_DIR}/bin:$(dirname "$MAGISKBOOT_BIN"):$PATH"
info "PATH updated: Clang and magiskboot directories prepended"

# ─── Step 5: Clean previous build ────────────────────────────────────────────
info "Wiping out/ from previous build..."
rm -rf "${OUT_DIR}"
success "Clean done"

# ─── Step 6: Defconfig ───────────────────────────────────────────────────────
info "Generating defconfig..."
make -C "${KERNEL_ROOT}" O="${OUT_DIR}" ARCH=arm64 vendor/a52sxq_kor_single_defconfig \
    || die "defconfig failed"
success "Defconfig generated"

# ─── Step 7: Kernel build ────────────────────────────────────────────────────
info "Building kernel with $(nproc) jobs..."
make -j"$(nproc)" \
    -C "${KERNEL_ROOT}" \
    O="${OUT_DIR}" \
    ARCH=arm64 \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    KBUILD_BUILD_USER="${KBUILD_BUILD_USER}" \
    KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST}" \
    CONFIG_SECTION_MISMATCH_WARN_ONLY=y \
    || die "Kernel build failed"
success "Kernel build complete"

# ─── Step 8: Install and strip modules, generate module metadata ──────────────
info "Installing kernel modules..."
MODULES_STAGING="${OUT_DIR}/modules_staging"
rm -rf "${MODULES_STAGING}"
mkdir -p "${MODULES_STAGING}"

# modules_install harvests already-built .ko files into INSTALL_MOD_PATH/lib/modules/<kernel-version>/
# No recompilation happens here — no need for CC, LLVM, or -j flags
# STRIP is explicitly set to llvm-strip from our Clang toolchain
make \
    -C "${KERNEL_ROOT}" \
    O="${OUT_DIR}" \
    ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    STRIP="${CLANG_DIR}/bin/llvm-strip" \
    INSTALL_MOD_PATH="${MODULES_STAGING}" \
    INSTALL_MOD_STRIP=1 \
    modules_install \
    || die "modules_install failed"

# Find the versioned subdir modules_install created — must be exactly one
mapfile -t MODULE_DIRS < <(
    find "${MODULES_STAGING}/lib/modules" -mindepth 1 -maxdepth 1 -type d
)
(( ${#MODULE_DIRS[@]} == 1 )) \
    || die "Expected exactly one module directory in ${MODULES_STAGING}/lib/modules, found ${#MODULE_DIRS[@]}"
MODULES_VERSIONED_DIR="${MODULE_DIRS[0]}"
KERNEL_VERSION="$(basename "$MODULES_VERSIONED_DIR")"
info "Kernel version: ${KERNEL_VERSION}"

# Collect flat list of .ko files for reference
MODULE_COUNT="$(find "${MODULES_VERSIONED_DIR}" -name "*.ko" | wc -l)"
(( MODULE_COUNT > 0 )) || die "No kernel modules found after modules_install — aborting"
info "Found ${MODULE_COUNT} kernel modules"

# Detect duplicate module filenames before flattening
DUPLICATES="$(find "${MODULES_VERSIONED_DIR}" -name '*.ko' -printf '%f\n' | sort | uniq -d)"

if [[ -n "$DUPLICATES" ]]; then
    echo "Duplicate module filenames:"
    echo "$DUPLICATES"
    die "Flattening would overwrite files"
fi

# Run depmod against the staging dir using the build's System.map for correct symbols
# This generates modules.dep, modules.alias, modules.softdep inside the versioned dir
SYSTEM_MAP="${OUT_DIR}/System.map"
[[ -f "$SYSTEM_MAP" ]] || die "System.map not found at ${SYSTEM_MAP}"
# Temporary flattened module tree
FLAT_MODULES_DIR="${OUT_DIR}/flat_modules"

rm -rf "${FLAT_MODULES_DIR}"
mkdir -p "${FLAT_MODULES_DIR}/lib/modules/${KERNEL_VERSION}"

# Copy every .ko into a flat directory
find "${MODULES_VERSIONED_DIR}" -name "*.ko" \
    -exec cp {} "${FLAT_MODULES_DIR}/lib/modules/${KERNEL_VERSION}/" \; \
    || die "Failed to flatten modules"

# Generate dependency metadata against the flat layout
depmod \
    -b "${FLAT_MODULES_DIR}" \
    -F "$SYSTEM_MAP" \
    "$KERNEL_VERSION" \
    || die "depmod failed"

# depmod writes into lib/modules/<version>/
FLAT_VERSIONED_DIR="${FLAT_MODULES_DIR}/lib/modules/${KERNEL_VERSION}"

[[ -d "$FLAT_VERSIONED_DIR" ]] \
    || die "depmod did not create ${FLAT_VERSIONED_DIR}"

for mod_file in "${FLAT_VERSIONED_DIR}"/modules.*; do
    [[ -f "$mod_file" ]] || continue

    sed -E -i \
        's@(^| )([^ /][^ ]*\.ko)@\1/lib/modules/\2@g' \
        "$mod_file"
done

# Generate modules.load from actual .ko files present (Android-specific, depmod doesn't make it)
find "${FLAT_VERSIONED_DIR}" -maxdepth 1 -name "*.ko" \
    -exec basename {} \; | sort \
    > "${FLAT_VERSIONED_DIR}/modules.load" \
    || die "Failed to generate modules.load"

success "Modules installed, stripped, and metadata generated: ${MODULE_COUNT} files"

# Verify kernel Image exists before starting repack stage
KERNEL_IMAGE="${OUT_DIR}/arch/arm64/boot/Image"
[[ -f "$KERNEL_IMAGE" ]] || die "Kernel Image missing after build — check build logs"

# ─── Step 9: boot.img ────────────────────────────────────────────────────────
find "${IMAGES_DIR}" -mindepth 1 -delete
info "Repacking boot.img..."
cd "${MAGISKBOOT_BOOT_DIR}" || die "Missing ${MAGISKBOOT_BOOT_DIR}"
rm -f kernel ramdisk.cpio new-boot.img
magiskboot unpack boot.img || die "magiskboot unpack boot.img failed"

cp "$KERNEL_IMAGE" kernel

magiskboot repack boot.img || die "magiskboot repack boot.img failed"
mkdir -p "${IMAGES_DIR}"
cp new-boot.img "${IMAGES_DIR}/boot.img" || die "new-boot.img not found after repack"
# Clean up unpacked artefacts left by magiskboot (kernel, ramdisk.cpio, new-boot.img)
rm -f kernel ramdisk.cpio new-boot.img
cd "${KERNEL_ROOT}"
success "boot.img repacked and placed in ${IMAGES_DIR}/"

# ─── Step 10: dtbo.img ───────────────────────────────────────────────────────
info "Copying dtbo.img..."
DTBO_SRC="${OUT_DIR}/arch/arm64/boot/dtbo.img"
[[ -f "$DTBO_SRC" ]] || die "dtbo.img not found at ${DTBO_SRC}"
cp "$DTBO_SRC" "${IMAGES_DIR}/dtbo.img"
success "dtbo.img placed in ${IMAGES_DIR}/"

# ─── Step 11: vendor_boot.img ────────────────────────────────────────────────
info "Repacking vendor_boot.img..."
cd "${MAGISKBOOT_VENDOR_DIR}" || die "Missing ${MAGISKBOOT_VENDOR_DIR}"
rm -f dtb header ramdisk.cpio new-boot.img
rm -rf ramdisk
set +e
magiskboot unpack -h vendor_boot.img
ret=$?
set -e

if [[ "$ret" -ne 0 && "$ret" -ne 3 ]]; then
    die "magiskboot unpack vendor_boot.img failed (exit code $ret)"
fi

# Replace dtb with yupik.dtb
YUPIK_DTB="${OUT_DIR}/arch/arm64/boot/dts/vendor/qcom/yupik.dtb"
[[ -f "$YUPIK_DTB" ]] || die "yupik.dtb not found at ${YUPIK_DTB}"
cp "$YUPIK_DTB" dtb

# Patch header: replace board name value, preserving the key and all other fields
[[ -f header ]] || die "vendor_boot header file not found after unpack"
sed -i 's/^name=.*/name=SRPUE26A001/' header

# Extract ramdisk
mkdir -p ramdisk
cd ramdisk || die "Failed to cd into ramdisk"
cpio -idmu < ../ramdisk.cpio || die "cpio extract failed"

# ── Surgical module replacement ───────────────────────────────────────────────
# Remove only what we own: stale .ko files, stale modules.* files, 5.4-gki contents
# Leave everything else untouched: first_stage_ramdisk/, lib/firmware/
rm -f lib/modules/*.ko
rm -f lib/modules/modules.alias \
      lib/modules/modules.dep \
      lib/modules/modules.load \
      lib/modules/modules.softdep
# Wipe contents of any *-gki dirs including dotfiles, preserving the directories themselves
find lib/modules -maxdepth 1 -type d -name '*-gki' -print0 |
    while IFS= read -r -d '' gki_dir; do
        find "${gki_dir:?}" -mindepth 1 -delete
    done

# Copy fresh .ko files flat into lib/modules/
mkdir -p lib/modules
find "${MODULES_VERSIONED_DIR}" -name "*.ko" -exec cp -t lib/modules/ {} + \
    || die "Failed to copy .ko files into ramdisk"

# Copy generated modules.* files
cp "${FLAT_VERSIONED_DIR}/modules.dep"     lib/modules/ || die "Failed to copy modules.dep"
cp "${FLAT_VERSIONED_DIR}/modules.alias"   lib/modules/ || die "Failed to copy modules.alias"
cp "${FLAT_VERSIONED_DIR}/modules.softdep" lib/modules/ || die "Failed to copy modules.softdep"
cp "${FLAT_VERSIONED_DIR}/modules.load"    lib/modules/ || die "Failed to copy modules.load"

# Copy firmware file (static, but must be present for any vendor_boot.img)
FIRMWARE_SRC="${KERNEL_ROOT}/firmware/tsp_stm"
[[ -d "$FIRMWARE_SRC" ]] || die "Firmware source not found at ${FIRMWARE_SRC}"
mkdir -p lib/firmware/tsp_stm
cp "${FIRMWARE_SRC}"/fts5cu56a_a52sxq* lib/firmware/tsp_stm/ \
    || die "Failed to copy firmware files"

# Fix permissions
find . -type d -exec chmod 755 '{}' \;
find . -type f -exec chmod 644 '{}' \;

# Repack ramdisk cpio (-mindepth 1 excludes the redundant '.' entry)
find . -mindepth 1 -print0 \
    | cpio --null -o -H newc --owner root:root > ../ramdisk.cpio \
    || die "cpio repack failed"

cd ..
rm -rf ramdisk/

magiskboot repack vendor_boot.img || die "magiskboot repack vendor_boot.img failed"
cp new-boot.img "${IMAGES_DIR}/vendor_boot.img" || die "new-boot.img not found after vendor_boot repack"
# Clean up unpacked artefacts left by magiskboot (dtb, header, ramdisk.cpio, new-boot.img)
rm -f dtb header ramdisk.cpio new-boot.img
cd "${KERNEL_ROOT}"
success "vendor_boot.img repacked and placed in ${IMAGES_DIR}/"

# ─── Step 12: Patch update-binary ────────────────────────────────────────────
info "Patching update-binary (ROM, Root, Build date)..."
[[ -f "$UPDATE_BINARY" ]] || die "update-binary not found at ${UPDATE_BINARY}"

# Escape strings for sed
ROM_ESC="$(printf '%s\n' "$ROM_TYPE" | sed 's/[\/&]/\\&/g')"
ROOT_ESC="$(printf '%s\n' "$ROOT_DISPLAY" | sed 's/[\/&]/\\&/g')"
DATE_ESC="$(printf '%s\n' "$BUILD_DATE" | sed 's/[\/&]/\\&/g')"

sed -i \
    -e "s|^ui_print \"ROM:.*\";$|ui_print \"ROM:        ${ROM_ESC}\";|" \
    -e "s|^ui_print \"Root:.*\";$|ui_print \"Root:       ${ROOT_ESC}\";|" \
    -e "s|^ui_print \"Build date:.*\";$|ui_print \"Build date: ${DATE_ESC}\";|" \
    "$UPDATE_BINARY" || die "sed patch of update-binary failed"

# Verify the patches actually landed
grep -Fq "ROM:        ${ROM_TYPE}"     "$UPDATE_BINARY" || die "update-binary ROM patch did not apply"
grep -Fq "Root:       ${ROOT_DISPLAY}" "$UPDATE_BINARY" || die "update-binary Root patch did not apply"
grep -Fq "Build date: ${BUILD_DATE}"   "$UPDATE_BINARY" || die "update-binary Build date patch did not apply"
success "update-binary patched and verified"

# ─── Step 13: Make flashable zip ─────────────────────────────────────────────
info "Creating flashable zip: ${ZIP_NAME}..."
[[ ! -f "${KERNEL_ROOT}/${ZIP_NAME}" ]] || warn "Overwriting existing zip: ${ZIP_NAME}"
cd "${TEMPLATE_ZIP_DIR}" || die "Missing ${TEMPLATE_ZIP_DIR}"
zip -X -r -9 "${KERNEL_ROOT}/${ZIP_NAME}" META-INF/ images/ \
    || die "zip creation failed"
cd "${KERNEL_ROOT}"
success "Flashable zip created: ${KERNEL_ROOT}/${ZIP_NAME}"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Build complete!${NC}"
echo -e "  Author:     ${AUTHOR}"
echo -e "  Device:     ${DEVICE}"
echo -e "  ROM:        ${ROM_TYPE}"
echo -e "  Root:       ${ROOT_DISPLAY}"
echo -e "  Date:       ${BUILD_DATE}"
echo -e "  Output:     ${ZIP_NAME}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
