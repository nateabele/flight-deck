#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cc -Wall -O0 -I../../vendor/fd-abduco -o /tmp/fd_outlog_test \
   test_outlog.c ../../vendor/fd-abduco/fd_outlog.c
/tmp/fd_outlog_test && echo "outlog OK"
