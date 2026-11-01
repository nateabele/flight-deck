//! The extractor shared by TypeScript, TSX and JavaScript.
//!
//! The three grammars name almost every node the same way (JavaScript is a subset of the
//! TypeScript shapes), so one walker serves all of them; `typescript.rs` and `javascript.rs` are
//! thin `Language` impls that only choose the grammar. A node kind a dialect never produces is
//! simply never matched.

use super::util::*;
use crate::facts::*;
use std::collections::HashSet;
use tree_sitter::{Language, Node};

/// Globals whose members are never project symbols. Recording `console.log` on every line would
/// add thousands of unresolvable references to every file for nothing.
const IGNORED_QUALIFIERS: &[&str] =
    &["console", "Math", "JSON", "Object", "Array", "Promise", "window", "document", "process", "Number", "String"];

pub fn extract(lang: &Language, source: &str) -> BlobFacts {
    let mut facts = BlobFacts { line_count: line_count(source), ..Default::default() };
    let Some(tree) = parse(lang, source) else { return facts };
    let mut w = Walker { src: source, facts: &mut facts, exported_names: HashSet::new() };
    w.items(tree.root_node(), None, false);
    w.finish();
    facts
}

struct Walker<'a> {
    src: &'a str,
    facts: &'a mut BlobFacts,
    /// Names listed in `export { a, b as c }`; applied to top-level symbols at the end.
    exported_names: HashSet<String>,
}

fn is_function_value(n: Node) -> bool {
    matches!(n.kind(), "arrow_function" | "function_expression" | "function" | "generator_function")
}

impl<'a> Walker<'a> {
    fn items(&mut self, n: Node, parent: Option<u32>, exported: bool) {
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            self.item(child, parent, exported);
        }
    }

    fn define(&mut self, n: Node, name: &str, kind: SymbolKind, parent: Option<u32>, exported: bool) -> u32 {
        let sig = signature_before_body(n, self.src);
        self.facts.push_symbol(symbol(n, name, kind, Some(sig), parent, exported))
    }

    fn item(&mut self, n: Node, parent: Option<u32>, exported: bool) {
        let src = self.src;
        match n.kind() {
            "export_statement" => self.export_statement(n, parent),
            "import_statement" => self.import_statement(n),
            "function_declaration" | "generator_function_declaration" | "function_signature" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Function, parent, exported);
                self.refs_except_name(n, Some(id));
            }
            "class_declaration" | "abstract_class_declaration" | "class" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Class, parent, exported);
                self.heritage(n, id);
                if let Some(tp) = n.child_by_field_name("type_parameters") {
                    self.refs(tp, Some(id));
                }
                if let Some(body) = n.child_by_field_name("body") {
                    self.class_members(body, id, exported);
                }
            }
            "interface_declaration" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Interface, parent, exported);
                let mut c = n.walk();
                for child in n.named_children(&mut c) {
                    match child.kind() {
                        "extends_type_clause" => {
                            let mut cc = child.walk();
                            for t in child.named_children(&mut cc) {
                                if let Some(target) = type_name(t, src) {
                                    self.facts.hierarchy.push(TypeRelation {
                                        symbol: id,
                                        target,
                                        kind: HierarchyKind::Extends,
                                    });
                                }
                                self.refs(t, Some(id));
                            }
                        }
                        "interface_body" | "object_type" => self.class_members(child, id, exported),
                        _ => {}
                    }
                }
            }
            "type_alias_declaration" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::TypeAlias, parent, exported);
                if let Some(v) = n.child_by_field_name("value") {
                    self.refs(v, Some(id));
                }
            }
            "enum_declaration" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name, SymbolKind::Enum, parent, exported);
                if let Some(body) = n.child_by_field_name("body") {
                    let mut c = body.walk();
                    for m in body.named_children(&mut c) {
                        let member = match m.kind() {
                            "property_identifier" | "string" => Some(m),
                            "enum_assignment" => m.child_by_field_name("name"),
                            _ => None,
                        };
                        if let Some(mn) = member {
                            self.facts.push_symbol(symbol(
                                m,
                                text(mn, src).trim_matches(['"', '\'']),
                                SymbolKind::Constructor,
                                None,
                                Some(id),
                                exported,
                            ));
                        }
                    }
                }
            }
            "internal_module" | "module" => {
                let Some(name) = field_text(n, "name", src) else { return };
                let id = self.define(n, name.trim_matches(['"', '\'']), SymbolKind::Module, parent, exported);
                if let Some(body) = n.child_by_field_name("body") {
                    self.items(body, Some(id), false);
                }
            }
            "ambient_declaration" => self.items(n, parent, exported),
            "lexical_declaration" | "variable_declaration" => {
                let mut c = n.walk();
                for d in n.named_children(&mut c) {
                    if d.kind() == "variable_declarator" {
                        self.declarator(d, n, parent, exported);
                    }
                }
            }
            "expression_statement" => {
                // `namespace Foo {}` parses as an expression statement wrapping the module.
                match n.named_child(0) {
                    Some(inner) if matches!(inner.kind(), "internal_module" | "module") => {
                        self.item(inner, parent, exported)
                    }
                    _ => self.refs(n, None),
                }
            }
            "comment" => {}
            _ => self.refs(n, None),
        }
    }

    fn declarator(&mut self, d: Node, decl: Node, parent: Option<u32>, exported: bool) {
        let src = self.src;
        let Some(name_node) = d.child_by_field_name("name") else { return };
        let value = d.child_by_field_name("value");
        // `const x = require('./x')` is an import, not a definition.
        if let Some(v) = value {
            if let Some(spec) = require_specifier(v, src) {
                let mut names = Vec::new();
                let mut alias = None;
                match name_node.kind() {
                    "identifier" => alias = Some(text(name_node, src).to_string()),
                    "object_pattern" => {
                        let mut c = name_node.walk();
                        for p in name_node.named_children(&mut c) {
                            match p.kind() {
                                "shorthand_property_identifier_pattern" => names.push(ImportName::plain(text(p, src))),
                                "pair_pattern" => {
                                    if let (Some(k), Some(v)) = (field_text(p, "key", src), field_text(p, "value", src)) {
                                        names.push(ImportName { name: k.to_string(), alias: Some(v.to_string()), subs: false });
                                    }
                                }
                                _ => {}
                            }
                        }
                    }
                    _ => {}
                }
                self.facts.imports.push(Import {
                    specifier: spec,
                    alias,
                    names,
                    line: d.start_position().row as u32 + 1,
                    kind: ImportKind::Import,
                });
                return;
            }
        }
        if name_node.kind() != "identifier" {
            if let Some(v) = value {
                self.refs(v, None);
            }
            return;
        }
        let name = text(name_node, src);
        let is_fn = value.is_some_and(is_function_value);
        let kind = if is_fn { SymbolKind::Function } else { SymbolKind::Const };
        // The declaration keyword belongs to the parent `const`/`let`; span the whole statement so
        // reading the symbol shows `export const x = …` rather than a bare `x = …`.
        let span = if decl.named_child_count() == 1 { decl } else { d };
        let sig = one_line(&src[span.start_byte()..value.map(|v| v.start_byte()).unwrap_or(span.end_byte())])
            .trim_end_matches(['=', ' '])
            .to_string();
        let id = self.facts.push_symbol(symbol(span, name, kind, Some(sig), parent, exported));
        if let Some(v) = value {
            self.refs(v, Some(id));
        }
        if let Some(t) = d.child_by_field_name("type") {
            self.refs(t, Some(id));
        }
    }

    fn class_members(&mut self, body: Node, class_id: u32, exported: bool) {
        let src = self.src;
        let mut c = body.walk();
        for m in body.named_children(&mut c) {
            match m.kind() {
                "method_definition" | "method_signature" | "abstract_method_signature" => {
                    let Some(name) = field_text(m, "name", src) else { continue };
                    let id = self.define(m, name, SymbolKind::Method, Some(class_id), exported);
                    self.refs_except_name(m, Some(id));
                }
                "public_field_definition" | "field_definition" | "property_signature" => {
                    let Some(name) = field_text(m, "name", src).or_else(|| field_text(m, "property", src)) else {
                        continue;
                    };
                    let is_fn = m.child_by_field_name("value").is_some_and(is_function_value);
                    let kind = if is_fn { SymbolKind::Method } else { SymbolKind::Field };
                    let id = self.define(m, name, kind, Some(class_id), exported);
                    self.refs_except_name(m, Some(id));
                }
                _ => {}
            }
        }
    }

    fn heritage(&mut self, class: Node, id: u32) {
        let src = self.src;
        let mut c = class.walk();
        for child in class.named_children(&mut c) {
            if child.kind() != "class_heritage" {
                continue;
            }
            let mut cc = child.walk();
            for h in child.named_children(&mut cc) {
                match h.kind() {
                    "extends_clause" => {
                        if let Some(v) = h.child_by_field_name("value") {
                            if let Some(t) = type_name(v, src) {
                                self.facts.hierarchy.push(TypeRelation { symbol: id, target: t, kind: HierarchyKind::Extends });
                            }
                            self.refs(v, Some(id));
                        }
                    }
                    "implements_clause" => {
                        let mut c3 = h.walk();
                        for t in h.named_children(&mut c3) {
                            if let Some(target) = type_name(t, src) {
                                self.facts.hierarchy.push(TypeRelation { symbol: id, target, kind: HierarchyKind::Implements });
                            }
                            self.refs(t, Some(id));
                        }
                    }
                    // JavaScript: `class A extends B` has the expression directly in the heritage.
                    _ => {
                        if let Some(t) = type_name(h, src) {
                            self.facts.hierarchy.push(TypeRelation { symbol: id, target: t, kind: HierarchyKind::Extends });
                        }
                        self.refs(h, Some(id));
                    }
                }
            }
        }
    }

    fn import_statement(&mut self, n: Node) {
        let src = self.src;
        let Some(source) = n.child_by_field_name("source") else { return };
        let specifier = string_value(source, src);
        let mut alias = None;
        let mut names = Vec::new();
        let mut c = n.walk();
        for clause in n.named_children(&mut c) {
            if clause.kind() != "import_clause" {
                continue;
            }
            let mut cc = clause.walk();
            for part in clause.named_children(&mut cc) {
                match part.kind() {
                    "identifier" => names.push(ImportName {
                        name: "default".into(),
                        alias: Some(text(part, src).to_string()),
                        subs: false,
                    }),
                    "namespace_import" => {
                        alias = part.named_child(0).map(|i| text(i, src).to_string());
                        names.push(ImportName::plain("*"));
                    }
                    "named_imports" => {
                        let mut c3 = part.walk();
                        for spec in part.named_children(&mut c3) {
                            if let Some(nm) = field_text(spec, "name", src) {
                                names.push(ImportName {
                                    name: nm.to_string(),
                                    alias: field_text(spec, "alias", src).map(str::to_string),
                                    subs: false,
                                });
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        self.facts.imports.push(Import {
            specifier,
            alias,
            names,
            line: n.start_position().row as u32 + 1,
            kind: ImportKind::Import,
        });
    }

    fn export_statement(&mut self, n: Node, parent: Option<u32>) {
        let src = self.src;
        let line = n.start_position().row as u32 + 1;
        if let Some(source) = n.child_by_field_name("source") {
            // `export … from './x'`: the file depends on the target without binding a local name.
            let mut names = Vec::new();
            let mut alias = None;
            let mut c = n.walk();
            for part in n.named_children(&mut c) {
                match part.kind() {
                    "export_clause" => {
                        let mut cc = part.walk();
                        for spec in part.named_children(&mut cc) {
                            if let Some(nm) = field_text(spec, "name", src) {
                                names.push(ImportName {
                                    name: nm.to_string(),
                                    alias: field_text(spec, "alias", src).map(str::to_string),
                                    subs: false,
                                });
                            }
                        }
                    }
                    "namespace_export" => {
                        alias = part.named_child(0).map(|i| text(i, src).to_string());
                        names.push(ImportName::plain("*"));
                    }
                    _ => {}
                }
            }
            if names.is_empty() {
                names.push(ImportName::plain("*"));
            }
            self.facts.imports.push(Import {
                specifier: string_value(source, src),
                alias,
                names,
                line,
                kind: ImportKind::Reexport,
            });
            return;
        }
        if let Some(decl) = n.child_by_field_name("declaration") {
            self.item(decl, parent, true);
            return;
        }
        let mut c = n.walk();
        for part in n.named_children(&mut c) {
            match part.kind() {
                "export_clause" => {
                    let mut cc = part.walk();
                    for spec in part.named_children(&mut cc) {
                        if let Some(nm) = field_text(spec, "name", src) {
                            self.exported_names.insert(nm.to_string());
                        }
                    }
                }
                // `export default <expr>`
                _ if n.child_by_field_name("value") == Some(part) => match part.kind() {
                    "identifier" => {
                        self.exported_names.insert(text(part, src).to_string());
                    }
                    k if is_function_value_kind(k) || k == "class" => {
                        let name = field_text(part, "name", src).unwrap_or("default");
                        let kind = if k == "class" { SymbolKind::Class } else { SymbolKind::Function };
                        let id = self.define(part, name, kind, parent, true);
                        if kind == SymbolKind::Class {
                            self.heritage(part, id);
                            if let Some(body) = part.child_by_field_name("body") {
                                self.class_members(body, id, true);
                            }
                        } else {
                            self.refs_except_name(part, Some(id));
                        }
                    }
                    _ => self.refs(part, None),
                },
                _ => {}
            }
        }
    }

    fn refs_except_name(&mut self, n: Node, enclosing: Option<u32>) {
        let name = n.child_by_field_name("name");
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            if Some(child) != name {
                self.refs(child, enclosing);
            }
        }
    }

    /// Record references (and `require`/`import()` imports) under `n`; never define symbols, so a
    /// function declared inside another function body stays invisible, as in every other index.
    fn refs(&mut self, n: Node, enclosing: Option<u32>) {
        let src = self.src;
        match n.kind() {
            "call_expression" => {
                if let Some(f) = n.child_by_field_name("function") {
                    if f.kind() == "import" || (f.kind() == "identifier" && text(f, src) == "require") {
                        if let Some(spec) = require_specifier(n, src) {
                            self.facts.imports.push(Import {
                                specifier: spec,
                                alias: None,
                                names: vec![],
                                line: n.start_position().row as u32 + 1,
                                kind: ImportKind::Import,
                            });
                        }
                        return;
                    }
                    self.callee(f, enclosing, RefKind::Call);
                }
                if let Some(a) = n.child_by_field_name("arguments") {
                    self.refs_children(a, enclosing);
                }
                if let Some(t) = n.child_by_field_name("type_arguments") {
                    self.refs(t, enclosing);
                }
            }
            "new_expression" => {
                if let Some(f) = n.child_by_field_name("constructor") {
                    self.callee(f, enclosing, RefKind::Call);
                }
                if let Some(a) = n.child_by_field_name("arguments") {
                    self.refs_children(a, enclosing);
                }
            }
            "type_identifier" => {
                let name = text(n, src);
                self.add(n, name, None, enclosing, RefKind::Type);
            }
            "nested_type_identifier" => {
                let (q, name) = split_qualified(text(n, src), ".");
                self.add(n, name, q, enclosing, RefKind::Type);
            }
            "member_expression" => {
                let obj = n.child_by_field_name("object");
                let prop = field_text(n, "property", src);
                match (obj, prop) {
                    (Some(o), Some(p)) if o.kind() == "identifier" => {
                        self.add(n, p, Some(text(o, src)), enclosing, RefKind::Use)
                    }
                    (Some(o), _) => self.refs(o, enclosing),
                    _ => {}
                }
            }
            "identifier" | "jsx_identifier" => {
                self.add(n, text(n, src), None, enclosing, RefKind::Use);
            }
            "string" | "template_string" | "comment" | "regex" => {}
            _ => self.refs_children(n, enclosing),
        }
    }

    fn refs_children(&mut self, n: Node, enclosing: Option<u32>) {
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            self.refs(child, enclosing);
        }
    }

    fn callee(&mut self, f: Node, enclosing: Option<u32>, kind: RefKind) {
        let src = self.src;
        match f.kind() {
            "identifier" => self.add(f, text(f, src), None, enclosing, kind),
            "member_expression" => {
                if let Some(p) = field_text(f, "property", src) {
                    let obj = f.child_by_field_name("object");
                    let q = obj
                        .filter(|o| matches!(o.kind(), "identifier" | "this"))
                        .map(|o| text(o, src));
                    self.add(f, p, q, enclosing, kind);
                    if let Some(o) = obj.filter(|o| !matches!(o.kind(), "identifier" | "this")) {
                        self.refs(o, enclosing);
                    }
                }
            }
            "super" => {}
            _ => self.refs(f, enclosing),
        }
    }

    fn add(&mut self, n: Node, name: &str, qualifier: Option<&str>, enclosing: Option<u32>, kind: RefKind) {
        if qualifier.is_some_and(|q| IGNORED_QUALIFIERS.contains(&q)) {
            return;
        }
        self.facts.refs.push(Reference {
            name: name.to_string(),
            qualifier: qualifier.map(str::to_string),
            line: n.start_position().row as u32 + 1,
            enclosing,
            kind,
        });
    }

    /// Apply `export { a }` and drop reference noise.
    ///
    /// Plain `identifier` mentions are overwhelmingly locals (`x`, `i`, `result`). Without scope
    /// analysis the cheap, safe filter is: a bare-identifier `Use` only matters if it names
    /// something this file imports or defines; a qualified `Use` only if its qualifier does. Calls
    /// and types are always kept so the unique-name fallback can still find cross-file targets.
    fn finish(&mut self) {
        for s in self.facts.symbols.iter_mut() {
            if s.parent.is_none() && self.exported_names.contains(&s.name) {
                s.exported = true;
            }
        }
        let mut known: HashSet<&str> = self.facts.symbols.iter().map(|s| s.name.as_str()).collect();
        for i in &self.facts.imports {
            if let Some(a) = &i.alias {
                known.insert(a);
            }
            for n in &i.names {
                known.insert(n.local());
            }
        }
        let known: HashSet<String> = known.into_iter().map(str::to_string).collect();
        self.facts.refs.retain(|r| {
            if r.kind != RefKind::Use {
                return true;
            }
            match &r.qualifier {
                Some(q) => known.contains(q),
                None => known.contains(&r.name),
            }
        });
    }
}

fn is_function_value_kind(k: &str) -> bool {
    matches!(k, "arrow_function" | "function_expression" | "function" | "generator_function")
}

fn type_name(n: Node, src: &str) -> Option<String> {
    match n.kind() {
        "type_identifier" | "identifier" => Some(text(n, src).to_string()),
        "nested_type_identifier" | "member_expression" => {
            Some(split_qualified(text(n, src), ".").1.to_string())
        }
        "generic_type" => n.child_by_field_name("name").and_then(|t| type_name(t, src)),
        _ => None,
    }
}

/// `'./x'` -> `./x`.
fn string_value(n: Node, src: &str) -> String {
    text(n, src).trim_matches(['"', '\'', '`']).to_string()
}

/// The specifier of `require('x')` / `import('x')`, if `n` is exactly such a call.
fn require_specifier(n: Node, src: &str) -> Option<String> {
    if n.kind() != "call_expression" {
        return None;
    }
    let f = n.child_by_field_name("function")?;
    let is_require = f.kind() == "import" || (f.kind() == "identifier" && text(f, src) == "require");
    if !is_require {
        return None;
    }
    let args = n.child_by_field_name("arguments")?;
    let first = args.named_child(0)?;
    (first.kind() == "string").then(|| string_value(first, src))
}
