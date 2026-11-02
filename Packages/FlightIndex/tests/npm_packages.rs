//! npm package views: TypeScript and JavaScript references to names imported from packages
//! resolve to symbols of the packages' declaration files under `node_modules` (written by each
//! test into its own temp repository, and ignored by git like a real install).
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::json;
use std::path::Path;
use std::sync::Arc;

/// A test runner split like vitest: the entry re-exports `describe`/`it` from a runner package,
/// exports a renamed constant, and types `it` with an intersection over a generic.
const TESTER_PKG: &str = r#"{"name":"tester","version":"3.2.7","exports":{".":{"import":{"types":"./dist/index.d.ts","default":"./dist/index.js"},"require":{"types":"./index.d.cts"}}}}"#;
const TESTER_DTS: &str = r#"import { Matchers } from './chunks/matchers.d.Abc123.js';
export { describe, it } from '@tester/runner';
export { Matchers };
interface ExpectStatic { soft(x: unknown): void; }
declare const globalExpect: ExpectStatic;
interface Utils { fn(): void; useFakeTimers(): void; }
declare const vi: Utils;
export { globalExpect as expect, vi };
"#;
const TESTER_CHUNK: &str = "interface Matchers { toBe(x: unknown): void; }\nexport { Matchers as M, Matchers };\n";
const RUNNER_PKG: &str = r#"{"name":"@tester/runner","version":"3.2.7","types":"./dist/index.d.ts","main":"./dist/index.js"}"#;
const RUNNER_DTS: &str = r#"type Chainable<T extends string, F, C = object> = F & { [x in T]: Chainable<T, F, C> } & C;
interface ExtendedAPI { skipIf(c: unknown): void; }
type TestAPI = Chainable<"only" | "skip", (name: string) => void, { each: (cases: unknown[]) => void }> & ExtendedAPI;
declare function describe(name: string, f: () => void): void;
declare const it: TestAPI;
export { describe, it };
"#;
/// `@types/node`, reduced: ambient modules reached through `/// <reference path>`.
const NODE_PKG: &str = r#"{"name":"@types/node","version":"20.19.24","types":"index.d.ts"}"#;
const NODE_INDEX: &str = "/// <reference lib=\"es2020\" />\n/// <reference path=\"path.d.ts\" />\n/// <reference path=\"assert.d.ts\" />\n";
const NODE_PATH: &str = r#"declare module "path" {
    namespace path {
        interface PlatformPath { join(...paths: string[]): string; sep: "/"; }
    }
    const path: path.PlatformPath;
    export = path;
}
declare module "node:path" {
    import path = require("path");
    export = path;
}
"#;
const NODE_ASSERT: &str = r#"declare module "assert" {
    function assert(value: unknown): asserts value;
    namespace assert {
        function strictEqual<T>(actual: unknown, expected: T): void;
    }
    export = assert;
}
"#;
/// A package without declarations, and its `@types` package written as a global script (how
/// `@types/chai@4` and `@types/mocha` are written).
const OLDLIB_PKG: &str = r#"{"name":"oldlib","version":"4.2.0","main":"./index"}"#;
const OLDLIB_TYPES_PKG: &str = r#"{"name":"@types/oldlib","version":"4.2.14","types":"index.d.ts"}"#;
const OLDLIB_TYPES: &str = r#"declare namespace Lib {
    interface Static { expect: (x: unknown) => void; version: string; }
}
declare const lib: Lib.Static;
declare module "oldlib" {
    export = lib;
}
"#;
/// Subpath patterns in a scoped package's `exports`.
const KIT_PKG: &str = r#"{"name":"@scope/kit","version":"1.0.0","exports":{"./*":{"types":"./types/*.d.ts","default":"./lib/*.js"}}}"#;
const KIT_TOOLS: &str = "export declare function tool(): number;\nexport declare class Box { open(): void; }\n";
/// `export =` of a namespace, imported by default.
const REACT_PKG: &str = r#"{"name":"@types/react","version":"19.2.2","types":"index.d.ts"}"#;
const REACT_DTS: &str = "export = React;\nexport as namespace React;\ndeclare namespace React {\n    function useState<S>(s: S): [S, (s: S) => void];\n    interface FC { displayName?: string; }\n}\n";

const APP: &str = r#"import { describe, it, expect, vi } from 'tester';
import * as kit from '@scope/kit/tools';
import { tool, Box } from '@scope/kit/tools';
import path from 'node:path';
import { join } from 'path';
import { expect as lexpect } from 'oldlib';
import React from 'react';
import { helper } from './local';
import { thing } from 'linked';

describe('x', () => {
  it('y', () => {
    expect(1);
    vi.fn();
    it.each([]);
    it.skipIf(true);
    kit.tool();
    tool();
    path.join('a');
    join('b');
    lexpect(1);
    React.useState(1);
    helper();
    thing();
    new Box();
  });
});
const c: React.FC = null;
"#;
const LOCAL: &str = "export function helper() {}\n";
/// The only repository function named `tool`: what an unimported `tool()` would fall back to.
const OTHER: &str = "export function tool() { return 0; }\n";
const SCRIPT: &str = "const assert = require('assert');\nassert.strictEqual(1, 1);\nassert(true);\n";

fn install(root: &Path) {
    write(root, ".gitignore", "node_modules/\n");
    let nm = |rel: &str, text: &str| write(root, &format!("node_modules/{rel}"), text);
    nm("tester/package.json", TESTER_PKG);
    nm("tester/dist/index.d.ts", TESTER_DTS);
    nm("tester/dist/chunks/matchers.d.Abc123.d.ts", TESTER_CHUNK);
    nm("@tester/runner/package.json", RUNNER_PKG);
    nm("@tester/runner/dist/index.d.ts", RUNNER_DTS);
    nm("@types/node/package.json", NODE_PKG);
    nm("@types/node/index.d.ts", NODE_INDEX);
    nm("@types/node/path.d.ts", NODE_PATH);
    nm("@types/node/assert.d.ts", NODE_ASSERT);
    nm("oldlib/package.json", OLDLIB_PKG);
    nm("oldlib/index.js", "module.exports = {};\n");
    nm("@types/oldlib/package.json", OLDLIB_TYPES_PKG);
    nm("@types/oldlib/index.d.ts", OLDLIB_TYPES);
    nm("@scope/kit/package.json", KIT_PKG);
    nm("@scope/kit/types/tools.d.ts", KIT_TOOLS);
    nm("@types/react/package.json", REACT_PKG);
    nm("@types/react/index.d.ts", REACT_DTS);
    // A workspace link back into the repository: source, not a package.
    write(root, "linked/package.json", r#"{"name":"linked","version":"0.0.1","types":"index.d.ts"}"#);
    write(root, "linked/index.d.ts", "export declare function thing(): void;\n");
    std::os::unix::fs::symlink(root.join("linked"), root.join("node_modules/linked")).unwrap();
}

fn project() -> Repo {
    let r = init_repo();
    install(&r.root);
    write(&r.root, "src/app.test.ts", APP);
    write(&r.root, "src/local.ts", LOCAL);
    write(&r.root, "src/other.ts", OTHER);
    write(&r.root, "src/script.cjs", SCRIPT);
    commit_all(&r.root, "init");
    r
}

fn graph_of(repo: &Repo) -> (tempfile::TempDir, Engine, Arc<ViewGraph>) {
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&repo.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    (dir, e, g)
}

/// Every reference of `path` named `name` (under `qualifier`): what it resolved to.
fn resolved(g: &ViewGraph, path: &str, qualifier: Option<&str>, name: &str) -> Vec<(Confidence, Option<String>, Option<String>)> {
    let f = g.file_idx(Path::new(path)).unwrap_or_else(|| panic!("no file {path}"));
    let facts = &g.file(f).facts;
    let res = g.resolution(f);
    let mut out = Vec::new();
    for (i, (fr, rr)) in facts.refs.iter().zip(&res.refs).enumerate() {
        if g.name(fr.name) == name && g.qualifier(fr) == qualifier {
            let local = rr.target.map(|t| format!("{}#{}", g.file(t.file).path, g.symbol(t).name));
            out.push((rr.confidence, local, g.package_target(f, i as u32).map(|s| s.display())));
        }
    }
    assert!(!out.is_empty(), "no reference {qualifier:?}.{name} in {path}");
    out
}

fn assert_pkg(g: &ViewGraph, path: &str, qualifier: Option<&str>, name: &str, want: &str) {
    for (c, local, pkg) in resolved(g, path, qualifier, name) {
        assert_eq!((c, local, pkg.as_deref()), (Confidence::Package, None, Some(want)), "{path}: {qualifier:?}.{name}");
    }
}

#[test]
fn named_imports_follow_re_exports_into_the_declaring_package() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // `describe` and `it` are declared in @tester/runner and re-exported by tester.
    assert_pkg(&g, "src/app.test.ts", None, "describe", "@tester/runner@3.2.7 @tester/runner.describe");
    assert_pkg(&g, "src/app.test.ts", None, "it", "@tester/runner@3.2.7 @tester/runner.it");
    // `export { globalExpect as expect }`: the symbol is the declaration.
    assert_pkg(&g, "src/app.test.ts", None, "expect", "tester@3.2.7 tester.globalExpect");
}

#[test]
fn members_come_from_a_constants_declared_type() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/app.test.ts", Some("vi"), "fn", "tester@3.2.7 tester.Utils.fn");
    // Through an intersection: an interface, and an object literal given as a type argument.
    assert_pkg(&g, "src/app.test.ts", Some("it"), "skipIf", "@tester/runner@3.2.7 @tester/runner.ExtendedAPI.skipIf");
    assert_pkg(&g, "src/app.test.ts", Some("it"), "each", "@tester/runner@3.2.7 @tester/runner.TestAPI.each");
}

#[test]
fn namespace_imports_and_export_pattern_subpaths_resolve() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/app.test.ts", Some("kit"), "tool", "@scope/kit@1.0.0 @scope/kit/types/tools.tool");
    assert_pkg(&g, "src/app.test.ts", None, "Box", "@scope/kit@1.0.0 @scope/kit/types/tools.Box");
}

#[test]
fn a_package_name_beats_the_unique_repository_symbol_of_that_name() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // Without the package view, `tool()` fell back to src/other.ts, the only `tool` in the repo.
    assert_pkg(&g, "src/app.test.ts", None, "tool", "@scope/kit@1.0.0 @scope/kit/types/tools.tool");
    // A repository import still wins.
    for (c, local, _) in resolved(&g, "src/app.test.ts", None, "helper") {
        assert_eq!((c, local.as_deref()), (Confidence::Exact, Some("src/local.ts#helper")));
    }
}

#[test]
fn node_builtins_resolve_to_the_ambient_modules_of_types_node() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // `node:path` is `import path = require("path"); export = path`, and `path` is a constant
    // whose type is the namespace's interface.
    assert_pkg(&g, "src/app.test.ts", Some("path"), "join", "@types/node@20.19.24 path.path.PlatformPath.join");
    assert_pkg(&g, "src/app.test.ts", None, "join", "@types/node@20.19.24 path.path.PlatformPath.join");
    // CommonJS: `require('assert')` binds the `export =` function and its namespace.
    assert_pkg(&g, "src/script.cjs", Some("assert"), "strictEqual", "@types/node@20.19.24 assert.assert.strictEqual");
    assert_pkg(&g, "src/script.cjs", None, "assert", "@types/node@20.19.24 assert.assert");
}

#[test]
fn a_package_without_declarations_uses_its_types_package() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // `@types/oldlib` declares `module "oldlib" { export = lib }`, `lib: Lib.Static`.
    assert_pkg(&g, "src/app.test.ts", None, "lexpect", "@types/oldlib@4.2.14 oldlib.Lib.Static.expect");
}

#[test]
fn a_default_import_of_an_export_assigned_namespace_reaches_its_members_and_types() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/app.test.ts", Some("React"), "useState", "@types/react@19.2.2 react.React.useState");
    assert_pkg(&g, "src/app.test.ts", Some("React"), "FC", "@types/react@19.2.2 react.React.FC");
}

#[test]
fn a_workspace_link_is_not_a_package() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    for (c, _, pkg) in resolved(&g, "src/app.test.ts", None, "thing") {
        assert!(c != Confidence::Package && pkg.is_none(), "linked/ is repository source: {c:?} {pkg:?}");
    }
}

#[test]
fn package_imports_add_no_file_edges() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    let app = g.file_idx(Path::new("src/app.test.ts")).unwrap();
    let local = g.file_idx(Path::new("src/local.ts")).unwrap();
    assert_eq!(g.resolution(app).edges, vec![local]);
}

/// Every path under `dir` with its length and modification time.
fn snapshot(dir: &Path) -> Vec<(String, u64, std::time::SystemTime)> {
    let mut out = Vec::new();
    let mut todo = vec![dir.to_path_buf()];
    while let Some(d) = todo.pop() {
        for e in std::fs::read_dir(&d).unwrap().flatten() {
            let m = std::fs::symlink_metadata(e.path()).unwrap();
            if m.is_dir() {
                todo.push(e.path());
            }
            out.push((e.path().display().to_string(), m.len(), m.modified().unwrap()));
        }
    }
    out.sort();
    out
}

#[test]
fn node_modules_is_only_read() {
    let r = project();
    let before = snapshot(&r.root.join("node_modules"));
    let (_d, _e, _g) = graph_of(&r);
    assert_eq!(before, snapshot(&r.root.join("node_modules")));
}

fn tool_call(svc: &Arc<Service>, cwd: &Path, name: &str, args: serde_json::Value) -> String {
    let r = svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: name.into(), args: args.as_object().cloned().unwrap_or_default() });
    assert!(r.ok, "{name} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

#[test]
fn find_and_refs_show_npm_package_symbols() {
    let r = project();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let found = tool_call(&svc, &r.root, "find", json!({"name": "describe"}));
    assert!(found.contains("Package: @tester/runner@3.2.7 @tester/runner.describe"), "{found}");
    assert!(found.contains("Signature: function describe(name: string, f: () => void): void"), "{found}");
    let refs = tool_call(&svc, &r.root, "refs", json!({"symbol": "describe"}));
    assert!(refs.contains("Defined in: package @tester/runner@3.2.7 @tester/runner.describe"), "{refs}");
    assert!(refs.contains(&r.root.join("src/app.test.ts").display().to_string()), "{refs}");
}

#[test]
fn incremental_resolution_with_npm_packages_equals_a_full_rebuild() {
    let r = project();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let base = e.graph(&v).unwrap();
    // A new file, and the test now imports `tool` from it: the repository import beats the package.
    write(&r.root, "src/tools.ts", "export function tool() { return 1; }\n");
    write(&r.root, "src/app.test.ts", &APP.replace("import { tool, Box } from '@scope/kit/tools';", "import { Box } from '@scope/kit/tools';\nimport { tool } from './tools';"));
    let dirty = e.view_for_path(&r.root).unwrap();
    e.build(&dirty, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty).unwrap();
    assert_ne!(base.fingerprint(), incremental.fingerprint());
    for (c, local, _) in resolved(&incremental, "src/app.test.ts", None, "tool") {
        assert_eq!((c, local.as_deref()), (Confidence::Exact, Some("src/tools.ts#tool")));
    }
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
}
