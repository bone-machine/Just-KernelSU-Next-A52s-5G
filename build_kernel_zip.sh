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

# ─── Trap: clean up temp dirs on unexpected exit ──────────────────────────────
TMP_CLANG=""
TMP_MAGISK=""
TMP_AVBTOOL=""
TMP_ZIP_STAGING=""
TMP_BOOT=""
TMP_VENDOR_BOOT=""
cleanup_tmp() {
    [[ -n "$TMP_CLANG"        && -d "$TMP_CLANG"        ]] && rm -rf "$TMP_CLANG"
    [[ -n "$TMP_MAGISK"       && -d "$TMP_MAGISK"       ]] && rm -rf "$TMP_MAGISK"
    [[ -n "$TMP_AVBTOOL"      && -f "$TMP_AVBTOOL"      ]] && rm -f "$TMP_AVBTOOL"
    [[ -n "$TMP_ZIP_STAGING"  && -d "$TMP_ZIP_STAGING"  ]] && rm -rf "$TMP_ZIP_STAGING"
    [[ -n "$TMP_BOOT"         && -d "$TMP_BOOT"         ]] && rm -rf "$TMP_BOOT"
    [[ -n "$TMP_VENDOR_BOOT"  && -d "$TMP_VENDOR_BOOT"  ]] && rm -rf "$TMP_VENDOR_BOOT"
}
trap cleanup_tmp EXIT

# ─── Hardcoded config ─────────────────────────────────────────────────────────
AUTHOR="bone-machine"
DEVICE="a52sxq"
# Change these to your own values before building
KBUILD_BUILD_USER="bone-machine"
KBUILD_BUILD_HOST="rios"
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz"
MAGISK_APK_URL="https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk"
# avbtool — downloaded from AOSP main branch
# Not pinned to a specific commit: erase_footer has been stable for years
# and the Python syntax check below catches any corrupted or breaking download
AVBTOOL_URL="https://android.googlesource.com/platform/external/avb/+/refs/heads/main/avbtool.py?format=TEXT"

# ─── Paths ────────────────────────────────────────────────────────────────────
# Script lives in the kernel root — resolve its real location regardless of cwd
KERNEL_ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN_DIR="${KERNEL_ROOT}/toolchain"
CLANG_DIR="${TOOLCHAIN_DIR}/clang"
MAGISKBOOT_BIN="${TOOLCHAIN_DIR}/magiskboot"
AVBTOOL_BIN="${TOOLCHAIN_DIR}/avbtool"
OUT_DIR="${KERNEL_ROOT}/out"

# Source images — never modified by the script
IMAGES_AOSP_DIR="${TOOLCHAIN_DIR}/baseimages/aosp"
IMAGES_ONEUI_DIR="${TOOLCHAIN_DIR}/baseimages/oneui"

# Flashable zip template — tracked in git, never modified by the script
TEMPLATE_ZIP_DIR="${TOOLCHAIN_DIR}/template-zip-file"
TEMPLATE_IMAGES_DIR="${TEMPLATE_ZIP_DIR}/images"
UPDATE_BINARY_TEMPLATE="${TEMPLATE_ZIP_DIR}/META-INF/com/google/android/update-binary"

# ─── Derived build metadata ───────────────────────────────────────────────────
BUILD_DATE="$(date +%Y-%m-%d)"

# Detect ROM type from current git branch
CURRENT_BRANCH="$(git -C "${KERNEL_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
case "$CURRENT_BRANCH" in
    main)      ROM_TYPE="One-UI" ROM_DISPLAY="One UI" ;;
    *oneui*)   ROM_TYPE="One-UI" ROM_DISPLAY="One UI" ;;
    *aosp*)    ROM_TYPE="AOSP" ROM_DISPLAY="AOSP"   ;;
    *)
        warn "Branch '$CURRENT_BRANCH' doesn't match any known ROM type — defaulting to AOSP"
        ROM_TYPE="AOSP"
        ;;
esac

# Select source images directory based on ROM type
if [[ "$ROM_TYPE" == "AOSP" ]]; then
    SOURCE_IMAGES_DIR="${IMAGES_AOSP_DIR}"
else
    SOURCE_IMAGES_DIR="${IMAGES_ONEUI_DIR}"
fi

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

# ZIP name
if [[ "$KSU_VERSION" == "none" ]]; then
    ZIP_NAME="${AUTHOR}_${BUILD_DATE}_${ROM_TYPE}_${DEVICE}.zip"
else
    ZIP_NAME="${AUTHOR}_${BUILD_DATE}_${ROM_TYPE}_KSU-Next-${KSU_VERSION}_${DEVICE}.zip"
fi

# ─── Sanity checks ────────────────────────────────────────────────────────────
[[ "$(basename "$KERNEL_ROOT")" == "android_kernel_samsung_sm7325_a52s_5g" ]] \
    || die "Run this script from the kernel root (android_kernel_samsung_sm7325_a52s_5g/)"

for cmd in curl unzip zip cpio find sed git uname tar grep nproc cp chmod depmod python3; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd"
done

# ─── Pre-flight checks ────────────────────────────────────────────────────────
info "Running pre-flight checks..."
PREFLIGHT_FAILED=0

check_file() {
    local path="$1" desc="$2"
    if [[ ! -f "$path" ]]; then
        echo -e "${RED}${BOLD}[MISSING]${NC} ${desc}: ${path}"
        PREFLIGHT_FAILED=1
    fi
}

check_dir() {
    local path="$1" desc="$2"
    if [[ ! -d "$path" ]]; then
        echo -e "${RED}${BOLD}[MISSING]${NC} ${desc}: ${path}"
        PREFLIGHT_FAILED=1
    fi
}

check_glob() {
    local glob="$1" desc="$2"
    if ! compgen -G "$glob" > /dev/null 2>&1; then
        echo -e "${RED}${BOLD}[MISSING]${NC} ${desc}: ${glob}"
        PREFLIGHT_FAILED=1
    fi
}

# Source boot images for current ROM type
check_file "${SOURCE_IMAGES_DIR}/boot.img"        "Source boot.img (${ROM_TYPE})"
check_file "${SOURCE_IMAGES_DIR}/vendor_boot.img" "Source vendor_boot.img (${ROM_TYPE})"

# Flashable zip template
check_file "${UPDATE_BINARY_TEMPLATE}"            "update-binary template"
check_dir  "${TEMPLATE_ZIP_DIR}/META-INF"         "Flashable zip META-INF dir"

# Firmware
check_dir  "${KERNEL_ROOT}/firmware/tsp_stm"      "Firmware source dir"
check_glob "${KERNEL_ROOT}/firmware/tsp_stm/fts5cu56a_a52sxq*" "TSP firmware file"

# KernelSU-Next submodule (only on KSU branches)
if [[ "$KSU_VERSION" != "none" ]]; then
    check_dir "${KERNEL_ROOT}/KernelSU-Next"      "KernelSU-Next submodule"
fi

# Kernel defconfig
check_file "${KERNEL_ROOT}/arch/arm64/configs/vendor/a52sxq_kor_single_defconfig" "Kernel defconfig"

# Verify update-binary template contains expected placeholders
for placeholder in "@ROM_DISPLAY@" "@ROOT_DISPLAY@" "@BUILD_DATE@"; do
    grep -q "$placeholder" "$UPDATE_BINARY_TEMPLATE" || {
        echo -e "${RED}${BOLD}[MISSING]${NC} Placeholder ${placeholder} not found in update-binary template"
        PREFLIGHT_FAILED=1
    }
done

(( PREFLIGHT_FAILED == 0 )) || die "Pre-flight checks failed — fix the above before building"
success "Pre-flight checks passed"

# ─── Step 1: Git submodules ───────────────────────────────────────────────────
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

# Post-install sanity check
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

    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        x86_64)  APK_ARCH="x86_64"      ;;
        aarch64) APK_ARCH="arm64-v8a"   ;;
        armv7l)  APK_ARCH="armeabi-v7a" ;;
        i686)    APK_ARCH="x86"         ;;
        *) die "Unsupported host architecture: ${HOST_ARCH}" ;;
    esac

    MAGISKBOOT_SO="${TMP_MAGISK}/extracted/lib/${APK_ARCH}/libmagiskboot.so"
    [[ -f "$MAGISKBOOT_SO" ]] || die "libmagiskboot.so not found at ${MAGISKBOOT_SO}"

    cp "$MAGISKBOOT_SO" "$MAGISKBOOT_BIN"
    chmod +x "$MAGISKBOOT_BIN"
    rm -rf "$TMP_MAGISK"
    TMP_MAGISK=""
    success "magiskboot installed to ${MAGISKBOOT_BIN}"
fi

# ─── Step 4: avbtool ─────────────────────────────────────────────────────────
if [[ -x "$AVBTOOL_BIN" ]]; then
    success "avbtool already present at ${AVBTOOL_BIN}, skipping"
else
    info "Downloading avbtool..."
    TMP_AVBTOOL="$(mktemp)"
    # The URL returns base64-encoded content — decode it to get the Python script
    curl -L --progress-meter "$AVBTOOL_URL" \
        | base64 -d > "$TMP_AVBTOOL" \
        || die "Failed to download avbtool"
    # Verify it's actually avbtool and not a corrupted download or HTML error page
    python3 -c "import ast; ast.parse(open('${TMP_AVBTOOL}').read())" \
        || die "avbtool download is not valid Python — possibly corrupted"
    grep -q "def erase_footer" "$TMP_AVBTOOL" \
        || die "avbtool download does not contain erase_footer — wrong file downloaded"
    chmod +x "$TMP_AVBTOOL"
    mv "$TMP_AVBTOOL" "$AVBTOOL_BIN"
    success "avbtool installed to ${AVBTOOL_BIN}"
fi

# ─── Step 5: Export PATH ──────────────────────────────────────────────────────
export PATH="${CLANG_DIR}/bin:${TOOLCHAIN_DIR}:$PATH"
info "PATH updated: Clang and toolchain directories prepended"

# ─── Step 6: Prepare working image copies ────────────────────────────────────
info "Preparing working image copies from ${ROM_TYPE} source images..."

# Create temp working dirs for magiskboot unpack/repack — cleaned up on exit
TMP_BOOT="$(mktemp -d)"
TMP_VENDOR_BOOT="$(mktemp -d)"

cp "${SOURCE_IMAGES_DIR}/boot.img"        "${TMP_BOOT}/boot.img"
cp "${SOURCE_IMAGES_DIR}/vendor_boot.img" "${TMP_VENDOR_BOOT}/vendor_boot.img"

# Strip AVB footer from working copies before magiskboot touches them
# avbtool exits non-zero if footer already absent — that's fine, image is already clean
info "Stripping AVB footer from boot.img..."
avbtool erase_footer --image "${TMP_BOOT}/boot.img" 2>/dev/null || true

info "Stripping AVB footer from vendor_boot.img..."
avbtool erase_footer --image "${TMP_VENDOR_BOOT}/vendor_boot.img" 2>/dev/null || true

# Validate ROM type matches image content
# SAMSUNG_SEANDROID is a Samsung-specific boot image marker present in One UI images
# and absent in AOSP images for this device — reliable enough for our purposes
info "Validating boot.img matches expected ROM type (${ROM_TYPE})..."
BOOT_UNPACK_OUTPUT="$(magiskboot unpack "${TMP_BOOT}/boot.img" 2>&1 || true)"
rm -f "${TMP_BOOT}/kernel" "${TMP_BOOT}/ramdisk.cpio"

if [[ "$ROM_TYPE" == "One-UI" ]]; then
    echo "$BOOT_UNPACK_OUTPUT" | grep -q "SAMSUNG_SEANDROID" \
        || die "boot.img does not appear to be a One UI image (SAMSUNG_SEANDROID not found) — check ${SOURCE_IMAGES_DIR}/boot.img"
else
    echo "$BOOT_UNPACK_OUTPUT" | grep -q "SAMSUNG_SEANDROID" \
        && die "boot.img appears to be a One UI image but branch is ${CURRENT_BRANCH} — check ${SOURCE_IMAGES_DIR}/boot.img"
fi

success "Working image copies prepared and validated"

# ─── Step 7: Clean previous build ────────────────────────────────────────────
info "Wiping out/ from previous build..."
rm -rf "${OUT_DIR}"
success "Clean done"

# ─── Step 8: Defconfig ───────────────────────────────────────────────────────
info "Generating defconfig..."
make -C "${KERNEL_ROOT}" O="${OUT_DIR}" ARCH=arm64 vendor/a52sxq_kor_single_defconfig \
    || die "defconfig failed"
success "Defconfig generated"

# ─── Step 9: Kernel build ────────────────────────────────────────────────────
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

# ─── Step 10: Install and strip modules, generate module metadata ─────────────
info "Installing kernel modules..."
MODULES_STAGING="${OUT_DIR}/modules_staging"
rm -rf "${MODULES_STAGING}"
mkdir -p "${MODULES_STAGING}"

# modules_install harvests already-built .ko files — no recompilation
# STRIP explicitly set to llvm-strip from our Clang toolchain
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

# Find the versioned subdir — must be exactly one
mapfile -t MODULE_DIRS < <(
    find "${MODULES_STAGING}/lib/modules" -mindepth 1 -maxdepth 1 -type d
)
(( ${#MODULE_DIRS[@]} == 1 )) \
    || die "Expected exactly one module directory in ${MODULES_STAGING}/lib/modules, found ${#MODULE_DIRS[@]}"
MODULES_VERSIONED_DIR="${MODULE_DIRS[0]}"
KERNEL_VERSION="$(basename "$MODULES_VERSIONED_DIR")"
info "Kernel version: ${KERNEL_VERSION}"

MODULE_COUNT="$(find "${MODULES_VERSIONED_DIR}" -name "*.ko" | wc -l)"
(( MODULE_COUNT > 0 )) || die "No kernel modules found after modules_install — aborting"
info "Found ${MODULE_COUNT} kernel modules"

# Detect duplicate module filenames before flattening
DUPLICATES="$(find "${MODULES_VERSIONED_DIR}" -name '*.ko' -printf '%f\n' | sort | uniq -d)"
if [[ -n "$DUPLICATES" ]]; then
    echo "Duplicate module filenames:"
    echo "$DUPLICATES"
    die "Flattening would overwrite files — aborting"
fi

# Create flat module staging dir for depmod
# depmod requires a versioned subdir internally; device expects flat /lib/modules/
FLAT_MODULES_DIR="${OUT_DIR}/flat_modules"
rm -rf "${FLAT_MODULES_DIR}"
mkdir -p "${FLAT_MODULES_DIR}/lib/modules/${KERNEL_VERSION}"

find "${MODULES_VERSIONED_DIR}" -name "*.ko" \
    -exec cp {} "${FLAT_MODULES_DIR}/lib/modules/${KERNEL_VERSION}/" \; \
    || die "Failed to flatten modules"

# Run depmod using System.map for correct symbol resolution
# depmod warnings about modules.order, modules.builtin, modules.builtin.modinfo
# are harmless — those files don't exist for external modules and don't affect
# the generated modules.dep or modules.alias
SYSTEM_MAP="${OUT_DIR}/System.map"
[[ -f "$SYSTEM_MAP" ]] || die "System.map not found at ${SYSTEM_MAP}"
depmod \
    -b "${FLAT_MODULES_DIR}" \
    -F "$SYSTEM_MAP" \
    "$KERNEL_VERSION" \
    || die "depmod failed"

FLAT_VERSIONED_DIR="${FLAT_MODULES_DIR}/lib/modules/${KERNEL_VERSION}"
[[ -d "$FLAT_VERSIONED_DIR" ]] || die "depmod did not create ${FLAT_VERSIONED_DIR}"

# Fix versioned paths — device expects flat /lib/modules/foo.ko
for mod_file in "${FLAT_VERSIONED_DIR}"/modules.*; do
    [[ -f "$mod_file" ]] || continue
    sed -E -i 's@(^| )([^ /][^ ]*\.ko)@\1/lib/modules/\2@g' "$mod_file"
done

# Generate modules.load (Android-specific, depmod doesn't produce it)
find "${FLAT_VERSIONED_DIR}" -maxdepth 1 -name "*.ko" \
    -exec basename {} \; | sort \
    > "${FLAT_VERSIONED_DIR}/modules.load" \
    || die "Failed to generate modules.load"

success "Modules installed, stripped, and metadata generated: ${MODULE_COUNT} files"

# Verify kernel Image exists before repack stage
KERNEL_IMAGE="${OUT_DIR}/arch/arm64/boot/Image"
[[ -f "$KERNEL_IMAGE" ]] || die "Kernel Image missing after build — check build logs"

# ─── Step 11: Create temp zip staging dir and ensure images dir exists ────────
# template-zip-file/images/ is intentionally kept empty in git (no .gitkeep needed)
# The script creates it here if absent, populates it via the temp staging dir
mkdir -p "${TEMPLATE_IMAGES_DIR}"

info "Creating flashable zip: ${ZIP_NAME}..."
[[ ! -f "${KERNEL_ROOT}/${ZIP_NAME}" ]] || warn "Overwriting existing zip: ${ZIP_NAME}"

TMP_ZIP_STAGING="$(mktemp -d)"
mkdir -p "${TMP_ZIP_STAGING}/images"
cp -r "${TEMPLATE_ZIP_DIR}/META-INF" "${TMP_ZIP_STAGING}/META-INF"

# ─── Step 12: boot.img ───────────────────────────────────────────────────────
info "Repacking boot.img..."
cd "${TMP_BOOT}" || die "Failed to cd into boot working dir"
rm -f kernel ramdisk.cpio new-boot.img
magiskboot unpack boot.img || die "magiskboot unpack boot.img failed"

cp "$KERNEL_IMAGE" kernel

magiskboot repack boot.img || die "magiskboot repack boot.img failed"
cp new-boot.img "${TMP_ZIP_STAGING}/images/boot.img" || die "new-boot.img not found after repack"
rm -f kernel ramdisk.cpio new-boot.img
cd "${KERNEL_ROOT}"
success "boot.img repacked"

# ─── Step 13: dtbo.img ───────────────────────────────────────────────────────
info "Copying dtbo.img..."
DTBO_SRC="${OUT_DIR}/arch/arm64/boot/dtbo.img"
[[ -f "$DTBO_SRC" ]] || die "dtbo.img not found at ${DTBO_SRC}"
cp "$DTBO_SRC" "${TMP_ZIP_STAGING}/images/dtbo.img"
success "dtbo.img placed in staging dir"

# ─── Step 14: vendor_boot.img ────────────────────────────────────────────────
info "Repacking vendor_boot.img..."
cd "${TMP_VENDOR_BOOT}" || die "Failed to cd into vendor_boot working dir"
rm -f dtb header ramdisk.cpio new-boot.img
rm -rf ramdisk

# magiskboot returns exit code 3 for a successful vendor_boot unpack
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

# Patch header board name
[[ -f header ]] || die "vendor_boot header file not found after unpack"
sed -i 's/^name=.*/name=SRPUE26A001/' header

# Extract ramdisk
mkdir -p ramdisk
cd ramdisk || die "Failed to cd into ramdisk"
cpio -idmu < ../ramdisk.cpio || die "cpio extract failed"

# Surgical module replacement — leave first_stage_ramdisk/ and lib/firmware/ untouched
mkdir -p lib/modules

rm -f lib/modules/*.ko
rm -f lib/modules/modules.alias \
      lib/modules/modules.dep \
      lib/modules/modules.load \
      lib/modules/modules.softdep

# Wipe *-gki dir contents if present, preserving the directories themselves
find lib/modules -maxdepth 1 -type d -name '*-gki' -print0 |
    while IFS= read -r -d '' gki_dir; do
        find "${gki_dir:?}" -mindepth 1 -delete
    done

# Copy fresh .ko files from canonical kernel install output
find "${MODULES_VERSIONED_DIR}" -name "*.ko" -exec cp -t lib/modules/ {} + \
    || die "Failed to copy .ko files into ramdisk"

# Copy generated modules.* files
cp "${FLAT_VERSIONED_DIR}/modules.dep"     lib/modules/ || die "Failed to copy modules.dep"
cp "${FLAT_VERSIONED_DIR}/modules.alias"   lib/modules/ || die "Failed to copy modules.alias"
cp "${FLAT_VERSIONED_DIR}/modules.softdep" lib/modules/ || die "Failed to copy modules.softdep"
cp "${FLAT_VERSIONED_DIR}/modules.load"    lib/modules/ || die "Failed to copy modules.load"

# Copy firmware
FIRMWARE_SRC="${KERNEL_ROOT}/firmware/tsp_stm"
[[ -d "$FIRMWARE_SRC" ]] || die "Firmware source not found at ${FIRMWARE_SRC}"
mkdir -p lib/firmware/tsp_stm
cp "${FIRMWARE_SRC}"/fts5cu56a_a52sxq* lib/firmware/tsp_stm/ \
    || die "Failed to copy firmware files"

# Fix permissions
find . -type d -exec chmod 755 '{}' \;
find . -type f -exec chmod 644 '{}' \;

# Repack ramdisk cpio
find . -mindepth 1 -print0 \
    | cpio --null -o -H newc --owner root:root > ../ramdisk.cpio \
    || die "cpio repack failed"

cd ..
rm -rf ramdisk/

magiskboot repack vendor_boot.img || die "magiskboot repack vendor_boot.img failed"
cp new-boot.img "${TMP_ZIP_STAGING}/images/vendor_boot.img" \
    || die "new-boot.img not found after vendor_boot repack"
rm -f dtb header ramdisk.cpio new-boot.img
cd "${KERNEL_ROOT}"
success "vendor_boot.img repacked"

# ─── Step 15: Build flashable zip ────────────────────────────────────────────
# Verify all three images landed in staging before zipping
for img in boot.img vendor_boot.img dtbo.img; do
    [[ -f "${TMP_ZIP_STAGING}/images/${img}" ]] \
        || die "Missing ${img} in zip staging dir — repack stage may have failed"
done

# Patch update-binary placeholders in the temp copy only — original template untouched
sed -i \
    -e "s|@ROM_DISPLAY@|${ROM_DISPLAY}|g" \
    -e "s|@ROOT_DISPLAY@|${ROOT_DISPLAY}|g" \
    -e "s|@BUILD_DATE@|${BUILD_DATE}|g" \
    "${TMP_ZIP_STAGING}/META-INF/com/google/android/update-binary" \
    || die "Failed to patch update-binary placeholders"

cd "${TMP_ZIP_STAGING}"
zip -X -r -9 "${KERNEL_ROOT}/${ZIP_NAME}" META-INF/ images/ \
    || die "zip creation failed"
cd "${KERNEL_ROOT}"

rm -rf "$TMP_ZIP_STAGING"
TMP_ZIP_STAGING=""
success "Flashable zip created: ${KERNEL_ROOT}/${ZIP_NAME}"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Build complete!${NC}"
echo -e "  Author:     ${AUTHOR}"
echo -e "  Device:     ${DEVICE}"
echo -e "  ROM:        ${ROM_DISPLAY}"
echo -e "  Root:       ${ROOT_DISPLAY}"
echo -e "  Date:       ${BUILD_DATE}"
echo -e "  Output:     ${ZIP_NAME}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"