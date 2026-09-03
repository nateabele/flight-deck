/*
 * Flight Deck: FdOutlog - bounded output log with boundary-aware trim
 */
#ifndef FD_OUTLOG_H
#define FD_OUTLOG_H
#include <stddef.h>
typedef struct { char *data; size_t len, cap, budget; } FdOutlog;
void fd_outlog_init(FdOutlog *o, size_t budget);
void fd_outlog_free(FdOutlog *o);
void fd_outlog_append(FdOutlog *o, const char *buf, size_t len);
void fd_outlog_trim(FdOutlog *o);
#endif
