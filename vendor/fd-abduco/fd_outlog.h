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
typedef struct {
    char *data; size_t len, cap, budget;
    char pend[FD_OUTLOG_PEND_CAP]; size_t pend_len;
} FdOutlog;
void fd_outlog_init(FdOutlog *o, size_t budget);
void fd_outlog_free(FdOutlog *o);
void fd_outlog_append(FdOutlog *o, const char *buf, size_t len);
void fd_outlog_trim(FdOutlog *o);
#endif
