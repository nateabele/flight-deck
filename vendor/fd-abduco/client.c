/*
 * Vendored from martanne/abduco @ e76729a2df45ecabe72a423e925ed876f66235d6 (tag v0.6): client.c
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
static void client_sigwinch_handler(int sig) {
	client.need_resize = true;
}

static bool client_send_packet(Packet *pkt) {
	print_packet("client-send:", pkt);
	if (send_packet(server.socket, pkt))
		return true;
	debug("FAILED\n");
	server.running = false;
	return false;
}

static bool client_recv_packet(Packet *pkt) {
	if (recv_packet(server.socket, pkt)) {
		print_packet("client-recv:", pkt);
		return true;
	}
	debug("client-recv: FAILED\n");
	server.running = false;
	return false;
}

/* Flight Deck fork: whether to use the alternate screen buffer at all.
 *
 * Upstream abduco unconditionally switches to the alternate buffer on attach so
 * that a later detach restores whatever the user's shell had on screen. That is
 * the right trade for a multiplexer you attach to from an existing terminal; it
 * is the wrong one for Flight Deck, where the attach client owns its ghostty
 * surface for the whole life of the tab and there is no prior screen to put
 * back. See `client_setup_terminal` for what it cost us.
 *
 * Opt back in with FD_ABDUCO_ALT_SCREEN=1 for standalone/upstream-equivalent
 * use. Flight Deck never sets it. Read once, because `client_restore_terminal`
 * runs from an atexit handler where getenv is not async-signal-safe and the
 * environment may already be torn down. */
static bool fd_use_alternate_buffer(void) {
	static int cached = -1;
	if (cached == -1) {
		const char *v = getenv("FD_ABDUCO_ALT_SCREEN");
		cached = (v && v[0] == '1' && v[1] == '\0') ? 1 : 0;
	}
	return cached == 1;
}

static void client_restore_terminal(void) {
	if (has_term)
		tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_term);
	if (alternate_buffer) {
		printf("\033[?25h\033[?1049l");
		fflush(stdout);
		alternate_buffer = false;
	} else {
		/* Flight Deck fork: upstream restored cursor visibility only as part of
		 * leaving the alternate buffer. With that switch off by default, the
		 * show-cursor still has to happen -- a session detached while its agent
		 * had the cursor hidden would otherwise leave it hidden for good. */
		printf("\033[?25h");
		fflush(stdout);
	}
}

static void client_setup_terminal(void) {
	atexit(client_restore_terminal);

	cur_term = orig_term;
	cur_term.c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON|IXOFF);
	cur_term.c_oflag &= ~(OPOST);
	cur_term.c_lflag &= ~(ECHO|ECHONL|ICANON|ISIG|IEXTEN);
	cur_term.c_cflag &= ~(CSIZE|PARENB);
	cur_term.c_cflag |= CS8;
	cur_term.c_cc[VLNEXT] = _POSIX_VDISABLE;
	cur_term.c_cc[VMIN] = 1;
	cur_term.c_cc[VTIME] = 0;
	tcsetattr(STDIN_FILENO, TCSANOW, &cur_term);

	/* Flight Deck fork: DO NOT switch to the alternate screen by default.
	 *
	 * Upstream ran `\033[?1049h\033[H` here unconditionally. Inside Flight Deck
	 * the attach client owns its ghostty surface for the tab's entire life, so
	 * that switch never gets undone, and everything the tab shows lives on the
	 * alternate screen. Two consequences, both user-visible:
	 *
	 *   1. The alternate screen has no scrollback, so two-finger scroll has
	 *      nothing to scroll -- the session's own history is unreachable.
	 *   2. Ghostty therefore converts scroll into cursor-key presses (DEC
	 *      private mode 1007, "alternate scroll", default ON -- see
	 *      `mouseScroll` in vendor/ghostty/src/Surface.zig, which requires
	 *      exactly alt-screen + no mouse reporting + 1007). Claude Code's
	 *      composer binds Up/Down to prompt-history recall, so every scroll
	 *      gesture walked the user backwards through old prompts instead of
	 *      scrolling.
	 *
	 * That was the "scrolling recalls my prompt history" bug (2026-09-20). It
	 * read as intermittent only because a stray `\033[?1049l` later in the
	 * replayed history -- from a pager that had exited, or from the mode
	 * preamble -- would sometimes leave the alternate screen again by accident,
	 * which is why some tabs behaved and others did not, and why a tab could
	 * break on the next re-attach.
	 *
	 * Verified by attaching read-only to 10 live sessions and diffing the
	 * attach stream: 8 arrived on the alternate screen, 2 (the ones that
	 * happened to carry a matching 1049l) did not. */
	if (fd_use_alternate_buffer() && !alternate_buffer) {
		printf("\033[?1049h\033[H");
		fflush(stdout);
		alternate_buffer = true;
	}
}

static int client_mainloop(void) {
	sigset_t emptyset, blockset;
	sigemptyset(&emptyset);
	sigemptyset(&blockset);
	sigaddset(&blockset, SIGWINCH);
	sigprocmask(SIG_BLOCK, &blockset, NULL);

	client.need_resize = true;
	Packet pkt = {
		.type = MSG_ATTACH,
		.u.i = client.flags,
		.len = sizeof(pkt.u.i),
	};
	client_send_packet(&pkt);

	while (server.running) {
		fd_set fds;
		FD_ZERO(&fds);
		FD_SET(STDIN_FILENO, &fds);
		FD_SET(server.socket, &fds);

		if (client.need_resize) {
			struct winsize ws;
			if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) != -1) {
				Packet pkt = {
					.type = MSG_RESIZE,
					.u = { .ws = ws },
					.len = sizeof(ws),
				};
				if (client_send_packet(&pkt))
					client.need_resize = false;
			}
		}

		if (pselect(server.socket+1, &fds, NULL, NULL, NULL, &emptyset) == -1) {
			if (errno == EINTR)
				continue;
			die("client-mainloop");
		}

		if (FD_ISSET(server.socket, &fds)) {
			Packet pkt;
			if (client_recv_packet(&pkt)) {
				switch (pkt.type) {
				case MSG_CONTENT:
					write_all(STDOUT_FILENO, pkt.u.msg, pkt.len);
					break;
				case MSG_RESIZE:
					client.need_resize = true;
					break;
				case MSG_EXIT:
					client_send_packet(&pkt);
					close(server.socket);
					return pkt.u.i;
				}
			}
		}

		if (FD_ISSET(STDIN_FILENO, &fds)) {
			Packet pkt = { .type = MSG_CONTENT };
			ssize_t len = read(STDIN_FILENO, pkt.u.msg, sizeof(pkt.u.msg));
			if (len == -1 && errno != EAGAIN && errno != EINTR)
				die("client-stdin");
			if (len > 0) {
				debug("client-stdin: %c\n", pkt.u.msg[0]);
				pkt.len = len;
				if (KEY_REDRAW && pkt.u.msg[0] == KEY_REDRAW) {
					client.need_resize = true;
				} else if (pkt.u.msg[0] == KEY_DETACH) {
					pkt.type = MSG_DETACH;
					pkt.len = 0;
					client_send_packet(&pkt);
					close(server.socket);
					return -1;
				} else if (!(client.flags & CLIENT_READONLY)) {
					client_send_packet(&pkt);
				}
			}
		}
	}

	return -EIO;
}
