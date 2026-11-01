//! Extractor behaviour per language, on small inline sources.

use flightindex::facts::*;
use flightindex::lang;

fn facts(lang_id: &str, src: &str) -> BlobFacts {
    lang::by_id(lang_id).unwrap().extract(src)
}

fn sym<'a>(f: &'a BlobFacts, name: &str) -> &'a Symbol {
    f.symbols.iter().find(|s| s.name == name).unwrap_or_else(|| panic!("no symbol {name}: {:?}", f.symbols.iter().map(|s| (&s.name, s.kind)).collect::<Vec<_>>()))
}

fn has_ref(f: &BlobFacts, q: Option<&str>, name: &str) -> bool {
    f.refs.iter().any(|r| r.name == name && r.qualifier.as_deref() == q)
}

const ELM: &str = r#"port module Foo.Bar exposing (Value(..), toString, Alias)

import List
import Json.Decode as D exposing (Decoder, field, Value)
import Foo.Baz exposing (..)

type Value
    = Int Int
    | Node (List V.Value) String

type alias Alias =
    { a : Int, b : String }

port sendIt : String -> Cmd msg

toString : Value -> String
toString v =
    case v of
        Int i ->
            String.fromInt i

        Node xs _ ->
            List.map toString xs |> String.join ","

helper x =
    let
        y = Foo.Node x
    in
    y

type Msg = A | B
"#;

#[test]
fn elm_module_and_exposing() {
    let f = facts("elm", ELM);
    assert_eq!(f.module_name.as_deref(), Some("Foo.Bar"));
    assert!(sym(&f, "toString").exported);
    assert!(!sym(&f, "helper").exported);
    assert!(sym(&f, "Value").exported);
    assert!(sym(&f, "Alias").exported);
    assert!(!sym(&f, "Msg").exported);
    // `Value(..)` exposes constructors, plain `Alias` does not matter here, `Msg` is not exposed.
    assert!(sym(&f, "Node").exported);
    assert!(!sym(&f, "A").exported);
}

#[test]
fn elm_definitions_and_kinds() {
    let f = facts("elm", ELM);
    assert_eq!(sym(&f, "toString").kind, SymbolKind::Function);
    assert_eq!(sym(&f, "toString").signature.as_deref(), Some("toString : Value -> String"));
    assert_eq!(sym(&f, "Value").kind, SymbolKind::Enum);
    assert_eq!(sym(&f, "Alias").kind, SymbolKind::TypeAlias);
    assert_eq!(sym(&f, "sendIt").kind, SymbolKind::Port);
    let node = sym(&f, "Node");
    assert_eq!(node.kind, SymbolKind::Constructor);
    assert_eq!(f.symbols[node.parent.unwrap() as usize].name, "Value");
    assert_eq!(sym(&f, "a").kind, SymbolKind::Field);
    assert_eq!(sym(&f, "a").parent, Some(sym(&f, "Alias").local_id));
    assert_eq!(sym(&f, "toString").start_line, 17);
}

#[test]
fn elm_imports() {
    let f = facts("elm", ELM);
    assert_eq!(f.imports.len(), 3);
    let d = f.imports.iter().find(|i| i.specifier == "Json.Decode").unwrap();
    assert_eq!(d.alias.as_deref(), Some("D"));
    assert_eq!(d.names.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), ["Decoder", "field", "Value"]);
    let baz = f.imports.iter().find(|i| i.specifier == "Foo.Baz").unwrap();
    assert_eq!(baz.names[0].name, "*");
}

#[test]
fn elm_qualified_references() {
    let f = facts("elm", ELM);
    assert!(has_ref(&f, Some("List"), "map"));
    assert!(has_ref(&f, Some("String"), "fromInt"));
    assert!(has_ref(&f, Some("V"), "Value"), "type refs keep their qualifier");
    assert!(has_ref(&f, Some("Foo"), "Node"));
    // function params, pattern variables and let bindings are locals, not references
    assert!(!has_ref(&f, None, "v"));
    assert!(!has_ref(&f, None, "xs"));
    assert!(!has_ref(&f, None, "y"));
    // the recursive mention of a top-level function is a real reference
    assert!(has_ref(&f, None, "toString"));
    let call = f.refs.iter().find(|r| r.name == "fromInt").unwrap();
    assert_eq!(call.kind, RefKind::Call);
    assert_eq!(call.enclosing, Some(sym(&f, "toString").local_id));
}

const RS: &str = r#"
use crate::store::{open, Store as S};
use std::io::*;
pub mod inner { pub fn x() {} }
mod child;
pub struct Foo { pub a: Bar, b: u8 }
pub enum E { A(Foo), B { x: i32 } }
pub trait T: Sized { fn m(&self) -> Foo; fn d(&self) {} }
impl T for Foo { fn m(&self) -> Foo { helper(); self.go(); store::open(1); Self::new() } }
impl Foo { pub fn new() -> Self { Foo { a: 1 } } }
const K: u32 = 1;
type Al = Vec<Foo>;
"#;

#[test]
fn rust_definitions() {
    let f = facts("rust", RS);
    assert_eq!(sym(&f, "Foo").kind, SymbolKind::Struct);
    assert!(sym(&f, "Foo").exported);
    assert_eq!(sym(&f, "E").kind, SymbolKind::Enum);
    assert_eq!(sym(&f, "T").kind, SymbolKind::Trait);
    assert_eq!(sym(&f, "K").kind, SymbolKind::Const);
    assert_eq!(sym(&f, "Al").kind, SymbolKind::TypeAlias);
    assert_eq!(sym(&f, "inner").kind, SymbolKind::Module);
    let x = sym(&f, "x");
    assert_eq!(f.symbols[x.parent.unwrap() as usize].name, "inner");
    let new = sym(&f, "new");
    assert_eq!(new.kind, SymbolKind::Method);
    assert_eq!(f.symbols[new.parent.unwrap() as usize].kind, SymbolKind::Impl);
    assert_eq!(sym(&f, "a").kind, SymbolKind::Field);
    assert_eq!(sym(&f, "A").kind, SymbolKind::Constructor);
    assert_eq!(sym(&f, "B").parent, Some(sym(&f, "E").local_id));
}

#[test]
fn rust_imports_and_mod_decls() {
    let f = facts("rust", RS);
    let store = f.imports.iter().find(|i| i.specifier == "crate::store").unwrap();
    let names: Vec<_> = store.names.iter().map(|n| (n.name.as_str(), n.alias.as_deref())).collect();
    assert_eq!(names, [("open", None), ("Store", Some("S"))]);
    let io = f.imports.iter().find(|i| i.specifier == "std::io").unwrap();
    assert_eq!(io.names[0].name, "*");
    let m = f.imports.iter().find(|i| i.kind == ImportKind::ModDecl).unwrap();
    assert_eq!(m.specifier, "child");
}

#[test]
fn rust_references_and_hierarchy() {
    let f = facts("rust", RS);
    assert!(has_ref(&f, None, "helper"));
    assert!(has_ref(&f, Some("self"), "go"));
    assert!(has_ref(&f, Some("store"), "open"));
    assert!(has_ref(&f, Some("Self"), "new"));
    assert!(has_ref(&f, None, "Bar"), "field type use");
    let imp = f.symbols.iter().find(|s| s.kind == SymbolKind::Impl && s.name == "Foo").unwrap();
    assert!(f.hierarchy.iter().any(|h| h.symbol == imp.local_id && h.target == "T" && h.kind == HierarchyKind::Implements));
    assert!(f.hierarchy.iter().any(|h| h.target == "Sized" && h.kind == HierarchyKind::Extends));
}

const TS: &str = r#"
import def, { a, b as c } from './x';
import * as ns from "../y";
export { q } from './q';
export interface I extends J { m(): void; p: number }
export abstract class K<T> extends B implements I, L {
  private f: number = 1;
  constructor(x: number) { super(); }
  m(): Foo { return helper(this.f, ns.go(), new Bar()); }
}
export const arrow = (x: number): Foo => other(x);
const hidden = 5;
export function top<T>(x: T): T { return x }
export type Al = Foo<Bar>;
export enum En { A, B }
namespace NS { export const z = 1 }
const m = require('./cjs');
function inner() { function nested() {} }
export { hidden };
"#;

#[test]
fn typescript_definitions() {
    let f = facts("typescript", TS);
    assert_eq!(sym(&f, "I").kind, SymbolKind::Interface);
    assert_eq!(sym(&f, "K").kind, SymbolKind::Class);
    assert!(sym(&f, "K").exported);
    assert_eq!(sym(&f, "arrow").kind, SymbolKind::Function);
    assert!(sym(&f, "arrow").exported);
    assert_eq!(sym(&f, "hidden").kind, SymbolKind::Const);
    assert!(sym(&f, "hidden").exported, "export {{ hidden }} marks it exported");
    assert_eq!(sym(&f, "top").kind, SymbolKind::Function);
    assert_eq!(sym(&f, "Al").kind, SymbolKind::TypeAlias);
    assert_eq!(sym(&f, "En").kind, SymbolKind::Enum);
    assert_eq!(sym(&f, "A").kind, SymbolKind::Constructor);
    assert_eq!(sym(&f, "NS").kind, SymbolKind::Module);
    assert_eq!(sym(&f, "z").parent, Some(sym(&f, "NS").local_id));
    let k = sym(&f, "K").local_id;
    assert!(f.symbols.iter().any(|s| s.name == "m" && s.kind == SymbolKind::Method && s.parent == Some(k)));
    assert_eq!(sym(&f, "f").kind, SymbolKind::Field);
    assert!(f.symbols.iter().all(|s| s.name != "nested"), "functions inside bodies are not indexed");
}

#[test]
fn typescript_imports_refs_hierarchy() {
    let f = facts("typescript", TS);
    let x = f.imports.iter().find(|i| i.specifier == "./x").unwrap();
    assert_eq!(x.names[0].name, "default");
    assert_eq!(x.names[0].alias.as_deref(), Some("def"));
    assert_eq!(x.names[2].name, "b");
    assert_eq!(x.names[2].alias.as_deref(), Some("c"));
    let y = f.imports.iter().find(|i| i.specifier == "../y").unwrap();
    assert_eq!(y.alias.as_deref(), Some("ns"));
    assert!(f.imports.iter().any(|i| i.specifier == "./q" && i.kind == ImportKind::Reexport));
    assert!(f.imports.iter().any(|i| i.specifier == "./cjs" && i.alias.as_deref() == Some("m")));
    assert!(has_ref(&f, None, "helper"));
    assert!(has_ref(&f, Some("ns"), "go"));
    assert!(has_ref(&f, None, "Bar"));
    assert!(has_ref(&f, None, "other"));
    let k = sym(&f, "K").local_id;
    assert!(f.hierarchy.iter().any(|h| h.symbol == k && h.target == "B" && h.kind == HierarchyKind::Extends));
    assert!(f.hierarchy.iter().any(|h| h.symbol == k && h.target == "L" && h.kind == HierarchyKind::Implements));
    let i = sym(&f, "I").local_id;
    assert!(f.hierarchy.iter().any(|h| h.symbol == i && h.target == "J"));
}

#[test]
fn tsx_and_javascript() {
    let tsx = facts("tsx", "import {Button} from './Button';\nexport const App = () => <Button label=\"x\" />;\n");
    assert_eq!(sym(&tsx, "App").kind, SymbolKind::Function);
    assert!(has_ref(&tsx, None, "Button"), "JSX element names are references");

    let js = facts(
        "javascript",
        "const u = require('./util');\nclass A extends B { go() { return u.run(); } }\nmodule.exports = { A };\nfunction f() { return helper(); }\n",
    );
    assert_eq!(sym(&js, "A").kind, SymbolKind::Class);
    assert_eq!(sym(&js, "go").kind, SymbolKind::Method);
    assert_eq!(sym(&js, "f").kind, SymbolKind::Function);
    assert!(js.imports.iter().any(|i| i.specifier == "./util"));
    assert!(js.hierarchy.iter().any(|h| h.target == "B"));
    assert!(has_ref(&js, Some("u"), "run"));
}

#[test]
fn extension_routing() {
    use std::path::Path;
    assert_eq!(lang::for_path(Path::new("a/B.elm")).unwrap().id(), "elm");
    assert_eq!(lang::for_path(Path::new("a/b.tsx")).unwrap().id(), "tsx");
    assert_eq!(lang::for_path(Path::new("a/b.ts")).unwrap().id(), "typescript");
    assert_eq!(lang::for_path(Path::new("a/b.mjs")).unwrap().id(), "javascript");
    assert!(lang::for_path(Path::new("a/b.png")).is_none());
}
