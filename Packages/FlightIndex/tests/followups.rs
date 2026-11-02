//! Extractor and store follow-ups: references inside Rust macro arguments and TypeScript template
//! substitutions, `#[path]` on Rust `mod` declarations, and Swift type facts inside the chunk.

use flightindex::chunk::{decode, encode, Decoded};
use flightindex::facts::*;
use flightindex::git::FileRef;
use flightindex::lang;
use flightindex::resolve::{Resolved, Resolver};

fn facts(lang_id: &str, src: &str) -> BlobFacts {
    lang::by_id(lang_id).unwrap().extract(src)
}

fn refs_named<'a>(f: &'a BlobFacts, name: &str) -> Vec<&'a Reference> {
    f.refs.iter().filter(|r| r.name == name).collect()
}

fn has(f: &BlobFacts, q: Option<&str>, name: &str, kind: RefKind) -> bool {
    f.refs.iter().any(|r| r.name == name && r.qualifier.as_deref() == q && r.kind == kind)
}

fn dump(f: &BlobFacts) -> Vec<(String, Option<String>, RefKind)> {
    f.refs.iter().map(|r| (r.name.clone(), r.qualifier.clone(), r.kind)).collect()
}

// ---- Rust macro arguments ------------------------------------------------------------------------

const RUST_MACROS: &str = r#"fn check(cfg: &Config) {
    assert!(is_valid(cfg), "bad {}", describe(cfg));
    let s = format!("{} {}", helper::render(cfg), cfg.name());
    let v = vec![make_item(1), Item::new(2), MAX_ITEMS];
    my_macro!(store.open(path), Kind::Leaf);
    assert_eq!(outer(inner(cfg)), other::deep::thing());
}
"#;

#[test]
fn rust_calls_inside_macro_arguments_are_references() {
    let f = facts("rust", RUST_MACROS);
    let d = dump(&f);
    assert!(has(&f, None, "is_valid", RefKind::Call), "{d:?}");
    assert!(has(&f, None, "describe", RefKind::Call), "{d:?}");
    assert!(has(&f, Some("helper"), "render", RefKind::Call), "{d:?}");
    assert!(has(&f, Some("cfg"), "name", RefKind::Call), "{d:?}");
    assert!(has(&f, None, "make_item", RefKind::Call), "{d:?}");
    assert!(has(&f, Some("Item"), "new", RefKind::Call), "{d:?}");
    assert!(has(&f, Some("store"), "open", RefKind::Call), "{d:?}");
    assert!(has(&f, None, "outer", RefKind::Call) && has(&f, None, "inner", RefKind::Call), "nested: {d:?}");
    assert!(has(&f, Some("other::deep"), "thing", RefKind::Call), "{d:?}");
    // Upper-case names are uses, as outside a macro.
    assert!(has(&f, None, "MAX_ITEMS", RefKind::Use), "{d:?}");
    assert!(has(&f, Some("Kind"), "Leaf", RefKind::Use), "{d:?}");
    // The macros themselves are `RefKind::Macro` (bound to a crate's `macro_rules!`, never to a
    // function of the same name: pk-rs); plain lower-case locals are still not recorded.
    assert!(has(&f, None, "assert", RefKind::Macro) && has(&f, None, "my_macro", RefKind::Macro), "{d:?}");
    assert!(refs_named(&f, "cfg").is_empty() && refs_named(&f, "path").is_empty(), "{d:?}");
    // Each reference sits in `check`.
    let check = f.symbols.iter().find(|s| s.name == "check").unwrap().local_id;
    assert!(refs_named(&f, "is_valid").iter().all(|r| r.enclosing == Some(check) && r.line == 2), "{d:?}");
}

#[test]
fn rust_macro_arguments_that_define_names_or_bind_metavariables_are_not_calls() {
    let src = r#"thread_local! { static CACHE: RefCell<u32> = RefCell::new(0); }
proptest! { fn round_trips(x in 0..10u32) { prop_assert!(encode(x) > 0); } }
macro_rules! twice { ($e:expr) => { run($e); run($e) } }
quote! { #helper(a) }
"#;
    let f = facts("rust", src);
    let d = dump(&f);
    assert!(refs_named(&f, "round_trips").is_empty(), "a fn name in a macro is a definition: {d:?}");
    assert!(refs_named(&f, "CACHE").is_empty(), "a static name in a macro is a definition: {d:?}");
    assert!(has(&f, Some("RefCell"), "new", RefKind::Call), "{d:?}");
    assert!(has(&f, None, "encode", RefKind::Call), "nested macro bodies: {d:?}");
    assert!(refs_named(&f, "run").is_empty(), "macro_rules bodies are templates, not code: {d:?}");
    assert!(refs_named(&f, "helper").is_empty(), "an interpolated #name is a metavariable: {d:?}");
}

// ---- Rust #[path] ----------------------------------------------------------------------------------

#[test]
fn rust_path_attribute_on_a_mod_decl_names_the_file() {
    let src = "#[cfg(unix)]\n#[path = \"platform/unix_impl.rs\"]\nmod imp;\nmod plain;\n";
    let f = facts("rust", src);
    let imp = f.imports.iter().find(|i| i.specifier == "imp").expect("mod imp");
    assert_eq!(imp.kind, ImportKind::ModDecl);
    assert_eq!(imp.alias.as_deref(), Some("platform/unix_impl.rs"));
    let plain = f.imports.iter().find(|i| i.specifier == "plain").unwrap();
    assert_eq!(plain.alias, None);

    let files: Vec<FileRef> = ["src/lib.rs", "src/platform/unix_impl.rs", "src/plain.rs", "src/net/mod.rs", "src/net/tls_shim.rs"]
        .iter()
        .map(|p| FileRef { path: p.to_string(), blob_id: "0".into(), language: "rust" })
        .collect();
    let r = Resolver::new(std::path::Path::new("/nonexistent"), &files);
    assert_eq!(r.resolve_import("src/lib.rs", "rust", imp), Resolved::File { path: "src/platform/unix_impl.rs".into(), rest: vec![] });
    assert_eq!(r.resolve_import("src/lib.rs", "rust", plain), Resolved::File { path: "src/plain.rs".into(), rest: vec![] });
    // Relative to the declaring file's directory, `..` allowed.
    let tls = Import { specifier: "tls".into(), alias: Some("tls_shim.rs".into()), names: vec![], line: 1, kind: ImportKind::ModDecl };
    assert_eq!(r.resolve_import("src/net/mod.rs", "rust", &tls), Resolved::File { path: "src/net/tls_shim.rs".into(), rest: vec![] });
    let up = Import { specifier: "u".into(), alias: Some("../plain.rs".into()), names: vec![], line: 1, kind: ImportKind::ModDecl };
    assert_eq!(r.resolve_import("src/net/mod.rs", "rust", &up), Resolved::File { path: "src/plain.rs".into(), rest: vec![] });
}

// ---- TypeScript template substitutions --------------------------------------------------------------

#[test]
fn typescript_template_substitutions_are_references() {
    // A bare name is kept only when the file imports or defines it (the extractor's local filter).
    let src = "import { LIMIT } from './limits';\nexport function f(x: number) {\n  const s = `a ${helper()} b ${util.format(x)} ${LIMIT}`;\n  return tag`x ${other(`${deep()}`)}`;\n}\n";
    for lang_id in ["typescript", "tsx", "javascript"] {
        let f = facts(lang_id, src);
        let d = dump(&f);
        assert!(has(&f, None, "helper", RefKind::Call), "{lang_id}: {d:?}");
        assert!(has(&f, Some("util"), "format", RefKind::Call), "{lang_id}: {d:?}");
        assert!(has(&f, None, "LIMIT", RefKind::Use), "{lang_id}: {d:?}");
        assert!(has(&f, None, "other", RefKind::Call) && has(&f, None, "deep", RefKind::Call), "{lang_id}: nested {d:?}");
        assert!(has(&f, None, "tag", RefKind::Call), "{lang_id}: {d:?}");
        // The literal text is not code.
        assert!(refs_named(&f, "a").is_empty() && refs_named(&f, "b").is_empty(), "{lang_id}: {d:?}");
    }
}

// ---- Swift type facts in the chunk ----------------------------------------------------------------

fn types() -> TypeFacts {
    TypeFacts {
        bindings: vec![
            Binding { name: "c".into(), ty: Some(TypeSource::Named("Car".into())), decl_line: 4, scope_start: 4, scope_end: 6, enclosing: Some(1) },
            Binding { name: "d".into(), ty: Some(TypeSource::Expr("c.make(ü)".into())), decl_line: 5, scope_start: 5, scope_end: 9, enclosing: None },
            Binding { name: "e".into(), ty: Some(TypeSource::Each("c.all".into())), decl_line: 5, scope_start: 3, scope_end: 6, enclosing: Some(u32::MAX - 1) },
            Binding { name: "f".into(), ty: None, decl_line: 6, scope_start: 6, scope_end: 6, enclosing: None },
            // An empty written type is not the same as none.
            Binding { name: "g".into(), ty: Some(TypeSource::Named(String::new())), decl_line: 1, scope_start: 1, scope_end: 1, enclosing: None },
        ],
        members: vec![MemberType { owner: "T".into(), member: "c".into(), ty: "Car".into() }, MemberType { owner: String::new(), member: "x".into(), ty: "[Int]".into() }],
        returns: vec![ReturnType { owner: String::new(), name: "make".into(), ty: None }, ReturnType { owner: "Car".into(), name: "all".into(), ty: Some("[Car]".into()) }],
    }
}

#[test]
fn swift_type_facts_round_trip_through_the_chunk() {
    let d = Decoded { types: types(), ..Default::default() };
    let back = decode(&encode(&d.symbols, &d.imports, &d.refs, &d.hierarchy, &d.types)).unwrap();
    assert_eq!(back, d);
    let empty = Decoded::default();
    assert_eq!(decode(&encode(&[], &[], &[], &[], &TypeFacts::default())).unwrap(), empty);
}

#[test]
fn the_store_keeps_type_facts_in_the_chunk_not_a_table_of_their_own() {
    use flightindex::store::*;
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().join("repo");
    let mut w = Writer::open(dir.path(), &repo).unwrap();
    let f = BlobFacts { line_count: 9, types: types(), ..Default::default() };
    w.put_facts(&[ParsedBlob { blob_id: "b1".into(), language: "swift", parser_version: 1, facts: Some(f.clone()) }]).unwrap();
    let got = w.get_interned("b1", "swift", 1).unwrap().unwrap();
    assert_eq!(got.types, f.types);
    let conn = rusqlite::Connection::open(db_path(dir.path(), &repo)).unwrap();
    let tables: Vec<String> = conn.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").unwrap().query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect();
    assert!(!tables.iter().any(|t| t == "type_facts"), "{tables:?}");
}
