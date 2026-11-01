//! Scores the `near` parameter (graph-distance ordering) of `find`, `grep` and `refs`.
//!
//! Two seeds, each against a baseline that runs the same tool calls without `near`:
//!
//! * `*_prev`: `near` = the files the parent commit itself changed (`git diff parent^ parent`),
//!   the closest stand-in for "what the agent was just working on" that leaks nothing of the
//!   task's own diff. Every task is answered; an empty seed is the baseline's answer.
//! * `*_open`: `near` = the first gold file, as `map_open` does (the simulated open file). Only
//!   tasks with 2 or more gold files; the seed is dropped from the ranking and the gold set.
//!   `*_openbase` is the same task set and exclusion with no `near`.
//!
//! `refs` has no built-in strategy: `refs symbol=<term>` per term, merged round-robin like `find`.
//!
//! `cargo run --release --features eval --example eval_near -- --repo … --only find,find_prev,…`
use flightindex::eval::{interleave, main_with, Probe, Ranking, Strategy, Task, DEPTH};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::process::Command;
use std::sync::{Arc, Mutex};

/// Files the parent commit changed, relative to the repo root (read-only git).
fn prev_diff(root: &std::path::Path, parent: &str, cache: &Mutex<HashMap<String, Vec<String>>>) -> Vec<String> {
    if let Some(v) = cache.lock().unwrap().get(parent) {
        return v.clone();
    }
    let out = Command::new("git").arg("-C").arg(root).args(["diff", "--name-only", "--no-renames", &format!("{parent}^"), parent]).output();
    let files: Vec<String> = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).lines().map(String::from).collect(),
        _ => Vec::new(),
    };
    cache.lock().unwrap().insert(parent.to_string(), files.clone());
    files
}

fn per_term(p: &Probe, t: &Task, tool: &str, key: &str, near: Option<&Vec<String>>) -> Option<Ranking> {
    let terms = t.terms();
    if terms.is_empty() {
        return None;
    }
    Some(interleave(
        terms
            .iter()
            .map(|w| {
                let mut args = json!({ key: w, "limit": DEPTH });
                if let Some(n) = near {
                    let abs: Vec<String> = n.iter().map(|f| p.root.join(f).display().to_string()).collect();
                    args["near"] = Value::from(abs);
                }
                p.ranking_from(&p.tool(tool, args))
            })
            .collect(),
    ))
}

fn main() {
    let cache: Arc<Mutex<HashMap<String, Vec<String>>>> = Arc::new(Mutex::new(HashMap::new()));
    let mut extra: Vec<(String, Strategy)> = Vec::new();
    for (tool, key) in [("find", "name"), ("grep", "query"), ("refs", "symbol")] {
        if tool == "refs" {
            extra.push(("refs".into(), Arc::new(move |p, t| per_term(p, t, tool, key, None))));
        }
        let c = cache.clone();
        extra.push((
            format!("{tool}_prev"),
            Arc::new(move |p, t| {
                let seed = prev_diff(p.root, &t.parent, &c);
                per_term(p, t, tool, key, Some(&seed))
            }),
        ));
        extra.push((
            format!("{tool}_openbase"),
            Arc::new(move |p, t| {
                if t.gold_files.len() < 2 {
                    return None;
                }
                let mut r = per_term(p, t, tool, key, None)?;
                r.exclude = vec![t.gold_files[0].clone()];
                Some(r)
            }),
        ));
        extra.push((
            format!("{tool}_open"),
            Arc::new(move |p, t| {
                if t.gold_files.len() < 2 {
                    return None;
                }
                let seed = vec![t.gold_files[0].clone()];
                let mut r = per_term(p, t, tool, key, Some(&seed))?;
                r.exclude = seed;
                Some(r)
            }),
        ));
    }
    main_with(extra);
}
