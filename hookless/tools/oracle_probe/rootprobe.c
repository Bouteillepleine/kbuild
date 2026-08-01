/*
 * rootprobe — active root/hiding-framework oracle probe (unprivileged).
 *
 * Beyond "does syscall N exist", detectors fingerprint root frameworks by their
 * *control channels*. This issues those probes as a plain shell-uid process and
 * reports which answer — exactly what a hostile app can see.
 *
 *   KSU   : prctl(0xDEADBEEF, CMD_GET_VERSION, &out) — KernelSU's magic prctl.
 *           A stock kernel ignores option 0xDEADBEEF; KSU writes its version.
 *   susfs : prctl(0xDEADBEEF, CMD_SUSFS_SHOW_VERSION, &out) — susfs command
 *           range piggybacks KSU's prctl. (magic per susfs4ksu; UNVALIDATED
 *           here — a NoMount device has no susfs, so this must report nothing.)
 *
 * The point for NoMount: NoMount's channel is netlink, not prctl, so neither
 * probe can see the mount-hider — while KSU (root) still answers, because
 * hiding the root manager is not NoMount's job.
 */
#define _GNU_SOURCE
#include <errno.h>
#include "small_rt.h"

#define KSU_MAGIC              0xDEADBEEF
#define CMD_GET_VERSION        2
#define CMD_SUSFS_SHOW_VERSION 0x555f0   /* susfs4ksu; unvalidated */

static void puts_(const char *s)
{
	long n = 0; const char *p = s; while (*p++) n++;
	__syscall(SYS_write, 1, (long)s, n, NONE, NONE, NONE);
}
static void put_dec(long v)
{
	char b[24]; int i = sizeof b; b[--i] = '\n';
	if (!v) b[--i] = '0';
	else { long x = v; while (x) { b[--i] = '0' + x % 10; x /= 10; } }
	__syscall(SYS_write, 1, (long)(b + i), sizeof b - i, NONE, NONE, NONE);
}

__attribute__((always_inline))
int c_main(int argc, char *argv[], char *envp[])
{
	/* KernelSU: GET_VERSION is read-only, any uid may query it */
	volatile int ver = 0;
	__syscall(SYS_prctl, KSU_MAGIC, CMD_GET_VERSION, (long)&ver, 0, 0, NONE);
	if (ver > 0) { puts_("KSU   prctl 0xDEADBEEF/GET_VERSION : PRESENT  ver="); put_dec(ver); }
	else           puts_("KSU   prctl 0xDEADBEEF/GET_VERSION : no response (stock/hidden)\n");

	/* susfs: expect NO response on a NoMount (susfs-free) device */
	volatile int sv = 0;
	__syscall(SYS_prctl, KSU_MAGIC, CMD_SUSFS_SHOW_VERSION, (long)&sv, 0, 0, NONE);
	if (sv != 0) { puts_("susfs prctl 0xDEADBEEF/SHOW_VERSION : RESPONSE v="); put_dec(sv); }
	else           puts_("susfs prctl 0xDEADBEEF/SHOW_VERSION : no response (no susfs)\n");

	return 0;
}

__attribute__((used))
void prep_main(long *sp)
{
	long argc = *sp;
	char **argv = (char **)(sp + 1);
	char **envp = argv + argc + 1;
	long rc = c_main(argc, argv, envp);
	__syscall(SYS_exit, rc, NONE, NONE, NONE, NONE, NONE);
	__builtin_unreachable();
}
