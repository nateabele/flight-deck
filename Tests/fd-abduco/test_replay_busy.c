/* Tests/fd-abduco/test_replay_busy.c — covers the ordering race between a
 * client's MSG_ATTACH and its MSG_RESIZE (a SEPARATE select() iteration on
 * the server; see vendor/fd-abduco/server.c). If the server forwards live PTY
 * output to a client that is STATE_CONNECTED but not yet STATE_ATTACHED, that
 * same output was already captured into the outlog and gets sent AGAIN when
 * MSG_RESIZE triggers replay -- duplicated and out of order at the head of
 * scrollback. This test attaches to a session whose child keeps emitting
 * numbered lines *during* the handshake gap (by deliberately delaying the
 * MSG_RESIZE) and asserts the numbers it observes are strictly increasing:
 * no duplicate, no repeat-from-history after a higher number already arrived
 * live. */
#include <assert.h>
#include <ctype.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include "protocol.h"

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

/* Scans raw bytes (packet framing included -- we don't bother parsing packet
 * boundaries) for ASCII "LINE-DDD" markers and returns the parsed values in
 * order of appearance. */
static int extract_lines(const char *buf, size_t n, int *out, int max) {
	int count = 0;
	for (size_t i = 0; i + 8 <= n && count < max; i++) {
		if (memcmp(buf + i, "LINE-", 5) == 0 &&
		    isdigit((unsigned char)buf[i + 5]) &&
		    isdigit((unsigned char)buf[i + 6]) &&
		    isdigit((unsigned char)buf[i + 7])) {
			out[count++] = (buf[i + 5] - '0') * 100 + (buf[i + 6] - '0') * 10 + (buf[i + 7] - '0');
			i += 7;
		}
	}
	return count;
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

	struct timeval tv = { .tv_sec = 0, .tv_usec = 150000 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

	/* MSG_ATTACH first, exactly like a real client. */
	int flags = 0;
	assert(send_pkt(fd, MSG_ATTACH, &flags, sizeof flags) == 0);

	/* Deliberately hold off on MSG_RESIZE, wide enough that the daemon's
	 * numbered-line loop (50ms/line) produces several lines while we sit in
	 * STATE_CONNECTED -- this is the exact window the race lives in. */
	usleep(300000);

	struct winsize ws;
	memset(&ws, 0, sizeof ws);
	ws.ws_row = 24;
	ws.ws_col = 80;
	assert(send_pkt(fd, MSG_RESIZE, &ws, sizeof ws) == 0);

	/* Drain everything: the (possibly buggy) live sends from the CONNECTED
	 * window, the MSG_RESIZE replay, and live output that follows it. */
	static char buf[1 << 20];
	size_t got = 0;
	int idle_streak = 0;
	while (got < sizeof buf - 1 && idle_streak < 3) {
		ssize_t n = read(fd, buf + got, sizeof buf - 1 - got);
		if (n <= 0) {
			idle_streak++;
			continue;
		}
		idle_streak = 0;
		got += (size_t)n;
	}
	buf[got] = 0;
	close(fd);

	int lines[1024];
	int n = extract_lines(buf, got, lines, 1024);
	if (n < 4) {
		fprintf(stderr, "only observed %d LINE-### markers -- test didn't exercise real output\n", n);
		assert(n >= 4);
	}
	for (int i = 1; i < n; i++) {
		if (lines[i] <= lines[i - 1]) {
			fprintf(stderr,
				"ORDER/DUPLICATE VIOLATION at index %d: ...LINE-%03d, LINE-%03d... "
				"(replayed history duplicated or misordered relative to live output during a busy attach)\n",
				i, lines[i - 1], lines[i]);
			assert(0);
		}
	}
	printf("busy-attach replay ordering OK (%d lines observed, strictly increasing)\n", n);
	return 0;
}
