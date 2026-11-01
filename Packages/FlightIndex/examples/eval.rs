//! Relevance evaluation harness: `cargo run --release --features eval --example eval -- --help`.
//! See `docs/superpowers/specs/2026-11-01-index-eval-harness.md`.
fn main() {
    flightindex::eval::main_with(Vec::new());
}
