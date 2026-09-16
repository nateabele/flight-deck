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

    /* 2b. XTGETTCAP DCS terminated by BEL (0x07) is also stripped --
     * ST is ESC \ OR BEL; a BEL-terminated query must not be flushed
     * verbatim into the ring. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "x\x1bP+q544e\x07y", 11);
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

    /* 7. long, batched XTGETTCAP (payload exceeds FD_OUTLOG_PEND_CAP) is
     * still fully stripped -- codex often batches several capabilities in
     * one DCS ("+q 524742;544e;4b53;..."), and once the pending-candidate
     * cap fires the old behavior flushed the whole thing VERBATIM into the
     * ring, reproducing the reattach-corruption bug for the long-query
     * case. Fed across several fd_outlog_append() calls, so this also
     * covers a +q DCS payload split across appends. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "x\x1bP+q", 5);
    for (int i = 0; i < 12; i++) fd_outlog_append(&o, "544e;", 5); /* 60 bytes, > cap */
    fd_outlog_append(&o, "\x1b\\y", 3);
    fd_outlog_trim(&o);
    assert(o.len == 2 && memcmp(o.data, "xy", 2) == 0);
    fd_outlog_free(&o);

    /* 8. remaining entries in the CSI query table are also stripped: DA2,
     * DA3, kitty keyboard-protocol, and the 0-param DA1/XTVERSION variants
     * (only DA1 "c", DSR "6n", and XTVERSION ">q" were exercised above). */
    {
        static const struct { const char *seq; size_t len; } more[] = {
            { "\x1b[>c",  4 }, /* DA2 */
            { "\x1b[>0c", 5 }, /* DA2 */
            { "\x1b[=c",  4 }, /* DA3 */
            { "\x1b[?u",  4 }, /* kitty keyboard-protocol query */
            { "\x1b[0c",  4 }, /* DA1, 0-param */
            { "\x1b[>0q", 5 }, /* XTVERSION, 0-param */
        };
        for (size_t i = 0; i < sizeof(more) / sizeof(more[0]); i++) {
            fd_outlog_init(&o, 1024);
            fd_outlog_append(&o, more[i].seq, more[i].len);
            fd_outlog_trim(&o);
            assert(o.len == 0);
            fd_outlog_free(&o);
        }
    }

    return 0;
}
