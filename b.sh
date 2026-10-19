#!/bin/bash
set -e

# ==========================================
# INISIALISASI & PATH
# ==========================================
export KERNEL_ROOT=$GITHUB_WORKSPACE
export TOOLCHAIN_DIR=$KERNEL_ROOT/toolchain_download
export ARCH=arm64
export SUBARCH=arm64
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-
export BSP_BUILD_FAMILY=sharkl3
export BSP_BUILD_ANDROID_OS=y
export DEFCONFIG="a3core_eur_open_defconfig"

# ---- Opsi ----
ENABLE_SUSFS=1                                   # 0 = build tanpa SuSFS
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="kernel-4.14"
LOCALVERSION_BASE="-Perf-v2s-BakaSU"             # nama kernel (uname -r), -SUSFS dan -@masalek ditambah otomatis

# ==========================================
# TAHAP 1: KSU Integration (BakaSU/ReSukiSU)
# ==========================================
echo "[+] Mengintegrasikan BakaSU/ReSukiSU..."
cd "$KERNEL_ROOT"

rm -rf "$KERNEL_ROOT/KernelSU"
git clone --depth=1 https://github.com/ReSukiSU/ReSukiSU.git "$KERNEL_ROOT/KernelSU"
echo "[+] KSU commit: $(git -C "$KERNEL_ROOT/KernelSU" rev-parse HEAD)"

echo "[+] Cek symlink drivers/kernelsu:"
ls -la "$KERNEL_ROOT/drivers/" | grep -i kernelsu || echo "[!] drivers/kernelsu TIDAK ADA"
echo "[+] Opsi KSU di Kconfig:"
grep -n "^config \|^	bool\|default" "$KERNEL_ROOT/KernelSU/kernel/Kconfig" | head -60 || true

# ==========================================
# TAHAP 1b: SuSFS (patch sisi kernel)
# ==========================================
if [ "$ENABLE_SUSFS" = "1" ]; then
    echo "[+] Integrasi SuSFS ($SUSFS_BRANCH)..."
    rm -rf /tmp/susfs
    git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" /tmp/susfs
    PATCH=/tmp/susfs/kernel_patches/50_add_susfs_in_kernel-4.14.patch
    if [ ! -f "$PATCH" ]; then
        echo "[!] Patch tidak ditemukan: $PATCH"
        ls /tmp/susfs/kernel_patches || true
        exit 1
    fi

    cd "$KERNEL_ROOT"

    # Salin susfs.c/susfs.h HANYA kalau patch tidak membuat file itu sendiri
    if ! grep -q '^+++ b/fs/susfs.c' "$PATCH"; then
        cp /tmp/susfs/kernel_patches/fs/susfs*.c fs/ 2>/dev/null || true
        cp /tmp/susfs/kernel_patches/include/linux/susfs*.h include/linux/ 2>/dev/null || true
    fi

    echo "[+] Dry-run patch SuSFS..."
    patch -p1 --dry-run < "$PATCH" || true

    echo "[+] Apply patch SuSFS..."
    patch -p1 < "$PATCH" || echo "[!] Ada hunk gagal, lihat .rej di bawah"

    find . -name '*.rej' -not -path './out/*' > /tmp/rej.list
    if [ -s /tmp/rej.list ]; then
        echo "[!] HUNK GAGAL. Build dihentikan biar tidak buang waktu."
        cat /tmp/rej.list
        while read -r r; do echo "----- $r -----"; cat "$r"; done < /tmp/rej.list
        exit 1
    fi

    echo "[+] Versi SuSFS di kernel:"
    grep -rn "SUSFS_VERSION" include/linux/susfs*.h 2>/dev/null | head -5 || true
fi

# ==========================================
# TAHAP 2: Extract Kernel Component
# ==========================================
cd "$KERNEL_ROOT"
echo "[+] Mengekstrak komponen sound/soc/sprd..."
mkdir -p $KERNEL_ROOT/output
if [ -d "$KERNEL_ROOT/sound/soc/sprd" ]; then
  cp -r $KERNEL_ROOT/sound/soc/sprd $KERNEL_ROOT/output/
  cd $KERNEL_ROOT/output
  zip -r sprd.zip sprd
  cd $KERNEL_ROOT
else
  echo "[!] Direktori sound/soc/sprd tidak ditemukan, melewati tahap ini."
fi

# ==========================================
# TAHAP 3: Setup Toolchains dari Skrip
# ==========================================
mkdir -p $TOOLCHAIN_DIR/gcc-14.3 $TOOLCHAIN_DIR/clang-r383902b

if [ ! -f "$TOOLCHAIN_DIR/clang-r383902b/bin/clang" ]; then
  echo "[+] Downloading Clang ke toolchain directory..."
  wget -q https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/0e9e7035bf8ad42437c6156e5950eab13655b26c/clang-r383902b.tar.gz -O /tmp/clang.tar.gz
  tar -xf /tmp/clang.tar.gz -C $TOOLCHAIN_DIR/clang-r383902b && rm /tmp/clang.tar.gz
else
  echo "[=] Clang sudah terunduh, melewatinya."
fi

if [ ! -f "$TOOLCHAIN_DIR/gcc-14.3/bin/aarch64-none-linux-gnu-gcc" ]; then
  echo "[+] Downloading GCC 14.3 ke toolchain directory..."
  wget -q https://developer.arm.com/-/media/Files/downloads/gnu/14.3.rel1/binrel/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu.tar.xz -O /tmp/gcc.tar.xz
  tar -xf /tmp/gcc.tar.xz -C $TOOLCHAIN_DIR/gcc-14.3 --strip-components=1 && rm /tmp/gcc.tar.xz
else
  echo "[=] GCC 14.3 sudah terunduh, melewatinya."
fi

# Mengatur PATH secara presisi ke bin toolchain baru
export PATH="$TOOLCHAIN_DIR/clang-r383902b/bin:$TOOLCHAIN_DIR/gcc-14.3/bin:$PATH"
export CROSS_COMPILE="$TOOLCHAIN_DIR/gcc-14.3/bin/aarch64-none-linux-gnu-"
export CROSS_COMPILE_ARM32="$TOOLCHAIN_DIR/gcc-14.3/bin/arm-none-linux-gnueabihf-"

# ==========================================
# TAHAP 4: Konfigurasi & Build Kernel
# ==========================================
cd "$KERNEL_ROOT"
CFG="$KERNEL_ROOT/out/.config"

echo "[+] Melakukan konfigurasi kernel dengan $DEFCONFIG..."
make -C $KERNEL_ROOT O=$KERNEL_ROOT/out ARCH=$ARCH CC=$CC LD=ld.lld $DEFCONFIG

# ---- BakaSU: MANUAL HOOK saja (tanpa opsi AUTO_*; setuid/read/input sudah manual di source) ----
echo "[+] Mengaktifkan BakaSU manual hook..."
scripts/config --file "$CFG" \
    -e KSU \
    -d KSU_TRACEPOINT_HOOK \
    -e KSU_MANUAL_HOOK \
    -e KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
    -e KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
    -e KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
    -e KALLSYMS_ALL

# ---- Nama kernel ----
LV="$LOCALVERSION_BASE"
[ "$ENABLE_SUSFS" = "1" ] && LV="$LV-SUSFS"
LV="$LV-@masalek"
scripts/config --file "$CFG" --set-str LOCALVERSION "$LV" -d LOCALVERSION_AUTO
echo "[+] LOCALVERSION: $LV"

if [ "$ENABLE_SUSFS" = "1" ]; then
    echo "[+] Mengaktifkan SuSFS (fitur inti saja)..."
    # AKTIF  : SUS_PATH, SUS_MOUNT, TRY_UMOUNT
    # NONAKTIF sengaja: SUS_SU (tidak didukung non-GKI), ENABLE_LOG, OPEN_REDIRECT, SUS_MAP, SUS_KSTAT, SPOOF_*
    #                   dan opsi *REORDER* (bikin bootloop di non-GKI)
    scripts/config --file "$CFG" \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_TRY_UMOUNT \
        -d KSU_SUSFS_SUS_SU \
        -d KSU_SUSFS_ENABLE_LOG \
        -d KSU_SUSFS_OPEN_REDIRECT \
        -d KSU_SUSFS_SUS_MAP \
        -d KSU_SUSFS_SUS_KSTAT \
        -d KSU_SUSFS_SPOOF_UNAME \
        -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
fi

make -C $KERNEL_ROOT O=$KERNEL_ROOT/out ARCH=$ARCH CC=$CC LD=ld.lld olddefconfig

# Pengaman bootloop: kalau ada opsi *REORDER* aktif, matikan
for sym in $(grep -E "^CONFIG_KSU_SUSFS.*REORDER.*=y" "$CFG" 2>/dev/null | sed -E 's/^CONFIG_([A-Za-z0-9_]+)=y/\1/'); do
    echo "[!] Mematikan opsi berisiko bootloop: $sym"
    scripts/config --file "$CFG" -d "$sym"
done
make -C $KERNEL_ROOT O=$KERNEL_ROOT/out ARCH=$ARCH CC=$CC LD=ld.lld olddefconfig

echo "[+] Config KSU aktif:"
grep -i "CONFIG_KSU" "$CFG" || echo "[!] CONFIG_KSU tidak ada di .config"

if ! grep -q '^CONFIG_KSU_MANUAL_HOOK=y' "$CFG"; then
    echo "[!] CONFIG_KSU_MANUAL_HOOK tidak aktif setelah olddefconfig, hentikan."
    exit 1
fi

if [ "$ENABLE_SUSFS" = "1" ]; then
    echo "[+] Verifikasi SuSFS..."
    if ! grep -q '^CONFIG_KSU_SUSFS=y' "$CFG"; then
        echo "[!] CONFIG_KSU_SUSFS TIDAK AKTIF setelah olddefconfig."
        echo "    Kemungkinan: bentrok dengan KSU_MANUAL_HOOK atau simbol tidak ada di Kconfig BakaSU."
        echo "===== Kconfig BakaSU: SUSFS & hook mode ====="
        grep -n -B2 -A14 "config KSU_SUSFS\b\|config KSU_MANUAL_HOOK\|^choice\|^endchoice" \
            "$KERNEL_ROOT/KernelSU/kernel/Kconfig" | head -200 || true
        echo "===== SuSFS di .config ====="
        grep -n "KSU_SUSFS\|KSU_MANUAL_HOOK" "$CFG" || echo "(tidak ada)"
        exit 1
    fi
    for s in KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_TRY_UMOUNT; do
        grep -q "^CONFIG_${s}=y" "$CFG" && echo "    [ok] $s" || echo "    [--] $s tidak aktif (simbol mungkin beda nama/versi)"
    done
    if grep -q '^CONFIG_KSU_SUSFS_SUS_SU=y' "$CFG"; then
        echo "[!] SUS_SU aktif, tidak didukung non-GKI. Hentikan."
        exit 1
    fi
    echo "[+] Semua opsi SuSFS di .config:"
    grep -n "KSU_SUSFS" "$CFG" || true
fi

echo "[+] Memulai kompilasi Kernel Image..."
export KBUILD_BUILD_USER="masalek"
export KBUILD_BUILD_HOST="A03Core"
export KBUILD_BUILD_TIMESTAMP="$(date '+%a %b %d %T WIB %Y')"

# Tambahan Flags Optimasi CPU (Cortex-A55) & Linker
export KCFLAGS="-march=armv8.2-a+crypto -mtune=cortex-a55 -fno-semantic-interposition"
export KBUILD_LDFLAGS="--gc-sections --icf=all"

# Ignore yaml
sed -i '/yamltree.o/d' scripts/dtc/Makefile
sed -i '/dt_to_yaml/d' scripts/dtc/dtc.c

# Eksekusi Build Image
make -C $KERNEL_ROOT O=$KERNEL_ROOT/out -j$(nproc) ARCH=$ARCH \
    CC=$CC \
    CROSS_COMPILE=$CROSS_COMPILE \
    CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    CLANG_TRIPLE=$CLANG_TRIPLE \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    KCFLAGS="$KCFLAGS" \
    KBUILD_LDFLAGS="$KBUILD_LDFLAGS" \
    Image

# ==========================================
# BUILD KERNEL MODULES
# ==========================================
echo "[+] Memulai kompilasi kernel modules (.ko)..."

make -C $KERNEL_ROOT O=$KERNEL_ROOT/out -j$(nproc) ARCH=$ARCH \
    CC=$CC \
    CROSS_COMPILE=$CROSS_COMPILE \
    CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
    CLANG_TRIPLE=$CLANG_TRIPLE \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    KCFLAGS="$KCFLAGS" \
    KBUILD_LDFLAGS="$KBUILD_LDFLAGS" \
    modules

echo "[+] Jumlah .ko yang dihasilkan:"
find "$KERNEL_ROOT/out" -type f -name "*.ko" | wc -l

# ==========================================
# ARTIFACTS: Pengumpulan Hasil Jadi
# ==========================================
echo "[+] Mengumpulkan hasil eksport..."
mkdir -p "$GITHUB_WORKSPACE/output_artifacts"

OUT="$KERNEL_ROOT/out"
ART="$GITHUB_WORKSPACE/output_artifacts"

# Kernel utama
if [ -f "$OUT/arch/arm64/boot/Image" ]; then
    cp "$OUT/arch/arm64/boot/Image" "$ART/"
    echo "[+] Image"
fi

# Kernel config
if [ -f "$OUT/.config" ]; then
    cp "$OUT/.config" "$ART/kernel.config"
    echo "[+] .config"
fi

# System.map
if [ -f "$OUT/System.map" ]; then
    cp "$OUT/System.map" "$ART/"
    echo "[+] System.map"
fi

# Module symbol table
if [ -f "$OUT/Module.symvers" ]; then
    cp "$OUT/Module.symvers" "$ART/"
    echo "[+] Module.symvers"
fi

MODULE_DIR="$ART/modules"
mkdir -p "$MODULE_DIR"

find "$OUT" -type f -name "*.ko" | while read -r ko; do
    rel="${ko#$OUT/}"
    mkdir -p "$MODULE_DIR/$(dirname "$rel")"
    cp -v "$ko" "$MODULE_DIR/$rel"
done

echo ""
echo "[+] Daftar module:"
find "$MODULE_DIR" -type f -name "*.ko" -exec du -h {} \;

echo ""
echo "[+] Daftar artifact:"
find "$ART" -type f -exec du -h {} \;
