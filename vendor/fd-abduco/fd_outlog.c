/*
 * Flight Deck: FdOutlog - bounded output log with boundary-aware trim
 */
#include "fd_outlog.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void flush_pending(FdOutlog *o);

void fd_outlog_init(FdOutlog *o, size_t budget) {
    o->data = NULL; o->len = 0; o->cap = 0;
    o->budget = budget ? budget : (4u * 1024 * 1024);
    o->pend_len = 0;
    o->dropping_dcs = 0; o->dropping_dcs_esc = 0;
    o->modes = NULL; o->modes_len = 0; o->modes_cap = 0;
}
void fd_outlog_free(FdOutlog *o) {
    flush_pending(o);
    free(o->data); o->data = NULL; o->len = o->cap = 0;
    free(o->modes); o->modes = NULL; o->modes_len = o->modes_cap = 0;
}

static void ensure(FdOutlog *o, size_t need) {
    if (o->cap >= need) return;
    size_t c = o->cap ? o->cap : 4096;
    while (c < need) c *= 2;
    o->data = realloc(o->data, c); o->cap = c;
}

/* grow o->modes (same doubling strategy as ensure() above, over the
 * FdOutlogMode table instead of the byte ring). */
static void modes_ensure(FdOutlog *o, size_t need) {
    if (o->modes_cap >= need) return;
    size_t c = o->modes_cap ? o->modes_cap : 8;
    while (c < need) c *= 2;
    o->modes = realloc(o->modes, c * sizeof(*o->modes)); o->modes_cap = c;
}

/* Flight Deck fork: record that DEC private mode `mode` is now set (nonzero
 * `set`) or reset (zero), updating an existing entry in place or appending
 * a new one in first-seen order. */
static void track_mode(FdOutlog *o, int mode, int set) {
    for (size_t i = 0; i < o->modes_len; i++) {
        if (o->modes[i].mode == mode) { o->modes[i].set = set; return; }
    }
    modes_ensure(o, o->modes_len + 1);
    o->modes[o->modes_len].mode = mode;
    o->modes[o->modes_len].set = set;
    o->modes_len++;
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

/* Flight Deck fork: is this completed CSI sequence a DEC private mode
 * set/reset (`CSI ? Pm h` / `CSI ? Pm l`)? `s`/`n` is the full sequence
 * including the leading ESC and the terminating final byte, as for
 * csi_is_query() above. Scope is deliberately narrow: `?` must immediately
 * follow `[` (a private-mode sequence), and the final byte must be `h`/`l`
 * (set/reset) -- this excludes DECRQM (`CSI ? Pm $p`, a *query*, final byte
 * `p`) and non-private ANSI modes (`CSI Pm h/l`, no `?`), neither of which
 * this task tracks. */
static int csi_is_private_mode(const char *s, size_t n) {
    return n >= 4 && s[2] == '?' && (s[n - 1] == 'h' || s[n - 1] == 'l');
}

/* Flight Deck fork: no real DEC private mode number is anywhere near this
 * large (the highest known ones, e.g. kitty's 2027/2031, are 4 digits); a
 * parameter beyond this is either adversarial/corrupted pty content or a
 * scanner mis-sync, not a mode worth restoring on reattach. Bounding
 * accumulation against it below is what keeps the multiply in
 * track_private_modes() from ever overflowing `int`, regardless of how
 * many digits follow. */
#define FD_OUTLOG_MODE_MAX 999999

/* Flight Deck fork: parse the `;`-separated decimal parameters between the
 * `?` and the final byte of a completed CSI ? ... h/l sequence (as matched
 * by csi_is_private_mode() above) and record each as newly set or reset in
 * o->modes. Tolerates the grammar's edge cases without ever getting stuck:
 * an empty parameter (a bare `;`, a leading/trailing `;`, or no parameters
 * at all -- e.g. `CSI ? h`) simply has nothing to record, and any
 * unexpected non-digit byte between separators is skipped one byte at a
 * time rather than aborting the scan.
 *
 * A parameter is only ever multiplied up while it's still <=
 * FD_OUTLOG_MODE_MAX; once it exceeds that, further digits are still
 * consumed (to stay in sync with the rest of the sequence) but no longer
 * folded into `val`, so `val` can never grow past
 * FD_OUTLOG_MODE_MAX * 10 + 9 -- nowhere near overflowing a 32-bit `int` --
 * no matter how many digits (10, 28, ...) the parameter actually has.
 * Such a parameter is real garbage, not a mode number, so it's dropped
 * rather than tracked. */
static void track_private_modes(FdOutlog *o, const char *s, size_t n) {
    int set = (s[n - 1] == 'h');
    size_t i = 3; /* first byte after "ESC [ ?"; s[n - 1] is the final byte */
    while (i < n - 1) {
        int val = 0, have_digit = 0, oversized = 0;
        while (i < n - 1 && s[i] >= '0' && s[i] <= '9') {
            if (val <= FD_OUTLOG_MODE_MAX) val = val * 10 + (s[i] - '0');
            else oversized = 1;
            have_digit = 1;
            i++;
        }
        if (have_digit && !oversized) track_mode(o, val, set);
        if (i < n - 1) i++; /* skip the ';' separator, or any stray byte */
    }
}

/* Scan one byte of pty output through the escape-candidate state machine
 * held in o->pend/o->pend_len, persisted across fd_outlog_append() calls so
 * a query split across two reads is still caught. Bytes classified as safe
 * (or a candidate that turns out not to be a listed query) are emitted via
 * raw_emit(); bytes matching a listed query are dropped silently. */
static void process_byte(FdOutlog *o, unsigned char b) {
    if (o->dropping_dcs) {
        /* committed-to-drop XTGETTCAP payload: consume bytes straight to
         * the ST terminator (ESC \ or BEL) without buffering into `pend`,
         * so an arbitrarily long, multi-capability batched query can never
         * hit FD_OUTLOG_PEND_CAP and fall back to a verbatim flush. */
        if (b == 0x07 || (o->dropping_dcs_esc && b == '\\')) {
            o->dropping_dcs = 0; o->dropping_dcs_esc = 0;
        } else {
            o->dropping_dcs_esc = (b == 0x1b);
        }
        return;
    }

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
            else {
                /* Flight Deck fork: classify (but never drop) a DEC
                 * private mode set/reset -- these bytes still belong in
                 * the ring verbatim, this just also records the mode's
                 * current value for fd_outlog_preamble(). If the sequence
                 * instead hit FD_OUTLOG_PEND_CAP mid-flight it was already
                 * flushed unclassified above (the existing under-strip,
                 * never over-strip tradeoff); that rare case simply isn't
                 * tracked. */
                if (csi_is_private_mode(o->pend, o->pend_len))
                    track_private_modes(o, o->pend, o->pend_len);
                flush_pending(o);
            }
            return;
        }
        /* doesn't fit CSI grammar (stray control byte, a new ESC, ...):
         * the candidate can't complete as a query -- emit it and reprocess
         * this byte as a fresh one. */
        flush_pending(o);
        process_byte(o, b);
        return;
    }

    /* DCS: o->pend[1] == 'P' -- buffer until the string terminator, which
     * is either the two-byte ST (ESC \) or a lone BEL (0x07); real
     * terminals accept both as ST for DCS/OSC-style strings. */
    o->pend[o->pend_len++] = (char)b;
    if (o->pend_len == 4 && dcs_is_query(o->pend, o->pend_len)) {
        /* the "+q" prefix alone identifies an XTGETTCAP request -- commit
         * to dropping right now, before the payload that follows (which
         * can batch many capabilities and run well past
         * FD_OUTLOG_PEND_CAP) is ever buffered into `pend`. */
        o->pend_len = 0;
        o->dropping_dcs = 1; o->dropping_dcs_esc = 0;
        return;
    }
    {
        int st_two_byte = o->pend_len >= 2 &&
            (unsigned char)o->pend[o->pend_len - 2] == 0x1b &&
            (unsigned char)o->pend[o->pend_len - 1] == '\\';
        int st_bel = b == 0x07;
        /* reaching a terminator here means the "+q" check above never
         * fired, so this DCS is not a listed query -- always flush. */
        if (st_two_byte || st_bel) flush_pending(o);
    }
}

void fd_outlog_append(FdOutlog *o, const char *buf, size_t len) {
    size_t i = 0;
    while (i < len) {
        if (o->pend_len == 0 && !o->dropping_dcs) {
            /* common case: bulk-emit the run of normal bytes up to the
             * next ESC in one ensure+memcpy, instead of the state machine's
             * one-byte-at-a-time raw_emit -- keeps the hot path cheap for
             * bursty/large pty output. (Skipped while dropping_dcs is set:
             * those bytes must go through process_byte() one at a time so
             * they are consumed, not bulk-emitted.) */
            size_t start = i;
            while (i < len && (unsigned char)buf[i] != 0x1b) i++;
            if (i > start) raw_emit(o, buf + start, i - start);
            if (i == len) break;
            /* buf[i] is ESC: fall through to the candidate state machine */
        }
        process_byte(o, (unsigned char)buf[i]);
        i++;
    }
    if (o->len > 2 * o->budget) fd_outlog_trim(o); /* amortized: keep the hot path cheap */
}

void fd_outlog_trim(FdOutlog *o) {
    /* an in-progress candidate must not be silently dropped when a
     * reattaching client is about to read `data` -- flush it verbatim
     * before either the budget check below or the replay loop that calls
     * us right before reading (server.c: fd_outlog_trim is called
     * immediately before that loop reads o->data). When this function is
     * instead reached via the amortized len > 2*budget path inside
     * fd_outlog_append, the same flush can fire mid-candidate; that is a
     * rare, tolerated under-strip (a not-yet-classified escape lands in
     * the ring verbatim), never an over-strip. */
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

/* Flight Deck fork: exact number of bytes fd_outlog_preamble() will write
 * for the modes currently tracked in o->modes -- one `\x1b[?<digits><h|l>`
 * sequence per entry, computed precisely (rather than assumed from a fixed
 * per-entry cap) since a mode number's digit count varies. */
size_t fd_outlog_preamble_size(const FdOutlog *o) {
    size_t total = 0;
    for (size_t i = 0; i < o->modes_len; i++)
        total += 3 /* ESC [ ? */ + (size_t)snprintf(NULL, 0, "%d", o->modes[i].mode) + 1 /* h or l */;
    return total;
}

/* Flight Deck fork: write the synthesized preamble -- one CSI set/reset
 * sequence per tracked mode, in first-seen order -- into `buf`, which must
 * be at least fd_outlog_preamble_size(o) bytes (the caller sizes it via
 * that call). Formats each sequence into a small stack buffer first rather
 * than snprintf'ing straight into `buf`, since snprintf always appends a
 * trailing NUL that fd_outlog_preamble_size()'s exact byte count doesn't
 * budget for -- writing that NUL into a buffer sized to the last byte of
 * content would be a one-byte overflow. */
size_t fd_outlog_preamble(const FdOutlog *o, char *buf) {
    size_t off = 0;
    for (size_t i = 0; i < o->modes_len; i++) {
        char tmp[3 + 10 + 1 + 1]; /* "ESC[?" + up to 10 digits (32-bit int) + h/l + NUL */
        int n = snprintf(tmp, sizeof tmp, "\x1b[?%d%c", o->modes[i].mode, o->modes[i].set ? 'h' : 'l');
        memcpy(buf + off, tmp, (size_t)n);
        off += (size_t)n;
    }
    return off;
}
