/*
 * syscall_scan — single-exec range scanner built on backslashxx's small_rt.
 *
 * One process walks [START..END], blind-invokes each syscall with zero args,
 * and prints the number of every syscall that does NOT return -ENOSYS.
 * stdout is therefore the kernel's "present set" — diff two of them
 * (modded vs stock / canonical unistd.h) to find footprint deltas.
 *
 *   scan START END            # present numbers, one per line
 *
 * Hazardous nullary syscalls are skipped, never invoked. All are baseline
 * (present on every kernel), so skipping them costs a fingerprint nothing:
 *   session/tty killers : 58 vhangup, 93 exit, 94 exit_group, 142 reboot,
 *                         157 setsid, 160 uname-adjacent, 161 sethostname
 *   indefinite blockers : 72 pselect6, 73 ppoll, 133 rt_sigsuspend,
 *                         137 rt_sigtimedwait
 *   self-sabotage       : 139 rt_sigreturn (restores bogus frame -> SIGSEGV),
 *                         277 seccomp (arg0 == SET_MODE_STRICT -> sandboxes
 *                         itself, next syscall SIGKILLed)
 *   process/image churn : 220 clone, 221 execve, 435 clone3
 * Everything else is safe as a non-root shell (mount/module/kexec/set*id all
 * return -EPERM; read/write use count 0 so they cannot block).
 */
#define _GNU_SOURCE
#include <errno.h>

#include "small_rt.h"

static int is_dig(char c) { return c >= '0' && c <= '9'; }

/* returns -1 on empty/non-numeric input */
static long my_atol(const char *s)
{
	long r = 0;
	if (!s || !*s)
		return -1;
	while (*s) {
		if (!is_dig(*s))
			return -1;
		r = r * 10 + (*s - '0');
		s++;
	}
	return r;
}

/* write "<n>\n" to fd, no libc */
static void put_line(int fd, long n)
{
	char buf[24];
	int i = sizeof(buf);
	buf[--i] = '\n';
	if (n == 0) {
		buf[--i] = '0';
	} else {
		long v = n;
		while (v > 0) {
			buf[--i] = '0' + (v % 10);
			v /= 10;
		}
	}
	__syscall(SYS_write, fd, (long)(buf + i), sizeof(buf) - i, NONE, NONE, NONE);
}

static int is_hazard(long n)
{
	switch (n) {
	case 58: case 72: case 73: case 93: case 94:
	case 133: case 137: case 139: case 142: case 157:
	case 160: case 161: case 220: case 221: case 277:
	case 435:
		return 1;
	}
	return 0;
}

static const char usage[] = "usage: scan START END\n";

__attribute__((always_inline))
int c_main(int argc, char *argv[], char *envp[])
{
	if (argc < 3) {
		__syscall(SYS_write, 2, (long)usage, sizeof(usage) - 1, NONE, NONE, NONE);
		return 1;
	}

	long start = my_atol(argv[1]);
	long end = my_atol(argv[2]);
	if (start < 0 || end < 0 || end < start) {
		__syscall(SYS_write, 2, (long)usage, sizeof(usage) - 1, NONE, NONE, NONE);
		return 1;
	}

	for (long n = start; n <= end; n++) {
		if (is_hazard(n))
			continue;
		long ret = __syscall(n, NONE, NONE, NONE, NONE, NONE, NONE);
		if (ret != -ENOSYS)
			put_line(1, n);
	}
	return 0;
}

__attribute__((used))
void prep_main(long *sp)
{
	long argc = *sp;
	char **argv = (char **)(sp + 1);
	char **envp = argv + argc + 1;

	long exit_code = c_main(argc, argv, envp);
	__syscall(SYS_exit, exit_code, NONE, NONE, NONE, NONE, NONE);
	__builtin_unreachable();
}
