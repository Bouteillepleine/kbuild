/*
 * genlprobe — resolve generic-netlink family names via CTRL_CMD_GETFAMILY.
 *
 * Any process can ask the genl controller "does family <name> exist?" and get
 * its id/version back. NoMount registers a genl family literally named
 * "nomount" (hookless/src/nomount.h: NOMOUNT_GENL_NAME) as its control channel
 * — which means the mount-hider is directly discoverable this way, an active
 * detection oracle independent of mounts/files/syscalls.
 *
 *   nlctrl   -> positive control (always present)
 *   nomount  -> the oracle under test
 *   <bogus>  -> negative control (must be absent)
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>

static int resolve(const char *name, int *id, int *ver)
{
	int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0) return -1000 - errno;

	struct sockaddr_nl sa; memset(&sa, 0, sizeof sa); sa.nl_family = AF_NETLINK;
	bind(fd, (struct sockaddr *)&sa, sizeof sa);

	char buf[512]; memset(buf, 0, sizeof buf);
	struct nlmsghdr *nlh = (struct nlmsghdr *)buf;
	struct genlmsghdr *g = (struct genlmsghdr *)NLMSG_DATA(nlh);
	nlh->nlmsg_type  = GENL_ID_CTRL;
	nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	nlh->nlmsg_seq   = 1;
	g->cmd = CTRL_CMD_GETFAMILY; g->version = 1;

	struct nlattr *na = (struct nlattr *)((char *)g + GENL_HDRLEN);
	int nl = (int)strlen(name) + 1;
	na->nla_type = CTRL_ATTR_FAMILY_NAME;
	na->nla_len  = NLA_HDRLEN + nl;
	memcpy((char *)na + NLA_HDRLEN, name, nl);
	nlh->nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + NLA_ALIGN(na->nla_len);

	struct sockaddr_nl dst; memset(&dst, 0, sizeof dst); dst.nl_family = AF_NETLINK;
	if (sendto(fd, buf, nlh->nlmsg_len, 0, (struct sockaddr *)&dst, sizeof dst) < 0) {
		int e = errno; close(fd); return -2000 - e;
	}

	char rbuf[2048];
	int len = recv(fd, rbuf, sizeof rbuf, 0);
	close(fd);
	if (len < 0) return -3000 - errno;

	struct nlmsghdr *rh = (struct nlmsghdr *)rbuf;
	if (rh->nlmsg_type == NLMSG_ERROR) {
		struct nlmsgerr *e = (struct nlmsgerr *)NLMSG_DATA(rh);
		return e->error; /* 0 = ok(ack), -ENOENT = absent */
	}
	struct genlmsghdr *rg = (struct genlmsghdr *)NLMSG_DATA(rh);
	struct nlattr *a = (struct nlattr *)((char *)rg + GENL_HDRLEN);
	int alen = rh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
	*id = -1; *ver = -1;
	while (alen >= (int)NLA_HDRLEN) {
		void *d = (char *)a + NLA_HDRLEN;
		if (a->nla_type == CTRL_ATTR_FAMILY_ID)      *id  = *(unsigned short *)d;
		else if (a->nla_type == CTRL_ATTR_VERSION)   *ver = *(int *)d;
		int step = NLA_ALIGN(a->nla_len);
		if (step <= 0) break;
		alen -= step; a = (struct nlattr *)((char *)a + step);
	}
	return 0;
}

int main(void)
{
	const char *names[] = { "nlctrl", "nomount", "no_such_family_xyz", 0 };
	printf("uid=%d — generic-netlink family resolution\n", getuid());
	for (int i = 0; names[i]; i++) {
		int id = 0, ver = 0, r = resolve(names[i], &id, &ver);
		if (r == 0 && id > 0)
			printf("  %-20s : PRESENT   id=%d ver=%d\n", names[i], id, ver);
		else if (r == -ENOENT || r == -EINVAL)
			printf("  %-20s : absent\n", names[i]);   /* kernel uses EINVAL for unknown family */
		else
			printf("  %-20s : err=%d (socket/SELinux?)\n", names[i], r);
	}
	return 0;
}
