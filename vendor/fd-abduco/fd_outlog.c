/*
 * Flight Deck: FdOutlog - bounded output log with boundary-aware trim
 */
#include "fd_outlog.h"
#include <stdlib.h>
#include <string.h>

static void flush_pending(FdOutlog *o);

void fd_outlog_init(FdOutlog *o, size_t budget) {
    o->data = NULL; o->len = 0; o->cap = 0;
    o->budget = budget ? budget : (4u * 1024 * 1024);
    o->pend_len = 0;
}
void fd_outlog_free(FdOutlog *o) {
    flush_pending(o);
    free(o->data); o->data = NULL; o->len = o->cap = 0;
}

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

/* Flight Deck fork: append bytes directly into the ring, bypassing the
 * query scanner -- used both for bytes the scanner has classified as safe
 * and for flushing an unresolved candidate verbatim. */
static void raw_emit(FdOutlog *o, const char *buf, size_t len) {
    if (len == 0) return;
    ensure(o, o->len + len);
    memcpy(o->data + o->len, buf, len);
    o->len += len;
}

static void flush_pending(FdOutlog *o) {
    if (o->pend_len == 0) return;
    raw_emit(o, o->pend, o->pend_len);
    o->pend_len = 0;
}

/* exact-match table of CSI query sequences to drop (text includes the
 * leading ESC and the terminating final byte) */
static int csi_is_query(const char *s, size_t n) {
    static const struct { const char *seq; size_t len; } table[] = {
        { "\x1b[c",   3 }, /* DA1 */
        { "\x1b[0c",  4 }, /* DA1 */
        { "\x1b[>c",  4 }, /* DA2 */
        { "\x1b[>0c", 5 }, /* DA2 */
        { "\x1b[=c",  4 }, /* DA3 */
        { "\x1b[5n",  4 }, /* DSR */
        { "\x1b[6n",  4 }, /* DSR */
        { "\x1b[>q",  4 }, /* XTVERSION */
        { "\x1b[>0q", 5 }, /* XTVERSION */
        { "\x1b[?u",  4 }, /* kitty keyboard-protocol query */
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++)
        if (n == table[i].len && memcmp(s, table[i].seq, n) == 0) return 1;
    return 0;
}

/* XTGETTCAP request: DCS + q <hex-encoded name...> ST -- "+q" immediately
 * after "ESC P" identifies a termcap/terminfo capability request. */
static int dcs_is_query(const char *s, size_t n) {
    return n >= 4 && s[2] == '+' && s[3] == 'q';
}

/* Scan one byte of pty output through the escape-candidate state machine
 * held in o->pend/o->pend_len, persisted across fd_outlog_append() calls so
 * a query split across two reads is still caught. Bytes classified as safe
 * (or a candidate that turns out not to be a listed query) are emitted via
 * raw_emit(); bytes matching a listed query are dropped silently. */
static void process_byte(FdOutlog *o, unsigned char b) {
    if (o->pend_len == 0) {
        if (b == 0x1b) { o->pend[0] = (char)b; o->pend_len = 1; return; }
        char c = (char)b;
        raw_emit(o, &c, 1);
        return;
    }

    if (o->pend_len == 1) {
        /* second byte decides the sequence family: only CSI ('[') and
         * DCS ('P') are scanned further -- anything else (e.g. ESC 'c'
         * full-reset) can't be one of our listed queries, so emit verbatim
         * immediately rather than tracking it. */
        o->pend[1] = (char)b; o->pend_len = 2;
        if (b != '[' && b != 'P') flush_pending(o);
        return;
    }

    if (o->pend_len >= FD_OUTLOG_PEND_CAP) {
        /* candidate has grown past the cap without completing: under-strip,
         * never over-strip -- emit verbatim and reprocess this byte fresh. */
        flush_pending(o);
        process_byte(o, b);
        return;
    }

    if (o->pend[1] == '[') {
        /* CSI: buffer parameter (0x30-0x3f) / intermediate (0x20-0x2f)
         * bytes until a final byte (0x40-0x7e) completes the sequence. */
        if ((b >= 0x30 && b <= 0x3f) || (b >= 0x20 && b <= 0x2f)) {
            o->pend[o->pend_len++] = (char)b;
            return;
        }
        if (b >= 0x40 && b <= 0x7e) {
            o->pend[o->pend_len++] = (char)b;
            if (csi_is_query(o->pend, o->pend_len)) o->pend_len = 0; /* drop */
            else flush_pending(o);
            return;
        }
        /* doesn't fit CSI grammar (stray control byte, a new ESC, ...):
         * the candidate can't complete as a query -- emit it and reprocess
         * this byte as a fresh one. */
        flush_pending(o);
        process_byte(o, b);
        return;
    }

    /* DCS: o->pend[1] == 'P' -- buffer until the two-byte ST (ESC \) */
    o->pend[o->pend_len++] = (char)b;
    if (o->pend_len >= 2 &&
        (unsigned char)o->pend[o->pend_len - 2] == 0x1b &&
        (unsigned char)o->pend[o->pend_len - 1] == '\\') {
        if (dcs_is_query(o->pend, o->pend_len)) o->pend_len = 0; /* drop */
        else flush_pending(o);
    }
}

void fd_outlog_append(FdOutlog *o, const char *buf, size_t len) {
    for (size_t i = 0; i < len; i++) process_byte(o, (unsigned char)buf[i]);
    if (o->len > 2 * o->budget) fd_outlog_trim(o); /* amortized: keep the hot path cheap */
}

void fd_outlog_trim(FdOutlog *o) {
    /* an in-progress candidate must not be silently dropped when a
     * reattaching client is about to read `data` -- flush it verbatim
     * before either the budget check below or the replay loop that calls
     * us right before reading (server.c). */
    flush_pending(o);
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
