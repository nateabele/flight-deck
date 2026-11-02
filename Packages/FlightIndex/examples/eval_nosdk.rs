//! The relevance harness with Swift package views off (`pkgview_swift::set_sdk(None)`): the
//! "before" side of an A/B on one build. Same flags as `examples/eval.rs`.
fn main() {
    flightindex::pkgview_swift::set_sdk(None);
    flightindex::eval::main_with(Vec::new());
}
