//! `grep search_bodies=true worktrees=…`: one body search over many worktrees of a repository,
//! answered by scanning each distinct blob once and fanning its hits out to every worktree that
//! holds it.

mod common;
use common::*;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn service_with(watch: bool) -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = Config::new(dir.path().join("store"));
    cfg.watch.enabled = watch;
    (dir, Service::open(cfg).unwrap())
}

fn call(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> flightindex::proto::Response {
    svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() })
}

fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r = call(svc, cwd, tool, args);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

const SHARED: &str = "export function shared() {\n  return needle + 1;\n}\n";
const GONE: &str = "export function gone() {\n  return needle;\n}\n";
const EDIT_V1: &str = "export function edit() {\n  return 1;\n}\n";
const EDIT_V2: &str = "export function edit() {\n  return needle * 2;\n}\n";
const MAIN_ONLY: &str = "export function mainOnly() {\n  const x = needle;\n  return x;\n}\n";

/// A repository whose main checkout and one linked worktree (`other`) sit on different commits,
/// with `other` dirty: `gone.ts` deleted and `edit.ts` edited, neither committed.
struct Fixture {
    main: Repo,
    _wt_dir: tempfile::TempDir,
    other: PathBuf,
}

fn fixture() -> Fixture {
    let main = init_repo();
    write(&main.root, "web/shared.ts", SHARED);
    write(&main.root, "web/gone.ts", GONE);
    write(&main.root, "web/edit.ts", EDIT_V1);
    commit_all(&main.root, "one");
    let wt_dir = tempfile::tempdir().unwrap();
    let other = wt_dir.path().canonicalize().unwrap().join("other");
    git(&main.root, &["worktree", "add", "-q", "-b", "other", other.to_str().unwrap()]);
    write(&main.root, "web/main_only.ts", MAIN_ONLY);
    commit_all(&main.root, "two");
    std::fs::remove_file(other.join("web/gone.ts")).unwrap();
    write(&other, "web/edit.ts", EDIT_V2);
    Fixture { main, _wt_dir: wt_dir, other }
}

/// `(worktree label, relative path, line, rest of row)` for every row of a multi-worktree answer.
fn multi_rows(text: &str) -> BTreeSet<(String, String, String)> {
    let mut out = BTreeSet::new();
    let mut labels: Vec<String> = Vec::new();
    for line in text.lines() {
        if let Some(inner) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            let (_, names) = inner.split_once(": ").expect("`[N worktrees: a, b]`");
            assert!(!names.contains('+'), "the fixture's label lists are never cut: {line}");
            labels = names.split(", ").map(String::from).collect();
        } else if line.contains(":L") && line.contains(" in ") && !line.starts_with("view:") {
            for l in &labels {
                out.insert((l.clone(), line.to_string(), String::new()));
            }
        }
    }
    out
}

/// The same rows from one single-view `grep search_bodies` per worktree: absolute paths become
/// relative to the worktree and are labelled with its directory name.
fn single_rows(svc: &Arc<Service>, wts: &[&Path]) -> BTreeSet<(String, String, String)> {
    let mut out = BTreeSet::new();
    for wt in wts {
        let label = wt.file_name().unwrap().to_string_lossy().to_string();
        let t = ok(svc, wt, "grep", json!({"query": "needle", "search_bodies": true}));
        let prefix = format!("{}/", wt.display());
        for line in t.lines().filter(|l| l.contains(":L") && l.contains(" in ")) {
            out.insert((label.clone(), line.strip_prefix(&prefix).unwrap_or(line).to_string(), String::new()));
        }
    }
    out
}

#[test]
fn one_search_covers_every_worktree_with_each_shared_blob_reported_once() {
    let (_d, svc) = service_with(true);
    let f = fixture();
    // `other` must be known to the store for `all` to name it.
    ok(&svc, &f.other, "grep", json!({"query": "needle", "search_bodies": true}));
    let t = ok(&svc, &f.main.root, "grep", json!({"query": "needle", "search_bodies": true, "worktrees": "all"}));
    let main = f.main.root.file_name().unwrap().to_string_lossy().to_string();
    assert!(t.lines().nth(1).unwrap().starts_with("worktrees: 2 searched"), "{t}");
    // The blob both worktrees hold is one group, labelled with both.
    let shared_groups: Vec<&str> = t.lines().filter(|l| l.starts_with("web/shared.ts:L2")).collect();
    assert_eq!(shared_groups.len(), 1, "{t}");
    let mut both = [main.clone(), "other".to_string()];
    both.sort();
    assert!(t.contains(&format!("[2 worktrees: {}]\nweb/shared.ts:L2 in shared (function): return needle + 1;", both.join(", "))), "{t}");
    // The uncommitted edit is found in `other` only; the committed file of the newer commit in main only.
    assert!(t.contains("[1 worktree: other]\nweb/edit.ts:L2 in edit (function): return needle * 2;"), "{t}");
    assert!(t.contains(&format!("[1 worktree: {main}]\nweb/main_only.ts:L2 in mainOnly (function)")), "{t}");
    // `gone.ts` is deleted in `other`: only main reports it.
    assert!(t.contains(&format!("[1 worktree: {main}]\nweb/gone.ts:L2 in gone (function)")), "{t}");
    assert_eq!(t.matches("web/gone.ts:L2").count(), 1, "{t}");
}

#[test]
fn the_hits_equal_the_union_of_single_view_searches() {
    let (_d, svc) = service_with(true);
    let f = fixture();
    let single = single_rows(&svc, &[&f.main.root, &f.other]);
    let t = ok(&svc, &f.main.root, "grep", json!({"query": "needle", "search_bodies": true, "worktrees": [f.main.root.to_string_lossy(), f.other.to_string_lossy()]}));
    assert_eq!(multi_rows(&t), single, "{t}");
    assert_eq!(single.len(), 5, "shared x2, gone, edit, main_only: {single:?}");
}

#[test]
fn an_edit_made_after_a_worktree_was_last_seen_is_found_without_the_watcher() {
    let (_d, svc) = service_with(false);
    let f = fixture();
    ok(&svc, &f.other, "grep", json!({"query": "needle", "search_bodies": true}));
    // Edited after `other` was last recorded, and nothing has looked at `other` since.
    std::thread::sleep(std::time::Duration::from_millis(1100));
    write(&f.other, "web/shared.ts", "export function shared() {\n  return needle + 7;\n}\n");
    write(&f.other, "web/fresh.ts", "export function fresh() {\n  return needle;\n}\n");
    let t = ok(&svc, &f.main.root, "grep", json!({"query": "needle", "search_bodies": true, "worktrees": "all"}));
    assert!(t.contains("[1 worktree: other]\nweb/shared.ts:L2 in shared (function): return needle + 7;"), "{t}");
    assert!(t.contains("web/fresh.ts:L2 in fresh (function)"), "a new untracked file: {t}");
    let main = f.main.root.file_name().unwrap().to_string_lossy().to_string();
    assert!(t.contains(&format!("[1 worktree: {main}]\nweb/shared.ts:L2 in shared (function): return needle + 1;")), "{t}");
}

#[test]
fn a_multi_worktree_search_builds_no_graph() {
    let (_d, svc) = service_with(true);
    let f = fixture();
    ok(&svc, &f.main.root, "build", json!({"file_path": f.main.root.to_string_lossy()}));
    ok(&svc, &f.other, "build", json!({"file_path": f.other.to_string_lossy()}));
    let graphs = |svc: &Arc<Service>| call(svc, &f.main.root, "status", json!({})).data.unwrap()["graphs"]["count"].as_u64().unwrap();
    let before = graphs(&svc);
    let t = ok(&svc, &f.main.root, "grep", json!({"query": "needle", "search_bodies": true, "worktrees": "all"}));
    assert!(t.contains("web/edit.ts:L2"), "{t}");
    assert_eq!(graphs(&svc), before, "no graph built or cached by the search");
}

#[test]
fn worktrees_is_refused_without_search_bodies() {
    let (_d, svc) = service_with(true);
    let f = fixture();
    let r = call(&svc, &f.main.root, "grep", json!({"query": "needle", "worktrees": "all"}));
    assert!(!r.ok && r.error.unwrap().contains("search_bodies"));
}

#[test]
fn a_path_that_is_no_worktree_of_the_repository_is_named_as_skipped() {
    let (_d, svc) = service_with(true);
    let f = fixture();
    let stranger = init_repo();
    write(&stranger.root, "x.ts", "export function x() { return needle; }\n");
    commit_all(&stranger.root, "s");
    let t = ok(&svc, &f.main.root, "grep", json!({"query": "needle", "search_bodies": true, "worktrees": [f.main.root.to_string_lossy(), stranger.root.to_string_lossy()]}));
    assert!(t.lines().nth(1).unwrap().contains("1 skipped"), "{t}");
    assert!(t.contains(&format!("skipped: {} (another repository)", stranger.root.display())), "{t}");
    assert!(!t.contains("x.ts"), "{t}");
}
