//! Swift has no file imports: files of one module see each other, so a reference resolves by name
//! within the module (and the modules it imports) and that resolution is the dependency edge.

mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::facts::SymbolKind;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::query::{Direction, NameMatch};
use std::path::Path;
use std::sync::Arc;

fn graph_of(repo: &Repo) -> (tempfile::TempDir, Engine, Arc<ViewGraph>) {
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&repo.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    (dir, e, g)
}

fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).to_string_lossy().to_string()
}

fn deps(g: &ViewGraph, r: &Repo, file: &str, dir: Direction) -> Vec<String> {
    let mut v: Vec<String> = g.file_deps(&r.root.join(file), dir, 1).data.unwrap().iter().map(|d| rel(&r.root, &d.path)).collect();
    v.sort();
    v
}

fn fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "Sources/App/Store.swift", "public final class Store {\n    func reload() {\n        Loader.fetch()\n        helper()\n    }\n}\n");
    write(&r.root, "Sources/App/Store+More.swift", "extension Store {\n    func more() { reload() }\n}\n");
    write(&r.root, "Sources/App/Loader.swift", "enum Loader {\n    static func fetch() {}\n}\n");
    write(&r.root, "Sources/App/Util.swift", "func helper() {}\n");
    write(&r.root, "Sources/App/UsesKit.swift", "import Kit\nfunc k() -> Kit { Kit() }\n");
    write(&r.root, "Sources/Other/Same.swift", "struct Store {}\n");
    write(&r.root, "Sources/Other/Thing.swift", "import App\nstruct Thing { let s: Store }\n");
    write(&r.root, "Packages/Kit/Sources/Kit/Kit.swift", "public struct Kit {}\n");
    write(&r.root, "Tests/AppTests/StoreTests.swift", "@testable import App\nfinal class StoreTests {\n    func t() { Store().reload() }\n}\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn files_of_one_module_depend_on_each_other_without_any_import() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(
        deps(&g, &r, "Sources/App/Store.swift", Direction::Out),
        ["Sources/App/Loader.swift", "Sources/App/Util.swift"],
        "a type used through `Loader.fetch()` and a top-level function"
    );
    assert_eq!(
        deps(&g, &r, "Sources/App/Store.swift", Direction::In),
        ["Sources/App/Store+More.swift", "Tests/AppTests/StoreTests.swift"],
        "the extension's file and the test through `@testable import App`; Other's own `Store` is not this one"
    );
    assert_eq!(deps(&g, &r, "Sources/App/Store+More.swift", Direction::Out), ["Sources/App/Store.swift"]);
}

#[test]
fn a_module_sees_only_itself_and_what_it_imports() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(deps(&g, &r, "Sources/Other/Thing.swift", Direction::Out), ["Sources/Other/Same.swift"], "its own `Store` shadows the imported one");
    assert_eq!(deps(&g, &r, "Sources/App/UsesKit.swift", Direction::Out), ["Packages/Kit/Sources/Kit/Kit.swift"], "`import Kit` reaches the package target");
    assert_eq!(deps(&g, &r, "Tests/AppTests/StoreTests.swift", Direction::Out), ["Sources/App/Store.swift"]);
}

#[test]
fn resolution_is_exact_when_the_module_decides_and_marked_when_it_guesses() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    let fetch = g.find_symbols(&NameMatch::Exact("fetch".into()), None, 5).data;
    let refs = g.references(fetch[0].id).data;
    assert!(refs.iter().any(|h| h.path.ends_with("Store.swift") && h.confidence == Confidence::Exact), "Loader.fetch: {refs:?}");
    let helper = g.find_symbols(&NameMatch::Exact("helper".into()), None, 5).data;
    assert!(g.references(helper[0].id).data.iter().all(|h| h.confidence == Confidence::Exact), "a unique top-level function in the module");
    // `Store().reload()` has an expression for a receiver, typed `Store` by its initialiser.
    let reload = g.find_symbols(&NameMatch::Exact("reload".into()), None, 5).data;
    let refs = g.references(reload[0].id).data;
    let from_test = refs.iter().find(|h| h.path.ends_with("StoreTests.swift")).expect("reload called from the test");
    assert_eq!(from_test.confidence, Confidence::Inferred);
    // `reload()` inside the extension is a member of the enclosing type, in another file.
    let from_ext = refs.iter().find(|h| h.path.ends_with("Store+More.swift")).expect("reload called from the extension");
    assert_eq!(from_ext.confidence, Confidence::Exact);
}

#[test]
fn the_class_and_its_extensions_are_distinct_definitions_and_references_see_both() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    let all = g.find_symbols(&NameMatch::Exact("Store".into()), None, 10).data;
    let kinds = |p: &str| all.iter().filter(|h| h.path.ends_with(p)).map(|h| h.kind).collect::<Vec<_>>();
    assert_eq!(kinds("App/Store.swift"), [SymbolKind::Class]);
    assert_eq!(kinds("Store+More.swift"), [SymbolKind::Extension]);
    let class = all.iter().find(|h| h.path.ends_with("App/Store.swift")).unwrap();
    let from: Vec<String> = g.references(class.id).data.iter().map(|h| rel(&r.root, &h.path)).collect();
    assert!(from.contains(&"Sources/App/Store+More.swift".to_string()), "the extension names the type it extends: {from:?}");
    assert!(from.contains(&"Tests/AppTests/StoreTests.swift".to_string()));
}

/// The overlay path must give exactly the answer a full rebuild of the same content gives.
fn assert_overlay_equals_full(r: &Repo, edit: impl Fn(&Path)) -> Arc<ViewGraph> {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let base_view = e.view_for_path(&r.root).unwrap();
    e.build(&base_view, &[], |_| {}).unwrap();
    let base = e.graph(&base_view).unwrap();
    edit(&r.root);
    let dirty_view = e.view_for_path(&r.root).unwrap();
    e.build(&dirty_view, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty_view).unwrap();
    assert_ne!(base.fingerprint(), incremental.fingerprint(), "the edit must change something");
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
    incremental
}

#[test]
fn overlay_adding_a_file_to_a_module_resolves_names_that_had_no_definition() {
    let r = init_repo();
    write(&r.root, "Sources/App/A.swift", "struct A { let b: Later }\n");
    commit_all(&r.root, "init");
    let g = assert_overlay_equals_full(&r, |root| write(root, "Sources/App/Later.swift", "struct Later {}\n"));
    assert_eq!(deps(&g, &r, "Sources/App/A.swift", Direction::Out), ["Sources/App/Later.swift"]);
}

// ---- receiver typing ---------------------------------------------------------------------
//
// `recv.m()` with an expression receiver: the ladder types `recv` from the file's own
// declarations (self, a local or parameter binding, an implicit-self property, a chain through
// property and return types) and looks `m` up on that type and its supertypes.

const MODELS: &str = "\
final class Engine {
    func start() {}
    static func make() -> Engine { Engine() }
}
final class Car {
    let engine: Engine
    var spare = Engine()
    func drive() {}
    func wash() {}
}
final class Boat {
    func start() {}
    func drive() {}
}
protocol Vehicle {}
extension Vehicle {
    func honk() {}
}
struct Bike: Vehicle {}
final class Garage {
    var cars: [Car] = []
    let car: Car
    func makeCar() -> Car { car }
}
";

const USES: &str = "\
func param(c: Car) {
    c.drive() // @param
}
func local() {
    let c = Car(engine: Engine())
    c.drive() // @init
    let b = Boat.init()
    b.drive() // @dotinit
    let e = Engine.make()
    e.start() // @static_ret
}
func guarded(o: Car?) {
    guard let c = o else { return }
    c.drive() // @guard
}
func loop(g: Garage) {
    for c in g.cars {
        c.drive() // @for
    }
}
extension Car {
    func viaSelfProp() {
        engine.start() // @implicit_self
        self.spare.start() // @self_chain
    }
}
func chain(g: Garage) {
    g.car.engine.start() // @chain
}
func returned(g: Garage) {
    let c = g.makeCar()
    c.drive() // @ret
}
func shadow(c: Boat) {
    [1].forEach { c in c.wash() } // @shadow
}
func external(d: Date) {
    d.wash() // @external
}
func proto(b: Bike) {
    b.honk() // @proto
}
";

fn line_of(src: &str, marker: &str) -> u32 {
    src.lines().position(|l| l.contains(marker)).unwrap_or_else(|| panic!("no {marker}")) as u32 + 1
}

/// Where the reference named `name` on `line` of `file` resolved: `Owner.member` and confidence.
fn resolved(g: &ViewGraph, r: &Repo, file: &str, line: u32, name: &str) -> (Option<String>, Confidence) {
    let f = g.file_idx(&r.root.join(file)).expect("file indexed");
    let node = g.file(f);
    let i = node.facts.refs.iter().position(|x| x.line == line && x.name == name).unwrap_or_else(|| panic!("no ref {name} at {file}:{line}"));
    let rr = &g.resolution(f).refs[i];
    let target = rr.target.map(|id| {
        let t = g.file(id.file);
        let s = t.symbol(id.local);
        let owner = s.parent.map(|p| t.symbol(p).name.clone()).unwrap_or_default();
        format!("{owner}.{}", s.name)
    });
    (target, rr.confidence)
}

fn receiver_fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "Sources/App/Models.swift", MODELS);
    write(&r.root, "Sources/App/Uses.swift", USES);
    commit_all(&r.root, "init");
    r
}

fn assert_typed(g: &ViewGraph, r: &Repo, marker: &str, name: &str, want: &str) {
    let got = resolved(g, r, "Sources/App/Uses.swift", line_of(USES, marker), name);
    assert_eq!(got, (Some(want.to_string()), Confidence::Inferred), "{marker}");
}

#[test]
fn a_parameter_type_types_the_receiver() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_typed(&g, &r, "@param", "drive", "Car.drive");
}

#[test]
fn a_local_initialised_with_a_type_types_the_receiver() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_typed(&g, &r, "@init", "drive", "Car.drive");
    assert_typed(&g, &r, "@dotinit", "drive", "Boat.drive");
}

#[test]
fn guard_let_and_for_over_an_array_type_the_binding() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_typed(&g, &r, "@guard", "drive", "Car.drive");
    assert_typed(&g, &r, "@for", "drive", "Car.drive");
}

#[test]
fn an_implicit_self_property_and_a_chain_type_the_receiver() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_typed(&g, &r, "@implicit_self", "start", "Engine.start");
    assert_typed(&g, &r, "@self_chain", "start", "Engine.start");
    assert_typed(&g, &r, "@chain", "start", "Engine.start");
}

#[test]
fn a_function_return_type_types_the_receiver() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_typed(&g, &r, "@ret", "drive", "Car.drive");
    assert_typed(&g, &r, "@static_ret", "start", "Engine.start");
}

#[test]
fn a_closure_parameter_shadows_the_outer_binding_and_stays_untyped() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    // Typed as the outer `c: Boat` it would find no `wash` and give nothing; untyped, the unique
    // member name is the labelled guess it always was.
    let got = resolved(&g, &r, "Sources/App/Uses.swift", line_of(USES, "@shadow"), "wash");
    assert_eq!(got, (Some("Car.wash".into()), Confidence::Fallback));
}

#[test]
fn a_receiver_of_a_type_the_repository_does_not_define_has_no_target() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    let got = resolved(&g, &r, "Sources/App/Uses.swift", line_of(USES, "@external"), "wash");
    assert_eq!(got.0, None, "`Date` has no `wash`; the unique `Car.wash` is not it");
}

#[test]
fn a_member_from_a_protocol_extension_is_found_through_the_conformance() {
    let r = receiver_fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_typed(&g, &r, "@proto", "honk", "Vehicle.honk");
}

#[test]
fn an_extension_in_a_module_the_file_cannot_see_is_not_a_member() {
    let r = init_repo();
    write(&r.root, "Packages/Kit/Sources/Kit/Handle.swift", "import Foundation\nextension FileHandle {\n    func pump() {}\n}\n");
    write(&r.root, "Sources/App/A.swift", "import Foundation\nfunc a(f: FileHandle) {\n    f.pump()\n}\n");
    write(&r.root, "Sources/Tools/T.swift", "import Kit\nfunc t(f: FileHandle) {\n    f.pump()\n}\n");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(resolved(&g, &r, "Sources/App/A.swift", 3, "pump").0, None, "App does not import Kit");
    assert_eq!(resolved(&g, &r, "Sources/Tools/T.swift", 3, "pump"), (Some("FileHandle.pump".into()), Confidence::Inferred));
}

#[test]
fn a_receiver_guess_keeps_its_reference_but_draws_no_file_edge() {
    let r = init_repo();
    write(&r.root, "Sources/App/Car.swift", "final class Car {\n    func wash() {}\n}\n");
    write(&r.root, "Sources/App/Guess.swift", "func g() {\n    unknown().wash()\n}\n");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(resolved(&g, &r, "Sources/App/Guess.swift", 2, "wash"), (Some("Car.wash".into()), Confidence::Fallback));
    assert!(deps(&g, &r, "Sources/App/Guess.swift", Direction::Out).is_empty(), "a name guess is not a dependency");
}

#[test]
fn overlay_changing_a_property_type_retypes_receivers_in_other_files() {
    let r = init_repo();
    write(&r.root, "Sources/App/Models.swift", MODELS);
    write(&r.root, "Sources/App/Holder.swift", "final class Holder {\n    let item: Car\n}\n");
    write(&r.root, "Sources/App/Use.swift", "func f(h: Holder) {\n    h.item.drive()\n}\n");
    commit_all(&r.root, "init");
    let g = assert_overlay_equals_full(&r, |root| write(root, "Sources/App/Holder.swift", "final class Holder {\n    let item: Boat\n}\n"));
    assert_eq!(resolved(&g, &r, "Sources/App/Use.swift", 2, "drive"), (Some("Boat.drive".into()), Confidence::Inferred));
}

#[test]
fn super_is_the_superclass_and_a_platform_superclass_gives_no_target() {
    let r = init_repo();
    write(&r.root, "Sources/App/Views.swift", "\
class Base {
    func paint() {}
}
final class Fancy: Base {
    override func paint() {
        super.paint()
    }
}
final class Field: NSTextView {
    override func moveLeft(_ s: Any?) {
        super.moveLeft(s)
    }
}
");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    let p = "Sources/App/Views.swift";
    assert_eq!(resolved(&g, &r, p, 6, "paint"), (Some("Base.paint".into()), Confidence::Inferred), "the superclass's, not the override");
    assert_eq!(resolved(&g, &r, p, 11, "moveLeft").0, None, "AppKit's `moveLeft`, not the override it is called from");
}

#[test]
fn a_member_of_a_type_the_repository_does_not_declare_is_not_a_repository_member() {
    let r = init_repo();
    write(&r.root, "Sources/App/Card.swift", "\
struct Card {
    func frame() {}
    func make() {
        Text(\"x\").font(.body).frame()
    }
}
");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    // `Text(..).font(..)` is SwiftUI's; its `frame` is SwiftUI's, not the unique `Card.frame`.
    assert_eq!(resolved(&g, &r, "Sources/App/Card.swift", 4, "frame").0, None);
}

#[test]
fn overlay_declaring_a_type_a_property_already_named_retypes_receivers_through_it() {
    let r = init_repo();
    write(&r.root, "Sources/App/Card.swift", "struct Card {\n    func frame() {}\n}\n");
    write(&r.root, "Sources/App/Holder.swift", "final class Holder {\n    let item: Label\n}\n");
    write(&r.root, "Sources/App/Use.swift", "func f(h: Holder) {\n    h.item.font().frame()\n}\n");
    commit_all(&r.root, "init");
    // `Label` was the platform's (no target for `frame`); once the repository declares it, its
    // `font()` is unknown and `frame` is a labelled guess again, in the overlay as in a rebuild.
    let g = assert_overlay_equals_full(&r, |root| write(root, "Sources/App/Label.swift", "struct Label {}\n"));
    assert_eq!(resolved(&g, &r, "Sources/App/Use.swift", 2, "frame"), (Some("Card.frame".into()), Confidence::Fallback));
}
