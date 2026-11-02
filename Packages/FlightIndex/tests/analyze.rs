//! `qartez_analyze`: the analysis tier behind one tool. `report` picks the analysis (unused,
//! cochange, context, hierarchy, diff_impact, hotspots); `report=help` documents each report's
//! parameters on demand, so the tool list an agent pays for every session stays one small schema.

mod common;
use common::*;
use flightindex::mcp::{Options, Shim};
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::runtime::Paths;
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn call(svc: &Arc<Service>, root: &Path, args: Value) -> flightindex::proto::Response {
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: root.to_string_lossy().to_string(), seq: 0, tool: "qartez_analyze".into(), args: args.as_object().cloned().unwrap() };
    svc.handle(req)
}

fn analyze(svc: &Arc<Service>, root: &Path, args: Value) -> String {
    let r = call(svc, root, args.clone());
    assert!(r.ok, "analyze {args} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

/// The rows of the section whose heading starts with `heading`, as (relative path, rest of line).
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
            out.push((path.to_string(), why.trim().to_string()));
        }
    }
    out
}

/// A small TypeScript repo: `hub.ts` (imported by two files and a test, with one export nobody
/// uses), a class hierarchy, and a history in which `co1.ts` and `co2.ts` change with `hub.ts`.
fn repo() -> Repo {
    let r = init_repo();
    write(
        &r.root,
        "src/hub.ts",
        "export function hub() { return 0; }\n\nexport function orphan() { return 1; }\n\nexport function selfish(n: number): number { return n > 0 ? selfish(n - 1) : 0; }\n\nfunction hidden() { return 2; }\nexport const used = hidden();\n",
    );
    write(&r.root, "src/imp1.ts", "import { hub, used } from './hub';\nexport function f1() { return hub() + used; }\n");
    write(&r.root, "src/imp2.ts", "import { f1 } from './imp1';\nexport function f2() { return f1(); }\nf2();\n");
    write(&r.root, "src/shapes.ts", "export interface Shape { area(): number }\nexport class Base implements Shape { area() { return 0; } }\nexport class Circle extends Base {}\nexport class Square extends Base {}\nexport class Unit extends Square {}\nnew Circle(); new Unit();\n");
    write(&r.root, "tests/hub.test.ts", "import { hub } from '../src/hub';\nexport function testOnlyHelper() { return hub(); }\n");
    write(&r.root, "src/co1.ts", "export const co1 = 0;\n");
    write(&r.root, "src/co2.ts", "export const co2 = 0;\n");
    commit_all(&r.root, "init");
    for n in 1..=3 {
        write(&r.root, "src/hub.ts", &format!("export function hub() {{ return {n}; }}\n\nexport function orphan() {{ return 1; }}\n\nexport function selfish(n: number): number {{ return n > 0 ? selfish(n - 1) : 0; }}\n\nfunction hidden() {{ return 2; }}\nexport const used = hidden();\n"));
        write(&r.root, "src/co1.ts", &format!("export const co1 = {n};\n"));
        if n > 1 {
            write(&r.root, "src/co2.ts", &format!("export const co2 = {n};\n"));
        }
        commit_all(&r.root, &format!("hub and partners {n}"));
    }
    r
}

#[test]
fn unused_lists_exports_nothing_else_references() {
    let (_d, svc) = service();
    let r = repo();
    let t = analyze(&svc, &r.root, json!({"report": "unused"}));
    let names: Vec<String> = t.lines().filter_map(|l| l.trim_start().strip_prefix("- ")).map(|l| l.split_whitespace().next().unwrap_or("").to_string()).collect();
    assert!(names.contains(&"orphan".to_string()), "{t}");
    assert!(names.contains(&"selfish".to_string()), "a function that only calls itself is unused: {t}");
    for live in ["hub", "used", "f1", "f2", "Shape", "Base", "Circle", "Square", "Unit"] {
        assert!(!names.contains(&live.to_string()), "{live} is referenced: {t}");
    }
    assert!(!names.contains(&"hidden".to_string()), "private symbols are not exports: {t}");
    assert!(!names.contains(&"testOnlyHelper".to_string()), "test files are left out by default: {t}");
    let t = analyze(&svc, &r.root, json!({"report": "unused", "include_tests": true}));
    assert!(t.contains("testOnlyHelper"), "{t}");
    // file_path narrows to one file or directory.
    let t = analyze(&svc, &r.root, json!({"report": "unused", "file_path": "src/shapes.ts"}));
    assert!(!t.contains("orphan"), "{t}");
}

#[test]
fn cochange_ranks_partners_of_a_file_or_a_set_by_confidence() {
    let (_d, svc) = service();
    let r = repo();
    let t = analyze(&svc, &r.root, json!({"report": "cochange", "file_path": "src/hub.ts"}));
    let rows = section(&t, &r.root, "Co-change partners");
    let order: Vec<&str> = rows.iter().map(|(p, _)| p.as_str()).collect();
    assert_eq!(order, ["src/co1.ts", "src/co2.ts"], "{t}");
    assert!(rows[0].1.contains("4/4"), "{t}");
    assert!(rows[1].1.contains("3/4"), "{t}");
    // A set: the seeds are not their own partners.
    let t = analyze(&svc, &r.root, json!({"report": "cochange", "files": ["src/hub.ts", "src/co1.ts"]}));
    let order: Vec<String> = section(&t, &r.root, "Co-change partners").into_iter().map(|(p, _)| p).collect();
    assert_eq!(order, ["src/co2.ts"], "{t}");
    let e = call(&svc, &r.root, json!({"report": "cochange"}));
    assert_eq!(e.state.as_deref(), Some("BAD_REQUEST"), "{e:?}");
}

#[test]
fn hierarchy_walks_supertypes_and_subtypes_transitively() {
    let (_d, svc) = service();
    let r = repo();
    let t = analyze(&svc, &r.root, json!({"report": "hierarchy", "symbol": "Base"}));
    let up = section(&t, &r.root, "Supertypes");
    let down = section(&t, &r.root, "Subtypes");
    assert!(t.contains("Shape"), "{t}");
    assert!(up.iter().any(|(p, l)| p.starts_with("src/shapes.ts") && l.contains("Shape")) || t.contains("implements Shape"), "{t}");
    let down_text = format!("{down:?}");
    for sub in ["Circle", "Square", "Unit"] {
        assert!(down_text.contains(sub), "{sub} derives from Base: {t}");
    }
    let t = analyze(&svc, &r.root, json!({"report": "hierarchy", "symbol": "Shape", "direction": "down", "depth": 1}));
    assert!(t.contains("Base") && !t.contains("Circle"), "depth 1 stops at the direct implementer: {t}");
    let e = call(&svc, &r.root, json!({"report": "hierarchy"}));
    assert_eq!(e.state.as_deref(), Some("BAD_REQUEST"), "{e:?}");
}

#[test]
fn diff_impact_follows_every_file_the_worktree_changed() {
    let (_d, svc) = service();
    let r = repo();
    let t = analyze(&svc, &r.root, json!({"report": "diff_impact"}));
    assert!(t.contains("no uncommitted changes"), "{t}");
    write(&r.root, "src/hub.ts", "export function hub() { return 9; }\nexport const used = 1;\n");
    write(&r.root, "src/shapes.ts", "export interface Shape { area(): number }\nexport class Base implements Shape { area() { return 1; } }\nexport class Circle extends Base {}\nexport class Square extends Base {}\nexport class Unit extends Square {}\nnew Circle(); new Unit();\n");
    let t = analyze(&svc, &r.root, json!({"report": "diff_impact"}));
    assert!(t.contains("src/hub.ts") && t.contains("src/shapes.ts"), "both changed files are seeds: {t}");
    let ranked = section(&t, &r.root, "Ranked impact");
    let paths: Vec<&str> = ranked.iter().map(|(p, _)| p.as_str()).collect();
    for p in ["src/imp1.ts", "src/imp2.ts", "src/co1.ts", "src/co2.ts"] {
        assert!(paths.contains(&p), "{p} is affected: {t}");
    }
    assert!(!paths.contains(&"src/hub.ts"), "a seed is not its own impact: {t}");
    let tests = section(&t, &r.root, "Tests (");
    assert!(tests.iter().any(|(p, _)| p == "tests/hub.test.ts"), "{t}");
}

#[test]
fn context_ranks_files_related_to_given_files_and_terms() {
    let (_d, svc) = service();
    let r = repo();
    let t = analyze(&svc, &r.root, json!({"report": "context", "files": ["src/imp2.ts"]}));
    let rows = section(&t, &r.root, "Related files");
    assert_eq!(rows.first().map(|r| r.0.as_str()), Some("src/imp1.ts"), "the seed's import ranks first: {t}");
    let t = analyze(&svc, &r.root, json!({"report": "context", "terms": ["circle"]}));
    let rows = section(&t, &r.root, "Related files");
    assert_eq!(rows.first().map(|r| r.0.as_str()), Some("src/shapes.ts"), "{t}");
    assert!(rows[0].1.contains("Circle"), "the matching symbol is named: {t}");
}

#[test]
fn hotspots_rank_files_by_churn_times_size() {
    let (_d, svc) = service();
    let r = repo();
    let t = analyze(&svc, &r.root, json!({"report": "hotspots"}));
    let rows = section(&t, &r.root, "Hotspots");
    assert_eq!(rows.first().map(|r| r.0.as_str()), Some("src/hub.ts"), "{t}");
    assert!(rows[0].1.contains("4 commits"), "{t}");
}

#[test]
fn help_documents_every_report_and_a_bad_report_says_which_exist() {
    let (_d, svc) = service();
    let r = repo();
    let t = analyze(&svc, &r.root, json!({"report": "help"}));
    for rep in ["unused", "cochange", "context", "hierarchy", "diff_impact", "hotspots"] {
        assert!(t.contains(rep), "help lacks {rep}: {t}");
    }
    for p in ["file_path", "files", "terms", "symbol", "direction", "depth", "include_tests", "limit"] {
        assert!(t.contains(p), "help lacks {p}: {t}");
    }
    let e = call(&svc, &r.root, json!({"report": "wiki"}));
    assert_eq!(e.state.as_deref(), Some("BAD_REQUEST"), "{e:?}");
    assert!(e.error.unwrap().contains("hotspots"));
    // help needs no index: it answers from a directory that is not a repository.
    let dir = tempfile::tempdir().unwrap();
    let t = analyze(&svc, dir.path(), json!({"report": "help"}));
    assert!(t.contains("cochange"), "{t}");
}

#[test]
fn the_shim_answers_help_without_a_daemon() {
    let paths = Paths::new("/nonexistent/fdi-store", Some("/nonexistent/fdi.sock".into()));
    let mut s = Shim::new(Options { paths, cwd: "/tmp".into(), auto_start: false, daemon_args: vec![] });
    let r = s.handle(json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "qartez_analyze", "arguments": {"report": "help"}}})).unwrap();
    assert_eq!(r["result"]["isError"], false, "{r}");
    assert!(r["result"]["content"][0]["text"].as_str().unwrap().contains("diff_impact"), "{r}");
}

#[test]
fn unused_counts_a_rust_use_inside_a_macro_call_which_the_parser_does_not_see() {
    // Tree-sitter reads a macro's arguments as a token tree, so `format!("{}", util::helper())`
    // records no reference to `helper`. A name that appears in Rust source outside its own
    // definition and outside a comment is not reported.
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "Cargo.toml", "[package]\nname = \"m\"\nversion = \"0.1.0\"\nedition = \"2021\"\n");
    write(&r.root, "src/lib.rs", "pub mod util;\n");
    write(&r.root, "src/util.rs", "pub fn helper() -> u32 { 1 }\n\n/// Not `ghost`: only this comment names it.\npub fn ghost() -> u32 { 2 }\n\n#[no_mangle]\npub extern \"C\" fn ffi_entry() -> u32 { 3 }\n");
    write(&r.root, "src/main.rs", "fn main() {\n    println!(\"{}\", m::util::helper());\n    // ghost() is not called\n}\n");
    commit_all(&r.root, "init");
    let t = analyze(&svc, &r.root, json!({"report": "unused"}));
    assert!(!t.contains("helper"), "helper is called inside println!: {t}");
    assert!(t.contains("ghost"), "a comment is not a use: {t}");
    assert!(!t.contains("ffi_entry"), "an extern fn is called from outside the crate: {t}");
}

#[test]
fn unused_counts_plain_reads_of_constants_and_skips_framework_entry_points() {
    // Python and Swift record calls and type uses as references, not every read of a constant;
    // a constant read in code is used. `@main` types and a type's nested type aliases (protocol
    // witnesses such as NIO's `InboundIn`) are called by the runtime, not by the code.
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "tool/run.py", "LIMIT = 3\nSPARE = 4\n\n\ndef go():\n    # SPARE is mentioned only here\n    return LIMIT\n\n\ngo()\n");
    write(&r.root, "App/main.swift", "let stateDir = \"/tmp\"\nlet unusedDir = \"/var\"\nprint(stateDir + \"/x\")\n");
    write(&r.root, "App/App.swift", "@main\nstruct ShellApp {\n    static func main() {}\n}\n\nstruct Handler: Codable {\n    typealias InboundIn = Int\n}\nlet h = Handler()\n");
    commit_all(&r.root, "init");
    let t = analyze(&svc, &r.root, json!({"report": "unused"}));
    assert!(!t.contains("LIMIT") && !t.contains("stateDir"), "constants read in code are used: {t}");
    assert!(t.contains("SPARE") && t.contains("unusedDir"), "{t}");
    assert!(!t.contains("ShellApp") && !t.contains("InboundIn"), "runtime entry points are not reported: {t}");
}
