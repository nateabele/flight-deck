//! `impact`'s ranked list (importers and co-change interleaved), its tests group, and seeding
//! co-change with the worktree diff.

mod common;
use common::*;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn impact(svc: &Arc<Service>, root: &Path, args: Value) -> String {
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: root.to_string_lossy().to_string(), seq: 0, tool: "impact".into(), args: args.as_object().cloned().unwrap() };
    let r = svc.handle(req);
    assert!(r.ok, "impact failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

/// The rows of the section whose heading starts with `heading`, as (relative path, reason).
fn section(text: &str, root: &Path, heading: &str) -> Vec<(String, String)> {
    let prefix = format!("{}/", root.display());
    let mut inside = false;
    let mut out = Vec::new();
    for line in text.lines() {
        if !line.starts_with(' ') {
            inside = line.starts_with(heading);
            continue;
        }
        if inside && let Some(rest) = line.trim_start().strip_prefix(&prefix) {
            let (path, why) = rest.split_once("  ").unwrap_or((rest, ""));
            out.push((path.to_string(), why.trim().trim_start_matches('(').trim_end_matches(')').to_string()));
        }
    }
    out
}

/// `hub.ts`, imported by four files, and two files that only ever change with it.
fn hub_repo() -> Repo {
    let r = init_repo();
    write(&r.root, "src/hub.ts", "export function hub() { return 0; }\n");
    for i in 1..=4 {
        write(&r.root, &format!("src/imp{i}.ts"), &format!("import {{ hub }} from './hub';\nexport function f{i}() {{ return hub(); }}\n"));
    }
    write(&r.root, "src/co1.ts", "export const co1 = 0;\n");
    write(&r.root, "src/co2.ts", "export const co2 = 0;\n");
    commit_all(&r.root, "init");
    for n in 1..=3 {
        write(&r.root, "src/hub.ts", &format!("export function hub() {{ return {n}; }}\n"));
        write(&r.root, "src/co1.ts", &format!("export const co1 = {n};\n"));
        if n > 1 {
            write(&r.root, "src/co2.ts", &format!("export const co2 = {n};\n"));
        }
        commit_all(&r.root, &format!("hub and partners {n}"));
    }
    r
}

#[test]
fn impact_ranks_importers_and_co_change_partners_alternately_with_their_reasons() {
    let (_d, svc) = service();
    let r = hub_repo();
    let t = impact(&svc, &r.root, json!({"file_path": "src/hub.ts"}));
    let rows = section(&t, &r.root, "Ranked impact");
    let order: Vec<&str> = rows.iter().map(|(p, _)| p.as_str()).collect();
    // hub.ts changed in 4 commits: co1 in 4 of them (the init and 3), co2 in 3.
    assert_eq!(order, ["src/imp1.ts", "src/co1.ts", "src/imp2.ts", "src/co2.ts", "src/imp3.ts", "src/imp4.ts"], "{t}");
    assert_eq!(rows[0].1, "importer depth 1", "{t}");
    assert_eq!(rows[1].1, "co-changed 4/4", "{t}");
    assert_eq!(rows[3].1, "co-changed 3/4", "{t}");
}

#[test]
fn impact_lists_every_linked_test_in_an_uncapped_group_whatever_include_tests_says() {
    let (_d, svc) = service();
    let r = hub_repo();
    // A name match that does not import hub, 35 tests that import it (more than any list's cap),
    // and a test that only co-changes with it.
    write(&r.root, "tests/hub.test.ts", "export const t = 1;\n");
    for i in 0..35 {
        write(&r.root, &format!("tests/uses{i:02}.test.ts"), "import { hub } from '../src/hub';\nhub();\n");
    }
    write(&r.root, "tests/cotest.test.ts", "export const c = 0;\n");
    write(&r.root, "tests/unrelated.test.ts", "export const u = 0;\n");
    commit_all(&r.root, "tests");
    for n in 0..2 {
        write(&r.root, "src/hub.ts", &format!("export function hub() {{ return {}; }}\n", 10 + n));
        write(&r.root, "tests/cotest.test.ts", &format!("export const c = {};\n", 10 + n));
        commit_all(&r.root, &format!("hub with its co-changing test {n}"));
    }
    let t = impact(&svc, &r.root, json!({"file_path": "src/hub.ts"}));
    let tests = section(&t, &r.root, "Tests (");
    let paths: Vec<&str> = tests.iter().map(|(p, _)| p.as_str()).collect();
    assert_eq!(paths.len(), 37, "name match + 35 importers + co-change, no cap, no unrelated test: {t}");
    assert_eq!(tests[0], ("tests/hub.test.ts".to_string(), "name match".to_string()), "{t}");
    assert_eq!(tests[1].1, "importer depth 1", "{t}");
    assert_eq!(tests[36], ("tests/cotest.test.ts".to_string(), "co-changed 2/6".to_string()), "{t}");
    assert!(t.contains("Tests (37):"), "{t}");
    // The ranked list keeps tests out by default, as the other lists do.
    assert!(section(&t, &r.root, "Ranked impact").iter().all(|(p, _)| !p.starts_with("tests/")), "{t}");
}

#[test]
fn co_change_is_seeded_by_the_worktree_diff_as_well_as_the_file_asked_about() {
    let (_d, svc) = service();
    let r = hub_repo();
    write(&r.root, "src/edited.ts", "export const e = 0;\n");
    write(&r.root, "src/buddy.ts", "export const b = 0;\n");
    commit_all(&r.root, "edited and buddy");
    write(&r.root, "src/edited.ts", "export const e = 1;\n");
    write(&r.root, "src/buddy.ts", "export const b = 1;\n");
    commit_all(&r.root, "edited and buddy again");
    write(&r.root, "tests/hub.test.ts", "export const t = 0;\n");
    commit_all(&r.root, "hub's test");
    // An uncommitted edit: `buddy.ts` always changed with it, never with `hub.ts`.
    write(&r.root, "src/edited.ts", "export const e = 2;\n");
    // A test the worktree already edits is still one to run: it stays in the tests group.
    write(&r.root, "tests/hub.test.ts", "export const t = 1;\n");
    let t = impact(&svc, &r.root, json!({"file_path": "src/hub.ts"}));
    assert!(t.contains("Seeds: src/hub.ts, and the worktree diff: src/edited.ts, tests/hub.test.ts"), "{t}");
    let rows = section(&t, &r.root, "Ranked impact");
    assert!(rows.contains(&("src/buddy.ts".to_string(), "co-changed 2/2 with src/edited.ts".to_string())), "{t}");
    assert!(rows.iter().all(|(p, _)| p != "src/edited.ts"), "a seed is not its own impact: {t}");
    assert!(section(&t, &r.root, "Tests (").contains(&("tests/hub.test.ts".to_string(), "name match".to_string())), "{t}");
    let t = impact(&svc, &r.root, json!({"file_path": "src/hub.ts", "seed_diff": false}));
    assert!(section(&t, &r.root, "Ranked impact").iter().all(|(p, _)| p != "src/buddy.ts"), "{t}");
    assert!(!t.contains("Seeds:"), "{t}");
}
