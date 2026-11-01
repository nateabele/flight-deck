//! Swift extractor behaviour on an inline source.

use flightindex::facts::*;
use flightindex::lang;

const SRC: &str = r#"import Foundation
@testable import FlightDeck

public final class Store: Base, Proto {
    public var name: String = ""
    let x = 1, y = 2
    private static let shared = Store()
    public init(a: Int) {}
    func go(_ a: Int) -> Foo { Foo.make(a); helper(); store.reload(); self.more() }
    enum Kind: String { case a, b(Int) }
    typealias ID = String
    subscript(i: Int) -> Int { 0 }
    deinit {}
    private func secret() {}
    var computed: Int { items.count + Util.zero }
}
extension Store: Other { func more() {} }
private extension Store { func hidden() {} }
protocol Proto: Q { func req(); var v: Int { get } }
actor A {}
struct S: Codable { var a: [Foo] }
func free(cb: () -> Void) { cb(); local() }
let topLevel = 1
var topVar = 2
"#;

fn facts() -> BlobFacts {
    lang::by_id("swift").expect("swift registered").extract(SRC)
}

fn sym<'a>(f: &'a BlobFacts, name: &str) -> &'a Symbol {
    f.symbols.iter().find(|s| s.name == name).unwrap_or_else(|| panic!("no symbol {name}: {:?}", f.symbols.iter().map(|s| (&s.name, s.kind)).collect::<Vec<_>>()))
}

fn has_ref(f: &BlobFacts, q: Option<&str>, name: &str, kind: RefKind) -> bool {
    f.refs.iter().any(|r| r.name == name && r.qualifier.as_deref() == q && r.kind == kind)
}

fn parent_name<'a>(f: &'a BlobFacts, s: &Symbol) -> &'a str {
    &f.symbols[s.parent.expect("has a parent") as usize].name
}

#[test]
fn swift_is_registered() {
    assert_eq!(lang::for_path(std::path::Path::new("Sources/A/B.swift")).map(|l| l.id()), Some("swift"));
}

#[test]
fn an_extension_is_its_own_kind_not_a_second_class() {
    let f = facts();
    let stores: Vec<(SymbolKind, bool)> = f.symbols.iter().filter(|s| s.name == "Store").map(|s| (s.kind, s.exported)).collect();
    assert_eq!(stores, [(SymbolKind::Class, true), (SymbolKind::Extension, true), (SymbolKind::Extension, false)]);
    let ext = f.symbols.iter().find(|s| s.kind == SymbolKind::Extension).unwrap();
    assert_eq!(ext.signature.as_deref(), Some("extension Store: Other"));
    // The extended type is a reference from the extension, which is what links the two files.
    assert!(f.refs.iter().any(|r| r.name == "Store" && r.kind == RefKind::Type && r.enclosing == Some(ext.local_id)));
}

#[test]
fn members_get_kinds_nesting_and_signatures() {
    let f = facts();
    let go = sym(&f, "go");
    assert_eq!((go.kind, parent_name(&f, go)), (SymbolKind::Method, "Store"));
    assert_eq!(go.signature.as_deref(), Some("func go(_ a: Int) -> Foo"));
    assert_eq!(sym(&f, "init").kind, SymbolKind::Method);
    assert_eq!(sym(&f, "deinit").kind, SymbolKind::Method);
    assert_eq!(sym(&f, "subscript").kind, SymbolKind::Method);
    for field in ["name", "x", "y", "shared", "computed"] {
        assert_eq!(sym(&f, field).kind, SymbolKind::Field, "{field}");
    }
    assert_eq!(sym(&f, "name").signature.as_deref(), Some("public var name: String"));
    let kind = sym(&f, "Kind");
    assert_eq!((kind.kind, parent_name(&f, kind)), (SymbolKind::Enum, "Store"));
    for case in ["a", "b"] {
        let c = sym(&f, case);
        assert_eq!((c.kind, parent_name(&f, c)), (SymbolKind::Constructor, "Kind"));
    }
    assert_eq!(sym(&f, "ID").kind, SymbolKind::TypeAlias);
    assert_eq!(sym(&f, "A").kind, SymbolKind::Class, "an actor is a class for our purposes");
    assert_eq!(sym(&f, "S").kind, SymbolKind::Struct);
    assert_eq!(sym(&f, "free").kind, SymbolKind::Function);
    assert_eq!(sym(&f, "topLevel").kind, SymbolKind::Const);
    assert_eq!(sym(&f, "topVar").kind, SymbolKind::Variable);
    let proto = sym(&f, "Proto");
    assert_eq!(proto.kind, SymbolKind::Trait);
    assert_eq!(sym(&f, "req").kind, SymbolKind::Method);
    assert_eq!(parent_name(&f, sym(&f, "req")), "Proto");
    assert_eq!(sym(&f, "v").kind, SymbolKind::Field);
}

#[test]
fn access_modifiers_decide_exported_and_default_internal_is_exported() {
    let f = facts();
    assert!(sym(&f, "go").exported, "internal by default");
    assert!(sym(&f, "name").exported);
    assert!(!sym(&f, "secret").exported);
    assert!(!sym(&f, "shared").exported);
    assert!(sym(&f, "more").exported);
    assert!(!sym(&f, "hidden").exported, "members of a private extension are private");
}

#[test]
fn inheritance_conformance_and_extensions_are_hierarchy_facts() {
    let f = facts();
    let rel = |name: &str| -> Vec<(String, HierarchyKind)> {
        let ids: Vec<u32> = f.symbols.iter().filter(|s| s.name == name).map(|s| s.local_id).collect();
        f.hierarchy.iter().filter(|h| ids.contains(&h.symbol)).map(|h| (h.target.clone(), h.kind)).collect()
    };
    assert_eq!(rel("Store"), [("Base".into(), HierarchyKind::Extends), ("Proto".into(), HierarchyKind::Implements), ("Other".into(), HierarchyKind::Implements)]);
    assert_eq!(rel("Proto"), [("Q".into(), HierarchyKind::Extends)]);
    assert_eq!(rel("S"), [("Codable".into(), HierarchyKind::Implements)]);
}

#[test]
fn imports_are_module_imports() {
    let f = facts();
    let specs: Vec<&str> = f.imports.iter().map(|i| i.specifier.as_str()).collect();
    assert_eq!(specs, ["Foundation", "FlightDeck"]);
}

#[test]
fn calls_type_uses_and_qualified_members_are_references() {
    let f = facts();
    assert!(has_ref(&f, None, "helper", RefKind::Call));
    assert!(has_ref(&f, Some("Foo"), "make", RefKind::Call));
    assert!(has_ref(&f, None, "Foo", RefKind::Use), "the type a static call goes through");
    assert!(has_ref(&f, None, "Foo", RefKind::Type), "return type and array element");
    assert!(has_ref(&f, None, "Base", RefKind::Type));
    assert!(has_ref(&f, Some("store"), "reload", RefKind::Call));
    assert!(has_ref(&f, Some("self"), "more", RefKind::Call));
    assert!(has_ref(&f, Some("Util"), "zero", RefKind::Use), "Type.member used as a value");
    assert!(!f.refs.iter().any(|r| r.name == "count"), "a member of a lowercase receiver that is not a call is not recorded");
    assert!(!f.refs.iter().any(|r| r.name == "String" || r.name == "Int"), "primitives are not worth a reference");
    let go = sym(&f, "go").local_id;
    assert_eq!(f.refs.iter().find(|r| r.name == "helper").unwrap().enclosing, Some(go));
}

#[test]
fn a_parameter_called_like_a_function_is_not_a_call_to_a_definition() {
    let f = facts();
    assert!(!f.refs.iter().any(|r| r.name == "cb"), "`cb` is a parameter");
    assert!(has_ref(&f, None, "local", RefKind::Call));
}
