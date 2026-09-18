/*
 * Flight Deck: FdOutlog - bounded output log with boundary-aware trim
 */
#ifndef FD_OUTLOG_H
#define FD_OUTLOG_H
#include <stddef.h>
/* Flight Deck fork: bytes belonging to a terminal-capability *query*
 * (XTVERSION/XTGETTCAP/DA/DSR/kitty keyboard-protocol) are scanned out of
 * what enters `data` below -- see fd_outlog.c -- so a fresh ghostty
 * reattaching doesn't re-answer them into the pty's stdin. `pend`/`pend_len`
 * hold an in-progress escape candidate that spans append() calls;
 * FD_OUTLOG_PEND_CAP bounds how long that scan buffer is allowed to grow
 * before it is emitted verbatim (under-strip, never over-strip). */
#define FD_OUTLOG_PEND_CAP 32
/* Flight Deck fork: last-observed set/reset state of one DEC private mode
 * (`CSI ? Pm h` / `CSI ? Pm l`) -- see fd_outlog.c's process_byte() and
 * fd_outlog_preamble(). `set` is nonzero for `h` (set), zero for `l`
 * (reset). */
typedef struct { int mode; int set; } FdOutlogMode;
typedef struct {
    char *data; size_t len, cap, budget;
    char pend[FD_OUTLOG_PEND_CAP]; size_t pend_len;
    /* set once a DCS candidate's "+q" prefix commits it to an XTGETTCAP
     * drop, so the (possibly long, multi-capability) payload is consumed
     * straight to its terminator without ever touching `pend` -- see
     * fd_outlog.c. dropping_dcs_esc is a 1-byte lookback used to notice
     * the two-byte ST (ESC \) while dropping. */
    int dropping_dcs, dropping_dcs_esc;
    /* Flight Deck fork: last-seen state of every DEC private mode observed
     * in the stream so far, tracked generically (mouse tracking,
     * alternate-scroll, alt-screen, bracketed paste, ...) -- whichever ones
     * a given program happens to set. Grows via realloc as new distinct
     * modes are observed; `modes_len` of them are live, in first-seen
     * order. Existing entries are updated in place on a later set/reset of
     * the same mode. See fd_outlog_preamble(). */
    FdOutlogMode *modes; size_t modes_len, modes_cap;
} FdOutlog;
void fd_outlog_init(FdOutlog *o, size_t budget);
void fd_outlog_free(FdOutlog *o);
void fd_outlog_append(FdOutlog *o, const char *buf, size_t len);
void fd_outlog_trim(FdOutlog *o);
/* Flight Deck fork: the two calls below let a caller synthesize a preamble
 * that unconditionally re-asserts every tracked private mode's current
 * value, so it can be replayed to a newly attaching client before history --
 * restoring mode state even once the mode's own set/reset bytes have aged
 * out of the trimmed ring. Two-call size-then-write (rather than an
 * internal malloc) so the caller owns the buffer, matching how
 * fd_outlog_append() takes a caller-owned buffer rather than an FdOutlog
 * owning client-facing I/O. */
size_t fd_outlog_preamble_size(const FdOutlog *o);
size_t fd_outlog_preamble(const FdOutlog *o, char *buf);
#endif
