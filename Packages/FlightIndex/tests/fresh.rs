//! Freshness and retention through the whole service: the kept views, the ref watcher, the
//! store's roots and the collection. Edits are made by other processes, as an agent's tools make them.
mod common;
use common::*;
use flightindex::proto::{Request, Response, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use flightindex::store;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;
use tempfile::TempDir;

fn service_with(watch: bool) -> (TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = Config::new(dir.path().join("store"));
    cfg.watch.enabled = watch;
    (dir, Service::open(cfg).unwrap())
}

fn service() -> (TempDir, Arc<Service>) {
    service_with(true)
}

fn call(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> Response {
    svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() })
}

fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r = call(svc, cwd, tool, args);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

fn finds(svc: &Arc<Service>, cwd: &Path, name: &str) -> bool {
    !ok(svc, cwd, "find", json!({"name": name})).contains("No symbol found")
}

/// A linked worktree of `repo` at `commit`.
fn add_worktree(repo: &Path, commit: &str) -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap().join("wt");
    git(repo, &["worktree", "add", "-q", "--detach", root.to_str().unwrap(), commit]);
    (dir, root)
}

fn sh(script: &str) {
    assert!(Command::new("sh").arg("-c").arg(script).status().unwrap().success(), "{script}");
}

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, "src/A.elm", ELM_A);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "lib.rs", "pub fn x() { y(); }\nfn y() {}\n");
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    commit_all(&r.root, "init");
    r
}

fn store_bytes(store: &Path) -> u64 {
    store::list_dbs(store).iter().map(|(db, _)| store::db_bytes(db)).sum()
}

#[test]
fn a_worktree_that_needed_no_build_still_has_a_store_row() {
    // GC roots are the worktrees table. A second worktree on an indexed commit parses nothing and
    // builds nothing, so without recording it would have no row, and its tree and overlay blobs
    // would be collected from under it.
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    let (_keep, wt) = add_worktree(&r.root, "HEAD");
    ok(&svc, &wt, "find", json!({"name": "a"}));
    let reader = svc.engine.reader(&r.root.join(".git").canonicalize().unwrap()).unwrap();
    let rows: Vec<PathBuf> = reader.worktrees().unwrap().into_iter().map(|(p, _)| p).collect();
    assert!(rows.contains(&wt), "{rows:?}");
    assert!(rows.contains(&r.root), "{rows:?}");
}

#[test]
fn every_external_write_is_in_the_very_next_answer() {
    // Requirement 9, counted not timed: 100 edits by another process, each followed at once by a
    // query for the symbol it introduced (or, for a removal, for the one it removed).
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    let mut wrong = Vec::new();
    let mut last_marker: std::collections::HashMap<usize, String> = std::collections::HashMap::new();
    for i in 0..100usize {
        let slot = i % 5;
        let file = r.root.join(format!("gen{slot}.rs"));
        let name = format!("marker_{i}");
        let script = match i % 4 {
            0 => format!("printf 'pub fn {name}() {{}}\\n' >> {}", file.display()),
            1 => format!("printf 'pub fn {name}() {{}}\\n' > {f}.tmp && mv {f}.tmp {f}", f = file.display()),
            2 => format!("printf 'pub fn {name}() {{}}\\n' >> {f}; sed -i '' 's/pub fn/pub fn/' {f}", f = file.display()),
            _ => format!("rm -f {}", file.display()),
        };
        sh(&script);
        let seen = if i % 4 == 3 {
            // A removal: whatever the file last defined must be gone (nothing to check if it never existed).
            last_marker.remove(&slot).map(|gone| !finds(&svc, &r.root, &gone)).unwrap_or(true)
        } else {
            last_marker.insert(slot, name.clone());
            finds(&svc, &r.root, &name)
        };
        if !seen {
            wrong.push(i);
        }
    }
    assert!(wrong.is_empty(), "queries that missed the preceding write: {wrong:?}");
}

#[test]
fn an_edit_to_a_worktree_whose_kept_view_was_dropped_is_still_seen() {
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    sh(&format!("printf 'pub fn dirty_one() {{}}\\n' >> {}/lib.rs", r.root.display()));
    assert!(finds(&svc, &r.root, "dirty_one"));
    // Idle long enough to lose its kept view (spec 5.4), then edited while nothing kept it.
    assert_eq!(svc.release_idle_views(Duration::ZERO), 1);
    sh(&format!("printf 'pub fn while_not_kept() {{}}\\n' >> {}/lib.rs; printf 'pub fn brand_new() {{}}\\n' > {}/fresh.rs; rm {}/src/B.elm", r.root.display(), r.root.display(), r.root.display()));
    assert!(finds(&svc, &r.root, "while_not_kept"));
    assert!(finds(&svc, &r.root, "brand_new"));
    assert!(finds(&svc, &r.root, "dirty_one"), "the earlier edit is still there");
    assert!(!ok(&svc, &r.root, "map", json!({})).contains("B.elm"), "the removal was missed");
}

#[test]
fn a_commit_moves_the_base_and_parses_nothing() {
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    sh(&format!("printf 'pub fn committed_soon() {{}}\\n' >> {}/lib.rs", r.root.display()));
    assert!(finds(&svc, &r.root, "committed_soon")); // the edit's blob is parsed here
    let old = git(&r.root, &["rev-parse", "HEAD"]);
    let new = commit_all(&r.root, "second");
    let parsed = svc.engine.parse_count();
    let t = ok(&svc, &r.root, "find", json!({"name": "committed_soon"}));
    let header = t.lines().next().unwrap();
    assert!(header.contains(&format!("base {}", &new[..7])) && !header.contains(&old[..7]), "{header}");
    assert!(header.ends_with("clean)"), "{header}");
    assert_eq!(svc.engine.parse_count(), parsed, "committing what the view already showed must parse nothing");
}

#[test]
fn a_checkout_parses_only_blobs_the_store_has_never_seen() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    for i in 0..12 {
        write(&r.root, &format!("src/M{}.elm", i % 4), &format!("module M{} exposing (v)\n\nv : Int\nv =\n    {i}\n", i % 4));
        commit_all(&r.root, &format!("c{i}"));
    }
    ok(&svc, &r.root, "find", json!({"name": "v"}));
    // Everything older than HEAD differs from it in the files the commits touched.
    let differing = git(&r.root, &["diff", "--name-only", "HEAD~6", "HEAD"]).lines().filter(|l| l.ends_with(".elm")).count();
    let parsed = svc.engine.parse_count();
    git(&r.root, &["checkout", "-q", "HEAD~6"]);
    let t = ok(&svc, &r.root, "find", json!({"name": "v"}));
    assert!(t.lines().next().unwrap().contains(&git(&r.root, &["rev-parse", "--short=7", "HEAD"])), "{t}");
    assert_eq!(svc.engine.parse_count() - parsed, differing, "only the files that differ were parsed");
}

#[test]
fn a_removed_worktree_is_released_and_its_overlay_collected() {
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    let (keep, wt) = add_worktree(&r.root, "HEAD");
    sh(&format!("printf 'pub fn only_in_the_overlay() {{}}\\n' >> {}/lib.rs", wt.display()));
    assert!(finds(&svc, &wt, "only_in_the_overlay"));
    let repo = r.root.join(".git").canonicalize().unwrap();
    let stats = || svc.engine.reader(&repo).unwrap().stats().unwrap();
    let facts_with_overlay = stats().facts;

    git(&r.root, &["worktree", "remove", "--force", wt.to_str().unwrap()]);
    drop(keep);
    svc.maintain();
    let status = call(&svc, &r.root, "status", json!({})).data.unwrap();
    let views: Vec<&str> = status["views"].as_array().unwrap().iter().map(|v| v["worktree"].as_str().unwrap()).collect();
    assert!(!views.contains(&wt.to_str().unwrap()), "{views:?}");

    // The sweep that found the worktree gone also queued a collection and ran it.
    assert!(stats().facts < facts_with_overlay, "the overlay-only blob must be collected");

    assert!(ok(&svc, &r.root, "find", json!({"name": "a"})).contains("src/A.elm"), "what is still referenced survives");
}

#[test]
fn a_repository_whose_common_dir_is_gone_has_its_database_deleted() {
    let (d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    let store_dir = d.path().join("store");
    assert_eq!(store::list_dbs(&store_dir).len(), 1);
    std::fs::remove_dir_all(&r.root).unwrap();
    // The maintenance thread may get there first, so what is asserted is the outcome, not who
    // collected.
    svc.maintain();
    svc.run_gc();
    assert!(store::list_dbs(&store_dir).is_empty());
    assert!(!std::fs::read_dir(&store_dir).unwrap().flatten().any(|e| e.file_name().to_string_lossy().contains(".db")), "no db or wal file is left behind");
}

#[test]
fn churning_worktrees_does_not_grow_the_store() {
    // The anti-goal: a store that grows without bound as worktrees come and go.
    let (d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    let mut commits = Vec::new();
    for i in 0..8 {
        for f in 0..6 {
            write(&r.root, &format!("src/N{f}.elm"), &format!("module N{f} exposing (v)\n\nv : Int\nv =\n    {}\n", i * 10 + f));
        }
        commits.push(commit_all(&r.root, &format!("c{i}")));
    }
    git(&r.root, &["branch", "-f", "keep", &commits[7]]);
    let store_dir = d.path().join("store");
    ok(&svc, &r.root, "find", json!({"name": "v"}));
    let baseline = svc.run_gc();
    let before = store_bytes(&store_dir);
    let mut held = Vec::new();
    for c in &commits[..7] {
        let (keep, wt) = add_worktree(&r.root, c);
        ok(&svc, &wt, "find", json!({"name": "v"}));
        held.push((keep, wt));
    }
    let peak = store_bytes(&store_dir);
    assert!(peak > before, "the churn must have grown the store for the test to mean anything ({before} -> {peak})");
    for (keep, wt) in held {
        git(&r.root, &["worktree", "remove", "--force", wt.to_str().unwrap()]);
        drop(keep);
    }
    svc.maintain();
    let report = svc.run_gc();
    let after = store_bytes(&store_dir);
    eprintln!("baseline gc: {}\nbefore {before} peak {peak} after {after}\n{}", baseline.summary(), report.summary());
    assert!(after <= before + before / 10, "store {after} bytes after churn, {before} before: not back to within 10%");
    assert_eq!(report.free_pages_after, 0, "freed pages were returned to the filesystem");
}

#[test]
fn gc_without_a_path_collects_the_store_and_status_reports_it() {
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    ok(&svc, &r.root, "find", json!({"name": "b"})); // the second request is the first sweep
    let t = ok(&svc, &r.root, "gc", json!({"now": true}));
    assert!(t.starts_with("gc: 1 repo(s)"), "{t}");
    let status = call(&svc, &r.root, "status", json!({})).data.unwrap();
    assert_eq!(status["gc"]["runs"], 1);
    assert!(status["gc"]["last"]["bytes_before"].as_u64().unwrap() > 0);
    assert_eq!(status["watch"]["enabled"], true);
    let v = &status["views"][0];
    assert_eq!(v["kept"], true, "{v}");
    assert!(v["snapshot_files"].as_u64().unwrap() >= 3 && v["last_sweep_ms"].is_number(), "{v}");
    assert_eq!(status["watch"]["ref_repos"].as_array().unwrap().len(), 1);
    let queued = ok(&svc, &r.root, "gc", json!({}));
    assert!(queued.starts_with("gc requested"), "{queued}");
}

#[test]
fn with_freshness_off_every_request_still_reads_git() {
    let (_d, svc) = service_with(false);
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    sh(&format!("printf 'pub fn no_watch_marker() {{}}\\n' >> {}/lib.rs", r.root.display()));
    assert!(finds(&svc, &r.root, "no_watch_marker"));
    let status = call(&svc, &r.root, "status", json!({})).data.unwrap();
    assert_eq!(status["watch"]["enabled"], false);
    assert_eq!(status["views"][0]["kept"], false);
}

#[test]
fn branch_heads_are_known_refs_so_their_trees_survive_collection() {
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    let tip = git(&r.root, &["rev-parse", "HEAD"]);
    let (keep, wt) = add_worktree(&r.root, &tip);
    ok(&svc, &wt, "find", json!({"name": "a"}));
    git(&r.root, &["worktree", "remove", "--force", wt.to_str().unwrap()]);
    drop(keep);
    svc.maintain();
    // The main checkout is on `main`, whose tip is `tip`: even with no worktree on it, a branch
    // head roots its tree.
    svc.run_gc();
    let repo = r.root.join(".git").canonicalize().unwrap();
    assert!(svc.engine.reader(&repo).unwrap().has_tree(&tip).unwrap());
}

/// Poll until `cond` holds, for at most `secs`.
fn eventually(secs: u64, mut cond: impl FnMut() -> bool) -> bool {
    let end = std::time::Instant::now() + Duration::from_secs(secs);
    while std::time::Instant::now() < end {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    cond()
}

#[test]
fn a_moved_branch_reaches_the_store_without_any_request() {
    // The ref watcher's job: known refs follow the repository on their own.
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "a"}));
    let repo = r.root.join(".git").canonicalize().unwrap();
    git(&r.root, &["branch", "feature"]);
    let tip = git(&r.root, &["rev-parse", "HEAD"]);
    let refs = || svc.engine.reader(&repo).unwrap().known_refs().unwrap();
    assert!(eventually(5, || refs().iter().any(|(n, c)| n == "refs/heads/feature" && *c == tip)), "{:?}", refs());
}

#[test]
fn a_checkout_is_prepared_before_anyone_asks() {
    // The ref watcher sees HEAD move, derives the new tree from the old one and parses only the
    // blobs the store has never seen, so the question that follows finds it done.
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    for i in 0..8 {
        write(&r.root, &format!("src/M{}.elm", i % 4), &format!("module M{} exposing (v)\n\nv : Int\nv =\n    {i}\n", i % 4));
        commit_all(&r.root, &format!("c{i}"));
    }
    ok(&svc, &r.root, "find", json!({"name": "v"}));
    ok(&svc, &r.root, "find", json!({"name": "v"})); // kept now
    let differing = git(&r.root, &["diff", "--name-only", "HEAD~4", "HEAD"]).lines().filter(|l| l.ends_with(".elm")).count();
    let before = svc.engine.parse_count();
    git(&r.root, &["checkout", "-q", "HEAD~4"]);
    assert!(eventually(10, || svc.engine.parse_count() - before == differing), "prepared {} of {differing} new blobs", svc.engine.parse_count() - before);
    let t = ok(&svc, &r.root, "find", json!({"name": "v"}));
    assert!(t.lines().next().unwrap().contains(&git(&r.root, &["rev-parse", "--short=7", "HEAD"])), "{t}");
    assert_eq!(svc.engine.parse_count() - before, differing, "the question itself parsed nothing more");
}
