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
SUSFS_SUS_MOUNT=0                                # 0 = aman buat boot pertama. Set 1 SETELAH kernel terbukti boot
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
    patch -p1 --no-backup-if-mismatch < "$PATCH" || echo "[!] Ada hunk gagal, mencoba perbaikan otomatis..."

    echo "[+] Memperbaiki hunk yang gagal (include/hook yang beda di source Samsung)..."
    python3 - <<'PYEOF' || true
import os, re, sys

root = os.environ["KERNEL_ROOT"]
log, bad = [], []


def rd(p):
    with open(os.path.join(root, p), encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def wr(p, s):
    with open(os.path.join(root, p), "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(s)


def rm_rej(p):
    f = os.path.join(root, p + ".rej")
    if os.path.exists(f):
        os.remove(f)


def ok(p, m):
    log.append("[OK]    %-24s %s" % (p, m))


def skip(p, m):
    log.append("[SKIP]  %-24s %s" % (p, m))


def fail(p, m):
    bad.append(p)
    log.append("[GAGAL] %-24s %s" % (p, m))


def func_span(src, header_re):
    m = re.search(header_re, src, re.M)
    if not m:
        return None
    op = src.find("{", m.end())
    if op < 0:
        return None
    depth = 0
    for i in range(op, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return m.start(), op, i
    return None


# ---------------------------------------------------------------- namei.c
def fix_namei():
    p = "fs/namei.c"
    s = rd(p)
    if "susfs_def.h" in s:
        rm_rej(p)
        return skip(p, "include sudah ada")
    m = re.search(r'^#include "internal.h"\n', s, re.M)
    if not m:
        return fail(p, '#include "internal.h" tidak ketemu')
    blk = ("#if defined(CONFIG_KSU_SUSFS_SUS_PATH) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n"
           "#include <linux/susfs_def.h>\n#endif\n\n")
    wr(p, s[:m.start()] + blk + s[m.start():])
    rm_rej(p)
    ok(p, "include susfs_def.h ditambah")


# ------------------------------------------------------------- task_mmu.c
def fix_task_mmu():
    p = "fs/proc/task_mmu.c"
    s = rd(p)
    if "susfs_def.h" in s:
        rm_rej(p)
        return skip(p, "include sudah ada")
    m = re.search(r'^#include <asm/elf.h>\n', s, re.M)
    if not m:
        return fail(p, "#include <asm/elf.h> tidak ketemu")
    blk = ("#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n\n")
    wr(p, s[:m.start()] + blk + s[m.start():])
    rm_rej(p)
    ok(p, "include susfs_def.h ditambah")


# ------------------------------------------------------------- cmdline.c
def fix_cmdline():
    p = "fs/proc/cmdline.c"
    s = rd(p)
    if "susfs_spoof_cmdline_or_bootconfig" in s:
        rm_rej(p)
        return skip(p, "sudah ada")
    m1 = re.search(r'^static int cmdline_proc_show\(', s, re.M)
    m2 = re.search(r'^[ \t]*seq_printf\(m, "%s\\n", saved_command_line\);', s, re.M)
    if not (m1 and m2):
        rm_rej(p)  # fitur spoof cmdline dimatikan, aman dilewati
        return skip(p, "pola beda, dilewati (SPOOF_CMDLINE dimatikan)")
    body = ("#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
            "\tif (!susfs_spoof_cmdline_or_bootconfig(m)) {\n"
            "\t\tseq_putc(m, '\\n');\n\t\treturn 0;\n\t}\n#endif\n")
    decl = ("#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
            "extern int susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);\n#endif\n\n")
    s = s[:m2.start()] + body + s[m2.start():]
    s = s[:m1.start()] + decl + s[m1.start():]
    wr(p, s)
    rm_rej(p)
    ok(p, "hook spoof cmdline dipasang")


# --------------------------------------------------------------- readdir.c
def fix_readdir():
    p = "fs/readdir.c"
    s = rd(p)
    span = func_span(s, r'^static int compat_fillonedir\(')
    if not span:
        return fail(p, "compat_fillonedir tidak ketemu")
    st, op, cl = span
    body = s[op:cl + 1]
    if "susfs_sus_ino_for_filldir64" in body:
        rm_rej(p)
        return skip(p, "hook sudah ada di compat_fillonedir")
    m = re.search(r'if \(buf->result\)\s*\n\s*return -EINVAL;[ \t]*\n', body)
    if not m:
        return fail(p, "pola 'if (buf->result) return -EINVAL;' tidak ketemu di compat_fillonedir")
    blk = ("#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
           "\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {\n"
           "\t\treturn 0;\n\t}\n#endif\n")
    body = body[:m.end()] + blk + body[m.end():]
    wr(p, s[:op] + body + s[cl + 1:])
    rm_rej(p)
    ok(p, "hook SUS_PATH dipasang di compat_fillonedir")


# ------------------------------------------------------------- namespace.c
NS_TOP_INC = ("#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)\n"
              "#include <linux/susfs_def.h>\n#endif\n\n")
NS_TOP_DECL = """
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern bool susfs_is_current_zygote_domain(void);

static DEFINE_IDA(susfs_mnt_id_ida);
static DEFINE_IDA(susfs_mnt_group_ida);
static int susfs_mnt_id_start = DEFAULT_SUS_MNT_ID;
static int susfs_mnt_group_start = DEFAULT_SUS_MNT_GROUP_ID;

#define CL_ZYGOTE_COPY_MNT_NS BIT(24) /* used by copy_mnt_ns() */
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif

#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);
bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
extern int susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);
bool susfs_is_auto_add_sus_bind_mount_enabled = true;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);
bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;
#endif
"""
NS_BOTTOM_UMOUNT = """
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
extern void susfs_try_umount_all(uid_t uid);
void susfs_run_try_umount_for_current_mnt_ns(void) {
	struct mount *mnt;
	struct mnt_namespace *mnt_ns;

	mnt_ns = current->nsproxy->mnt_ns;
	// Lock the namespace
	namespace_lock();
	list_for_each_entry(mnt, &mnt_ns->list, mnt_list) {
		// Change the sus mount to be private
		if (mnt->mnt_id >= DEFAULT_SUS_MNT_ID) {
			change_mnt_propagation(mnt, MS_PRIVATE);
		}
	}
	// Unlock the namespace
	namespace_unlock();
	susfs_try_umount_all(current_uid().val);
}
#endif
"""
NS_BOTTOM_DEVNAME = """#ifdef CONFIG_KSU_SUSFS
bool susfs_is_mnt_devname_ksu(struct path *path) {
	struct mount *mnt;

	if (path && path->mnt) {
		mnt = real_mount(path->mnt);
		if (mnt && mnt->mnt_devname && !strcmp(mnt->mnt_devname, "KSU")) {
			return true;
		}
	}
	return false;
}
#endif
"""


def fix_namespace():
    p = "fs/namespace.c"
    s = rd(p)
    notes = []
    if "susfs_mnt_id_ida" not in s:
        m = re.search(r'^#include "pnode.h"\n', s, re.M)
        if not m:
            return fail(p, '#include "pnode.h" tidak ketemu')
        s = s[:m.start()] + NS_TOP_INC + s[m.start():]
        m = re.search(r'^#include "internal.h"\n', s, re.M)
        if not m:
            return fail(p, '#include "internal.h" tidak ketemu')
        s = s[:m.end()] + NS_TOP_DECL + s[m.end():]
        notes.append("blok atas")
    if not re.search(r'void susfs_run_try_umount_for_current_mnt_ns\(', s):
        s = s.rstrip("\n") + "\n" + NS_BOTTOM_UMOUNT
        notes.append("try_umount")
    if not re.search(r'bool susfs_is_mnt_devname_ksu\(struct path', s):
        s = s.rstrip("\n") + "\n" + NS_BOTTOM_DEVNAME
        notes.append("devname_ksu")
    wr(p, s)
    rm_rej(p)
    if notes:
        ok(p, "ditambah: " + ", ".join(notes))
    else:
        skip(p, "semua sudah ada")


# --------------------------------------------------------------- fdinfo.c
def fix_fdinfo():
    p = "fs/notify/fdinfo.c"
    if os.path.exists(os.path.join(root, p + ".rej")):
        rm_rej(p)
        skip(p, "hook sembunyikan inotify fdinfo dilewati (tidak kritikal, pola 4.14 beda)")


for fn in (fix_namei, fix_task_mmu, fix_cmdline, fix_readdir, fix_namespace, fix_fdinfo):
    try:
        fn()
    except Exception as e:
        fail(fn.__name__, "exception: %r" % (e,))

print("\n".join(log))
sys.exit(1 if bad else 0)
PYEOF

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
    -d KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
    -d KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
    -d KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
    -e KALLSYMS_ALL

# ---- Nama kernel ----
LV="$LOCALVERSION_BASE"
[ "$ENABLE_SUSFS" = "1" ] && LV="$LV-SUSFS"
LV="$LV-@masalek"
scripts/config --file "$CFG" --set-str LOCALVERSION "$LV" -d LOCALVERSION_AUTO
echo "[+] LOCALVERSION: $LV"

if [ "$ENABLE_SUSFS" = "1" ]; then
    echo "[+] Mengaktifkan SuSFS (fitur inti saja)..."
    # AKTIF  : SUS_PATH, TRY_UMOUNT (+ SUS_MOUNT kalau SUSFS_SUS_MOUNT=1)
    # NONAKTIF sengaja: SUS_SU (tidak didukung non-GKI), ENABLE_LOG, OPEN_REDIRECT, SUS_MAP, SUS_KSTAT, SPOOF_*
    #                   dan opsi *REORDER* (bikin bootloop di non-GKI)
    scripts/config --file "$CFG" \
        -e KSU_SUSFS \
        -e KSU_SUSFS_SUS_PATH \
        -e KSU_SUSFS_TRY_UMOUNT \
        -d KSU_SUSFS_SUS_SU \
        -d KSU_SUSFS_ENABLE_LOG \
        -d KSU_SUSFS_OPEN_REDIRECT \
        -d KSU_SUSFS_SUS_MAP \
        -d KSU_SUSFS_SUS_KSTAT \
        -d KSU_SUSFS_SPOOF_UNAME \
        -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG

    # SUS_MOUNT di patch ini membawa logika reorder mnt_id (dilaporkan bikin bootloop di non-GKI)
    if [ "$SUSFS_SUS_MOUNT" = "1" ]; then
        scripts/config --file "$CFG" -e KSU_SUSFS_SUS_MOUNT
    else
        scripts/config --file "$CFG" -d KSU_SUSFS_SUS_MOUNT
    fi
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
    CHK="KSU_SUSFS_SUS_PATH KSU_SUSFS_TRY_UMOUNT"
    [ "$SUSFS_SUS_MOUNT" = "1" ] && CHK="$CHK KSU_SUSFS_SUS_MOUNT"
    for s in $CHK; do
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
