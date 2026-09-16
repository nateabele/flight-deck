/*
 * Vendored from martanne/abduco @ e76729a2df45ecabe72a423e925ed876f66235d6 (tag v0.6): config.def.h
 * Flight Deck fork ("fd-abduco") -- see vendor/fd-abduco/PROVENANCE.md.
 * Edited: VERSION/ABDUCO_CMD below identify this build as the fd-abduco fork (Task 1, decision
 * #4); everything else is unmodified upstream default configuration. `socket_dirs` below is
 * unused whenever a caller passes an absolute (or relative-with-slash) socket path -- see
 * `set_socket_name()` in abduco.c, which takes such paths verbatim, bypassing this table
 * entirely. This is upstream's existing behavior (confirmed by reading the source), not a
 * fork-specific patch; explicit socket paths are already honored as-is.
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
/* identify this fork's build in `-v` output (abduco.c: puts("abduco-"VERSION" ...")) */
#define VERSION "fd-abduco-0.6"
/* default command to execute if none is given and $ABDUCO_CMD is unset.
 * Upstream defaults to "dvtm", which Flight Deck does not depend on or ship;
 * fall back to a plain shell instead. */
#define ABDUCO_CMD "/bin/sh"
/* default detach key, can be overriden at run time using -e option */
static char KEY_DETACH = CTRL('\\');
/* redraw key to send a SIGWINCH signal to underlying process
 * (set to 0 to disable the redraw key) */
static char KEY_REDRAW = 0;
/* Where to place the "abduco" directory storing all session socket files.
 * The first directory to succeed is used. Only consulted for a session name
 * that is neither an absolute path nor a relative path containing a slash --
 * see the file header comment above. */
static struct Dir {
	char *path;    /* fixed (absolute) path to a directory */
	char *env;     /* environment variable to use if (set) */
	bool personal; /* if false a user owned sub directory will be created */
} socket_dirs[] = {
	{ .env  = "ABDUCO_SOCKET_DIR", false },
	{ .env  = "HOME",              true  },
	{ .env  = "TMPDIR",            false },
	{ .path = "/tmp",              false },
};
