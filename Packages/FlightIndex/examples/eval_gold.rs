//! Writes each mined task's gold symbols to a JSONL file, for scorers outside the harness.
//!
//! The harness computes gold symbols from the parent commit's graph while it runs (they are not in
//! the task cache), so a scorer that does not run in process, such as the agent-level A/B
//! (`scripts/agent-ab.py`), cannot see them. This adds a strategy, `gold`, that records
//! `{repo, commit, gold_files, gold_symbols: [[file, line, name], …]}` per task to the file named
//! by `FDINDEX_EVAL_GOLD_OUT` and answers no task, so it costs one graph per parent commit.
//!
//! `FDINDEX_EVAL_GOLD_OUT=<out>/gold.jsonl cargo run --release --features eval --example eval_gold -- --repo … --only gold`
use flightindex::eval::{main_with, Strategy};
use serde_json::json;
use std::io::Write;
use std::sync::{Arc, Mutex};

fn main() {
    let path = std::env::var("FDINDEX_EVAL_GOLD_OUT").expect("set FDINDEX_EVAL_GOLD_OUT to the JSONL file to write");
    let file = Mutex::new(std::fs::File::create(&path).expect("create FDINDEX_EVAL_GOLD_OUT"));
    let gold: Strategy = Arc::new(move |_p, t| {
        let row = json!({ "repo": t.repo, "commit": t.commit, "gold_files": t.gold_files, "gold_symbols": t.gold_symbols });
        writeln!(file.lock().unwrap(), "{row}").expect("write gold row");
        None
    });
    main_with(vec![("gold".into(), gold)]);
}
