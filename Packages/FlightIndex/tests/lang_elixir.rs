//! Elixir extractor behaviour on an inline source.

use flightindex::facts::*;
use flightindex::lang;

const SRC: &str = r#"defmodule Foo.Bar do
  @moduledoc "x"
  @behaviour Access
  alias Foo.{A, B.C}
  alias Other.Thing, as: T
  import Enum, only: [map: 2]
  require Logger
  use GenServer

  defmodule Baz do
    defstruct [:a, :b]
    def make, do: %__MODULE__{}
  end

  @type t :: %__MODULE__{}
  @typep hidden :: integer
  @spec run(integer) :: :ok
  def run(x) when is_integer(x), do: T.go(x)
  def run(_), do: helper(1)

  defp helper(a, b \\ 2) do
    %A{x: 1}
    Logger.info("x")
    Baz.make()
    C.thing()
    unknown_local()
  end
  defmacro mm(x), do: x
  defmacrop hidden_mm(x), do: x
  def short, do: :ok
  def short(a), do: a
end

defprotocol Sized do
  def size(x)
end

defimpl Sized, for: Foo.Bar do
  def size(_), do: 1
end
"#;

fn facts() -> BlobFacts {
    lang::by_id("elixir").expect("elixir registered").extract(SRC)
}

fn sym<'a>(f: &'a BlobFacts, name: &str) -> &'a Symbol {
    f.symbols.iter().find(|s| s.name == name).unwrap_or_else(|| panic!("no symbol {name}: {:?}", f.symbols.iter().map(|s| (&s.name, s.kind)).collect::<Vec<_>>()))
}

fn has_ref(f: &BlobFacts, q: Option<&str>, name: &str, kind: RefKind) -> bool {
    f.refs.iter().any(|r| r.name == name && r.qualifier.as_deref() == q && r.kind == kind)
}

#[test]
fn elixir_is_registered_for_ex_and_exs() {
    for p in ["lib/a.ex", "test/a_test.exs"] {
        assert_eq!(lang::for_path(std::path::Path::new(p)).map(|l| l.id()), Some("elixir"), "{p}");
    }
}

#[test]
fn nested_modules_get_their_full_dotted_name_and_parent() {
    let f = facts();
    let outer = sym(&f, "Foo.Bar");
    assert_eq!(outer.kind, SymbolKind::Module);
    assert_eq!(outer.parent, None);
    let inner = sym(&f, "Foo.Bar.Baz");
    assert_eq!(inner.kind, SymbolKind::Module);
    assert_eq!(inner.parent, Some(outer.local_id));
    assert_eq!((inner.start_line, inner.end_line), (10, 13));
}

#[test]
fn clauses_of_one_function_collapse_into_one_symbol_spanning_all_of_them() {
    let f = facts();
    let runs: Vec<&Symbol> = f.symbols.iter().filter(|s| s.name == "run").collect();
    assert_eq!(runs.len(), 1);
    let run = runs[0];
    assert_eq!(run.kind, SymbolKind::Function);
    assert_eq!((run.start_line, run.end_line), (18, 19));
    assert!(run.exported);
    assert_eq!(f.symbols[run.parent.unwrap() as usize].name, "Foo.Bar");
    let sig = run.signature.as_deref().unwrap();
    assert!(sig.starts_with("def run/1"), "{sig}");
    assert!(sig.contains("@spec run(integer) :: :ok"), "the spec rides along: {sig}");
    // Different arity is a different function.
    assert_eq!(f.symbols.iter().filter(|s| s.name == "short").count(), 2);
    assert!(f.symbols.iter().any(|s| s.name == "short" && s.signature.as_deref() == Some("def short/0")));
}

#[test]
fn visibility_defaults_and_macros() {
    let f = facts();
    assert!(!sym(&f, "helper").exported);
    assert_eq!(sym(&f, "helper").signature.as_deref(), Some("defp helper/2"), "a defaulted argument still counts");
    assert_eq!(sym(&f, "mm").kind, SymbolKind::Macro);
    assert!(sym(&f, "mm").exported);
    assert!(!sym(&f, "hidden_mm").exported);
    assert!(sym(&f, "t").exported);
    assert_eq!(sym(&f, "t").kind, SymbolKind::TypeAlias);
    assert!(!sym(&f, "hidden").exported, "@typep is private");
}

#[test]
fn structs_protocols_and_impls() {
    let f = facts();
    let s = sym(&f, "__struct__");
    assert_eq!(s.kind, SymbolKind::Struct);
    assert_eq!(f.symbols[s.parent.unwrap() as usize].name, "Foo.Bar.Baz");
    let fields: Vec<&str> = f.symbols.iter().filter(|x| x.kind == SymbolKind::Field).map(|x| x.name.as_str()).collect();
    assert_eq!(fields, ["a", "b"]);
    assert_eq!(sym(&f, "Sized").kind, SymbolKind::Trait);
    let imp = f.symbols.iter().find(|x| x.kind == SymbolKind::Impl).unwrap();
    assert_eq!(imp.name, "Foo.Bar");
    assert!(f.hierarchy.iter().any(|h| h.symbol == imp.local_id && h.target == "Sized" && h.kind == HierarchyKind::Implements));
    let size_in_impl = f.symbols.iter().find(|x| x.name == "size" && x.parent == Some(imp.local_id)).unwrap();
    assert_eq!(size_in_impl.kind, SymbolKind::Method);
}

#[test]
fn behaviour_is_a_hierarchy_fact() {
    let f = facts();
    let bar = sym(&f, "Foo.Bar").local_id;
    assert!(f.hierarchy.iter().any(|h| h.symbol == bar && h.target == "Access" && h.kind == HierarchyKind::Implements));
}

#[test]
fn imports_cover_alias_forms_import_require_and_use() {
    let f = facts();
    let by = |spec: &str| f.imports.iter().find(|i| i.specifier == spec).unwrap_or_else(|| panic!("no import {spec}: {:?}", f.imports.iter().map(|i| &i.specifier).collect::<Vec<_>>()));
    assert_eq!(by("Foo.A").alias.as_deref(), Some("A"));
    assert_eq!(by("Foo.B.C").alias.as_deref(), Some("C"));
    assert_eq!(by("Other.Thing").alias.as_deref(), Some("T"));
    assert_eq!(by("Enum").names, vec![ImportName::plain("map")]);
    assert_eq!(by("Logger").alias, None);
    assert!(by("GenServer").names.is_empty());
}

#[test]
fn remote_calls_resolve_their_qualifier_through_aliases() {
    let f = facts();
    assert!(has_ref(&f, Some("Other.Thing"), "go", RefKind::Call), "T.go through `as: T`");
    assert!(has_ref(&f, Some("Foo.Bar.Baz"), "make", RefKind::Call), "Baz is aliased by its own nesting");
    assert!(has_ref(&f, Some("Foo.B.C"), "thing", RefKind::Call), "alias Foo.{{A, B.C}}");
    assert!(has_ref(&f, Some("Logger"), "info", RefKind::Call));
    assert!(has_ref(&f, None, "helper", RefKind::Call), "local call");
    let helper = sym(&f, "helper").local_id;
    let r = f.refs.iter().find(|r| r.name == "info").unwrap();
    assert_eq!(r.enclosing, Some(helper));
}

#[test]
fn struct_literals_are_type_references_to_the_expanded_module() {
    let f = facts();
    assert!(has_ref(&f, Some("Foo"), "A", RefKind::Type), "%A{{}} through alias Foo.A");
    assert!(has_ref(&f, Some("Foo.Bar"), "Baz", RefKind::Type), "%__MODULE__{{}} inside Baz is Foo.Bar.Baz");
}

#[test]
fn kernel_and_unknown_local_calls_are_not_recorded() {
    let f = facts();
    assert!(!f.refs.iter().any(|r| r.name == "is_integer"));
    assert!(!f.refs.iter().any(|r| r.name == "unknown_local"), "not defined here, nor imported by name");
}

#[test]
fn scripts_without_a_module_still_extract() {
    let f = lang::by_id("elixir").unwrap().extract("defmodule X do\nend\nIO.puts(X.hi())\n");
    assert_eq!(sym(&f, "X").kind, SymbolKind::Module);
    assert!(has_ref(&f, Some("X"), "hi", RefKind::Call));
}

#[test]
fn a_spec_head_is_a_declaration_not_a_reference_to_itself() {
    let f = facts();
    assert!(!f.refs.iter().any(|r| r.name == "run"), "`@spec run(integer)` names the function it describes");
}
