//! Scores orderings of `grep`'s prefix rows (`src/tools/grep_order.rs`), side by side, over one
//! graph per task. `grep_stem_tiers` is the shipped order, the same as the built-in `grep`.
//!
//! `grep_<policy>`: `grep query=<term> order_eval=<policy>` per term, merged round-robin like the
//! built-in `grep`. `cargo run --release --features eval --example eval_grep_order -- --repo …`
use flightindex::eval::{interleave, main_with, Strategy, DEPTH};
use serde_json::json;
use std::sync::Arc;

const POLICIES: &[&str] = &["stem_tiers", "pagerank", "alpha", "alpha_zpath", "exact", "unique", "few2", "few3", "few5", "ident", "stem", "stem_prefix", "stem_prefix_exact"];

fn main() {
    let mut extra: Vec<(String, Strategy)> = Vec::new();
    for policy in POLICIES {
        extra.push((
            format!("grep_{policy}"),
            Arc::new(move |p, t| {
                let terms = t.terms();
                (!terms.is_empty()).then(|| interleave(terms.iter().map(|w| p.ranking_from(&p.tool("grep", json!({ "query": w, "limit": DEPTH, "order_eval": policy })))).collect()))
            }),
        ));
    }
    main_with(extra);
}
