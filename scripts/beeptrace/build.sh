#!/usr/bin/env bash
# Builds the NSBeep tracer (BeepTrace.m) into DerivedData/beeptrace/libBeepTrace.dylib.
# test-unit-remote.sh and smoke-remote.sh run this for FD_TRACE_BEEPS=1; nothing else uses it.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../.."
mkdir -p DerivedData/beeptrace
xcrun clang -dynamiclib -fobjc-arc -Wno-arc-performSelector-leaks -arch arm64 -mmacosx-version-min=14.0 \
  -framework AppKit -framework AudioToolbox -framework Foundation -install_name @rpath/libBeepTrace.dylib \
  scripts/beeptrace/BeepTrace.m -o DerivedData/beeptrace/libBeepTrace.dylib
codesign -f -s - DerivedData/beeptrace/libBeepTrace.dylib >/dev/null 2>&1
