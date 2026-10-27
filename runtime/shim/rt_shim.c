/* rt_shim — die variadische Unterkante, typisiert (doc/spec/110 F110-1).
 *
 * aiml-FFI kennt keine varargs, und `pivot_root`/`seccomp`/`clone3` haben gar
 * keinen glibc-Wrapper.  Hier steht NUR die Uebersetzung: feste Signaturen,
 * keine Politik.  Jede Funktion gibt 0 = ok oder -errno zurueck, damit der
 * aiml-Kern den Grund benennen kann statt nur zu scheitern.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <dirent.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <linux/capability.h>
#include <sys/stat.h>

static int fail(void) { return -errno; }

int rt_uid(void) { return (int)getuid(); }

/* Maschine ("x86_64", "aarch64", "armv7l") — bestimmt den seccomp-Bytecode. */
int rt_machine(char* out, int cap) {
    struct utsname uts;
    if (uname(&uts) != 0) return fail();
    snprintf(out, (size_t)cap, "%s", uts.machine);
    return 0;
}

int rt_kernel(char* out, int cap) {
    struct utsname uts;
    if (uname(&uts) != 0) return fail();
    snprintf(out, (size_t)cap, "%s", uts.release);
    return 0;
}

/* AUDIT_ARCH dieser Maschine — der seccomp-Filter MUSS dagegen pruefen,
 * sonst ist ein auf x86 dichtes Profil auf dem Pi eine offene Tuer. */
long long rt_audit_arch(void) {
#if defined(__x86_64__)
    return (long long)AUDIT_ARCH_X86_64;
#elif defined(__aarch64__)
    return (long long)AUDIT_ARCH_AARCH64;
#elif defined(__arm__)
    return (long long)AUDIT_ARCH_ARM;
#else
    return 0;
#endif
}

/* seccomp ueberhaupt vorhanden?  0 = ja. */
int rt_seccomp_available(void) {
    int mode = prctl(PR_GET_SECCOMP);
    if (mode < 0) return fail();
    return 0;
}

static int write_file(const char* path, const char* text) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return fail();
    ssize_t n = write(fd, text, strlen(text));
    int saved = (n < 0) ? -errno : 0;
    close(fd);
    return saved;
}

/* Der entscheidende Versuch: einen User-Namespace erzeugen und die
 * ID-Abbildung schreiben.  Im KIND, damit der Aufrufer unberuehrt bleibt —
 * und weil CLONE_NEWUSER einen EINFAEDIGEN Prozess verlangt (F110-2).
 *
 * Rueckgabe: 0 ok · -1 fork · 10+ Stufe, an der es scheiterte:
 *   11 unshare(CLONE_NEWUSER)   12 setgroups=deny   13 uid_map   14 gid_map
 *   15 unshare(CLONE_NEWNS)     16 mount(tmpfs)
 */
int rt_probe_userns(int want_mount) {
    int uid = (int)getuid(), gid = (int)getgid();
    pid_t kid = fork();
    if (kid < 0) return -1;
    if (kid == 0) {
        char buf[64];
        if (unshare(CLONE_NEWUSER) != 0) _exit(11);
        if (write_file("/proc/self/setgroups", "deny") != 0) _exit(12);
        snprintf(buf, sizeof(buf), "0 %d 1", uid);
        if (write_file("/proc/self/uid_map", buf) != 0) _exit(13);
        snprintf(buf, sizeof(buf), "0 %d 1", gid);
        if (write_file("/proc/self/gid_map", buf) != 0) _exit(14);
        if (want_mount) {
            if (unshare(CLONE_NEWNS) != 0) _exit(15);
            /* Eigene Wurzel-Propagation, sonst traegt der Mount nicht. */
            if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) _exit(16);
            if (mount("none", "/mnt", "tmpfs", 0, NULL) != 0) _exit(16);
        }
        _exit(0);
    }
    int st = 0;
    if (waitpid(kid, &st, 0) < 0) return -1;
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    return -2;
}

/* pivot_root hat keinen glibc-Wrapper — hier die einzige Stelle, an der
 * `syscall` auftaucht. */
int rt_pivot_root(const char* new_root, const char* put_old) {
    if (syscall(SYS_pivot_root, new_root, put_old) != 0) return fail();
    return 0;
}

int rt_mount(const char* src, const char* dst, const char* fstype,
             unsigned long flags, const char* data) {
    if (mount(src, dst, fstype, flags, data) != 0) return fail();
    return 0;
}

/* ── Argumente und Umgebung sammeln (doc/spec/110 M1) ────────────────────────
 * aiml-FFI kennt keine `char* const[]`-Parameter, und `execve` braucht genau
 * das.  Darum ein winziger Sammler: aiml schiebt Zeichenketten einzeln hinein,
 * der Aufruf verwendet sie.  Statisch begrenzt — ein Bundle mit mehr als 128
 * Argumenten ist ein Fehler, kein Anwendungsfall.
 */
#define RT_MAX_VEC 128
static char* g_args[RT_MAX_VEC + 1];
static int   g_args_n = 0;
static char* g_envs[RT_MAX_VEC + 1];
static int   g_envs_n = 0;

static void vec_clear(char** vec, int* n) {
    for (int i = 0; i < *n; ++i) { free(vec[i]); vec[i] = NULL; }
    *n = 0;
}
static int vec_push(char** vec, int* n, const char* s) {
    if (!s || *n >= RT_MAX_VEC) return -E2BIG;
    vec[*n] = strdup(s);
    if (!vec[*n]) return -ENOMEM;
    vec[++(*n)] = NULL;
    return 0;
}

void rt_args_reset(void) { vec_clear(g_args, &g_args_n); }
int  rt_args_push(const char* val) { return vec_push(g_args, &g_args_n, val); }
void rt_env_reset(void)  { vec_clear(g_envs, &g_envs_n); }
int  rt_env_push(const char* val)  { return vec_push(g_envs, &g_envs_n, val); }

/* ── Der Einrichtungsplan (doc/spec/110 M2) ──────────────────────────────────
 * Zwischen `fork` und `execve` liegt die ganze Isolation: Wurzel wechseln,
 * mounten, maskieren, Rechte abgeben.  Das Kind darf dafuer NICHT nach aiml
 * zurueck (nach dem fork ist nur noch async-signal-sicherer Code erlaubt), also
 * stellt aiml den Plan VORHER zusammen und das Kind arbeitet ihn ab.
 *
 * Die Uebersetzung der OCI-Optionen ("nosuid","ro",…) in MS_*-Bits macht aiml:
 * sie ist Politik und ohne Rechte pruefbar.  Hier stehen nur die Aufrufe.
 */
enum { RT_OP_MOUNT = 1, RT_OP_MASK = 2, RT_OP_RO = 3 };

typedef struct {
    int  op;
    char src[256];
    char dst[256];
    char type[64];
    char data[256];
    unsigned long flags;
} rt_step_t;

#define RT_MAX_STEPS 64
static rt_step_t g_steps[RT_MAX_STEPS];
static int  g_steps_n = 0;
static char g_rootfs[512] = {0};
static int  g_rootfs_ro = 0;

static void copy_into(char* dst, size_t cap, const char* src) {
    if (!src) { dst[0] = '\0'; return; }
    snprintf(dst, cap, "%s", src);
}

void rt_plan_reset(void) { g_steps_n = 0; g_rootfs[0] = '\0'; g_rootfs_ro = 0; }

/* Die cgroup, in die sich das Kind eintraegt (doc/spec/110 M4).  Eintragen muss
 * es sich SELBST: der Elternprozess kennt die PID erst nach dem fork, und
 * zwischen fork und Eintrag duerfte das Kind sonst schon Speicher nehmen. */
static char g_cgroup[512] = {0};
int rt_set_cgroup(const char* dir) {
    copy_into(g_cgroup, sizeof(g_cgroup), dir);
    return 0;
}

static int child_join_cgroup(void) {
    if (!g_cgroup[0]) return 0;
    char at[600], pid[32];
    snprintf(at, sizeof(at), "%s/cgroup.procs", g_cgroup);
    snprintf(pid, sizeof(pid), "%d", (int)getpid());
    return write_file(at, pid);
}

int rt_set_rootfs(const char* path, int readonly) {
    if (!path) return -EINVAL;
    copy_into(g_rootfs, sizeof(g_rootfs), path);
    g_rootfs_ro = readonly;
    return 0;
}

int rt_plan_mount(const char* src, const char* dst, const char* type,
                  long flags, const char* data) {
    if (g_steps_n >= RT_MAX_STEPS) return -E2BIG;
    rt_step_t* s = &g_steps[g_steps_n++];
    s->op = RT_OP_MOUNT;
    copy_into(s->src, sizeof(s->src), src);
    copy_into(s->dst, sizeof(s->dst), dst);
    copy_into(s->type, sizeof(s->type), type);
    copy_into(s->data, sizeof(s->data), data);
    s->flags = (unsigned long)flags;
    return 0;
}

static int rt_plan_simple(int op, const char* path) {
    if (g_steps_n >= RT_MAX_STEPS) return -E2BIG;
    rt_step_t* s = &g_steps[g_steps_n++];
    s->op = op;
    copy_into(s->dst, sizeof(s->dst), path);
    s->src[0] = s->type[0] = s->data[0] = '\0';
    s->flags = 0;
    return 0;
}
int rt_plan_mask(const char* path)     { return rt_plan_simple(RT_OP_MASK, path); }
int rt_plan_readonly(const char* path) { return rt_plan_simple(RT_OP_RO, path); }
int rt_plan_count(void)                { return g_steps_n; }

/* Maskieren: eine DATEI bekommt /dev/null daruebergelegt, ein VERZEICHNIS ein
 * leeres, schreibgeschuetztes tmpfs.  Was es nicht gibt, wird uebergangen —
 * ein Bundle darf Pfade nennen, die dieses System nicht kennt. */
static int child_mask(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    if (S_ISDIR(st.st_mode))
        return mount("none", path, "tmpfs", MS_RDONLY, "size=0k") == 0 ? 0 : -errno;
    return mount("/dev/null", path, NULL, MS_BIND, NULL) == 0 ? 0 : -errno;
}

/* Die GESPERRTEN Flags eines Einhaengepunkts.  Im User-Namespace darf ein
 * Remount keine davon verlieren — sonst EPERM.  Wer also nur MS_RDONLY setzt,
 * scheitert auf jedem Dateisystem, das `nosuid`/`nodev` traegt (gemessen
 * 18.10.2026: genau hier blieb der Schreibschutz haengen).
 *
 * Das ist der Grund, warum eine eigene Runtime teuer ist: nicht der Syscall,
 * sondern die Bedingungen, unter denen er NICHT gilt. */
static unsigned long locked_flags(const char* path) {
    struct statvfs vfs;
    if (statvfs(path, &vfs) != 0) return 0;
    unsigned long f = 0;
    if (vfs.f_flag & ST_NOSUID)     f |= MS_NOSUID;
    if (vfs.f_flag & ST_NODEV)      f |= MS_NODEV;
    if (vfs.f_flag & ST_NOEXEC)     f |= MS_NOEXEC;
    if (vfs.f_flag & ST_NOATIME)    f |= MS_NOATIME;
    if (vfs.f_flag & ST_NODIRATIME) f |= MS_NODIRATIME;
    if (vfs.f_flag & ST_RELATIME)   f |= MS_RELATIME;
    return f;
}

/* Schreibschutz: binden und als ro neu einhaengen — ein einzelnes `mount` mit
 * MS_RDONLY wirkt bei einem Bind-Mount NICHT, das ist die klassische Falle. */
static int child_readonly(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    if (mount(path, path, NULL, MS_BIND | MS_REC, NULL) != 0) return -errno;
    if (mount(NULL, path, NULL,
              MS_BIND | MS_REMOUNT | MS_RDONLY | locked_flags(path), NULL) != 0) return -errno;
    return 0;
}

/* pivot_root: die alte Wurzel wird nach `/.oldroot` geschwenkt und sofort
 * abgehaengt.  `chroot` waere das schwaechere Mittel — daraus kommt man mit
 * einem offenen Verzeichnis-Deskriptor wieder heraus. */
static int child_pivot(const char* rootfs, int readonly) {
    /* Die Wurzel MUSS ein eigener Mount-Punkt sein; ein gewoehnliches
     * Verzeichnis lehnt pivot_root ab (EINVAL). */
    if (mount(rootfs, rootfs, NULL, MS_BIND | MS_REC, NULL) != 0) {
        dprintf(2, "[rt] pivot/bind(%s) scheiterte: %s\n", rootfs, strerror(errno));
        return -errno;
    }
    /* Schreibschutz VOR dem Wechsel, auf dem rootfs-Bind.  Die gesperrten Flags
     * muessen mit (locked_flags), sonst EPERM im User-Namespace. */
    if (readonly) {
        if (mount(NULL, rootfs, NULL,
                  MS_BIND | MS_REMOUNT | MS_RDONLY | locked_flags(rootfs), NULL) != 0) {
            dprintf(2, "[rt] pivot/readonly(%s) scheiterte: %s\n", rootfs, strerror(errno));
            return -errno;
        }
    }
    /* Der Kniff aus pivot_root(2): neue und alte Wurzel auf DASSELBE
     * Verzeichnis legen, dann die alte abhaengen.  So bleibt kein `.oldroot`
     * zurueck — was auf einer schreibgeschuetzten Wurzel ohnehin nicht mehr
     * loeschbar waere (gemessen 18.10.2026: das leere Verzeichnis blieb stehen). */
    if (chdir(rootfs) != 0) {
        dprintf(2, "[rt] pivot/chdir(%s): %s\n", rootfs, strerror(errno));
        return -errno;
    }
    if (syscall(SYS_pivot_root, ".", ".") != 0) {
        dprintf(2, "[rt] pivot/syscall(%s): %s\n", rootfs, strerror(errno));
        return -errno;
    }
    if (umount2(".", MNT_DETACH) != 0) {
        dprintf(2, "[rt] pivot/umount: %s\n", strerror(errno));
        return -errno;
    }
    if (chdir("/") != 0) { dprintf(2, "[rt] pivot/chdir(/): %s\n", strerror(errno)); return -errno; }
    return 0;
}

/* ── seccomp (doc/spec/110 M2) ────────────────────────────────────────────────
 * Die Nummern kommen aus den libc-Headern (`SYS_*`), nicht aus einer eigenen
 * Tabelle: damit ist die Architektur-Frage beim Uebersetzen beantwortet und
 * kann nicht veralten.  Die AUSWAHL der Syscalls ist Politik und steht in aiml.
 *
 * Der Filter prueft ZUERST die Architektur.  Ohne diese Pruefung waere ein auf
 * x86_64 dichtes Profil auf aarch64 eine offene Tuer, weil dieselbe Nummer dort
 * einen anderen Aufruf bezeichnet (doc/spec/110 §110.2).
 */
#define RT_MAX_DENY 128
static int g_deny[RT_MAX_DENY];
static int g_deny_n = 0;

void rt_seccomp_reset(void) { g_deny_n = 0; }
int  rt_seccomp_count(void) { return g_deny_n; }

/* Syscall-Nummer eines Namens auf DIESER Architektur, -1 = unbekannt hier. */
int rt_sys_nr(const char* name) {
    if (!name) return -1;
#define RT_SYS(n) if (strcmp(name, #n) == 0) return SYS_##n;
    RT_SYS(mount) RT_SYS(umount2) RT_SYS(pivot_root) RT_SYS(chroot)
    RT_SYS(reboot) RT_SYS(kexec_load) RT_SYS(init_module) RT_SYS(delete_module)
    RT_SYS(bpf) RT_SYS(perf_event_open) RT_SYS(ptrace) RT_SYS(keyctl)
    RT_SYS(add_key) RT_SYS(request_key) RT_SYS(userfaultfd) RT_SYS(setns)
    RT_SYS(unshare) RT_SYS(swapon) RT_SYS(swapoff) RT_SYS(settimeofday)
    RT_SYS(clock_settime) RT_SYS(acct) RT_SYS(quotactl) RT_SYS(uname)
    RT_SYS(process_vm_readv) RT_SYS(process_vm_writev) RT_SYS(finit_module)
#undef RT_SYS
    return -1;
}

int rt_seccomp_deny(const char* name) {
    int nr = rt_sys_nr(name);
    if (nr < 0) return -ENOSYS;              /* hier unbekannt — nicht still uebergehen */
    if (g_deny_n >= RT_MAX_DENY) return -E2BIG;
    g_deny[g_deny_n++] = nr;
    return 0;
}

/* Den Filter bauen und scharf schalten.  Reihenfolge: NACH no_new_privs —
 * ohne das lehnt der Kernel PR_SET_SECCOMP fuer unprivilegierte Prozesse ab. */
static int child_seccomp(void) {
    if (g_deny_n == 0) return 0;
    /* 4 Kopfbefehle + 2 je verbotenem Aufruf + 1 Abschluss */
    int len = 4 + 2 * g_deny_n + 1;
    struct sock_filter* code = (struct sock_filter*)calloc((size_t)len, sizeof(*code));
    if (!code) return -ENOMEM;
    int i = 0;
    /* arch laden, vergleichen, sonst toeten */
    code[i++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                             offsetof(struct seccomp_data, arch));
    code[i++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                             (unsigned int)rt_audit_arch(), 1, 0);
    code[i++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
    /* Nummer laden; jeder Treffer endet in EPERM */
    code[i++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                             offsetof(struct seccomp_data, nr));
    for (int d = 0; d < g_deny_n; ++d) {
        code[i++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                                 (unsigned int)g_deny[d], 0, 1);
        code[i++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K,
                                                 SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA));
    }
    code[i++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    struct sock_fprog prog = { (unsigned short)i, code };
    int rc = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog);
    if (rc != 0) rc = prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog, 0, 0);
    free(code);
    return rc == 0 ? 0 : -errno;
}

/* no_new_privs + Capabilities abgeben.  Reihenfolge ist Pflicht: erst
 * no_new_privs, dann die Rechte — andersherum koennte ein setuid-Programm
 * dazwischen noch etwas zurueckholen. */
/* Capabilities behalten?  Fuer einen LAUF-Container ist „alles abgeben"
 * richtig: die Nutzlast soll nichts duerfen.  Ein BAU-Container braucht sie
 * dagegen — `dpkg` setzt Eigentuemer (CAP_CHOWN), `apt` faellt fuer seinen
 * HTTP-Helfer auf den Benutzer `_apt` (CAP_SETGID/SETUID).  Gemessen:
 * „Failed to setgroups — Operation not permitted".
 *
 * Es sind Capabilities IM NAMESPACE: sie gelten gegenueber den abgebildeten
 * Kennungen, nicht gegenueber dem Host.  `no_new_privs` bleibt in beiden
 * Faellen gesetzt. */
static int g_keep_caps = 0;
void rt_keep_caps(int on) { g_keep_caps = on ? 1 : 0; }

static int child_drop_privs(void) {
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -errno;
    if (g_keep_caps) return 0;
    struct __user_cap_header_struct hdr = { _LINUX_CAPABILITY_VERSION_3, 0 };
    struct __user_cap_data_struct   dat[2];
    memset(dat, 0, sizeof(dat));
    if (syscall(SYS_capset, &hdr, dat) != 0) return -errno;
    return 0;
}

/* ── Mehrere IDs abbilden (doc/spec/110 §110.23) ─────────────────────────────
 * Eine einzige abgebildete ID genuegt zum Laufen, aber nicht zum BAUEN: `dpkg`
 * legt Dateien unter verschiedenen Benutzern an (root, _apt, man, …), und ein
 * `chown` auf eine nicht abgebildete ID scheitert mit EINVAL.
 *
 * Mehrzeilige Abbildungen darf ein unprivilegierter Prozess nicht selbst
 * schreiben — dafuer gibt es `newuidmap`/`newgidmap` (setuid root), die den
 * Bereich aus /etc/subuid gegenpruefen.  Also: das Kind erzeugt den Namespace
 * und WARTET, der Elternprozess ruft die Helfer, dann geht es weiter.  Zwei
 * Rohre, damit keiner rät, wann der andere fertig ist.
 */
static int g_sub_uid = 0, g_sub_ucount = 0, g_sub_gid = 0, g_sub_gcount = 0;

void rt_set_subids(int uid_start, int uid_count, int gid_start, int gid_count) {
    g_sub_uid = uid_start; g_sub_ucount = uid_count;
    g_sub_gid = gid_start; g_sub_gcount = gid_count;
}

/* Einen Helfer aufrufen und auf ihn warten.  0 = ok. */
static int run_helper(const char* prog, char* const argv[]) {
    pid_t h = fork();
    if (h < 0) return -errno;
    if (h == 0) { execvp(prog, argv); _exit(127); }
    int st = 0;
    if (waitpid(h, &st, 0) < 0) return -errno;
    return (WIFEXITED(st) && WEXITSTATUS(st) == 0) ? 0 : -EPERM;
}

static int map_range_for(pid_t kid) {
    char pid_s[32], uid_s[32], gid_s[32], one[8] = "1";
    char sub_u[32], sub_g[32], cnt_u[32], cnt_g[32], zero[8] = "0", in_one[8] = "1";
    snprintf(pid_s, sizeof(pid_s), "%d", (int)kid);
    snprintf(uid_s, sizeof(uid_s), "%d", (int)getuid());
    snprintf(gid_s, sizeof(gid_s), "%d", (int)getgid());
    snprintf(sub_u, sizeof(sub_u), "%d", g_sub_uid);
    snprintf(sub_g, sizeof(sub_g), "%d", g_sub_gid);
    snprintf(cnt_u, sizeof(cnt_u), "%d", g_sub_ucount);
    snprintf(cnt_g, sizeof(cnt_g), "%d", g_sub_gcount);
    /* 0 → meine UID (1 Stueck), 1.. → der untergeordnete Bereich */
    char* uargv[] = { (char*)"newuidmap", pid_s, zero, uid_s, one,
                      in_one, sub_u, cnt_u, NULL };
    char* gargv[] = { (char*)"newgidmap", pid_s, zero, gid_s, one,
                      in_one, sub_g, cnt_g, NULL };
    int rc = run_helper("newuidmap", uargv);
    if (rc != 0) return rc;
    return run_helper("newgidmap", gargv);
}

/* ── rt_run: Kind in eigenen Namespaces starten und auf es warten ────────────
 * `ns_flags` sind die CLONE_NEW*-Bits, wie sie der Bundle-Leser aus
 * `linux.namespaces` zusammenstellt.  Die ID-Abbildung bildet die EIGENE UID
 * auf 0 ab — innen root, aussen unprivilegiert; das ist der ganze Zweck.
 *
 * Rueckgabe: >= 0 Exit-Code des Kindes · -1 fork · -(100+Stufe) bei
 * Einrichtungsfehlern (siehe rt_probe_userns fuer die Stufen).
 */
int rt_run(const char* exe, const char* cwd, int ns_flags) {
    if (!exe || g_args_n == 0) return -EINVAL;
    int uid = (int)getuid(), gid = (int)getgid();
    pid_t parent_pid = getpid();
    int use_range = (g_sub_ucount > 0 && (ns_flags & CLONE_NEWUSER));
    int ns_ready[2] = {-1,-1}, maps_done[2] = {-1,-1};
    if (use_range) {
        if (pipe(ns_ready) != 0 || pipe(maps_done) != 0) return -errno;
    }
    pid_t kid = fork();
    if (kid < 0) return -1;
    if (kid == 0) {
        char buf[64];
        /* Stirbt cosmos-rt, stirbt der Container — sonst bleibt eine WAISE
         * zurueck, die weiterlaeuft, sich weiter beim Controller meldet und
         * niemandem mehr gehoert.  Gemessen 18.10.2026: drei abgebrochene
         * Laeufe hinterliessen drei lebende Agenten, die sich nach einem
         * Server-Neustart prompt wieder anmeldeten.
         *
         * PDEATHSIG haengt am ELTERN-FADEN, nicht am Prozess, und wird beim
         * exec NICHT geloescht — genau das Richtige hier.  Der Nachtest gegen
         * eine Race (Eltern schon tot, bevor das Signal gesetzt war) steht
         * direkt danach. */
        if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) _exit(128);
        if (getppid() != parent_pid) _exit(129);

        /* Zuerst in die Gruppe, dann die Namespaces: was danach entsteht,
         * zaehlt bereits auf das Konto des Containers. */
        if (child_join_cgroup() != 0) _exit(127);
        if (unshare(ns_flags) != 0) _exit(111);
        if (ns_flags & CLONE_NEWUSER) {
            if (use_range) {
                /* Dem Elternprozess sagen: Namespace steht.  Dann warten, bis
                 * er die Abbildung geschrieben hat — vorher ist man niemand. */
                char sig = 'r';
                close(ns_ready[0]); close(maps_done[1]);
                if (write(ns_ready[1], &sig, 1) != 1) _exit(130);
                close(ns_ready[1]);
                if (read(maps_done[0], &sig, 1) != 1) _exit(131);
                close(maps_done[0]);
                if (sig != 'o') _exit(132);
                /* Innen root werden: die Abbildung macht uid 0 moeglich. */
                if (setgid(0) != 0 || setuid(0) != 0) _exit(133);
            } else {
                if (write_file("/proc/self/setgroups", "deny") != 0) _exit(112);
                snprintf(buf, sizeof(buf), "0 %d 1", uid);
                if (write_file("/proc/self/uid_map", buf) != 0) _exit(113);
                snprintf(buf, sizeof(buf), "0 %d 1", gid);
                if (write_file("/proc/self/gid_map", buf) != 0) _exit(114);
            }
        }
        /* PID-Namespace: `unshare(CLONE_NEWPID)` versetzt NICHT den Aufrufer,
         * sondern erst dessen naechste Kinder.  Ohne diesen zweiten fork waere
         * die Nutzlast nicht PID 1 — und ein frisches `proc` liesse sich gar
         * nicht einhaengen (der Kernel verlangt dafuer einen eigenen, bewohnten
         * PID-Namespace; gemessen 18.10.2026: mount(proc) → EPERM).
         * Der Zwischenprozess tut nichts als warten und den Exit-Code reichen. */
        if (ns_flags & CLONE_NEWPID) {
            pid_t inner = fork();
            if (inner < 0) _exit(123);
            if (inner == 0) {
                /* Nur PDEATHSIG, KEIN getppid()-Nachtest: im neuen
                 * PID-Namespace ist der Elternprozess ausserhalb nicht
                 * sichtbar, getppid() liefert dort 0 (gemessen: Exit 129). */
                if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) _exit(128);
            }
            if (inner > 0) {
                int ist = 0;
                if (waitpid(inner, &ist, 0) < 0) _exit(124);
                if (WIFEXITED(ist)) _exit(WEXITSTATUS(ist));
                if (WIFSIGNALED(ist)) _exit(128 + WTERMSIG(ist));
                _exit(125);
            }
        }

        /* Eigene Wurzel-Propagation, sonst wirken Mounts auf den Host zurueck. */
        if (ns_flags & CLONE_NEWNS) {
            if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) _exit(115);
            /* Reihenfolge: erst die Mounts des Bundles (sie zeigen noch auf die
             * alte Wurzel), dann der Wurzelwechsel, dann Maske und Schreibschutz
             * INNERHALB der neuen Wurzel. */
            for (int i = 0; i < g_steps_n; ++i) {
                rt_step_t* s = &g_steps[i];
                if (s->op != RT_OP_MOUNT) continue;
                if (mount(s->src[0] ? s->src : NULL, s->dst,
                          s->type[0] ? s->type : NULL, s->flags,
                          s->data[0] ? s->data : NULL) != 0) {
                    /* Ein stiller Fehlschlag kostet hier eine Stunde: WELCHER
                     * Mount, WOHIN, und warum. */
                    dprintf(2, "[rt] Schritt %d: mount(%s → %s, typ='%s', flags=0x%lx) "
                               "scheiterte: %s\n", i,
                            s->src[0] ? s->src : "(null)", s->dst,
                            s->type, s->flags, strerror(errno));
                    _exit(118);
                }
            }
                if (g_rootfs[0]) {
                int pv = child_pivot(g_rootfs, g_rootfs_ro);
                if (pv != 0) {
                    dprintf(2, "[rt] pivot_root(%s) scheiterte: %s\n", g_rootfs, strerror(-pv));
                    _exit(119);
                }
            }
            for (int i = 0; i < g_steps_n; ++i) {
                rt_step_t* s = &g_steps[i];
                if (s->op == RT_OP_MASK && child_mask(s->dst) != 0) _exit(120);
                if (s->op == RT_OP_RO   && child_readonly(s->dst) != 0) _exit(121);
            }
        }
        if (cwd && cwd[0] && chdir(cwd) != 0) _exit(116);
        if (child_drop_privs() != 0) _exit(122);
        if (child_seccomp() != 0) { dprintf(2, "[rt] seccomp: %s\n", strerror(errno)); _exit(126); }
        execve(exe, g_args, g_envs_n ? g_envs : (char* const[]){ NULL });
        /* execve kehrt nur im Fehlerfall zurueck — und „ENOENT" heisst hier
         * meistens nicht „Datei fehlt", sondern „der LADER fehlt". */
        dprintf(2, "[rt] execve(%s) scheiterte: %s\n", exe, strerror(errno));
        _exit(117);
    }
    if (use_range) {
        char sig = 0;
        close(ns_ready[1]); close(maps_done[0]);
        if (read(ns_ready[0], &sig, 1) != 1) { close(ns_ready[0]); close(maps_done[1]); return -ECHILD; }
        close(ns_ready[0]);
        int mrc = map_range_for(kid);
        sig = (mrc == 0) ? 'o' : 'x';
        if (mrc != 0) dprintf(2, "[rt] newuidmap/newgidmap scheiterte (%s) — Bereich %d+%d\n",
                              strerror(-mrc), g_sub_uid, g_sub_ucount);
        ssize_t ignored = write(maps_done[1], &sig, 1);
        (void)ignored;
        close(maps_done[1]);
    }
    int st = 0;
    if (waitpid(kid, &st, 0) < 0) return -1;
    if (WIFEXITED(st)) {
        int code = WEXITSTATUS(st);
        if ((code >= 111 && code <= 122) || (code >= 126 && code <= 133)) return -code;   /* Einrichtungsfehler, Stufe im Betrag */
        return code;
    }
    if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);
    return -2;
}

/* Die CLONE_NEW*-Bits, die der Bundle-Leser braucht — als Funktionen, weil die
 * Zahlen pro Architektur gleich, aber in aiml nicht bekannt sind. */
int rt_ns_bit(const char* kind) {
    if (!kind) return 0;
    if (strcmp(kind, "user")    == 0) return CLONE_NEWUSER;
    if (strcmp(kind, "mount")   == 0) return CLONE_NEWNS;
    if (strcmp(kind, "pid")     == 0) return CLONE_NEWPID;
    if (strcmp(kind, "uts")     == 0) return CLONE_NEWUTS;
    if (strcmp(kind, "ipc")     == 0) return CLONE_NEWIPC;
    if (strcmp(kind, "network") == 0) return CLONE_NEWNET;
    if (strcmp(kind, "cgroup")  == 0) return CLONE_NEWCGROUP;
    return 0;                      /* unbekannt → nichts anfordern */
}

/* Die MS_*-Bits einer OCI-Mount-Option.  Wie rt_ns_bit: die Zahlen gehoeren dem
 * Kernel, die Uebersetzungstabelle der Politik — darum fragt aiml hier nach,
 * statt Zahlen zu fuehren, die beim naechsten Kernel anders heissen koennten. */
long rt_ms_bit(const char* name) {
    if (!name) return 0;
    if (strcmp(name, "ro")          == 0) return MS_RDONLY;
    if (strcmp(name, "nosuid")      == 0) return MS_NOSUID;
    if (strcmp(name, "nodev")       == 0) return MS_NODEV;
    if (strcmp(name, "noexec")      == 0) return MS_NOEXEC;
    if (strcmp(name, "bind")        == 0) return MS_BIND;
    if (strcmp(name, "rbind")       == 0) return (long)(MS_BIND | MS_REC);
    if (strcmp(name, "noatime")     == 0) return MS_NOATIME;
    if (strcmp(name, "relatime")    == 0) return MS_RELATIME;
    if (strcmp(name, "strictatime") == 0) return MS_STRICTATIME;
    if (strcmp(name, "nodiratime")  == 0) return MS_NODIRATIME;
    if (strcmp(name, "sync")        == 0) return MS_SYNCHRONOUS;
    if (strcmp(name, "remount")     == 0) return MS_REMOUNT;
    if (strcmp(name, "private")     == 0) return MS_PRIVATE;
    if (strcmp(name, "rprivate")    == 0) return (long)(MS_PRIVATE | MS_REC);
    if (strcmp(name, "slave")       == 0) return MS_SLAVE;
    if (strcmp(name, "rslave")      == 0) return (long)(MS_SLAVE | MS_REC);
    return 0;        /* "rw", "defaults", Unbekanntes: kein Bit */
}
