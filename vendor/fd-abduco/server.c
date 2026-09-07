/*
 * Vendored from martanne/abduco @ e76729a2df45ecabe72a423e925ed876f66235d6 (tag v0.6): server.c
 * Flight Deck fork ("fd-abduco") -- see vendor/fd-abduco/PROVENANCE.md.
 *
 * Copyright (c) 2013-2016 Marc André Tanner <mat at brain-dump.org>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
#define FD_SET_MAX(fd, set, maxfd) do { \
		FD_SET(fd, set);        \
		if (fd > maxfd)         \
			maxfd = fd;     \
	} while (0)

static Client *client_malloc(int socket) {
	Client *c = calloc(1, sizeof(Client));
	if (!c)
		return NULL;
	c->socket = socket;
	return c;
}

static void client_free(Client *c) {
	if (c && c->socket > 0)
		close(c->socket);
	free(c);
}

static void server_sink_client() {
	if (!server.clients || !server.clients->next)
		return;
	Client *target = server.clients;
	server.clients = target->next;
	Client *dst = server.clients;
	while (dst->next)
		dst = dst->next;
	target->next = NULL;
	dst->next = target;
}

static void server_mark_socket_exec(bool exec, bool usr) {
	struct stat sb;
	if (stat(sockaddr.sun_path, &sb) == -1)
		return;
	mode_t mode = sb.st_mode;
	mode_t flag = usr ? S_IXUSR : S_IXGRP;
	if (exec)
		mode |= flag;
	else
		mode &= ~flag;
	chmod(sockaddr.sun_path, mode);
}

static int server_create_socket(const char *name) {
	if (!set_socket_name(&sockaddr, name))
		return -1;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd == -1)
		return -1;
	socklen_t socklen = offsetof(struct sockaddr_un, sun_path) + strlen(sockaddr.sun_path) + 1;
	mode_t mask = umask(S_IXUSR|S_IRWXG|S_IRWXO);
	int r = bind(fd, (struct sockaddr*)&sockaddr, socklen);
	umask(mask);

	if (r == -1) {
		close(fd);
		return -1;
	}

	if (listen(fd, 5) == -1) {
		unlink(sockaddr.sun_path);
		close(fd);
		return -1;
	}

	return fd;
}

static int server_set_socket_non_blocking(int sock) {
	int flags;
	if ((flags = fcntl(sock, F_GETFL, 0)) == -1)
		flags = 0;
    	return fcntl(sock, F_SETFL, flags | O_NONBLOCK);
}

static Client *server_accept_client(void) {
	int newfd = accept(server.socket, NULL, NULL);
	if (newfd == -1 || server_set_socket_non_blocking(newfd) == -1)
		goto error;
	Client *c = client_malloc(newfd);
	if (!c)
		goto error;
	if (!server.clients)
		server_mark_socket_exec(true, true);
	c->socket = newfd;
	c->state = STATE_CONNECTED;
	c->next = server.clients;
	server.clients = c;
	server.read_pty = true;
	return c;
error:
	if (newfd != -1)
		close(newfd);
	return NULL;
}

static bool server_read_pty(Packet *pkt) {
	pkt->type = MSG_CONTENT;
	ssize_t len = read(server.pty, pkt->u.msg, sizeof(pkt->u.msg));
	if (len > 0)
		pkt->len = len;
	else if (len == 0)
		server.running = false;
	else if (len == -1 && errno != EAGAIN && errno != EINTR && errno != EWOULDBLOCK)
		server.running = false;
	print_packet("server-read-pty:", pkt);
	return len > 0;
}

static bool server_write_pty(Packet *pkt) {
	print_packet("server-write-pty:", pkt);
	size_t size = pkt->len;
	if (write_all(server.pty, pkt->u.msg, size) == size)
		return true;
	debug("FAILED\n");
	server.running = false;
	return false;
}

static bool server_recv_packet(Client *c, Packet *pkt) {
	if (recv_packet(c->socket, pkt)) {
		print_packet("server-recv:", pkt);
		return true;
	}
	debug("server-recv: FAILED\n");
	c->state = STATE_DISCONNECTED;
	return false;
}

static bool server_send_packet(Client *c, Packet *pkt) {
	print_packet("server-send:", pkt);
	if (send_packet(c->socket, pkt))
		return true;
	debug("FAILED\n");
	c->state = STATE_DISCONNECTED;
	return false;
}

static void server_pty_died_handler(int sig) {
	int errsv = errno;
	pid_t pid;

	while ((pid = waitpid(-1, &server.exit_status, WNOHANG)) != 0) {
		if (pid == -1)
			break;
		server.exit_status = WEXITSTATUS(server.exit_status);
		server_mark_socket_exec(true, false);
	}

	debug("server pty died: %d\n", server.exit_status);
	errno = errsv;
}

static void server_sigterm_handler(int sig) {
	exit(EXIT_FAILURE); /* invoke atexit handler */
}

static void server_sigusr1_handler(int sig) {
	int socket = server_create_socket(server.session_name);
	if (socket != -1) {
		if (server.socket)
			close(server.socket);
		server.socket = socket;
	}
}

/* Flight Deck fork (Task 1): "<socket>.pid" sidecar holding the server
 * process's own decimal pid, so Flight Deck can SIGTERM the daemon that
 * owns the PTY without first attaching to it. Reuses the already-resolved
 * `sockaddr.sun_path` (set once, before forking, by server_create_socket())
 * rather than tracking a second static -- both the write here and the
 * unlink in server_atexit_handler() derive the same path from it. A write
 * failure is non-fatal: the daemon still runs, it just can't be signalled
 * by pidfile. */
static bool server_pidfile_path(char *path, size_t size) {
	int n = snprintf(path, size, "%s.pid", sockaddr.sun_path);
	return n >= 0 && (size_t)n < size;
}

static bool server_write_pidfile(void) {
	char path[sizeof(sockaddr.sun_path) + 4];
	if (!server_pidfile_path(path, sizeof(path)))
		return false;
	int fd = open(path, O_WRONLY|O_CREAT|O_TRUNC, S_IRUSR|S_IWUSR);
	if (fd == -1)
		return false;
	char buf[32];
	int len = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
	bool ok = len > 0 && (size_t)len < sizeof(buf) && write_all(fd, buf, len) == len;
	close(fd);
	return ok;
}

static void server_remove_pidfile(void) {
	char path[sizeof(sockaddr.sun_path) + 4];
	if (server_pidfile_path(path, sizeof(path)))
		unlink(path);
}

static void server_atexit_handler(void) {
	unlink(sockaddr.sun_path);
	server_remove_pidfile();
}

static void server_mainloop(void) {
	atexit(server_atexit_handler);
	fd_set new_readfds, new_writefds;
	FD_ZERO(&new_readfds);
	FD_ZERO(&new_writefds);
	FD_SET(server.socket, &new_readfds);
	int new_fdmax = server.socket;
	bool exit_packet_delivered = false;

	if (server.read_pty)
		FD_SET_MAX(server.pty, &new_readfds, new_fdmax);

	while (server.clients || !exit_packet_delivered) {
		int fdmax = new_fdmax;
		fd_set readfds = new_readfds;
		fd_set writefds = new_writefds;
		FD_SET_MAX(server.socket, &readfds, fdmax);

		if (select(fdmax+1, &readfds, &writefds, NULL, NULL) == -1) {
			if (errno == EINTR)
				continue;
			die("server-mainloop");
		}

		FD_ZERO(&new_readfds);
		FD_ZERO(&new_writefds);
		new_fdmax = server.socket;

		bool pty_data = false;

		Packet server_packet, client_packet;

		if (FD_ISSET(server.socket, &readfds))
			server_accept_client();

		if (FD_ISSET(server.pty, &readfds)) {
			pty_data = server_read_pty(&server_packet);
			/* Flight Deck fork (Task 3): capture what was just read, before it is
			 * forwarded to clients below, so replay can hand it to late attachers. */
			if (pty_data)
				fd_outlog_append(&server.outlog, server_packet.u.msg, server_packet.len);
		}

		for (Client **prev_next = &server.clients, *c = server.clients; c;) {
			if (FD_ISSET(c->socket, &readfds) && server_recv_packet(c, &client_packet)) {
				switch (client_packet.type) {
				case MSG_CONTENT:
					server_write_pty(&client_packet);
					break;
				case MSG_ATTACH:
					c->flags = client_packet.u.i;
					if (c->flags & CLIENT_LOWPRIORITY)
						server_sink_client();
					break;
				case MSG_RESIZE:
					/* Flight Deck fork (Task 3): this is the point a client actually
					 * becomes attached -- MSG_ATTACH above only records flags; the
					 * client always follows it with MSG_RESIZE (client.c:
					 * client.need_resize starts true). Replay history to this client
					 * only, once, on the CONNECTED/DETACHED -> ATTACHED transition,
					 * and do it before falling through to the live-forwarding code
					 * below so history always precedes any live/resize repaint. A
					 * later client-initiated resize also sends MSG_RESIZE while
					 * already ATTACHED; that must not replay again. */
					if (c->state != STATE_ATTACHED) {
						c->state = STATE_ATTACHED;
						fd_outlog_trim(&server.outlog);
						for (size_t off = 0; off < server.outlog.len; ) {
							Packet rp;
							memset(&rp, 0, sizeof rp);
							size_t chunk = server.outlog.len - off;
							if (chunk > sizeof(rp.u.msg))
								chunk = sizeof(rp.u.msg);
							rp.type = MSG_CONTENT;
							rp.len = chunk;
							memcpy(rp.u.msg, server.outlog.data + off, chunk);
							server_send_packet(c, &rp);
							off += chunk;
						}
					} else {
						c->state = STATE_ATTACHED;
					}
				case MSG_REDRAW:
					if (!(c->flags & CLIENT_READONLY) && (client_packet.type == MSG_REDRAW || c == server.clients)) {
						debug("server-ioct: TIOCSWINSZ\n");
						ioctl(server.pty, TIOCSWINSZ, &client_packet.u.ws);
					}
					kill(-server.pid, SIGWINCH);
					break;
				case MSG_EXIT:
					exit_packet_delivered = true;
					/* fall through */
				case MSG_DETACH:
					c->state = STATE_DISCONNECTED;
					break;
				default: /* ignore package */
					break;
				}
			}

			if (c->state == STATE_DISCONNECTED) {
				bool first = (c == server.clients);
				Client *t = c->next;
				client_free(c);
				*prev_next = c = t;
				if (first && server.clients) {
					Packet pkt = {
						.type = MSG_RESIZE,
						.len = 0,
					};
					server_send_packet(server.clients, &pkt);
				} else if (!server.clients) {
					server_mark_socket_exec(false, true);
				}
				continue;
			}

			FD_SET_MAX(c->socket, &new_readfds, new_fdmax);

			/* Flight Deck fork (Task 3 fix): a client is STATE_CONNECTED from
			 * accept() until its MSG_RESIZE lands (a separate select() iteration
			 * from its MSG_ATTACH) -- during that gap it must not receive live PTY
			 * output, or those same bytes (already captured into server.outlog)
			 * arrive twice: once here, live, and again moments later as the head
			 * of the MSG_RESIZE replay. Gate on STATE_ATTACHED so live forwarding
			 * only ever reaches a client whose replay has already been sent. */
			if (pty_data && c->state == STATE_ATTACHED)
				server_send_packet(c, &server_packet);
			if (!server.running) {
				if (server.exit_status != -1) {
					Packet pkt = {
						.type = MSG_EXIT,
						.u.i = server.exit_status,
						.len = sizeof(pkt.u.i),
					};
					if (!server_send_packet(c, &pkt))
						FD_SET_MAX(c->socket, &new_writefds, new_fdmax);
				} else {
					FD_SET_MAX(c->socket, &new_writefds, new_fdmax);
				}
			}
			prev_next = &c->next;
			c = c->next;
		}

		if (server.running && server.read_pty)
			FD_SET_MAX(server.pty, &new_readfds, new_fdmax);
	}

	exit(EXIT_SUCCESS);
}
