/*
 * Vendored from martanne/abduco @ e76729a2df45ecabe72a423e925ed876f66235d6 (tag v0.6):
 * `enum PacketType` and the `Packet` struct, factored out of abduco.c verbatim.
 * Flight Deck fork ("fd-abduco") -- see vendor/fd-abduco/PROVENANCE.md.
 *
 * Factored (Task 3) so `Tests/fd-abduco/test_replay.c` can share the exact wire
 * protocol declarations with the daemon instead of redeclaring them; no field or
 * value was changed from what abduco.c previously declared inline.
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
#ifndef ABDUCO_PROTOCOL_H
#define ABDUCO_PROTOCOL_H

#include <stddef.h>
#include <stdio.h>
#include <sys/ioctl.h>

enum PacketType {
	MSG_CONTENT = 0,
	MSG_ATTACH  = 1,
	MSG_DETACH  = 2,
	MSG_RESIZE  = 3,
	MSG_REDRAW  = 4,
	MSG_EXIT    = 5,
};

typedef struct {
	unsigned int type;
	size_t len;
	union {
		char msg[BUFSIZ];
		struct winsize ws;
		int i;
	} u;
} Packet;

#endif
