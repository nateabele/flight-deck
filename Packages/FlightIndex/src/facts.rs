//! What one file says about itself.
//!
//! `BlobFacts` is the only thing the expensive parse step produces, and it is a pure function of
//! `(file bytes, language, parser version)`. Nothing in here may mention a path, a worktree or a
//! commit: the moment a fact depends on where the file lives, two worktrees holding the same blob
//! can no longer share one parse, which is the whole reason the store is keyed by blob. Anything
//! that needs the surrounding tree (which file does this import land on? who calls this?) is
//! derived later, in memory, by `graph`.

use serde::{Deserialize, Serialize};

/// Symbol kinds. The string forms are what the store holds and what tools will print, so they are
/// part of the on-disk contract: add new kinds, never rename.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SymbolKind {
    Function,
    Method,
    Struct,
    Enum,
    Trait,
    Interface,
    Class,
    TypeAlias,
    Const,
    Module,
    Field,
    /// A custom-type constructor (Elm `Node`), enum variant (Rust).
    Constructor,
    Impl,
    Port,
    Macro,
    /// Swift `extension Foo`: adds members to a type declared elsewhere, so it is not a second
    /// class named `Foo`.
    Extension,
    /// A mutable module-level binding (Python `counter = 0`); `Const` is for constants.
    Variable,
}

impl SymbolKind {
    pub fn as_str(self) -> &'static str {
        match self {
            SymbolKind::Function => "function",
            SymbolKind::Method => "method",
            SymbolKind::Struct => "struct",
            SymbolKind::Enum => "enum",
            SymbolKind::Trait => "trait",
            SymbolKind::Interface => "interface",
            SymbolKind::Class => "class",
            SymbolKind::TypeAlias => "type_alias",
            SymbolKind::Const => "const",
            SymbolKind::Module => "module",
            SymbolKind::Field => "field",
            SymbolKind::Constructor => "constructor",
            SymbolKind::Impl => "impl",
            SymbolKind::Port => "port",
            SymbolKind::Macro => "macro",
            SymbolKind::Extension => "extension",
            SymbolKind::Variable => "variable",
        }
    }

    pub fn parse(s: &str) -> Option<SymbolKind> {
        Some(match s {
            "function" => SymbolKind::Function,
            "method" => SymbolKind::Method,
            "struct" => SymbolKind::Struct,
            "enum" => SymbolKind::Enum,
            "trait" => SymbolKind::Trait,
            "interface" => SymbolKind::Interface,
            "class" => SymbolKind::Class,
            "type_alias" => SymbolKind::TypeAlias,
            "const" => SymbolKind::Const,
            "module" => SymbolKind::Module,
            "field" => SymbolKind::Field,
            "constructor" => SymbolKind::Constructor,
            "impl" => SymbolKind::Impl,
            "port" => SymbolKind::Port,
            "macro" => SymbolKind::Macro,
            "extension" => SymbolKind::Extension,
            "variable" => SymbolKind::Variable,
            _ => return None,
        })
    }
}

/// A definition. `local_id` is an index within this blob only (it is the position in
/// `BlobFacts::symbols`), which is what lets two worktrees share the row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Symbol {
    pub local_id: u32,
    pub name: String,
    pub kind: SymbolKind,
    /// 1-based lines, 0-based UTF-8 byte columns (tree-sitter's own columns).
    pub start_line: u32,
    pub start_col: u32,
    pub end_line: u32,
    pub end_col: u32,
    /// The declaration line(s) up to the body, e.g. `toString : Value -> String` for Elm.
    pub signature: Option<String>,
    pub parent: Option<u32>,
    pub exported: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImportKind {
    /// `import`, `use`, `require`.
    Import,
    /// Rust `mod foo;` — a pointer at a child file, not a name binding.
    ModDecl,
    /// `export … from './x'`: no local binding, but the file still depends on the target.
    Reexport,
}

impl ImportKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ImportKind::Import => "import",
            ImportKind::ModDecl => "mod",
            ImportKind::Reexport => "reexport",
        }
    }

    pub fn parse(s: &str) -> ImportKind {
        match s {
            "mod" => ImportKind::ModDecl,
            "reexport" => ImportKind::Reexport,
            _ => ImportKind::Import,
        }
    }
}

/// One name an import brings in. `name` is `"*"` for a glob / `exposing (..)`; `subs` is true for
/// Elm `Type(..)`, which also exposes the type's constructors.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportName {
    pub name: String,
    pub alias: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub subs: bool,
}

impl ImportName {
    pub fn plain(name: impl Into<String>) -> Self {
        ImportName { name: name.into(), alias: None, subs: false }
    }

    /// The name this import makes visible in the importing file.
    pub fn local(&self) -> &str {
        self.alias.as_deref().unwrap_or(&self.name)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Import {
    /// Raw, unresolved: `Json.Decode`, `./util`, `crate::store`.
    pub specifier: String,
    /// `import X as Alias`, `import * as ns`, `import def from`.
    pub alias: Option<String>,
    pub names: Vec<ImportName>,
    pub line: u32,
    pub kind: ImportKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefKind {
    Call,
    /// A type position.
    Type,
    /// Any other mention of the name (passing a function, constructor in a pattern, …).
    Use,
}

impl RefKind {
    pub fn as_str(self) -> &'static str {
        match self {
            RefKind::Call => "call",
            RefKind::Type => "type",
            RefKind::Use => "use",
        }
    }

    pub fn parse(s: &str) -> RefKind {
        match s {
            "call" => RefKind::Call,
            "type" => RefKind::Type,
            _ => RefKind::Use,
        }
    }
}

/// An outgoing reference by name. Resolution to a definition happens in `graph`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reference {
    pub name: String,
    /// `List` in `List.map`, `crate::store` in `crate::store::open`, `self` in `self.open()`.
    pub qualifier: Option<String>,
    pub line: u32,
    pub enclosing: Option<u32>,
    pub kind: RefKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HierarchyKind {
    Extends,
    Implements,
}

impl HierarchyKind {
    pub fn as_str(self) -> &'static str {
        match self {
            HierarchyKind::Extends => "extends",
            HierarchyKind::Implements => "implements",
        }
    }

    pub fn parse(s: &str) -> HierarchyKind {
        if s == "implements" { HierarchyKind::Implements } else { HierarchyKind::Extends }
    }
}

/// `class A extends B`, `impl Trait for A`: symbol `symbol` relates to the type named `target`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeRelation {
    pub symbol: u32,
    pub target: String,
    pub kind: HierarchyKind,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlobFacts {
    /// Elm `module Foo.Bar`. Rust and TS have no equivalent declaration, so it stays `None`.
    pub module_name: Option<String>,
    pub line_count: u32,
    pub symbols: Vec<Symbol>,
    pub imports: Vec<Import>,
    pub refs: Vec<Reference>,
    pub hierarchy: Vec<TypeRelation>,
    /// What the file's declarations say about the types of names (Swift only, empty elsewhere):
    /// the receiver ladder in `graph::swift_types` reads it to type `recv` in `recv.m()`.
    #[serde(default, skip_serializing_if = "TypeFacts::is_empty")]
    pub types: TypeFacts,
}

/// How a binding's type is known, as written: still unresolved, because `Expr` and `Each` need the
/// view's property and return-type tables, which depend on other files.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TypeSource {
    /// A written type, normalised to its bare name (`Car` for `Car?`, `[Car]` for an array).
    Named(String),
    /// An initialiser or `if let` condition, as receiver text: `Car(…)`, `g.makeCar()`, `o`.
    Expr(String),
    /// The element of a `for … in <expr>` collection.
    Each(String),
}

/// A local name with what types it, visible over `scope_start..=scope_end` (lines) from
/// `decl_line`. `ty: None` still matters: a closure parameter `c` hides an outer typed `c`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Binding {
    pub name: String,
    pub ty: Option<TypeSource>,
    pub decl_line: u32,
    pub scope_start: u32,
    pub scope_end: u32,
    /// The symbol the binding sits in, as for a `Reference`: its container is `self`'s type.
    pub enclosing: Option<u32>,
}

/// A stored or computed property's type, from its annotation or a `T(...)` initialiser.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemberType {
    pub owner: String,
    pub member: String,
    pub ty: String,
}

/// A function's declared return type; `owner` is empty for a top-level function.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReturnType {
    pub owner: String,
    pub name: String,
    pub ty: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeFacts {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub bindings: Vec<Binding>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub members: Vec<MemberType>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub returns: Vec<ReturnType>,
}

impl TypeFacts {
    pub fn is_empty(&self) -> bool {
        self.bindings.is_empty() && self.members.is_empty() && self.returns.is_empty()
    }

    /// The store's form: one tab-separated line per fact (`b`inding, `m`ember, `r`eturn), a
    /// third the size of the JSON (11 MB → under 4 MB for Flight Deck's 1,800 Swift files). No
    /// field can hold a tab or newline: names are identifiers, types are normalised and
    /// expressions went through `one_line`.
    pub fn encode(&self) -> String {
        use std::fmt::Write;
        let mut out = String::new();
        for b in &self.bindings {
            let (k, t) = match &b.ty {
                None => ("-", ""),
                Some(TypeSource::Named(t)) => ("n", t.as_str()),
                Some(TypeSource::Expr(t)) => ("e", t.as_str()),
                Some(TypeSource::Each(t)) => ("f", t.as_str()),
            };
            let enc = b.enclosing.map(|e| e.to_string()).unwrap_or_default();
            let _ = writeln!(out, "b\t{}\t{k}\t{t}\t{}\t{}\t{}\t{enc}", b.name, b.decl_line, b.scope_start, b.scope_end);
        }
        for m in &self.members {
            let _ = writeln!(out, "m\t{}\t{}\t{}", m.owner, m.member, m.ty);
        }
        for r in &self.returns {
            let _ = writeln!(out, "r\t{}\t{}\t{}", r.owner, r.name, r.ty.as_deref().unwrap_or("-"));
        }
        out
    }

    /// Inverse of `encode`; a malformed line is skipped (the facts are derived, never precious).
    pub fn decode(s: &str) -> TypeFacts {
        let mut t = TypeFacts::default();
        for line in s.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            match f.as_slice() {
                ["b", name, k, ty, decl, start, end, enc] => {
                    let ty = match *k {
                        "n" => Some(TypeSource::Named(ty.to_string())),
                        "e" => Some(TypeSource::Expr(ty.to_string())),
                        "f" => Some(TypeSource::Each(ty.to_string())),
                        _ => None,
                    };
                    let (Ok(decl_line), Ok(scope_start), Ok(scope_end)) = (decl.parse(), start.parse(), end.parse()) else { continue };
                    t.bindings.push(Binding { name: name.to_string(), ty, decl_line, scope_start, scope_end, enclosing: enc.parse().ok() });
                }
                ["m", owner, member, ty] => t.members.push(MemberType { owner: owner.to_string(), member: member.to_string(), ty: ty.to_string() }),
                ["r", owner, name, ty] => {
                    let ty = (*ty != "-").then(|| ty.to_string());
                    t.returns.push(ReturnType { owner: owner.to_string(), name: name.to_string(), ty });
                }
                _ => {}
            }
        }
        t
    }
}

impl BlobFacts {
    /// Append a symbol and return its local id.
    pub fn push_symbol(&mut self, mut s: Symbol) -> u32 {
        let id = self.symbols.len() as u32;
        s.local_id = id;
        self.symbols.push(s);
        id
    }
}
