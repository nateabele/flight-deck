#!/bin/sh
# nextest setup script: exports RUST_SRC_PATH (the rust-analyzer variable `pkgview::cargo` honours)
# pointing at the stub library, to every test process of the run. cwd is the crate root.
echo "RUST_SRC_PATH=$PWD/tests/fixtures/rust-src-stub" >> "$NEXTEST_ENV"
