//! Rust.

use super::util::*;
use super::Language;
use crate::facts::*;
use tree_sitter::Node;

pub struct Rust;

impl Language for Rust {
    fn id(&self) -> &'static str {
        "rust"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["rs"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        let mut facts = BlobFacts { line_count: line_count(source), ..Default::default() };
        let lang = tree_sitter_rust::LANGUAGE.into();
        let Some(tree) = parse(&lang, source) else { return facts };
        let mut w = Walker { src: source, facts: &mut facts };
        w.walk_children(tree.root_node(), None, None);
        facts
    }
}

struct Walker<'a> {
    src: &'a str,
    facts: &'a mut BlobFacts,
}

impl<'a> Walker<'a> {
    fn walk_children(&mut self, n: Node, parent: Option<u32>, enclosing: Option<u32>) {
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            self.walk(child, parent, enclosing);
        }
    }

    fn is_pub(n: Node) -> bool {
        let mut c = n.walk();
        n.children(&mut c).any(|k| k.kind() == "visibility_modifier")
    }

    fn define(&mut self, n: Node, name: &str, kind: SymbolKind, parent: Option<u32>, exported: bool) -> u32 {
        let sig = signature_before_body(n, self.src);
        self.facts.push_symbol(symbol(n, name, kind, Some(sig), parent, exported))
    }

    /// Visit everything under `n` except the definition's own `name` child.
    fn walk_except_name(&mut self, n: Node, parent: Option<u32>, enclosing: Option<u32>) {
        let name = n.child_by_field_name("name");
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            if Some(child) != name {
                self.walk(child, parent, enclosing);
            }
        }
    }

    fn walk(&mut self, n: Node, parent: Option<u32>, enclosing: Option<u32>) {
        let src = self.src;
        match n.kind() {
            "function_item" | "function_signature_item" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let in_container = parent
                    .map(|p| matches!(self.facts.symbols[p as usize].kind, SymbolKind::Impl | SymbolKind::Trait))
                    .unwrap_or(false);
                let kind = if in_container { SymbolKind::Method } else { SymbolKind::Function };
                // Trait items and trait-impl methods are public if the trait is reachable; `pub`
                // alone would call every trait method private.
                let exported = Self::is_pub(n)
                    || parent.is_some_and(|p| {
                        let ps = &self.facts.symbols[p as usize];
                        ps.kind == SymbolKind::Trait && ps.exported
                            || ps.kind == SymbolKind::Impl && self.facts.hierarchy.iter().any(|h| h.symbol == p)
                    });
                let id = self.define(n, name, kind, parent, exported);
                self.walk_except_name(n, parent, Some(id));
            }
            "struct_item" | "union_item" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Struct, parent, Self::is_pub(n));
                if let Some(body) = n.child_by_field_name("body") {
                    let mut c = body.walk();
                    for f in body.named_children(&mut c) {
                        if f.kind() == "field_declaration"
                            && let Some(fname) = field_text(f, "name", src) {
                                self.facts.push_symbol(symbol(
                                    f,
                                    fname,
                                    SymbolKind::Field,
                                    Some(one_line(text(f, src))),
                                    Some(id),
                                    Self::is_pub(f),
                                ));
                            }
                    }
                }
                self.walk_except_name(n, parent, Some(id));
            }
            "enum_item" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Enum, parent, Self::is_pub(n));
                let exported = Self::is_pub(n);
                if let Some(body) = n.child_by_field_name("body") {
                    let mut c = body.walk();
                    for v in body.named_children(&mut c) {
                        if v.kind() == "enum_variant"
                            && let Some(vname) = field_text(v, "name", src) {
                                let vid = self.facts.push_symbol(symbol(
                                    v,
                                    vname,
                                    SymbolKind::Constructor,
                                    Some(one_line(text(v, src))),
                                    Some(id),
                                    exported,
                                ));
                                self.walk_except_name(v, Some(id), Some(vid));
                            }
                    }
                }
            }
            "trait_item" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Trait, parent, Self::is_pub(n));
                if let Some(bounds) = n.child_by_field_name("bounds") {
                    let mut c = bounds.walk();
                    for b in bounds.named_children(&mut c) {
                        if let Some(t) = base_type_name(b, src) {
                            self.facts.hierarchy.push(TypeRelation {
                                symbol: id,
                                target: t,
                                kind: HierarchyKind::Extends,
                            });
                        }
                    }
                }
                self.walk_except_name(n, Some(id), Some(id));
            }
            "impl_item" => {
                let ty = n.child_by_field_name("type");
                let Some(name) = ty.and_then(|t| base_type_name(t, src)) else { return };
                let id = self.define(n, &name, SymbolKind::Impl, parent, false);
                if let Some(tr) = n.child_by_field_name("trait").and_then(|t| base_type_name(t, src)) {
                    self.facts.hierarchy.push(TypeRelation {
                        symbol: id,
                        target: tr,
                        kind: HierarchyKind::Implements,
                    });
                }
                // The impl header's own type mentions are references; body items are children.
                let body = n.child_by_field_name("body");
                let mut c = n.walk();
                for child in n.named_children(&mut c) {
                    if Some(child) == body {
                        self.walk_children(child, Some(id), Some(id));
                    } else {
                        self.walk(child, parent, Some(id));
                    }
                }
            }
            "mod_item" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Module, parent, Self::is_pub(n));
                match n.child_by_field_name("body") {
                    Some(body) => self.walk_children(body, Some(id), None),
                    None => self.facts.imports.push(Import {
                        specifier: name.to_string(),
                        alias: None,
                        names: vec![],
                        line: n.start_position().row as u32 + 1,
                        kind: ImportKind::ModDecl,
                    }),
                }
            }
            "const_item" | "static_item" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Const, parent, Self::is_pub(n));
                self.walk_except_name(n, parent, Some(id));
            }
            "type_item" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::TypeAlias, parent, Self::is_pub(n));
                self.walk_except_name(n, parent, Some(id));
            }
            "macro_definition" => {
                if let Some(name) = field_text(n, "name", src) {
                    self.define(n, name, SymbolKind::Macro, parent, true);
                }
            }
            "use_declaration" => {
                if let Some(arg) = n.child_by_field_name("argument") {
                    let line = n.start_position().row as u32 + 1;
                    self.use_tree(arg, "", line);
                }
            }
            "call_expression" => {
                if let Some(f) = n.child_by_field_name("function") {
                    self.callee(f, enclosing);
                }
                if let Some(args) = n.child_by_field_name("arguments") {
                    self.walk_children(args, parent, enclosing);
                }
            }
            "macro_invocation" => {
                if let Some(m) = n.child_by_field_name("macro") {
                    let (q, name) = split_qualified(text(m, src), "::");
                    self.add_ref(n, name, q, enclosing, RefKind::Call);
                }
            }
            "type_parameter" => {
                // `T: Trait` — the bound is a reference, the parameter name is not.
                self.walk_except_name(n, parent, enclosing);
            }
            "type_identifier" => {
                let name = text(n, src);
                if name != "Self" {
                    self.add_ref(n, name, None, enclosing, RefKind::Type);
                }
            }
            "scoped_type_identifier" => {
                let (q, name) = split_qualified(text(n, src), "::");
                self.add_ref(n, name, q, enclosing, RefKind::Type);
            }
            "scoped_identifier" => {
                let (q, name) = split_qualified(text(n, src), "::");
                self.add_ref(n, name, q, enclosing, RefKind::Use);
            }
            "identifier" => {
                // Only SHOUTY_CONSTANTS and unit values: lowercase identifiers are almost all
                // locals, and recording them would swamp the facts.
                let name = text(n, src);
                if name.chars().next().is_some_and(|ch| ch.is_ascii_uppercase()) {
                    self.add_ref(n, name, None, enclosing, RefKind::Use);
                }
            }
            "token_tree" | "string_literal" | "line_comment" | "block_comment" | "attribute_item" => {}
            _ => self.walk_children(n, parent, enclosing),
        }
    }

    fn callee(&mut self, f: Node, enclosing: Option<u32>) {
        let src = self.src;
        match f.kind() {
            "identifier" => self.add_ref(f, text(f, src), None, enclosing, RefKind::Call),
            "scoped_identifier" => {
                let (q, name) = split_qualified(text(f, src), "::");
                self.add_ref(f, name, q, enclosing, RefKind::Call);
            }
            "field_expression" => {
                if let Some(field) = field_text(f, "field", src) {
                    let value = f.child_by_field_name("value");
                    let q = value
                        .filter(|v| matches!(v.kind(), "self" | "identifier"))
                        .map(|v| text(v, src));
                    self.add_ref(f, field, q, enclosing, RefKind::Call);
                }
                if let Some(v) = f.child_by_field_name("value") {
                    self.walk(v, None, enclosing);
                }
            }
            "generic_function" => {
                if let Some(inner) = f.child_by_field_name("function") {
                    self.callee(inner, enclosing);
                }
            }
            _ => self.walk(f, None, enclosing),
        }
    }

    fn add_ref(&mut self, n: Node, name: &str, qualifier: Option<&str>, enclosing: Option<u32>, kind: RefKind) {
        self.facts.refs.push(Reference {
            name: name.to_string(),
            qualifier: qualifier.map(str::to_string),
            line: n.start_position().row as u32 + 1,
            enclosing,
            kind,
        });
    }

    /// Flatten a `use` tree into one `Import` per path prefix with a leaf list.
    fn use_tree(&mut self, n: Node, prefix: &str, line: u32) {
        let src = self.src;
        let join = |a: &str, b: &str| if a.is_empty() { b.to_string() } else { format!("{a}::{b}") };
        match n.kind() {
            "scoped_use_list" => {
                let path = n.child_by_field_name("path").map(|p| text(p, src)).unwrap_or("");
                let full = join(prefix, path);
                if let Some(list) = n.child_by_field_name("list") {
                    self.use_list(list, &full, line);
                }
            }
            "use_list" => self.use_list(n, prefix, line),
            "use_wildcard" => {
                let path = n.named_child(0).map(|p| text(p, src)).unwrap_or("");
                self.push_import(join(prefix, path), vec![ImportName::plain("*")], line);
            }
            "use_as_clause" => {
                let path = n.child_by_field_name("path").map(|p| text(p, src)).unwrap_or("");
                let alias = field_text(n, "alias", src).map(str::to_string);
                let (q, name) = split_qualified(path, "::");
                self.push_import(
                    join(prefix, q.unwrap_or("")),
                    vec![ImportName { name: name.to_string(), alias, subs: false }],
                    line,
                );
            }
            "scoped_identifier" => {
                let (q, name) = split_qualified(text(n, src), "::");
                self.push_import(join(prefix, q.unwrap_or("")), vec![ImportName::plain(name)], line);
            }
            "identifier" | "self" | "crate" | "super" => {
                let name = text(n, src);
                if prefix.is_empty() {
                    self.push_import(name.to_string(), vec![], line);
                } else {
                    self.push_import(prefix.to_string(), vec![ImportName::plain(name)], line);
                }
            }
            _ => {}
        }
    }

    /// `{a, b as c, d::{e}, self}`: leaves with no nesting share one import; nested trees recurse.
    fn use_list(&mut self, list: Node, prefix: &str, line: u32) {
        let src = self.src;
        let mut leaves: Vec<ImportName> = Vec::new();
        let mut c = list.walk();
        for item in list.named_children(&mut c) {
            match item.kind() {
                "identifier" | "self" => leaves.push(ImportName::plain(text(item, src))),
                "use_as_clause" => {
                    let name = field_text(item, "path", src).unwrap_or("");
                    let alias = field_text(item, "alias", src).map(str::to_string);
                    leaves.push(ImportName { name: name.to_string(), alias, subs: false });
                }
                "use_wildcard" => leaves.push(ImportName::plain("*")),
                _ => self.use_tree(item, prefix, line),
            }
        }
        if !leaves.is_empty() {
            self.push_import(prefix.to_string(), leaves, line);
        }
    }

    fn push_import(&mut self, specifier: String, names: Vec<ImportName>, line: u32) {
        self.facts.imports.push(Import { specifier, alias: None, names, line, kind: ImportKind::Import });
    }
}

/// The type's base name: `Foo` for `Foo<T>`, `a::Foo`, `&Foo`.
fn base_type_name(n: Node, src: &str) -> Option<String> {
    match n.kind() {
        "type_identifier" => Some(text(n, src).to_string()),
        "scoped_type_identifier" => field_text(n, "name", src).map(str::to_string),
        "generic_type" => n.child_by_field_name("type").and_then(|t| base_type_name(t, src)),
        "reference_type" | "pointer_type" => n.child_by_field_name("type").and_then(|t| base_type_name(t, src)),
        _ => None,
    }
}
