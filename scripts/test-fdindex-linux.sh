#!/usr/bin/env bash
# scripts/test-fdindex-linux.sh — Packages/FlightIndex's `cargo test` and `cargo clippy` on Linux,
# in rust:1.96.0-slim-trixie under Docker. Arguments go to `cargo test` (a test name, `--test fresh`).
#
# The tests run as an ordinary user, not root: two of them make a directory unreadable and expect
# the refusal, which root never gets. Target directory and registry live in named volumes, so a
# second run is incremental and the macOS build's target/ is left alone. Every daemon the tests
# start uses a temporary store and socket inside the container.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=fdindex-linux-test
docker build -q -t "$IMAGE" - >/dev/null <<'EOF'
FROM rust:1.96.0-slim-trixie
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates build-essential procps && rm -rf /var/lib/apt/lists/*
RUN rustup component add clippy
RUN git config --system user.email t@example.com && git config --system user.name t && git config --system init.defaultBranch main && git config --system --add safe.directory '*'
RUN useradd -m -u 1000 dev && mkdir -p /target /home/dev/.cargo/registry && chown -R dev:dev /target /home/dev/.cargo
USER dev
ENV CARGO_HOME=/home/dev/.cargo PATH=/usr/local/cargo/bin:$PATH CARGO_TARGET_DIR=/target
EOF
docker run --rm -v "$PWD:/src" -v fdindex-linux-target:/target -v fdindex-linux-registry:/home/dev/.cargo/registry \
  -w /src/Packages/FlightIndex "$IMAGE" bash -euo pipefail -c 'cargo test "$@" && cargo clippy --all-targets -- -D warnings' cargo-test "$@"
