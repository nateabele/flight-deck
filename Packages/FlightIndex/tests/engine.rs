mod common;
use common::*;
use flightindex::engine::{Engine, Phase, Progress};
use flightindex::store::Reader;
use std::path::PathBuf;

fn engine() -> (tempfile::TempDir, Engine) {
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    (dir, e)
}

fn seed(r: &Repo) -> String {
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/A.elm", ELM_A);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "src/C.elm", "module C exposing (c)\n\nc : Int\nc =\n    2\n");
    write(&r.root, "web/app.ts", "import { f } from './util';\nexport const g = () => f();\n");
    write(&r.root, "web/util.ts", "export function f() { return 1 }\n");
    write(&r.root, "lib.rs", "pub fn x() {}\n");
    commit_all(&r.root, "init")
}

#[test]
fn build_stores_every_blob_and_counts_progress() {
    let (_d, e) = engine();
    let r = init_repo();
    seed(&r);
    let v = e.view_for_path(&r.root).unwrap();
    let mut events: Vec<Progress> = Vec::new();
    let rep = e.build(&v, &[], |p| events.push(p)).unwrap();
    assert_eq!(rep.total_files, 6);
    assert_eq!(rep.parsed, 6);
    assert_eq!(rep.parsed_by_language["elm"], 3);
    assert_eq!(rep.parsed_by_language["typescript"], 2);
    assert_eq!(rep.parsed_by_language["rust"], 1);
    let last = events.last().unwrap();
    assert_eq!((last.phase, last.done, last.total), (Phase::Done, 6, 6));
    assert!(events.windows(2).all(|w| w[0].done <= w[1].done), "progress never goes backwards");
    let reader = e.reader(&v.label.repo).unwrap();
    assert_eq!(reader.stats().unwrap().facts, 6);
}

#[test]
fn second_worktree_on_an_indexed_commit_parses_zero_blobs() {
    let (d, e) = engine();
    let r = init_repo();
    seed(&r);
    let main = e.view_for_path(&r.root).unwrap();
    e.build(&main, &[], |_| {}).unwrap();
    let before = e.parse_count();
    assert_eq!(before, 6);

    let wt = d.path().canonicalize().unwrap().join("wt");
    git(&r.root, &["worktree", "add", "-q", "-b", "feature", wt.to_str().unwrap()]);
    let v2 = e.view_for_path(&wt.join("src/A.elm")).unwrap();
    assert_ne!(v2.label.worktree, main.label.worktree);
    let rep = e.build(&v2, &[], |_| {}).unwrap();
    assert_eq!(rep.parsed, 0, "same commit, same blobs: nothing to parse");
    assert_eq!(rep.already_stored, 6);
    assert_eq!(e.parse_count(), before, "the engine-wide parse counter did not move either");
    // and it still answers
    let g = e.graph(&v2).unwrap();
    let hits = g.find_symbols(&flightindex::query::NameMatch::Exact("a".into()), None, 10);
    assert_eq!(hits.data.len(), 1);
    assert_eq!(hits.data[0].path, wt.join("src/A.elm"), "answered with the new worktree's absolute path");
    assert_eq!(hits.view.worktree, wt);
}

#[test]
fn a_new_commit_parses_only_blobs_the_store_has_not_seen() {
    let (_d, e) = engine();
    let r = init_repo();
    seed(&r);
    e.build(&e.view_for_path(&r.root).unwrap(), &[], |_| {}).unwrap();
    write(&r.root, "src/B.elm", "module B exposing (b)\n\nb : Int\nb =\n    99\n");
    write(&r.root, "src/D.elm", "module D exposing (d)\n\nd =\n    1\n");
    commit_all(&r.root, "two");
    let v = e.view_for_path(&r.root).unwrap();
    let rep = e.build(&v, &[], |_| {}).unwrap();
    assert_eq!(rep.parsed, 2, "one modified, one added");
    assert_eq!(rep.already_stored, 5);
}

#[test]
fn an_uncommitted_edit_parses_just_that_file() {
    let (_d, e) = engine();
    let r = init_repo();
    seed(&r);
    e.build(&e.view_for_path(&r.root).unwrap(), &[], |_| {}).unwrap();
    write(&r.root, "src/C.elm", "module C exposing (c, c2)\n\nc : Int\nc =\n    2\n\nc2 : Int\nc2 =\n    3\n");
    write(&r.root, "web/new.ts", "export const n = 1;\n");
    let v = e.view_for_path(&r.root).unwrap();
    assert!(v.label.dirty);
    let rep = e.build(&v, &[], |_| {}).unwrap();
    assert_eq!(rep.parsed, 2);
}

#[test]
fn requested_paths_and_their_direct_imports_come_first() {
    let (_d, e) = engine();
    let r = init_repo();
    seed(&r);
    let v = e.view_for_path(&r.root).unwrap();
    let mut at_priority_done: Option<Progress> = None;
    let mut snapshot_facts = 0u64;
    let repo = v.label.repo.clone();
    let root = e.store_root().to_path_buf();
    let rep = e
        .build(&v, &[r.root.join("src/A.elm")], |p| {
            if p.phase == Phase::PriorityDone {
                at_priority_done = Some(p);
                snapshot_facts = Reader::open(&root, &repo).unwrap().stats().unwrap().facts;
            }
        })
        .unwrap();
    let p = at_priority_done.expect("a PriorityDone event");
    // A.elm imports B; C, app.ts, util.ts and lib.rs are not part of the slice.
    assert_eq!(p.done, 2, "A and its direct import B are stored when the slice completes");
    assert_eq!(snapshot_facts, 2);
    assert_eq!(rep.priority_files, 2);
    assert_eq!(rep.parsed, 6, "the rest still finishes");
}

#[test]
fn directory_without_git_builds_too() {
    let (_d, e) = engine();
    let dir = tempfile::tempdir().unwrap();
    let root: PathBuf = dir.path().canonicalize().unwrap();
    write(&root, "elm.json", r#"{"source-directories":["src"]}"#);
    write(&root, "src/A.elm", ELM_A);
    write(&root, "src/B.elm", ELM_B);
    let v = e.view_for_path(&root.join("src")).unwrap();
    let rep = e.build(&v, &[], |_| {}).unwrap();
    assert_eq!(rep.parsed, 2);
    let g = e.graph(&v).unwrap();
    assert_eq!(g.stats().data.files, 2);
}

#[test]
fn non_utf8_files_are_skipped_not_fatal() {
    let (_d, e) = engine();
    let r = init_repo();
    write(&r.root, "ok.ts", "export const a = 1;\n");
    std::fs::write(r.root.join("bin.ts"), [0xff, 0xfe, 0x00, 0x80, 0x81]).unwrap();
    commit_all(&r.root, "init");
    let v = e.view_for_path(&r.root).unwrap();
    let rep = e.build(&v, &[], |_| {}).unwrap();
    assert_eq!((rep.parsed, rep.skipped), (1, 1));
    let again = e.build(&v, &[], |_| {}).unwrap();
    assert_eq!(again.parsed + again.skipped, 0, "a skipped blob is not retried every build");
}

/// Two commits of one repo, both built; returns the views.
fn two_commits(e: &Engine, r: &Repo) -> (flightindex::git::View, flightindex::git::View) {
    seed(r);
    let v1 = e.view_for_path(&r.root).unwrap();
    e.build(&v1, &[], |_| {}).unwrap();
    write(&r.root, "src/B.elm", "module B exposing (b)\n\nb : Int\nb =\n    99\n");
    commit_all(&r.root, "two");
    let v2 = e.view_for_path(&r.root).unwrap();
    e.build(&v2, &[], |_| {}).unwrap();
    (v1, v2)
}

#[test]
fn graphs_over_budget_evict_the_least_recently_used() {
    let (_d, e) = engine();
    let r = init_repo();
    let (v1, v2) = two_commits(&e, &r);
    e.graph(&v1).unwrap();
    assert_eq!(e.graph_cache_stats().graphs, 1);
    e.set_graph_budget(1); // nothing fits: only the graph a request is using survives
    e.graph(&v2).unwrap();
    let st = e.graph_cache_stats();
    assert_eq!((st.graphs, st.evictions), (1, 1), "the first commit's graph was dropped for the second's");
    // The evicted graph is rebuilt on demand, not lost.
    assert_eq!(e.graph(&v1).unwrap().stats().data.files, 6);
}

#[test]
fn graphs_of_neighbouring_commits_share_the_facts_they_have_in_common() {
    let (_d, e) = engine();
    let r = init_repo();
    let (v1, v2) = two_commits(&e, &r);
    let g1 = e.graph(&v1).unwrap();
    let one = e.graph_cache_stats().facts_bytes;
    let g2 = e.graph(&v2).unwrap();
    let both = e.graph_cache_stats().facts_bytes;
    // Five of six blobs are identical between the commits, so the second graph adds one blob's
    // facts, not six.
    assert!(both < one * 2, "facts held once: {one} -> {both}");
    assert!(std::sync::Arc::ptr_eq(&g1.file(g1.file_idx(std::path::Path::new("web/util.ts")).unwrap()).facts, &g2.file(g2.file_idx(std::path::Path::new("web/util.ts")).unwrap()).facts));
}

#[test]
fn a_graph_of_a_half_built_view_is_never_cached() {
    let (_d, e) = engine();
    let r = init_repo();
    seed(&r);
    let v = e.view_for_path(&r.root).unwrap();
    // Nothing stored yet: every file resolves as empty.
    let partial = e.graph_partial(&v).unwrap();
    assert_eq!(partial.stats().data.symbols, 0);
    assert_eq!(e.graph_cache_stats().graphs, 0);
    e.build(&v, &[], |_| {}).unwrap();
    assert!(e.graph(&v).unwrap().stats().data.symbols > 0, "the full graph is not the cached empty one");
}

#[test]
fn a_warm_view_needs_no_build_until_a_file_changes() {
    let (_d, e) = engine();
    let r = init_repo();
    seed(&r);
    let v = e.view_for_path(&r.root).unwrap();
    assert!(!e.is_ready(&v).unwrap());
    e.build(&v, &[], |_| {}).unwrap();
    assert!(e.is_ready(&v).unwrap());
    write(&r.root, "src/C.elm", "module C exposing (c, c2)\n\nc : Int\nc =\n    2\n\nc2 =\n    3\n");
    let dirty = e.view_for_path(&r.root).unwrap();
    assert!(!e.is_ready(&dirty).unwrap(), "an edited file has no facts yet");
    let rep = e.build(&dirty, &[], |_| {}).unwrap();
    assert_eq!((rep.parsed, rep.already_stored), (1, 5));
    assert!(e.is_ready(&dirty).unwrap());
}

#[test]
fn concurrent_builds_of_one_repository_parse_each_blob_once() {
    let (d, e) = engine();
    let r = init_repo();
    for i in 0..150 {
        write(&r.root, &format!("src/m{i}.ts"), &format!("export function f{i}() {{ return {i}; }}\n"));
    }
    commit_all(&r.root, "one");
    write(&r.root, "src/m0.ts", "export function f0() { return 'changed'; }\n");
    commit_all(&r.root, "two");
    let wt = d.path().canonicalize().unwrap().join("old");
    git(&r.root, &["worktree", "add", "-q", "--detach", wt.to_str().unwrap(), "HEAD~1"]);
    let (a, b) = (e.view_for_path(&r.root).unwrap(), e.view_for_path(&wt).unwrap());
    assert_ne!(a.label.base_commit, b.label.base_commit);
    let barrier = std::sync::Barrier::new(2);
    std::thread::scope(|s| {
        for v in [&a, &b] {
            s.spawn(|| {
                barrier.wait();
                e.build(v, &[], |_| {}).unwrap();
            });
        }
    });
    // 150 blobs shared by both commits, plus the one file that differs: 151 distinct.
    assert_eq!(e.parse_count(), 151, "builds ran one after the other, so the second found the first's blobs");
}

#[test]
fn a_graph_a_request_holds_is_not_evicted_to_make_room() {
    let (_d, e) = engine();
    let r = init_repo();
    let (v1, v2) = two_commits(&e, &r);
    let in_use = e.graph(&v1).unwrap();
    e.set_graph_budget(1);
    e.graph(&v2).unwrap();
    // Dropping the held graph from the cache frees nothing and costs the holder's next request a rebuild.
    let st = e.graph_cache_stats();
    assert_eq!((st.graphs, st.evictions), (2, 0), "{st:?}");
    drop(in_use);
}

#[test]
fn the_heap_limit_evicts_idle_graphs_and_spares_the_ones_in_use() {
    let (_d, e) = engine();
    let r = init_repo();
    let (v1, v2) = two_commits(&e, &r);
    e.set_heap_limit(1); // any live heap is over
    let held = e.graph(&v1).unwrap();
    e.graph(&v2).unwrap();
    let st = e.graph_cache_stats();
    assert_eq!((st.graphs, st.evictions, st.heap_limit), (2, 0, 1), "v1 is held, v2 was just touched: {st:?}");
    assert!(e.over_heap_limit() && !e.shed_graphs(), "only what is in use or just touched may remain");
    drop(held);
    assert!(!e.shed_graphs(), "still over: nothing idle is left");
    assert_eq!(e.graph_cache_stats().graphs, 0, "shedding evicts every idle graph, the touched one included");
    e.set_heap_limit(0);
    assert!(!e.over_heap_limit(), "0 is no limit");
}

#[test]
fn the_memory_target_maps_to_a_heap_limit_and_back() {
    use flightindex::engine::{heap_limit_for, target_for_heap, DEFAULT_GRAPH_BUDGET, DEFAULT_MEMORY_TARGET};
    assert_eq!(DEFAULT_MEMORY_TARGET, 1536 << 20);
    assert_eq!(heap_limit_for(DEFAULT_MEMORY_TARGET), (1536 - 192) * (1 << 20) / 6 * 5, "(1536 - 192) / 1.2");
    assert_eq!(DEFAULT_GRAPH_BUDGET, heap_limit_for(DEFAULT_MEMORY_TARGET));
    assert_eq!(heap_limit_for(1 << 20), 0, "a target below the fixed overhead leaves no heap, not an underflow");
    let t = target_for_heap(600 << 20);
    assert!(heap_limit_for(t).abs_diff(600 << 20) < 8, "{t}");
    let c = flightindex::service::Config::new("/x").with_graph_budget(2000 << 20);
    assert_eq!(c.graph_budget, Some(2000 << 20));
    assert!(c.memory_target >= target_for_heap(2000 << 20), "an explicit budget raises the target to fit it");
    let small = flightindex::service::Config::new("/x").with_graph_budget(10 << 20);
    assert_eq!(small.memory_target, DEFAULT_MEMORY_TARGET, "a smaller budget leaves the target alone");
}

#[test]
fn many_requests_for_cold_graphs_all_get_one_under_a_tiny_heap_limit() {
    let (_d, e) = engine();
    let r = init_repo();
    let (v1, v2) = two_commits(&e, &r);
    e.set_heap_limit(1);
    let e = &e;
    std::thread::scope(|s| {
        let jobs: Vec<_> = (0..8).map(|i| s.spawn({ let v = if i % 2 == 0 { v1.clone() } else { v2.clone() }; move || e.graph(&v).unwrap().stats().data.files })).collect();
        for j in jobs {
            assert!(j.join().unwrap() >= 5);
        }
    });
    assert!(e.graph_cache_stats().graphs <= 2);
}
