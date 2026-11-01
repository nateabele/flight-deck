//! Elm. qartez had no Elm module, so every `.elm` file in Tessera was invisible to agents.

use super::util::*;
use super::Language;
use crate::facts::*;
use std::collections::{HashMap, HashSet};
use tree_sitter::Node;

pub struct Elm;

impl Language for Elm {
    fn id(&self) -> &'static str {
        "elm"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["elm"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        let mut facts = BlobFacts { line_count: line_count(source), ..Default::default() };
        let lang = tree_sitter_elm::LANGUAGE.into();
        let Some(tree) = parse(&lang, source) else { return facts };
        let root = tree.root_node();

        // `module X exposing (..)` decides every symbol's `exported` flag, so read it before the
        // declarations; Elm requires the module line first anyway.
        let mut exposing = Exposing::default();
        let mut cursor = root.walk();
        for child in root.children(&mut cursor) {
            match child.kind() {
                "module_declaration" => {
                    facts.module_name = field_text(child, "name", source).map(str::to_string);
                    if let Some(list) = child.child_by_field_name("exposing") {
                        exposing = read_exposing(list, source);
                    }
                }
                "import_clause" => {
                    if let Some(i) = read_import(child, source) {
                        facts.imports.push(i);
                    }
                }
                _ => {}
            }
        }

        // A `type_annotation` precedes its `value_declaration`; keep it to use as the signature.
        let mut annotations: HashMap<&str, Node> = HashMap::new();
        for child in root.children(&mut cursor) {
            match child.kind() {
                "type_annotation" => {
                    if let Some(name) = field_text(child, "name", source) {
                        annotations.insert(name, child);
                    }
                }
                "value_declaration" => {
                    let Some(left) = child.child_by_field_name("functionDeclarationLeft") else {
                        continue; // destructuring `(a, b) = …` at top level
                    };
                    let Some(name_node) = left.named_child(0).filter(|n| n.kind() == "lower_case_identifier")
                    else {
                        continue;
                    };
                    let name = text(name_node, source);
                    let has_args = left.named_child_count() > 1;
                    let annotation = annotations.get(name).copied();
                    let signature = annotation
                        .map(|a| one_line(text(a, source)))
                        .unwrap_or_else(|| one_line(text(left, source)));
                    let kind = if has_args { SymbolKind::Function } else { SymbolKind::Const };
                    let id = facts.push_symbol(symbol(
                        child,
                        name,
                        kind,
                        Some(signature),
                        None,
                        exposing.exports_value(name),
                    ));
                    let bound = bound_names(child, source);
                    if let Some(a) = annotation {
                        collect_refs(a, source, Some(id), &bound, &mut facts.refs);
                    }
                    collect_refs(child, source, Some(id), &bound, &mut facts.refs);
                }
                "type_declaration" => {
                    let Some(name) = field_text(child, "name", source) else { continue };
                    let type_exposed = exposing.exports_type(name);
                    let ctors_exposed = exposing.exports_constructors(name);
                    let id = facts.push_symbol(symbol(
                        child,
                        name,
                        SymbolKind::Enum,
                        Some(one_line(&format!("type {name}"))),
                        None,
                        type_exposed,
                    ));
                    let mut c = child.walk();
                    for variant in child.children_by_field_name("unionVariant", &mut c) {
                        let Some(vname) = field_text(variant, "name", source) else { continue };
                        let vid = facts.push_symbol(symbol(
                            variant,
                            vname,
                            SymbolKind::Constructor,
                            Some(one_line(text(variant, source))),
                            Some(id),
                            ctors_exposed,
                        ));
                        collect_refs(variant, source, Some(vid), &HashSet::new(), &mut facts.refs);
                    }
                }
                "type_alias_declaration" => {
                    let Some(name) = field_text(child, "name", source) else { continue };
                    let id = facts.push_symbol(symbol(
                        child,
                        name,
                        SymbolKind::TypeAlias,
                        Some(one_line(&format!("type alias {name}"))),
                        None,
                        exposing.exports_type(name),
                    ));
                    if let Some(te) = child.child_by_field_name("typeExpression") {
                        record_fields(te, source, id, &mut facts);
                    }
                    collect_refs(child, source, Some(id), &HashSet::new(), &mut facts.refs);
                }
                "port_annotation" => {
                    let Some(name) = field_text(child, "name", source) else { continue };
                    let id = facts.push_symbol(symbol(
                        child,
                        name,
                        SymbolKind::Port,
                        Some(one_line(text(child, source))),
                        None,
                        exposing.exports_value(name),
                    ));
                    collect_refs(child, source, Some(id), &HashSet::new(), &mut facts.refs);
                }
                _ => {}
            }
        }
        facts
    }
}

/// Record fields of a record-shaped alias as child symbols (cheap, and `find` on a field name is
/// a common agent query).
fn record_fields(te: Node, src: &str, parent: u32, facts: &mut BlobFacts) {
    let mut stack = vec![te];
    while let Some(n) = stack.pop() {
        if n.kind() == "field_type" {
            if let Some(name) = field_text(n, "name", src) {
                facts.push_symbol(symbol(
                    n,
                    name,
                    SymbolKind::Field,
                    Some(one_line(text(n, src))),
                    Some(parent),
                    true,
                ));
            }
            continue; // nested records inside a field type are not fields of this alias
        }
        let mut c = n.walk();
        let kids: Vec<Node> = n.named_children(&mut c).collect();
        stack.extend(kids.into_iter().rev());
    }
}

#[derive(Default)]
struct Exposing {
    all: bool,
    values: HashSet<String>,
    /// type name -> exposes constructors (`Type(..)`)
    types: HashMap<String, bool>,
}

impl Exposing {
    fn exports_value(&self, n: &str) -> bool {
        self.all || self.values.contains(n)
    }
    fn exports_type(&self, n: &str) -> bool {
        self.all || self.types.contains_key(n)
    }
    fn exports_constructors(&self, n: &str) -> bool {
        self.all || self.types.get(n).copied().unwrap_or(false)
    }
}

fn read_exposing(list: Node, src: &str) -> Exposing {
    let mut e = Exposing::default();
    let mut c = list.walk();
    for item in list.named_children(&mut c) {
        match item.kind() {
            "double_dot" => e.all = true,
            "exposed_value" => {
                e.values.insert(text(item, src).to_string());
            }
            "exposed_type" => {
                let subs = text(item, src).ends_with("(..)");
                let name = item.named_child(0).map(|n| text(n, src)).unwrap_or("");
                e.types.insert(name.to_string(), subs);
            }
            _ => {}
        }
    }
    e
}

fn read_import(n: Node, src: &str) -> Option<Import> {
    let specifier = field_text(n, "moduleName", src)?.to_string();
    let alias = n
        .child_by_field_name("asClause")
        .and_then(|a| field_text(a, "name", src))
        .map(str::to_string);
    let mut names = Vec::new();
    if let Some(list) = n.child_by_field_name("exposing") {
        let ex = read_exposing(list, src);
        if ex.all {
            names.push(ImportName::plain("*"));
        }
        let mut c = list.walk();
        for item in list.named_children(&mut c) {
            match item.kind() {
                "exposed_value" => names.push(ImportName::plain(text(item, src))),
                "exposed_type" => {
                    let nm = item.named_child(0).map(|x| text(x, src)).unwrap_or("");
                    names.push(ImportName {
                        name: nm.to_string(),
                        alias: None,
                        subs: text(item, src).ends_with("(..)"),
                    });
                }
                _ => {}
            }
        }
    }
    Some(Import {
        specifier,
        alias,
        names,
        line: n.start_position().row as u32 + 1,
        kind: ImportKind::Import,
    })
}

/// Names bound by patterns and let-declarations inside one top-level declaration. Elm has no
/// cheap scope analysis, but an unqualified lowercase name bound anywhere in the declaration is
/// almost always the local, and recording every `x`/`acc`/`model` as a reference to resolve (then
/// fail to) would bloat the facts several-fold for nothing.
fn bound_names<'a>(decl: Node<'a>, src: &'a str) -> HashSet<&'a str> {
    let mut out = HashSet::new();
    let mut stack = vec![decl];
    while let Some(n) = stack.pop() {
        match n.kind() {
            "lower_pattern" | "record_pattern" => {
                let mut inner = vec![n];
                while let Some(m) = inner.pop() {
                    if m.kind() == "lower_case_identifier" {
                        out.insert(text(m, src));
                    }
                    let mut c = m.walk();
                    inner.extend(m.named_children(&mut c));
                }
                continue;
            }
            // A let-bound function's own name (the top-level declaration's name is not local).
            "function_declaration_left" if n.parent().and_then(|p| p.parent()).is_some_and(|g| g.kind() == "let_in_expr") => {
                if let Some(first) = n.named_child(0) {
                    out.insert(text(first, src));
                }
            }
            _ => {}
        }
        let mut c = n.walk();
        stack.extend(n.named_children(&mut c));
    }
    out
}

fn collect_refs(root: Node, src: &str, enclosing: Option<u32>, bound: &HashSet<&str>, out: &mut Vec<Reference>) {
    let mut stack = vec![root];
    while let Some(n) = stack.pop() {
        match n.kind() {
            "value_qid" | "upper_case_qid" => {
                let full = text(n, src);
                let (qualifier, name) = split_qualified(full, ".");
                let parent = n.parent();
                let kind = match parent.map(|p| p.kind()) {
                    Some("type_ref") => RefKind::Type,
                    Some("value_expr") => {
                        let call_target = parent
                            .and_then(|p| p.parent())
                            .map(|g| {
                                g.kind() == "function_call_expr"
                                    && g.child_by_field_name("target") == parent
                            })
                            .unwrap_or(false);
                        if call_target { RefKind::Call } else { RefKind::Use }
                    }
                    _ => RefKind::Use,
                };
                let is_local = qualifier.is_none() && n.kind() == "value_qid" && bound.contains(name);
                if !is_local {
                    out.push(Reference {
                        name: name.to_string(),
                        qualifier: qualifier.map(str::to_string),
                        line: n.start_position().row as u32 + 1,
                        enclosing,
                        kind,
                    });
                }
                continue;
            }
            _ => {}
        }
        let mut c = n.walk();
        let kids: Vec<Node> = n.named_children(&mut c).collect();
        stack.extend(kids.into_iter().rev());
    }
}
