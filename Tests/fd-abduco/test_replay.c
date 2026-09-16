/* Tests/fd-abduco/test_replay.c — connects to a live fd-abduco session socket,
 * performs the real attach handshake (MSG_ATTACH then MSG_RESIZE, replicated
 * from vendor/fd-abduco/client.c's client_mainloop()), and asserts a marker
 * printed by the session's child process arrives via history replay before
 * (or without needing) any further live output.
 *
 * WANT_MARKER (default "MARKER-12345") must be present in the replayed
 * bytes. WANT_ABSENT, if defined (no default), must NOT be present -- used
 * by run_trim_test.sh to prove the output-log budget trim actually dropped
 * the early bulk of a session's output. */
#ifndef WANT_MARKER
#define WANT_MARKER "MARKER-12345"
#endif

#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include "protocol.h"

/* Mirrors abduco.c's send_packet(): header (everything up to `u`) plus the
 * first `len` bytes of the union, as one write. */
static int send_pkt(int fd, unsigned int type, const void *payload, size_t len) {
	Packet p;
	memset(&p, 0, sizeof p);
	p.type = type;
	p.len = len;
	if (payload && len)
		memcpy(p.u.msg, payload, len);
	size_t size = offsetof(Packet, u) + len;
	ssize_t n = write(fd, &p, size);
	return n == (ssize_t)size ? 0 : -1;
}

int main(int argc, char **argv) {
	assert(argc >= 2);
	const char *sock = argv[1];
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	assert(fd >= 0);
	struct sockaddr_un a;
	memset(&a, 0, sizeof a);
	a.sun_family = AF_UNIX;
	strncpy(a.sun_path, sock, sizeof a.sun_path - 1);
	assert(connect(fd, (struct sockaddr *)&a, sizeof a) == 0);

	/* Bound each read() so a server that never replays fails the assertion below
	 * instead of hanging the test forever. */
	struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

	/* client_mainloop(): first packet is always MSG_ATTACH carrying client.flags
	 * (0 here -- no -r/-l). */
	int flags = 0;
	assert(send_pkt(fd, MSG_ATTACH, &flags, sizeof flags) == 0);

	/* client.need_resize starts true, so the real client's very next action is a
	 * MSG_RESIZE carrying the terminal's winsize; this is what actually flips the
	 * server's Client into STATE_ATTACHED (see server.c). Fabricate a plausible
	 * winsize since this test process has no controlling terminal. */
	struct winsize ws;
	memset(&ws, 0, sizeof ws);
	ws.ws_row = 24;
	ws.ws_col = 80;
	assert(send_pkt(fd, MSG_RESIZE, &ws, sizeof ws) == 0);

	char buf[65536];
	size_t got = 0;
	int found = 0;
	for (int i = 0; i < 50 && got < sizeof buf - 1; i++) {
		ssize_t n = read(fd, buf + got, sizeof buf - 1 - got);
		if (n <= 0)
			break;
		got += (size_t)n;
		buf[got] = 0;
		if (memmem(buf, got, WANT_MARKER, strlen(WANT_MARKER))) {
			found = 1;
			break;
		}
	}
	assert(found);
#ifdef WANT_ABSENT
	assert(memmem(buf, got, WANT_ABSENT, strlen(WANT_ABSENT)) == NULL);
#endif
	printf("replay OK\n");
	close(fd);
	return 0;
}
