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
