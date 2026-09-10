/* Tests/fd-abduco/test_outlog_queries.c
 *
 * Flight Deck fork: terminal-capability *query* sequences (XTVERSION,
 * XTGETTCAP, DA1/DA2/DA3, DSR, kitty keyboard-protocol) must never enter
 * the replay ring -- a fresh ghostty re-answers them into codex's stdin
 * on reattach, which is the garbage-composer bug this filters out.
 */
#include <assert.h>
#include <string.h>
#include "fd_outlog.h"

int main(void) {
    FdOutlog o;

    /* 1. XTVERSION mid-stream is stripped */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "abc\x1b[>qdef", 10);
    fd_outlog_trim(&o);
    assert(o.len == 6 && memcmp(o.data, "abcdef", 6) == 0);
    fd_outlog_free(&o);

    /* 2. XTGETTCAP DCS is stripped */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "x\x1bP+q544e\x1b\\y", 12);
    fd_outlog_trim(&o);
    assert(o.len == 2 && memcmp(o.data, "xy", 2) == 0);
    fd_outlog_free(&o);

    /* 3a. DA1 stripped */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[c", 3);
    fd_outlog_trim(&o);
    assert(o.len == 0);
    fd_outlog_free(&o);

    /* 3b. DSR stripped */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[6n", 4);
    fd_outlog_trim(&o);
    assert(o.len == 0);
    fd_outlog_free(&o);

    /* 4. query split across two appends is still stripped */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "ab\x1b[>", 5);
    fd_outlog_append(&o, "qcd", 3);
    fd_outlog_trim(&o);
    assert(o.len == 4 && memcmp(o.data, "abcd", 4) == 0);
    fd_outlog_free(&o);

    /* 5. normal output (SGR, cursor home, screen clear) is not over-stripped */
    fd_outlog_init(&o, 1024);
    {
        const char *in = "\x1b[1;31mred\x1b[0m\x1b[2J\x1b[H";
        size_t n = strlen(in);
        fd_outlog_append(&o, in, n);
        fd_outlog_trim(&o);
        assert(o.len == n && memcmp(o.data, in, n) == 0);
    }
    fd_outlog_free(&o);

    /* 6. an ambiguous/incomplete escape pending at finalize flushes verbatim
     * (must not be silently dropped) */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "hi\x1b[>", 5);
    fd_outlog_trim(&o);
    assert(o.len == 5 && memcmp(o.data, "hi\x1b[>", 5) == 0);
    fd_outlog_free(&o);

    return 0;
}
