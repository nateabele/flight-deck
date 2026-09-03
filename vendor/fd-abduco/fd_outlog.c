/*
 * Flight Deck: FdOutlog - bounded output log with boundary-aware trim
 */
#include "fd_outlog.h"
#include <stdlib.h>
#include <string.h>

void fd_outlog_init(FdOutlog *o, size_t budget) {
    o->data = NULL; o->len = 0; o->cap = 0;
    o->budget = budget ? budget : (4u * 1024 * 1024);
}
void fd_outlog_free(FdOutlog *o) { free(o->data); o->data = NULL; o->len = o->cap = 0; }

static void ensure(FdOutlog *o, size_t need) {
    if (o->cap >= need) return;
    size_t c = o->cap ? o->cap : 4096;
    while (c < need) c *= 2;
    o->data = realloc(o->data, c); o->cap = c;
}

/* find the byte index of the last occurrence of `needle` at or after `from`, or (size_t)-1 */
static size_t last_of(const char *hay, size_t n, size_t from, const char *needle, size_t nl) {
    if (nl == 0 || n < nl) return (size_t)-1;
    size_t best = (size_t)-1;
    for (size_t i = from; i + nl <= n; i++)
        if (memcmp(hay + i, needle, nl) == 0) best = i;
    return best;
}

void fd_outlog_append(FdOutlog *o, const char *buf, size_t len) {
    if (len == 0) return;
    ensure(o, o->len + len);
    memcpy(o->data + o->len, buf, len);
    o->len += len;
    if (o->len > 2 * o->budget) fd_outlog_trim(o); /* amortized: keep the hot path cheap */
}

void fd_outlog_trim(FdOutlog *o) {
    if (o->len <= o->budget) return;
    size_t window = o->len - o->budget;               /* earliest index we may keep from */
    size_t cut = window;                              /* default: hard cut to budget */
    /* prefer starting at a full clear so a fresh emulator lands correctly */
    const char *marks[] = { "\033c", "\x1b[2J", "\x1b[3J" };
    const size_t mlen[] = { 2, 4, 4 };
    for (int m = 0; m < 3; m++) {
        size_t p = last_of(o->data, o->len, window, marks[m], mlen[m]);
        if (p != (size_t)-1 && p > cut) cut = p;      /* the most recent clear in-window */
    }
    memmove(o->data, o->data + cut, o->len - cut);
    o->len -= cut;
}
