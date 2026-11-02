//! Rust package views: references into crates of `Cargo.lock` and into std/core/alloc resolve to
//! package symbols read from a fake `CARGO_HOME` registry and a fake rust-src `library`, both
//! written into a temporary directory once per test process, never from the real `~/.cargo` or
//! toolchain.
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::pkgview;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

const REGISTRY: &[(&str, &str)] = &[
    ("minijson-1.2.0/Cargo.toml", "[package]\nname = \"minijson\"\nversion = \"1.2.0\"\nedition = \"2021\"\n"),
    (
        "minijson-1.2.0/src/lib.rs",
        r#"//! A tiny JSON crate.
pub mod value;
mod ser;

pub use value::Value;
pub use ser::to_string;

macro_rules! cfg_extra {
    ($($item:item)*) => { $($item)* }
}

cfg_extra! {
    pub mod extra;
}

#[macro_export]
macro_rules! json {
    ($($t:tt)*) => { $crate::Value::Null };
}

pub mod prelude {
    pub use crate::value::{Map, Value};
}

pub(crate) fn internal() {}
"#,
    ),
    (
        "minijson-1.2.0/src/value.rs",
        "pub enum Value {\n    Null,\n    Bool(bool),\n}\n\npub struct Map;\n\nimpl Value {\n    pub fn is_null(&self) -> bool {\n        true\n    }\n\n    fn private(&self) {}\n}\n",
    ),
    ("minijson-1.2.0/src/ser.rs", "pub fn to_string(v: &crate::Value) -> String {\n    String::new()\n}\n"),
    ("minijson-1.2.0/src/extra.rs", "pub fn extra_fn() {}\n"),
    ("wrapper-0.1.0/Cargo.toml", "[package]\nname = \"wrapper\"\nversion = \"0.1.0\"\n\n[dependencies.minijson]\nversion = \"1\"\n"),
    ("wrapper-0.1.0/src/lib.rs", "pub use minijson::Value as JsonValue;\npub use minijson::*;\n"),
];

const LIBRARY: &[(&str, &str)] = &[
    // core's own tests name std, which depends on core: following that would deadlock.
    (
        "core/src/lib.rs",
        "pub mod option;\npub mod result;\npub mod mem;\npub mod prelude;\npub mod arch;\n#[path = \"../../stdarch/crates/core_arch/src/mod.rs\"]\nmod core_arch;\n#[macro_use]\nmod macros;\n\n#[cfg(test)]\nmod tests {\n    use std::vec::Vec;\n}\n",
    ),
    // core pulls in stdarch from outside its own `src`: built apart, on the first lookup into it.
    ("core/src/arch.rs", "pub use crate::core_arch::arch::*;\n"),
    ("stdarch/crates/core_arch/src/mod.rs", "pub mod arch {\n    pub use crate::core_arch::simd::*;\n}\npub mod simd;\n"),
    ("stdarch/crates/core_arch/src/simd.rs", "pub fn simd_add() {}\n"),
    ("core/src/option.rs", "pub enum Option<T> {\n    None,\n    Some(T),\n}\n\nimpl<T> Option<T> {\n    pub fn is_some(&self) -> bool {\n        true\n    }\n}\n"),
    ("core/src/result.rs", "pub enum Result<T, E> {\n    Ok(T),\n    Err(E),\n}\n"),
    ("core/src/mem.rs", "pub fn drop<T>(_x: T) {}\n"),
    ("core/src/macros.rs", "#[macro_export]\n#[rustc_builtin_macro]\nmacro_rules! assert_eq {\n    ($l:expr, $r:expr) => {};\n}\n"),
    ("core/src/prelude/mod.rs", "pub mod v1;\n\npub mod rust_2021 {\n    pub use super::v1::*;\n}\n"),
    (
        "core/src/prelude/v1.rs",
        "pub use crate::option::Option::{self, None, Some};\npub use crate::result::Result::{self, Err, Ok};\npub use crate::mem::drop;\npub use crate::assert_eq;\n",
    ),
    ("alloc/src/lib.rs", "pub mod vec;\npub mod string;\n\n#[macro_export]\nmacro_rules! vec {\n    ($($x:expr),*) => {};\n}\n"),
    ("alloc/src/vec.rs", "pub struct Vec<T>(T);\n\nimpl<T> Vec<T> {\n    pub fn new() -> Self {\n        loop {}\n    }\n}\n"),
    ("alloc/src/string.rs", "pub struct String;\n\nimpl From<&str> for String {\n    fn from(s: &str) -> String {\n        String\n    }\n}\n"),
    (
        "std/src/lib.rs",
        r#"extern crate alloc as alloc_crate;

pub use core::option;
pub use core::result;
pub use core::mem;
pub use core::arch;
pub use alloc_crate::vec;
pub use alloc_crate::string;
pub use core::assert_eq;

pub mod collections;
pub mod prelude;

#[macro_export]
macro_rules! println {
    ($($arg:tt)*) => {};
}
"#,
    ),
    ("std/src/collections/mod.rs", "pub use self::hash_map::HashMap;\n\nmod hash;\n\npub mod hash_map {\n    pub use super::hash::map::*;\n}\n"),
    ("std/src/collections/hash/mod.rs", "pub mod map;\n"),
    ("std/src/collections/hash/map.rs", "pub struct HashMap<K, V>(K, V);\n\nimpl<K, V> HashMap<K, V> {\n    pub fn new() -> Self {\n        loop {}\n    }\n}\n"),
    ("std/src/prelude/mod.rs", "pub mod v1;\n\npub mod rust_2021 {\n    pub use super::v1::*;\n    pub use core::prelude::rust_2021::*;\n}\n"),
    (
        "std/src/prelude/v1.rs",
        r#"pub use crate::option::Option::{self, None, Some};
pub use crate::result::Result::{self, Err, Ok};
pub use crate::mem::drop;
pub use crate::string::String;
pub use crate::vec::Vec;
pub use core::prelude::v1::assert_eq;
pub use crate::println;

mod ambiguous_macros_only {
    mod vec {}
    pub use crate::*;
}
pub use self::ambiguous_macros_only::vec;
"#,
    ),
];

struct Fixture {
    cargo_home: PathBuf,
    library: PathBuf,
}

/// The fake caches, written once per process. Tests take `serial()` because the cache locations
/// are process-wide and one test points rust-src at nothing.
fn fixture() -> &'static Fixture {
    static F: OnceLock<Fixture> = OnceLock::new();
    F.get_or_init(|| {
        let dir = tempfile::tempdir().unwrap().keep();
        let cargo_home = dir.join("cargo-home");
        let reg = cargo_home.join("registry/src/index.example-0000");
        for (rel, text) in REGISTRY {
            write(&reg, rel, text);
        }
        let library = dir.join("rust-src/library");
        for (rel, text) in LIBRARY {
            write(&library, rel, text);
        }
        Fixture { cargo_home, library }
    })
}

fn serial() -> MutexGuard<'static, ()> {
    static L: Mutex<()> = Mutex::new(());
    let g = L.lock().unwrap_or_else(|e| e.into_inner());
    let f = fixture();
    pkgview::cargo::set_cargo_home(Some(f.cargo_home.clone()));
    pkgview::cargo::set_rust_src(Some(Some((f.library.clone(), "0.0.0-test".into()))));
    g
}

const CARGO_TOML: &str = "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\nminijson = \"1\"\nwrap = { package = \"wrapper\", version = \"0.1\" }\n";

const CARGO_LOCK: &str = r#"# This file is automatically @generated by Cargo.
version = 4

[[package]]
name = "app"
version = "0.1.0"
dependencies = [
 "minijson",
 "wrapper",
]

[[package]]
name = "minijson"
version = "1.2.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0000"

[[package]]
name = "wrapper"
version = "0.1.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0000"
dependencies = [
 "minijson",
]
"#;

const MAIN: &str = r#"mod util;
mod local;

use minijson::json;
use minijson::Value;
use std::collections::HashMap;
use std::fmt;

fn main() {
    let v: Value = json!(1);
    let m: HashMap<String, Vec<u8>> = HashMap::new();
    let n = minijson::to_string(&v);
    let o = Some(1);
    let w: wrap::JsonValue = Value::Null;
    assert_eq!(1, 1);
    println!("{n}");
    let s = String::from("x");
    let e = minijson::extra::extra_fn();
    let x = v.is_null();
    let i = minijson::internal();
    let items = vec![1, 2];
    util::helper();
    drop(o);
    std::arch::simd_add();
}

fn show(f: &mut fmt::Formatter) {}
"#;

const UTIL: &str = "pub fn helper() {}\n\n/// The only repository symbol called `String`: no reference outside this file means it.\npub struct String;\n";

const LOCAL: &str = "struct HashMap;\n\nfn f() -> HashMap {\n    HashMap\n}\n";

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, "Cargo.toml", CARGO_TOML);
    write(&r.root, "Cargo.lock", CARGO_LOCK);
    write(&r.root, "src/main.rs", MAIN);
    write(&r.root, "src/util.rs", UTIL);
    write(&r.root, "src/local.rs", LOCAL);
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

fn line_of(text: &str, needle: &str) -> u32 {
    text.lines().position(|l| l.contains(needle)).unwrap_or_else(|| panic!("no line with {needle}")) as u32 + 1
}

/// Every reference of `path` named `name` on the line holding `on`: what it resolved to.
fn resolved(g: &ViewGraph, path: &str, name: &str, on: &str) -> Vec<(Confidence, Option<String>, Option<String>)> {
    let text = match path {
        "src/main.rs" => MAIN,
        "src/local.rs" => LOCAL,
        other => panic!("no text for {other}"),
    };
    let line = line_of(text, on);
    let f = g.file_idx(Path::new(path)).unwrap_or_else(|| panic!("no file {path}"));
    let facts = &g.file(f).facts;
    let res = g.resolution(f);
    let mut out = Vec::new();
    for (i, (fr, rr)) in facts.refs.iter().zip(&res.refs).enumerate() {
        if g.name(fr.name) == name && fr.line == line {
            let local = rr.target.map(|t| format!("{}#{}", g.file(t.file).path, g.symbol(t).name));
            let pkg = g.package_target(f, i as u32).map(|s| s.display());
            out.push((rr.confidence, local, pkg));
        }
    }
    assert!(!out.is_empty(), "no reference {name} in {path} on `{on}`");
    out
}

fn assert_pkg(g: &ViewGraph, name: &str, on: &str, want: &str) {
    for (c, local, pkg) in resolved(g, "src/main.rs", name, on) {
        assert_eq!((c, local, pkg.as_deref()), (Confidence::Package, None, Some(want)), "{name} on `{on}`");
    }
}

fn assert_unresolved(g: &ViewGraph, name: &str, on: &str) {
    for (c, local, pkg) in resolved(g, "src/main.rs", name, on) {
        assert_eq!((c, local, pkg), (Confidence::Exact, None, None), "{name} on `{on}`");
    }
}

#[test]
fn use_paths_into_a_locked_crate_resolve_to_its_public_items() {
    let _s = serial();
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // `use minijson::Value` names the re-export of `value::Value`; symbols carry the defining path.
    assert_pkg(&g, "Value", "let v: Value", "minijson@1.2.0 value::Value");
    // An exported `macro_rules!` lives at the crate root, whatever module defines it.
    assert_pkg(&g, "json", "let v: Value", "minijson@1.2.0 json");
    // An enum variant through the imported type.
    assert_pkg(&g, "Null", "Value::Null", "minijson@1.2.0 value::Value::Null");
}

#[test]
fn qualified_paths_name_crates_of_the_extern_prelude() {
    let _s = serial();
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "to_string", "minijson::to_string", "minijson@1.2.0 ser::to_string");
    // A module declared inside an item macro (`cfg_extra! { pub mod extra; }`, as tokio does).
    assert_pkg(&g, "extra_fn", "extra_fn", "minijson@1.2.0 extra::extra_fn");
    // A renamed dependency (`wrap = { package = "wrapper" }`) re-exporting another crate's item.
    assert_pkg(&g, "JsonValue", "wrap::JsonValue", "minijson@1.2.0 value::Value");
    // `pub(crate)` is not public surface; a method call on a value is not a path.
    assert_unresolved(&g, "internal", "minijson::internal");
    for (c, _, pkg) in resolved(&g, "src/main.rs", "is_null", "v.is_null") {
        assert_eq!((c, pkg), (Confidence::Exact, None));
    }
}

#[test]
fn std_names_resolve_through_imports_the_prelude_and_re_exports_of_core_and_alloc() {
    let _s = serial();
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // `std::collections::HashMap` is a re-export through an inline module's glob.
    assert_pkg(&g, "HashMap", "let m: HashMap", "std@0.0.0-test collections::hash::map::HashMap");
    assert_pkg(&g, "new", "HashMap::new", "std@0.0.0-test collections::hash::map::HashMap::new");
    // The prelude: std's own re-exports of alloc and core.
    assert_pkg(&g, "Vec", "let m: HashMap", "alloc@0.0.0-test vec::Vec");
    assert_pkg(&g, "Some", "Some(1)", "core@0.0.0-test option::Option::Some");
    assert_pkg(&g, "drop", "drop(o)", "core@0.0.0-test mem::drop");
    // A trait impl's method is a member of the type (`impl From<&str> for String`).
    assert_pkg(&g, "from", "String::from", "alloc@0.0.0-test string::String::from");
    // Macros: the prelude's, std's own, and alloc's through the prelude's glob.
    assert_pkg(&g, "assert_eq", "assert_eq!", "core@0.0.0-test assert_eq");
    assert_pkg(&g, "println", "println!", "std@0.0.0-test println");
    assert_pkg(&g, "vec", "vec![", "alloc@0.0.0-test vec");
    // A module core takes from outside its source directory (`core::arch`'s intrinsics).
    assert_pkg(&g, "simd_add", "simd_add()", "core@0.0.0-test core_arch::simd::simd_add");
    // A module imported by `use std::fmt;` qualifies nothing the fixture's std defines.
    assert_unresolved(&g, "Formatter", "fmt::Formatter");
}

#[test]
fn a_prelude_name_beats_the_unique_repository_symbol_of_that_name_and_a_local_one_beats_both() {
    let _s = serial();
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // util.rs defines the only `String` in the repository; main.rs's `String` is alloc's.
    assert_pkg(&g, "String", "let m: HashMap", "alloc@0.0.0-test string::String");
    // local.rs defines its own `HashMap`.
    for (c, local, _) in resolved(&g, "src/local.rs", "HashMap", "fn f()") {
        assert_eq!((c, local.as_deref()), (Confidence::Exact, Some("src/local.rs#HashMap")));
    }
    for (c, local, _) in resolved(&g, "src/main.rs", "helper", "util::helper") {
        assert_eq!((c, local.as_deref()), (Confidence::Exact, Some("src/util.rs#helper")));
    }
    let main = g.file_idx(Path::new("src/main.rs")).unwrap();
    let util = g.file_idx(Path::new("src/util.rs")).unwrap();
    let local = g.file_idx(Path::new("src/local.rs")).unwrap();
    let mut edges = g.resolution(main).edges.clone();
    edges.sort();
    let mut want = vec![util, local];
    want.sort();
    assert_eq!(edges, want, "package references add no file edge");
}

#[test]
fn without_rust_src_std_names_stay_unresolved_and_crates_still_resolve() {
    let _s = serial();
    pkgview::cargo::set_rust_src(Some(None));
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "Value", "let v: Value", "minijson@1.2.0 value::Value");
    assert_unresolved(&g, "Some", "Some(1)");
    assert_unresolved(&g, "new", "HashMap::new");
    assert!(pkgview::stats().crates.missing.iter().any(|m| m.contains("rust-src")), "{:?}", pkgview::stats().crates.missing);
}

#[test]
fn incremental_resolution_with_crates_equals_a_full_rebuild() {
    let _s = serial();
    let r = project();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let base = e.graph(&v).unwrap();
    // A new local module defines `Value`, and main imports it instead of minijson's.
    write(&r.root, "src/model.rs", "pub struct Value;\n");
    write(&r.root, "src/main.rs", &MAIN.replace("use minijson::Value;", "use model::Value;").replace("mod local;", "mod local; mod model;"));
    let dirty = e.view_for_path(&r.root).unwrap();
    e.build(&dirty, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty).unwrap();
    assert_ne!(base.fingerprint(), incremental.fingerprint());
    for (c, local, _) in resolved(&incremental, "src/main.rs", "Value", "let v: Value") {
        assert_eq!((c, local.as_deref()), (Confidence::Exact, Some("src/model.rs#Value")));
    }
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
}

fn tool(svc: &Arc<Service>, cwd: &Path, name: &str, args: serde_json::Value) -> String {
    let r = svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: name.into(), args: args.as_object().cloned().unwrap_or_default() });
    assert!(r.ok, "{name} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

#[test]
fn find_and_refs_show_crate_symbols_labelled_as_package() {
    let _s = serial();
    let r = project();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let found = tool(&svc, &r.root, "find", json!({"name": "minijson::to_string"}));
    assert!(found.contains("Package: minijson@1.2.0 ser::to_string"), "{found}");
    assert!(found.contains("Signature: pub fn to_string(v: &crate::Value) -> String"), "{found}");
    let refs = tool(&svc, &r.root, "refs", json!({"symbol": "HashMap::new"}));
    assert!(refs.contains("Defined in: package std@0.0.0-test collections::hash::map::HashMap::new"), "{refs}");
    assert!(refs.contains(&format!("L{} call in main", line_of(MAIN, "HashMap::new"))), "{refs}");
    let st = tool(&svc, &r.root, "status", json!({}));
    assert!(st.contains("crates:"), "{st}");
}
