//! Python extractor behaviour on an inline source.

use flightindex::facts::*;
use flightindex::lang;

const SRC: &str = r#"import os, a.b as c
from . import x
from ..pkg.mod import y as z, w
from m import *
from __future__ import annotations
__all__ = ["Foo", "helper"]
MAX = 3
counter = 0
class Foo(Base, mod.Other, metaclass=Meta):
    attr = 1
    @property
    def p(self): return helper(self.q())
    async def q(self): pass
    def __init__(self): pass
@deco
def helper(a: int) -> Foo:
    def inner(): pass
    return Foo(a) + os.getcwd() + z(1)
def _priv(): pass
"#;

fn facts() -> BlobFacts {
    lang::by_id("python").expect("python registered").extract(SRC)
}

fn sym<'a>(f: &'a BlobFacts, name: &str) -> &'a Symbol {
    f.symbols.iter().find(|s| s.name == name).unwrap_or_else(|| panic!("no symbol {name}"))
}

#[test]
fn python_is_registered_for_py_files() {
    assert_eq!(lang::for_path(std::path::Path::new("pkg/mod.py")).map(|l| l.id()), Some("python"));
}

#[test]
fn symbols_have_kinds_nesting_and_signatures() {
    let f = facts();
    assert_eq!(sym(&f, "Foo").kind, SymbolKind::Class);
    assert_eq!(sym(&f, "helper").kind, SymbolKind::Function);
    let p = sym(&f, "p");
    assert_eq!(p.kind, SymbolKind::Method);
    assert_eq!(f.symbols[p.parent.unwrap() as usize].name, "Foo");
    assert_eq!(sym(&f, "q").kind, SymbolKind::Method);
    assert_eq!(sym(&f, "q").signature.as_deref(), Some("async def q(self)"));
    assert_eq!(sym(&f, "helper").signature.as_deref(), Some("def helper(a: int) -> Foo"));
    assert_eq!(sym(&f, "attr").kind, SymbolKind::Field);
    assert_eq!(sym(&f, "MAX").kind, SymbolKind::Const);
    assert_eq!(sym(&f, "counter").kind, SymbolKind::Variable);
    assert!(f.symbols.iter().all(|s| s.name != "inner"), "a function-local def is not a symbol");
    assert!(f.symbols.iter().all(|s| s.name != "__all__"));
}

#[test]
fn a_decorated_def_spans_its_decorators() {
    let f = facts();
    let h = sym(&f, "helper");
    assert_eq!((h.start_line, h.end_line), (15, 18));
    let p = sym(&f, "p");
    assert_eq!(p.start_line, 11, "the property decorator is part of the method");
}

#[test]
fn dunder_all_decides_what_is_exported_else_underscore() {
    let f = facts();
    assert!(sym(&f, "Foo").exported);
    assert!(sym(&f, "helper").exported);
    assert!(!sym(&f, "MAX").exported, "__all__ is present and does not list it");
    assert!(!sym(&f, "_priv").exported);

    let g = lang::by_id("python").unwrap().extract("def a(): pass\ndef _b(): pass\nclass C:\n    def __init__(self): pass\n    def _m(self): pass\n");
    assert!(sym(&g, "a").exported);
    assert!(!sym(&g, "_b").exported);
    assert!(sym(&g, "__init__").exported, "dunder methods are public API");
    assert!(!sym(&g, "_m").exported);
}

#[test]
fn imports_keep_relative_levels_aliases_and_names() {
    let f = facts();
    let by = |spec: &str| f.imports.iter().find(|i| i.specifier == spec).unwrap_or_else(|| panic!("no import {spec}"));
    assert_eq!(by("os").alias, None);
    assert_eq!(by("a.b").alias.as_deref(), Some("c"));
    assert_eq!(by(".").names, vec![ImportName::plain("x")]);
    let m = by("..pkg.mod");
    assert_eq!(m.names.len(), 2);
    assert_eq!(m.names[0], ImportName { name: "y".into(), alias: Some("z".into()), subs: false });
    assert_eq!(by("m").names, vec![ImportName::plain("*")]);
    assert!(f.imports.iter().all(|i| i.specifier != "__future__"));
}

#[test]
fn bases_are_hierarchy_facts_and_keyword_arguments_are_not() {
    let f = facts();
    let foo = sym(&f, "Foo").local_id;
    let targets: Vec<&str> = f.hierarchy.iter().filter(|h| h.symbol == foo).map(|h| h.target.as_str()).collect();
    assert_eq!(targets, vec!["Base", "Other"]);
}

#[test]
fn calls_and_annotations_are_references_with_qualifiers() {
    let f = facts();
    let has = |q: Option<&str>, n: &str, k: RefKind| f.refs.iter().any(|r| r.name == n && r.qualifier.as_deref() == q && r.kind == k);
    assert!(has(None, "helper", RefKind::Call));
    assert!(has(Some("self"), "q", RefKind::Call));
    assert!(has(Some("os"), "getcwd", RefKind::Call));
    assert!(has(None, "Foo", RefKind::Call));
    assert!(has(None, "Foo", RefKind::Type), "return annotation");
    assert!(has(None, "deco", RefKind::Call), "decorator");
    assert!(has(None, "Base", RefKind::Type), "base class");
    assert!(has(None, "z", RefKind::Call), "an aliased import is called by its local name");
    let helper = sym(&f, "helper").local_id;
    let inner_call = f.refs.iter().find(|r| r.name == "getcwd").unwrap();
    assert_eq!(inner_call.enclosing, Some(helper), "refs inside a nested def belong to the outer symbol");
}
