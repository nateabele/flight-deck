/* Tests/fd-abduco/test_outlog.c */
#include <assert.h>
#include <string.h>
#include "fd_outlog.h"

int main(void) {
    /* 1. small append round-trips verbatim */
    FdOutlog o; fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "HELLO", 5);
    fd_outlog_trim(&o);
    assert(o.len == 5 && memcmp(o.data, "HELLO", 5) == 0);
    fd_outlog_free(&o);

    /* 2. over budget with no clear seq -> keep exactly the last `budget` bytes */
    fd_outlog_init(&o, 8);
    fd_outlog_append(&o, "0123456789ABCDEF", 16); /* 16 > 8 */
    fd_outlog_trim(&o);
    assert(o.len == 8 && memcmp(o.data, "89ABCDEF", 8) == 0);
    fd_outlog_free(&o);

    /* 3. clear seq inside the trailing window -> replay starts at the clear seq */
    fd_outlog_init(&o, 10);
    /* content: "aaaa" then ESC[2J then "bbb" ; total 4+4+3=11 > 10 */
    fd_outlog_append(&o, "aaaa\x1b[2Jbbb", 11);
    fd_outlog_trim(&o);
    assert(o.len == 7 && memcmp(o.data, "\x1b[2Jbbb", 7) == 0);
    fd_outlog_free(&o);

    return 0;
}
