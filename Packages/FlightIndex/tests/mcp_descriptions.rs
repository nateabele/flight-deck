//! The MCP tool descriptions an agent reads to pick a tool: what each one does, when to use it
//! instead of its siblings, and nothing fdindex does not do, in as few words as that takes.

use flightindex::mcp::{Options, Shim};
use flightindex::runtime::Paths;
use serde_json::{json, Value};
use std::collections::BTreeMap;

fn shim() -> Shim {
    let paths = Paths::new("/nonexistent/fdi-store", Some("/nonexistent/fdi.sock".into()));
    Shim::new(Options { paths, cwd: "/tmp".into(), auto_start: false, daemon_args: vec![] })
}

fn tools() -> Vec<Value> {
    let r = shim().handle(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})).unwrap();
    r["result"]["tools"].as_array().unwrap().clone()
}

fn instructions() -> String {
    let r = shim().handle(json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})).unwrap();
    r["result"]["instructions"].as_str().unwrap().to_string()
}

fn tool(name: &str) -> Value {
    tools().into_iter().find(|t| t["name"] == name).unwrap_or_else(|| panic!("no tool {name}"))
}

fn desc(name: &str) -> String {
    tool(name)["description"].as_str().unwrap().to_string()
}

fn param(name: &str, p: &str) -> String {
    tool(name)["inputSchema"]["properties"][p]["description"].as_str().unwrap_or_else(|| panic!("{name}.{p} has no description")).to_string()
}

/// Every description string in a tool: its own, each parameter's, and each `$defs` entry's.
fn all_descriptions(t: &Value) -> Vec<(String, String)> {
    let name = t["name"].as_str().unwrap();
    let mut out = vec![(name.to_string(), t["description"].as_str().unwrap_or("").to_string())];
    for (p, v) in t["inputSchema"]["properties"].as_object().into_iter().flatten() {
        out.push((format!("{name}.{p}"), v["description"].as_str().unwrap_or("").to_string()));
    }
    for (d, v) in t["inputSchema"]["$defs"].as_object().into_iter().flatten() {
        if let Some(s) = v["description"].as_str() {
            out.push((format!("{name}.$defs.{d}"), s.to_string()));
        }
    }
    out
}

#[test]
fn tool_and_parameter_names_stay_the_qartez_set() {
    let want: BTreeMap<&str, Vec<&str>> = BTreeMap::from([
        ("qartez_map", vec!["all_files", "boost_files", "boost_terms", "by", "format", "personalize", "token_budget", "top_n", "with_health"]),
        ("qartez_find", vec!["detail", "format", "history", "kind", "limit", "name", "near", "regex"]),
        ("qartez_grep", vec!["detail", "format", "history", "kind", "limit", "near", "query", "rank", "regex", "search_bodies", "token_budget"]),
        ("qartez_read", vec!["context_lines", "end_line", "file_path", "limit", "max_bytes", "start_line", "symbol_name", "symbols", "with"]),
        ("qartez_outline", vec!["file_path", "format", "offset", "token_budget"]),
        ("qartez_deps", vec!["file_path", "format", "token_budget"]),
        ("qartez_stats", vec!["file_path"]),
        ("qartez_impact", vec!["file_path", "format", "include_tests", "near", "pending", "seed_diff", "token_budget"]),
        ("qartez_refs", vec!["format", "include_tests", "near", "symbol", "token_budget", "transitive"]),
        ("qartez_calls", vec!["depth", "direction", "file_path", "format", "include_tests", "kind", "limit", "name", "near", "token_budget"]),
        ("qartez_replace_symbol", vec!["apply", "file_path", "kind", "new_code", "symbol"]),
        ("qartez_insert_before_symbol", vec!["apply", "file_path", "kind", "new_code", "symbol"]),
        ("qartez_insert_after_symbol", vec!["apply", "file_path", "kind", "new_code", "symbol"]),
        ("qartez_rename", vec!["allow_collision", "apply", "file_path", "kind", "new_name", "old_name"]),
        ("qartez_move", vec!["apply", "file_path", "kind", "symbol", "to_file"]),
        ("qartez_safe_delete", vec!["apply", "file_path", "force", "kind", "symbol"]),
        ("qartez_rename_file", vec!["apply", "from", "to"]),
        ("qartez_add_root", vec!["alias", "path", "persist", "watch"]),
        ("qartez_workspace", vec!["action", "alias", "path"]),
    ]);
    let got: BTreeMap<String, Vec<String>> = tools()
        .iter()
        .map(|t| {
            let mut ps: Vec<String> = t["inputSchema"]["properties"].as_object().unwrap().keys().cloned().collect();
            ps.sort();
            (t["name"].as_str().unwrap().to_string(), ps)
        })
        .collect();
    let want: BTreeMap<String, Vec<String>> = want.into_iter().map(|(k, v)| (k.to_string(), v.into_iter().map(String::from).collect())).collect();
    assert_eq!(got, want);
}

#[test]
fn every_tool_and_parameter_is_described_tersely() {
    let mut total = 0;
    for t in tools() {
        for (at, d) in all_descriptions(&t) {
            assert!(!d.trim().is_empty(), "{at} has no description");
            let cap = if at.contains('.') { 140 } else { 360 };
            assert!(d.len() <= cap, "{at} is {} chars (cap {cap}): {d}", d.len());
            total += d.len();
        }
    }
    // The qartez wording was 19,698 characters; the audit holds the set under half that, with
    // room for the parameters added since (near, pending, seed_diff, with).
    assert!(total <= 9_800, "descriptions total {total} chars");
}

#[test]
fn each_read_tool_says_which_sibling_to_use_instead() {
    for (tool, siblings) in [
        ("qartez_find", &["qartez_grep", "qartez_refs"][..]),
        ("qartez_grep", &["qartez_find"][..]),
        ("qartez_refs", &["qartez_calls", "qartez_impact"][..]),
        ("qartez_calls", &["qartez_refs"][..]),
        ("qartez_impact", &["qartez_refs", "qartez_deps"][..]),
        ("qartez_deps", &["qartez_impact"][..]),
        ("qartez_read", &["qartez_outline"][..]),
        ("qartez_outline", &["qartez_read"][..]),
        ("qartez_map", &["qartez_find"][..]),
    ] {
        let d = desc(tool);
        for s in siblings {
            assert!(d.contains(s), "{tool} does not name {s}: {d}");
        }
    }
}

#[test]
fn descriptions_claim_only_what_fdindex_does() {
    for t in tools() {
        for (at, d) in all_descriptions(&t) {
            // fdindex has no FTS5 table or tree-sitter call analysis, and exposes none of these tools.
            for wrong in ["FTS5", "tree-sitter", "qartez_hierarchy", "qartez_unused", "qartez_context", "qartez_health", "reject_mermaid"] {
                assert!(!d.contains(wrong), "{at} mentions {wrong}: {d}");
            }
        }
    }
    // find reads `name`, `symbol` and `symbol_name`; `query` is grep's.
    assert!(!param("qartez_find", "name").contains("query"), "{}", param("qartez_find", "name"));
    // map accepts with_health and ignores it.
    assert!(param("qartez_map", "with_health").to_lowercase().contains("ignored"));
    // grep matches a name prefix, case-insensitively; body search reads function bodies.
    assert!(desc("qartez_grep").contains("prefix"));
    assert!(param("qartez_grep", "search_bodies").contains("bod"));
}

#[test]
fn instructions_route_each_question_to_a_tool() {
    let s = instructions();
    for t in ["map", "find", "grep", "read", "outline", "deps", "stats", "impact", "refs", "calls"] {
        assert!(s.contains(&format!("qartez_{t}")), "instructions do not name qartez_{t}");
    }
    // What the contract promises the instructions say.
    for must in ["Flight Deck", "machine-wide", "absolute", "view:", "index: building", "state: UNAVAILABLE", "rg"] {
        assert!(s.contains(must), "instructions lack {must:?}");
    }
    // A routing line per question, e.g. "Who uses symbol X? qartez_refs".
    assert!(s.contains("Who uses"), "{s}");
    assert!(s.len() <= 1_400, "instructions are {} chars", s.len());
}
