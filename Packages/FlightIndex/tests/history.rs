mod common;
use common::*;
use flightindex::history::{HistoryIndex, Options, Scope};
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

const V1: &str = "pub fn alpha() -> u32 {\n    1\n}\n\npub fn beta() -> u32 {\n    2\n}\n\npub struct Store;\n\nimpl Store {\n    pub fn open() -> u32 {\n        3\n    }\n}\n";
const V2: &str = "pub fn alpha() -> u32 {\n    1\n}\n\npub fn beta() -> u32 {\n    let tries = 2;\n    tries\n}\n\npub struct Store;\n\nimpl Store {\n    pub fn open() -> u32 {\n        3\n    }\n}\n";
const V3: &str = "pub fn alpha() -> u32 {\n    let width = 1;\n    width\n}\n\npub fn beta() -> u32 {\n    let tries = 2;\n    tries\n}\n\npub struct Store;\n\nimpl Store {\n    pub fn open() -> u32 {\n        3\n    }\n}\n";
const V4: &str = "pub fn alpha() -> u32 {\n    let width = 1;\n    width\n}\n\npub fn beta() -> u32 {\n    let tries = 2;\n    tries\n}\n\npub struct Store;\n\nimpl Store {\n    pub fn open() -> u32 {\n        let shelf = 3;\n        shelf\n    }\n}\n";

/// lib.rs over four commits: beta, alpha and Store.open each changed by one commit whose subject
/// says why in words none of their names contain.
fn repo() -> (Repo, Vec<String>) {
    let r = init_repo();
    write(&r.root, "lib.rs", V1);
    write(&r.root, "other.rs", "pub fn gamma() {}\n");
    let c1 = commit_all(&r.root, "initial import");
    write(&r.root, "lib.rs", V2);
    let c2 = commit_all(&r.root, "retry the flaky upload when the network times out");
    write(&r.root, "lib.rs", V3);
    let c3 = commit_all(&r.root, "teach the parser about unicode grapheme widths");
    write(&r.root, "lib.rs", V4);
    let c4 = commit_all(&r.root, "persist settings in the keychain");
    (r, vec![c1, c2, c3, c4])
}

#[test]
fn a_prose_query_finds_the_symbol_whose_commit_said_it() {
    let (r, _) = repo();
    let idx = HistoryIndex::compute(&r.root, "HEAD", &Options::default(), &|_, _| None).unwrap();
    assert_eq!(idx.stats.commits_indexed, 4);
    let hits = idx.search("upload retry after network timeout", Scope::All, 10);
    assert_eq!((hits[0].path.as_str(), hits[0].symbol.as_str()), ("lib.rs", "beta"), "{hits:?}");
    assert!(idx.commits[hits[0].commit as usize].subject.starts_with("retry the flaky upload"));
    let hits = idx.search("keychain settings", Scope::All, 10);
    assert_eq!(hits[0].symbol, "Store.open", "a method is credited, not its impl: {hits:?}");
}

#[test]
fn a_scope_keeps_commits_out_of_the_answer() {
    let (r, ids) = repo();
    let idx = HistoryIndex::compute(&r.root, "HEAD", &Options::default(), &|_, _| None).unwrap();
    let pos = idx.commit_positions();
    let without: HashSet<u32> = pos.iter().filter(|(c, _)| **c != ids[1]).map(|(_, i)| *i).collect();
    let hits = idx.search("flaky upload", Scope::Only(&without), 10);
    assert!(hits.iter().all(|h| h.symbol != "beta"), "{hits:?}");
}

#[test]
fn changed_line_words_count_by_default_and_can_be_left_out() {
    let (r, _) = repo();
    let hunks = HistoryIndex::compute(&r.root, "HEAD", &Options::default(), &|_, _| None).unwrap();
    assert_eq!(hunks.search("shelf", Scope::All, 10)[0].symbol, "Store.open");
    let plain = HistoryIndex::compute(&r.root, "HEAD", &Options { hunks: false, ..Options::default() }, &|_, _| None).unwrap();
    assert!(plain.search("shelf", Scope::All, 10).is_empty());
}

#[test]
fn a_sweep_commit_is_skipped() {
    let (r, _) = repo();
    for i in 0..45 {
        write(&r.root, &format!("gen/m{i}.rs"), &format!("pub fn m{i}() {{}}\n"));
    }
    commit_all(&r.root, "vendor the generated modules");
    let idx = HistoryIndex::compute(&r.root, "HEAD", &Options::default(), &|_, _| None).unwrap();
    assert_eq!(idx.stats.mass_skipped, 1);
    assert!(idx.search("vendor generated", Scope::All, 10).is_empty());
}

// ---- the tier in find and grep ----------------------------------------------------------------

fn call(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() };
    let r = svc.handle(req);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

/// The history index builds in the background; ask until it has answered.
fn settled(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    for _ in 0..200 {
        let t = call(svc, cwd, tool, args.clone());
        if !t.contains("history: indexing") {
            return t;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    panic!("the history tier never became ready");
}

#[test]
fn find_and_grep_answer_prose_from_history() {
    let (r, _) = repo();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let lib = r.root.join("lib.rs").display().to_string();

    let t = settled(&svc, &r.root, "find", json!({"name": "flaky upload retry"}));
    assert!(t.contains("No symbol found with name 'flaky upload retry'"), "{t}");
    let section = t.split_once("History matches").map(|(_, s)| s).unwrap_or_else(|| panic!("no history section: {t}"));
    let first = section.lines().nth(1).unwrap();
    assert!(first.starts_with("beta") && first.contains(&format!("{lib} [L6-L9]")) && first.contains("retry the flaky upload"), "{t}");

    let t = settled(&svc, &r.root, "grep", json!({"query": "unicode widths"}));
    let section = t.split_once("History matches").map(|(_, s)| s).unwrap_or_else(|| panic!("no history section: {t}"));
    assert!(section.lines().nth(1).unwrap().starts_with("alpha"), "{t}");

    // An identifier that matches needs no history; `history=false` turns the tier off.
    let t = settled(&svc, &r.root, "find", json!({"name": "beta"}));
    assert!(!t.contains("History matches"), "{t}");
    let t = call(&svc, &r.root, "find", json!({"name": "flaky upload retry", "history": false}));
    assert!(!t.contains("History matches") && !t.contains("history:"), "{t}");
    // `history=true` adds it to an answer that already has hits (gamma's lines were added by the
    // initial import, so changed-line words find it), and says when nothing matched.
    let t = settled(&svc, &r.root, "grep", json!({"query": "gamma", "history": true}));
    assert!(t.contains("Found 1 result(s)") && t.contains("History matches for 'gamma'"), "{t}");
    let t = settled(&svc, &r.root, "grep", json!({"query": "zebra"}));
    assert!(t.contains("No history matches for 'zebra' in the last 4 commits"), "{t}");
}

/// p4's ranked-by-words `grep` and q19's history tier are separate tiers of one answer: the ranked
/// rows first, then the commit-message matches, neither replacing the other.
#[test]
fn a_ranked_grep_keeps_its_rows_and_adds_the_history_tier_after_them() {
    let (r, _) = repo();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let t = settled(&svc, &r.root, "grep", json!({"query": "beta retry"}));
    let (ranked, history) = t.split_once("History matches").unwrap_or_else(|| panic!("no history tier: {t}"));
    assert!(ranked.contains("Ranked by words: beta retry") && ranked.contains("beta"), "{t}");
    assert!(history.lines().nth(1).unwrap().starts_with("beta"), "{t}");
    // `history=false` leaves the ranked rows alone.
    let t = call(&svc, &r.root, "grep", json!({"query": "beta retry", "history": false}));
    assert!(t.contains("Ranked by words: beta retry") && !t.contains("History matches"), "{t}");
    // A zero-hit find keeps both its closest-by-words rows and the history tier.
    let t = settled(&svc, &r.root, "find", json!({"name": "betaRetry"}));
    assert!(t.contains("Closest by words (beta retry)") && t.contains("History matches for 'betaRetry'"), "{t}");
}

#[test]
fn a_file_changed_outside_its_symbols_gets_a_row_where_it_ranks() {
    let (r, _) = repo();
    write(&r.root, "lib.rs", &format!("use std::fmt;\n{V4}"));
    commit_all(&r.root, "switch the upload logger to tracing");
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let t = settled(&svc, &r.root, "find", json!({"name": "upload logger tracing"}));
    let rows: Vec<&str> = t.split_once("History matches").unwrap_or_else(|| panic!("{t}")).1.lines().skip(1).collect();
    // The file's document holds both subjects; beta's holds only the upload one.
    assert!(rows[0].starts_with("(file)") && rows[0].contains("lib.rs  — switch the upload logger"), "{t}");
    assert!(rows[1].starts_with("beta"), "{t}");
}

#[test]
fn moving_head_forward_extends_the_index_to_what_a_full_build_gives() {
    let (r, ids) = repo();
    let full = HistoryIndex::compute(&r.root, &ids[3], &Options::default(), &|_, _| None).unwrap();
    let old = HistoryIndex::compute(&r.root, &ids[2], &Options::default(), &|_, _| None).unwrap();
    let grown = HistoryIndex::update(&old, &ids[2], &r.root, &ids[3], &Options::default(), &|_, _| None).unwrap();
    assert!(grown.stats.incremental && grown.stats.commits_scanned == 1, "{:?}", grown.stats);
    assert_eq!(grown.commits.len(), 4);
    for q in ["keychain settings", "flaky upload", "unicode widths", "shelf tries width"] {
        let a: Vec<_> = full.search(q, Scope::All, 10).into_iter().map(|h| (h.path, h.symbol, (h.score * 1e9) as i64, full.commits[h.commit as usize].id.clone())).collect();
        let b: Vec<_> = grown.search(q, Scope::All, 10).into_iter().map(|h| (h.path, h.symbol, (h.score * 1e9) as i64, grown.commits[h.commit as usize].id.clone())).collect();
        assert_eq!(a, b, "{q}");
    }
    // Not a fast-forward (HEAD moved back): a full build.
    let back = HistoryIndex::update(&full, &ids[3], &r.root, &ids[1], &Options::default(), &|_, _| None).unwrap();
    assert!(!back.stats.incremental && back.commits.len() == 2, "{:?}", back.stats);
}

#[test]
fn status_reports_each_history_index_and_its_bytes() {
    let (r, ids) = repo();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    settled(&svc, &r.root, "find", json!({"name": "flaky upload retry"}));
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: r.root.to_string_lossy().to_string(), seq: 0, tool: "status".into(), args: Default::default() };
    let data = svc.handle(req).data.unwrap();
    let h = &data["history"][0];
    assert_eq!(h["commit"], json!(ids[3]), "{data}");
    assert_eq!(h["commits"], json!(4));
    assert!(h["bytes"].as_u64().unwrap() > 0 && h["building"] == json!(false), "{h}");
}
