/*
 * Vendored from martanne/abduco @ e76729a2df45ecabe72a423e925ed876f66235d6 (tag v0.6): debug.c
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
#ifdef NDEBUG
static void debug(const char *errstr, ...) { }
static void print_packet(const char *prefix, Packet *pkt) { }
#else

static void debug(const char *errstr, ...) {
	va_list ap;
	va_start(ap, errstr);
	vfprintf(stderr, errstr, ap);
	va_end(ap);
}

static void print_packet(const char *prefix, Packet *pkt) {
	static const char *msgtype[] = {
		[MSG_CONTENT] = "CONTENT",
		[MSG_ATTACH]  = "ATTACH",
		[MSG_DETACH]  = "DETACH",
		[MSG_RESIZE]  = "RESIZE",
		[MSG_REDRAW]  = "REDRAW",
		[MSG_EXIT]    = "EXIT",
	};
	const char *type = "UNKNOWN";
	if (pkt->type < countof(msgtype) && msgtype[pkt->type])
		type = msgtype[pkt->type];

	fprintf(stderr, "%s: %s ", prefix, type);
	switch (pkt->type) {
	case MSG_CONTENT:
		fwrite(pkt->u.msg, pkt->len, 1, stderr);
		break;
	case MSG_RESIZE:
		fprintf(stderr, "%dx%d", pkt->u.ws.ws_col, pkt->u.ws.ws_row);
		break;
	case MSG_ATTACH:
		fprintf(stderr, "readonly: %d low-priority: %d",
			pkt->u.i & CLIENT_READONLY,
			pkt->u.i & CLIENT_LOWPRIORITY);
		break;
	default:
		fprintf(stderr, "len: %zu", pkt->len);
		break;
	}
	fprintf(stderr, "\n");
}

#endif /* NDEBUG */
