/* Tests/fd-abduco/test_outlog_modes.c
 *
 * Flight Deck fork: FdOutlog tracks the last-seen set/reset state of every
 * DEC private mode (`CSI ? Pm h` / `CSI ? Pm l`) it observes in the pty
 * stream, so fd_outlog_preamble() can re-assert current mode state (e.g.
 * mouse tracking) to a brand-new terminal surface on reattach even after
 * the mode's own set/reset bytes have aged out of the trimmed ring -- see
 * fd_outlog.c's track_private_modes()/fd_outlog_preamble().
 */
#include <assert.h>
#include <string.h>
#include "fd_outlog.h"

int main(void) {
    FdOutlog o;

    /* 1. a mode-set sequence pushed out of the trim budget by filler bytes
     * must still be reflected in the synthesized preamble -- this is the
     * whole point of tracking modes outside the byte ring. */
    fd_outlog_init(&o, 16);
    fd_outlog_append(&o, "\x1b[?1000h", 8); /* enable mouse tracking */
    fd_outlog_append(&o, "0123456789ABCDEFGHIJ", 20); /* filler, > budget */
    fd_outlog_trim(&o);
    /* the mode-set bytes themselves are long gone from the ring */
    assert(memmem(o.data, o.len, "\x1b[?1000h", 8) == NULL);
    {
        size_t n = fd_outlog_preamble_size(&o);
        char buf[64];
        assert(n < sizeof buf);
        assert(fd_outlog_preamble(&o, buf) == n);
        assert(n == 8 && memcmp(buf, "\x1b[?1000h", 8) == 0);
    }
    fd_outlog_free(&o);

    /* 2. set-then-reset: the preamble must reflect the final (reset) value,
     * not the earlier set. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[?1000h", 8);
    fd_outlog_append(&o, "\x1b[?1000l", 8);
    fd_outlog_trim(&o);
    {
        size_t n = fd_outlog_preamble_size(&o);
        char buf[64];
        assert(n < sizeof buf);
        fd_outlog_preamble(&o, buf);
        assert(n == 8 && memcmp(buf, "\x1b[?1000l", 8) == 0);
    }
    fd_outlog_free(&o);

    /* 3. a multi-param sequence sets/resets every listed mode. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[?1000;1006h", 13);
    fd_outlog_trim(&o);
    {
        size_t n = fd_outlog_preamble_size(&o);
        char buf[64];
        assert(n < sizeof buf);
        fd_outlog_preamble(&o, buf);
        /* first-seen order: 1000 then 1006 */
        assert(n == 16 && memcmp(buf, "\x1b[?1000h\x1b[?1006h", 16) == 0);
    }
    /* the sequence itself is not stripped -- it's a set/reset, not a query */
    assert(memmem(o.data, o.len, "\x1b[?1000;1006h", 13) != NULL);
    fd_outlog_free(&o);

    /* 4. no modes observed yet -> empty preamble, not garbage. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "plain output, no escapes", 24);
    fd_outlog_trim(&o);
    assert(fd_outlog_preamble_size(&o) == 0);
    fd_outlog_free(&o);

    /* 5. distinct modes accumulate independently, each keeping its own
     * last-seen value; a later mode's reset doesn't disturb an earlier
     * mode's set. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[?1049h", 8);  /* alt screen on */
    fd_outlog_append(&o, "\x1b[?2004h", 8);  /* bracketed paste on */
    fd_outlog_append(&o, "\x1b[?2004l", 8);  /* bracketed paste off */
    fd_outlog_trim(&o);
    {
        size_t n = fd_outlog_preamble_size(&o);
        char buf[64];
        assert(n < sizeof buf);
        fd_outlog_preamble(&o, buf);
        assert(n == 16 && memcmp(buf, "\x1b[?1049h\x1b[?2004l", 16) == 0);
    }
    fd_outlog_free(&o);

    /* 6. DECRQM (a mode *query*, not a set/reset) is not tracked and not
     * stripped -- final byte 'p' with an intermediate '$', out of scope
     * per the brief. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[?1000$p", 9);
    fd_outlog_trim(&o);
    assert(fd_outlog_preamble_size(&o) == 0);
    assert(memmem(o.data, o.len, "\x1b[?1000$p", 9) != NULL);
    fd_outlog_free(&o);

    /* 7. a non-private mode (`CSI Pm h`, no `?`) is out of scope and left
     * untouched -- must not be tracked as a private mode. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[4h", 4); /* IRM, not a DEC private mode */
    fd_outlog_trim(&o);
    assert(fd_outlog_preamble_size(&o) == 0);
    assert(memmem(o.data, o.len, "\x1b[4h", 4) != NULL);
    fd_outlog_free(&o);

    /* 8. degenerate parameter forms don't crash or record garbage: an
     * empty param list (`CSI ? h`), and a param list that's nothing but
     * separators (`CSI ? ;; h`) both track zero modes. A well-formed mode
     * afterward still parses normally, proving the scanner state wasn't
     * left wedged by the garbage. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[?h", 4);
    fd_outlog_append(&o, "\x1b[?;;h", 6);
    assert(fd_outlog_preamble_size(&o) == 0);
    fd_outlog_append(&o, "\x1b[?1h", 5);
    {
        size_t n = fd_outlog_preamble_size(&o);
        char buf[64];
        assert(n < sizeof buf);
        fd_outlog_preamble(&o, buf);
        assert(n == 5 && memcmp(buf, "\x1b[?1h", 5) == 0);
    }
    fd_outlog_free(&o);

    /* 9. an oversized parameter (far more digits than any real DEC private
     * mode ever has) must not be tracked, and -- the actual regression this
     * guards -- must not signed-integer-overflow while being parsed. This
     * is the reviewer's reproducer verbatim: 10 digits, well past
     * FD_OUTLOG_MODE_MAX, previously overflowed `int` inside
     * track_private_modes()'s accumulation (caught by
     * -fsanitize=undefined; see PROVENANCE.md's 2026-09-18 entry). A
     * well-formed mode right after still parses correctly, proving the
     * scanner wasn't left wedged. */
    fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "\x1b[?3217300869h", 14);
    assert(fd_outlog_preamble_size(&o) == 0);
    fd_outlog_append(&o, "\x1b[?1000h", 8);
    {
        size_t n = fd_outlog_preamble_size(&o);
        char buf[64];
        assert(n < sizeof buf);
        fd_outlog_preamble(&o, buf);
        assert(n == 8 && memcmp(buf, "\x1b[?1000h", 8) == 0);
    }
    /* not a query -- the raw bytes (garbage mode number and all) still
     * belong in the ring verbatim */
    assert(memmem(o.data, o.len, "\x1b[?3217300869h", 14) != NULL);
    fd_outlog_free(&o);

    return 0;
}
