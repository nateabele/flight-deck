#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cc -Wall -O0 -I../../vendor/fd-abduco -o /tmp/fd_outlog_modes_test \
   test_outlog_modes.c ../../vendor/fd-abduco/fd_outlog.c
/tmp/fd_outlog_modes_test && echo "outlog_modes OK"
