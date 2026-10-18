#!/usr/bin/env python3
"""
Pasang manual hook BakaSU/ReSukiSU di source kernel 4.14 (non-GKI).

Hook yang dipasang (kalau belum ada):
  - fs/stat.c         : ksu_handle_stat, ksu_handle_newfstat_ret
  - fs/exec.c         : ksu_handle_execveat, ksu_handle_post_execveat
  - fs/open.c         : ksu_handle_faccessat
  - kernel/reboot.c   : ksu_handle_sys_reboot (fallback: kernel/sys.c)

Hook setuid, read(init.rc), dan input TIDAK dipasang di sini karena
diurus otomatis lewat CONFIG_KSU_MANUAL_HOOK_AUTO_*_HOOK.

Pemakaian:  python3 ksu_hooks.py <root-source-kernel>
Exit code 1 kalau ada hook yang gagal dipasang.
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
report = []
failed = False


def p(rel):
    return os.path.join(ROOT, rel)


def read(rel):
    with open(p(rel), encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def write(rel, s):
    with open(p(rel), "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(s)


def func_span(src, header_re):
    """Return (start, open_brace, close_brace) dari fungsi yang cocok."""
    m = re.search(header_re, src, re.M)
    if not m:
        return None
    op = src.find("{", m.end())
    if op < 0:
        return None
    depth = 0
    for i in range(op, len(src)):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return m.start(), op, i
    return None


def insert_before_func(src, header_re, text):
    m = re.search(header_re, src, re.M)
    if not m:
        return None
    ls = src.rfind("\n", 0, m.start()) + 1
    return src[:ls] + text + src[ls:]


def insert_in_body(src, header_re, anchor_re, text, after=True, last=False):
    span = func_span(src, header_re)
    if not span:
        return None
    _, op, cl = span
    body = src[op:cl + 1]
    ms = list(re.finditer(anchor_re, body, re.M))
    if not ms:
        return None
    m = ms[-1] if last else ms[0]
    if after:
        nl = body.find("\n", m.end())
        pos = (nl + 1) if nl >= 0 else len(body)
    else:
        pos = m.start()
    body = body[:pos] + text + body[pos:]
    return src[:op] + body + src[cl + 1:]


def ok(name, msg):
    report.append("[OK]    %-28s %s" % (name, msg))


def skip(name, msg):
    report.append("[SKIP]  %-28s %s" % (name, msg))


def fail(name, msg):
    global failed
    failed = True
    report.append("[GAGAL] %-28s %s" % (name, msg))


# ------------------------------------------------------------------ stat.c
def hook_stat():
    f = "fs/stat.c"
    if not os.path.exists(p(f)):
        return fail("stat", f + " tidak ada")
    s = read(f)

    # --- newfstatat -> ksu_handle_stat
    if "ksu_handle_stat" in s:
        skip("ksu_handle_stat", "sudah ada di " + f)
    else:
        hdr = r"^SYSCALL_DEFINE4\(newfstatat,"
        decl = (
            "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
            "__attribute__((hot))\n"
            "extern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n"
            "\t\t\t\tint *flags);\n"
            "#endif\n\n"
        )
        call = (
            "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
            "\tksu_handle_stat(&dfd, &filename, &flag);\n"
            "#endif\n"
        )
        n = insert_in_body(s, hdr, r"^[ \t]*error = vfs_fstatat\(.*$", call, after=False)
        if n is None:
            fail("ksu_handle_stat", "SYSCALL newfstatat / vfs_fstatat tidak ketemu di " + f)
        else:
            n = insert_before_func(n, hdr, decl)
            s = n
            ok("ksu_handle_stat", "dipasang di newfstatat")

    # --- newfstat -> ksu_handle_newfstat_ret
    if "ksu_handle_newfstat_ret" in s:
        skip("ksu_handle_newfstat_ret", "sudah ada di " + f)
    else:
        hdr = r"^SYSCALL_DEFINE2\(newfstat,"
        decl = (
            "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
            "extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);\n"
            "#endif\n\n"
        )
        call = (
            "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
            "\tksu_handle_newfstat_ret(&fd, &statbuf);\n"
            "#endif\n"
        )
        n = insert_in_body(s, hdr, r"^[ \t]*return error;", call, after=False, last=True)
        if n is None:
            fail("ksu_handle_newfstat_ret", "SYSCALL newfstat / 'return error;' tidak ketemu di " + f)
        else:
            n = insert_before_func(n, hdr, decl)
            s = n
            ok("ksu_handle_newfstat_ret", "dipasang di newfstat")

    write(f, s)


# ------------------------------------------------------------------ exec.c
def hook_exec():
    f = "fs/exec.c"
    if not os.path.exists(p(f)):
        return fail("exec", f + " tidak ada")
    s = read(f)

    has_pre = "ksu_handle_execveat" in s
    has_post = "ksu_handle_post_execveat" in s
    if has_pre and has_post:
        return skip("ksu_handle_execveat(+post)", "sudah ada di " + f)
    if has_pre or "ksu_handle_execve" in s:
        return fail(
            "ksu_handle_execveat(+post)",
            "hook execve LAMA terdeteksi tanpa post hook; pasang manual "
            "(kirim fungsi do_execveat_common ke gw)",
        )

    old = "static int do_execveat_common("
    new = "static int __do_execveat_common("
    if not re.search(r"^static int do_execveat_common\(", s, re.M):
        return fail("ksu_handle_execveat(+post)", "static int do_execveat_common( tidak ketemu di " + f)

    s = re.sub(r"^static int do_execveat_common\(", new, s, count=1, flags=re.M)
    span = func_span(s, r"^static int __do_execveat_common\(")
    if not span:
        return fail("ksu_handle_execveat(+post)", "gagal mencari akhir fungsi do_execveat_common")
    _, _, cl = span

    wrapper = (
        "\n#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t\tvoid *argv, void *envp, int *flags);\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\t\t\tvoid *argv, void *envp, int *flags, int *retval);\n"
        "#endif\n\n"
        "static int do_execveat_common(int fd, struct filename *filename,\n"
        "\t\t\t      struct user_arg_ptr argv,\n"
        "\t\t\t      struct user_arg_ptr envp,\n"
        "\t\t\t      int flags)\n"
        "{\n"
        "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "\tint retval;\n\n"
        "\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
        "\tretval = __do_execveat_common(fd, filename, argv, envp, flags);\n"
        "\tksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);\n"
        "\treturn retval;\n"
        "#else\n"
        "\treturn __do_execveat_common(fd, filename, argv, envp, flags);\n"
        "#endif\n"
        "}\n"
    )
    s = s[:cl + 1] + "\n" + wrapper + s[cl + 1:]
    write(f, s)
    ok("ksu_handle_execveat(+post)", "do_execveat_common dibungkus wrapper")


# ------------------------------------------------------------------ open.c
def hook_faccessat():
    f = "fs/open.c"
    if not os.path.exists(p(f)):
        return fail("faccessat", f + " tidak ada")
    s = read(f)
    if "ksu_handle_faccessat" in s:
        return skip("ksu_handle_faccessat", "sudah ada di " + f)

    hdr = r"^SYSCALL_DEFINE3\(faccessat,"
    decl = (
        "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "__attribute__((hot))\n"
        "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
        "\t\t\t\tint *mode, int *flags);\n"
        "#endif\n\n"
    )
    call = (
        "\n#ifdef CONFIG_KSU_MANUAL_HOOK\n"
        "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
        "#endif\n"
    )
    n = insert_in_body(s, hdr, r"^[ \t]*unsigned int lookup_flags = LOOKUP_FOLLOW;", call)
    if n is None:
        return fail(
            "ksu_handle_faccessat",
            "pola faccessat 4.14 tidak cocok (mungkin sudah versi do_faccessat), pasang manual",
        )
    n = insert_before_func(n, hdr, decl)
    write(f, n)
    ok("ksu_handle_faccessat", "dipasang di SYSCALL faccessat")


# ------------------------------------------------------------------ reboot
def hook_reboot():
    for f in ("kernel/reboot.c", "kernel/sys.c"):
        if not os.path.exists(p(f)):
            continue
        s = read(f)
        if "ksu_handle_sys_reboot" in s:
            return skip("ksu_handle_sys_reboot", "sudah ada di " + f)
        hdr = r"^SYSCALL_DEFINE4\(reboot,"
        if not re.search(hdr, s, re.M):
            continue
        decl = (
            "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
            "extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n"
            "#endif\n\n"
        )
        call = (
            "#ifdef CONFIG_KSU_MANUAL_HOOK\n"
            "\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n"
            "#endif\n"
        )
        n = insert_in_body(s, hdr, r"^[ \t]*int ret = 0;", call)
        if n is None:
            return fail("ksu_handle_sys_reboot", "'int ret = 0;' tidak ketemu di SYSCALL reboot (" + f + ")")
        n = insert_before_func(n, hdr, decl)
        write(f, n)
        return ok("ksu_handle_sys_reboot", "dipasang di " + f)
    fail("ksu_handle_sys_reboot", "SYSCALL reboot tidak ketemu di kernel/reboot.c maupun kernel/sys.c")


def main():
    for fn in (hook_stat, hook_exec, hook_faccessat, hook_reboot):
        try:
            fn()
        except Exception as e:  # noqa
            fail(fn.__name__, "exception: %r" % (e,))
    print("\n".join(report))
    if failed:
        print("\n[!] Ada hook yang gagal. Perbaiki manual lalu jalankan ulang.")
        sys.exit(1)
    print("\n[+] Semua hook wajib beres.")


if __name__ == "__main__":
    main()
