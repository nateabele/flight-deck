//! Imports through manifest links (spec §5.3): a Cargo path dependency, a mix path dependency, a
//! package.json `link:` dependency or workspace member, and a tsconfig `paths` alias make the
//! imports that name them land in the linked code, so `refs`, `calls`, `deps` and `impact` follow
//! them in both directions with the other view labelled.
//!
//! Each fixture is two repositories side by side, like the real cases: a `tessera` worktree whose
//! `designer/package.json` links `formula-editor` and whose `server/mix.exs` has a path dependency
//! on a sibling engine library.
mod common;
use common::*;
use flightindex::proto::{Request, Response, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r: Response = svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() });
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

fn repo_at(parent: &Path, name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = parent.join(name);
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    for (rel, text) in files {
        write(&root, rel, text);
    }
    commit_all(&root, "init");
    root
}

fn tag(root: &Path) -> String {
    format!("{} @ {}", root.file_name().unwrap().to_string_lossy(), root.display())
}

fn parent() -> (tempfile::TempDir, PathBuf) {
    let outer = tempfile::tempdir().unwrap();
    let p = outer.path().canonicalize().unwrap();
    (outer, p)
}

// ---- Cargo path dependencies ----------------------------------------------------------------------

const DEP_TOML: &str = "[package]\nname = \"dep-core\"\nversion = \"0.1.0\"\n";
const DEP_LIB: &str = "pub mod store;\npub use store::open;\n";
const DEP_STORE: &str = "pub fn open() -> u32 {\n    1\n}\n\npub struct Handle;\n\nimpl Handle {\n    pub fn new() -> Handle {\n        Handle\n    }\n}\n";
const APP_TOML: &str = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\ndep-core = { path = \"../dep\" }\n";
const APP_MAIN: &str = "use dep_core::open;\nuse dep_core::store::Handle;\n\nfn main() {\n    let _ = open();\n    let _h = Handle::new();\n    let _ = dep_core::store::open();\n}\n";

fn cargo_world(p: &Path) -> (PathBuf, PathBuf) {
    let dep = repo_at(p, "dep", &[("Cargo.toml", DEP_TOML), ("src/lib.rs", DEP_LIB), ("src/store.rs", DEP_STORE)]);
    let app = repo_at(p, "app", &[("Cargo.toml", APP_TOML), ("src/main.rs", APP_MAIN)]);
    (dep, app)
}

#[test]
fn a_cargo_path_dependency_resolves_use_paths_into_the_linked_crate() {
    let (_d, svc) = service();
    let (_o, p) = parent();
    let (dep, app) = cargo_world(&p);
    let main = app.join("src/main.rs");
    let store = dep.join("src/store.rs");

    let deps = ok(&svc, &app, "deps", json!({"file_path": "src/main.rs"}));
    assert!(deps.contains(&format!("-> {} (view: {}, import: dep_core", store.display(), tag(&dep))), "{deps}");
    assert!(deps.contains(&format!("-> {} (view: {}, import: dep_core", dep.join("src/lib.rs").display(), tag(&dep))), "{deps}");

    // `open` through the `pub use` in lib.rs, and `dep_core::store::open()` written out in full.
    let refs = ok(&svc, &app, "refs", json!({"symbol": "open", "file_path": store}));
    assert!(refs.contains(&format!("{}  [view: {}]\n  L5 call in main\n  L7 call in main", main.display(), tag(&app))), "both uses in app's main.rs: {refs}");
    let new = ok(&svc, &app, "refs", json!({"symbol": "new", "file_path": store}));
    assert!(new.contains(&main.display().to_string()), "`Handle::new()` through `use dep_core::store::Handle`: {new}");

    let callers = ok(&svc, &app, "calls", json!({"name": "open", "file_path": store, "direction": "callers"}));
    assert!(callers.contains("main (function)") && callers.contains(&main.display().to_string()), "{callers}");
    let callees = ok(&svc, &app, "calls", json!({"name": "main", "direction": "callees"}));
    assert!(callees.contains(&format!("defined in {}  [view: {}]", store.display(), tag(&dep))), "{callees}");

    let impact = ok(&svc, &app, "impact", json!({"file_path": store}));
    assert!(impact.contains(&format!("{}  [view: {}]", main.display(), tag(&app))), "{impact}");

    let stats = ok(&svc, &app, "stats", json!({}));
    assert!(stats.contains(&format!("{} via Cargo.toml: 2 import(s)", tag(&dep))), "{stats}");
}

#[test]
fn a_crate_that_was_linked_into_answers_with_its_dependents_uses_labelled() {
    let (_d, svc) = service();
    let (_o, p) = parent();
    let (dep, app) = cargo_world(&p);
    ok(&svc, &app, "find", json!({"name": "main"})); // app is indexed and its links recorded
    let refs = ok(&svc, &dep, "refs", json!({"symbol": "open", "file_path": "src/store.rs"}));
    assert!(refs.contains(&format!("dependent view: {} (repo app", app.display())), "{refs}");
    let row = refs.lines().find(|l| l.starts_with(&app.join("src/main.rs").display().to_string())).unwrap_or_else(|| panic!("{refs}"));
    assert!(row.ends_with(&format!("[view: {}]", tag(&app))), "{row}");
}

// ---- mix path dependencies --------------------------------------------------------------------------

#[test]
fn a_mix_path_dependency_resolves_modules_wherever_the_library_defines_them() {
    let (_d, svc) = service();
    let (_o, p) = parent();
    // `CALCEngine` lives in lib/calc.ex, not lib/calc_engine.ex: only a scan of the library knows.
    let engine = repo_at(
        &p,
        "engine",
        &[
            ("mix.exs", "defmodule CALCEngine.MixProject do\n  use Mix.Project\nend\n"),
            ("lib/calc.ex", "defmodule CALCEngine do\n  def eval(x), do: x\n\n  defmodule Error do\n    defstruct [:message]\n  end\nend\n"),
            ("lib/calc/parser.ex", "defmodule CALCEngine.Parser do\n  def parse(s), do: s\nend\n"),
        ],
    );
    let server = repo_at(
        &p,
        "server",
        &[
            ("mix.exs", "defmodule Server.MixProject do\n  defp deps do\n    [{:engine, path: \"../engine\"}, {:jason, \"~> 1.4\"}]\n  end\nend\n"),
            ("lib/server/runner.ex", "defmodule Server.Runner do\n  alias CALCEngine.Parser\n\n  def run(x), do: CALCEngine.eval(x)\n\n  def parse(s), do: Parser.parse(s)\n\n  def fail, do: %CALCEngine.Error{message: \"no\"}\nend\n"),
        ],
    );
    let runner = server.join("lib/server/runner.ex");
    let refs = ok(&svc, &server, "refs", json!({"symbol": "eval", "file_path": engine.join("lib/calc.ex")}));
    assert!(refs.contains(&format!("{}  [view: {}]\n  L4 call in run", runner.display(), tag(&server))), "{refs}");
    let parse = ok(&svc, &server, "refs", json!({"symbol": "parse", "file_path": engine.join("lib/calc/parser.ex")}));
    assert!(parse.contains(&runner.display().to_string()), "through `alias CALCEngine.Parser`: {parse}");
    let err = ok(&svc, &server, "refs", json!({"symbol": "CALCEngine.Error", "file_path": engine.join("lib/calc.ex")}));
    assert!(err.contains(&runner.display().to_string()), "a nested module by its full name: {err}");

    let deps = ok(&svc, &server, "deps", json!({"file_path": runner}));
    assert!(deps.contains(&format!("-> {} (view: {}", engine.join("lib/calc/parser.ex").display(), tag(&engine))), "{deps}");
    let impact = ok(&svc, &server, "impact", json!({"file_path": engine.join("lib/calc.ex")}));
    assert!(impact.contains(&format!("{}  [view: {}]", runner.display(), tag(&server))), "a remote call with no alias is a dependency: {impact}");
}

// ---- package.json names and tsconfig paths ----------------------------------------------------------

fn shared(p: &Path) -> PathBuf {
    let root = repo_at(
        p,
        "shared",
        &[
            (".gitignore", "dist/\n"),
            ("package.json", r#"{"name":"@acme/shared","main":"./dist/index.js","types":"dist/index.d.ts"}"#),
            ("src/index.ts", "export function slug(s: string): string {\n  return s;\n}\n"),
            ("src/format/date.ts", "export function day(n: number): string {\n  return String(n);\n}\n"),
        ],
    );
    // Built output on disk but not indexed: the import must land on the source.
    write(&root, "dist/index.js", "export function slug(s) { return s; }\n");
    root
}

#[test]
fn a_linked_package_name_resolves_into_the_packages_source() {
    let (_d, svc) = service();
    let (_o, p) = parent();
    let shared = shared(&p);
    let web = repo_at(
        &p,
        "web",
        &[
            ("package.json", r#"{"name":"web","dependencies":{"@acme/shared":"link:../shared","left-pad":"^1.0.0"}}"#),
            ("src/page.ts", "import { slug } from '@acme/shared';\nimport { day } from '@acme/shared/src/format/date';\nimport pad from 'left-pad';\n\nexport function title(s: string): string {\n  return slug(s) + day(1) + pad(s);\n}\n"),
        ],
    );
    let page = web.join("src/page.ts");
    let deps = ok(&svc, &web, "deps", json!({"file_path": "src/page.ts"}));
    assert!(deps.contains(&format!("-> {} (view: {}, import: @acme/shared)", shared.join("src/index.ts").display(), tag(&shared))), "{deps}");
    assert!(deps.contains(&format!("-> {} (view: {}, import: @acme/shared/src/format/date)", shared.join("src/format/date.ts").display(), tag(&shared))), "{deps}");
    assert!(!deps.contains("dist/") && !deps.contains("left-pad"), "{deps}");
    let refs = ok(&svc, &web, "refs", json!({"symbol": "slug"}));
    assert!(refs.contains(&format!("Defined in: {}", shared.join("src/index.ts").display())) && refs.contains(&page.display().to_string()), "{refs}");
    let impact = ok(&svc, &web, "impact", json!({"file_path": shared.join("src/format/date.ts")}));
    assert!(impact.contains(&format!("{}  [view: {}]", page.display(), tag(&web))), "{impact}");
}

#[test]
fn a_tsconfig_paths_alias_resolves_into_the_linked_directory() {
    let (_d, svc) = service();
    let (_o, p) = parent();
    let shared = shared(&p);
    // Vite keeps `paths` in tsconfig.app.json; the root tsconfig.json only references it.
    let web = repo_at(
        &p,
        "web",
        &[
            ("tsconfig.json", r#"{ "files": [], "references": [{ "path": "./tsconfig.app.json" }] }"#),
            ("tsconfig.app.json", "{\n  // aliases\n  \"compilerOptions\": { \"baseUrl\": \".\", \"paths\": { \"@lib/*\": [\"../shared/src/*\"], \"@/*\": [\"./src/*\"], }, },\n}\n"),
            ("src/util/fmt.ts", "export function fmt(s: string): string {\n  return s;\n}\n"),
            ("src/page.ts", "import { day } from '@lib/format/date';\nimport { fmt } from '@/util/fmt';\n\nexport function title(): string {\n  return fmt(day(1));\n}\n"),
        ],
    );
    let deps = ok(&svc, &web, "deps", json!({"file_path": "src/page.ts"}));
    assert!(deps.contains(&format!("-> {} (view: {}, import: @lib/format/date)", shared.join("src/format/date.ts").display(), tag(&shared))), "{deps}");
    assert!(deps.contains(&format!("-> {} (import: @/util/fmt)", web.join("src/util/fmt.ts").display())), "an alias inside the view: {deps}");
    let callers = ok(&svc, &web, "calls", json!({"name": "day", "direction": "callers"}));
    assert!(callers.contains("title (function)"), "{callers}");
}

#[test]
fn workspace_packages_and_aliases_inside_one_repository_resolve_in_view() {
    let (_d, svc) = service();
    let (_o, p) = parent();
    let mono = repo_at(
        &p,
        "mono",
        &[
            ("package.json", r#"{"name":"mono","private":true,"workspaces":["packages/*"]}"#),
            ("packages/common/package.json", r#"{"name":"@m/common","main":"dist/index.js"}"#),
            ("packages/common/src/index.ts", "export function shared(): number {\n  return 1;\n}\n"),
            ("packages/ui/package.json", r#"{"name":"@m/ui","dependencies":{"@m/common":"workspace:*"}}"#),
            ("packages/ui/src/app.ts", "import { shared } from '@m/common';\n\nexport function app(): number {\n  return shared();\n}\n"),
        ],
    );
    let deps = ok(&svc, &mono, "deps", json!({"file_path": "packages/ui/src/app.ts"}));
    assert!(deps.contains(&format!("-> {} (import: @m/common)", mono.join("packages/common/src/index.ts").display())), "{deps}");
    let refs = ok(&svc, &mono, "refs", json!({"symbol": "shared"}));
    assert!(refs.contains(&mono.join("packages/ui/src/app.ts").display().to_string()), "{refs}");
}
