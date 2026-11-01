//! Swift. One grammar node, `class_declaration`, covers class, struct, enum, actor and extension;
//! the keyword token tells them apart.

use super::util::*;
use super::Language;
use crate::facts::*;
use std::collections::HashSet;
use tree_sitter::Node;

pub struct Swift;

impl Language for Swift {
    fn id(&self) -> &'static str {
        "swift"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["swift"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        let mut facts = BlobFacts { line_count: line_count(source), ..Default::default() };
        let lang = tree_sitter_swift::LANGUAGE.into();
        let Some(tree) = parse(&lang, source) else { return facts };
        let mut w = Walker { src: source, facts: &mut facts };
        w.decls(tree.root_node(), &Scope { parent: None, exported: true, generics: HashSet::new() });
        facts
    }
}

/// Types that cost a reference apiece and can never be defined by the repository.
const PRIMITIVES: &[&str] = &[
    "Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float",
    "Bool", "String", "Character", "Void", "Any", "AnyObject", "Self", "Never", "Array", "Dictionary", "Set",
    "Optional",
];

/// Protocols a class commonly lists first. A class's first inherited name is its superclass unless
/// it is one of these: the grammar cannot tell a superclass from a protocol, and without this
/// every `class Foo: Codable` would claim `Codable` as its parent class.
const COMMON_PROTOCOLS: &[&str] = &[
    "Codable", "Decodable", "Encodable", "Equatable", "Hashable", "Comparable", "Identifiable", "Sendable",
    "ObservableObject", "CustomStringConvertible", "Error", "View", "App", "NSCopying", "CaseIterable",
    "RawRepresentable", "LocalizedError",
];

#[derive(Clone)]
struct Scope {
    parent: Option<u32>,
    exported: bool,
    /// Generic parameter names in scope: `T` is not a type the repository defines.
    generics: HashSet<String>,
}

struct Walker<'a> {
    src: &'a str,
    facts: &'a mut BlobFacts,
}

/// Is `n`'s own access level visible outside its file? `private(set)` still reads as public.
fn is_visible(n: Node, src: &str) -> bool {
    let mut c = n.walk();
    let Some(mods) = n.children(&mut c).find(|k| k.kind() == "modifiers") else { return true };
    let mut c2 = mods.walk();
    mods.children(&mut c2).filter(|m| m.kind() == "visibility_modifier").all(|m| {
        let t = text(m, src);
        !(t.starts_with("private") || t.starts_with("fileprivate")) || t.contains("(set)")
    })
}

fn last_type_name<'a>(n: Node, src: &'a str) -> Option<&'a str> {
    let mut c = n.walk();
    n.named_children(&mut c).filter(|k| k.kind() == "type_identifier").last().map(|k| text(k, src))
}

impl<'a> Walker<'a> {
    fn decls(&mut self, n: Node, sc: &Scope) {
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            self.decl(child, sc);
        }
    }

    fn decl(&mut self, n: Node, sc: &Scope) {
        let src = self.src;
        match n.kind() {
            "import_declaration" => {
                let mut c = n.walk();
                if let Some(id) = n.named_children(&mut c).find(|k| k.kind() == "identifier") {
                    self.facts.imports.push(Import {
                        specifier: text(id, src).to_string(),
                        alias: None,
                        names: vec![],
                        line: n.start_position().row as u32 + 1,
                        kind: ImportKind::Import,
                    });
                }
            }
            "class_declaration" => self.type_decl(n, sc),
            "protocol_declaration" => self.protocol(n, sc),
            "function_declaration" | "protocol_function_declaration" => {
                if let Some(name) = field_text(n, "name", src) {
                    self.function(n, name, sc);
                }
            }
            "init_declaration" => self.function(n, "init", sc),
            "deinit_declaration" => self.function(n, "deinit", sc),
            "subscript_declaration" => self.function(n, "subscript", sc),
            "property_declaration" | "protocol_property_declaration" => self.property(n, sc),
            "typealias_declaration" | "associatedtype_declaration" => {
                let mut c = n.walk();
                let Some(name) = n.named_children(&mut c).find(|k| k.kind() == "type_identifier") else { return };
                let id = self.define(n, text(name, src), SymbolKind::TypeAlias, sc, is_visible(n, src));
                self.refs(n, Some(id), sc, &HashSet::new());
            }
            "enum_entry" => {
                let mut c = n.walk();
                let names: Vec<Node> = n.children_by_field_name("name", &mut c).collect();
                let mut first = None;
                for nm in names {
                    let id = self.define(n, text(nm, src), SymbolKind::Constructor, sc, true);
                    first.get_or_insert(id);
                }
                self.refs(n, first, sc, &HashSet::new());
            }
            // A stray `;` after a declaration makes the grammar wrap what follows in ERROR; the
            // declarations inside are still declarations.
            "ERROR" => self.decls(n, sc),
            "comment" | "multiline_comment" | "directive" => {}
            _ => self.refs(n, sc.parent, sc, &HashSet::new()),
        }
    }

    fn define(&mut self, n: Node, name: &str, kind: SymbolKind, sc: &Scope, own_visible: bool) -> u32 {
        let src = self.src;
        let end = ["body", "value", "computed_value"]
            .iter()
            .filter_map(|f| n.child_by_field_name(f))
            .map(|b| b.start_byte())
            .min()
            .unwrap_or(n.end_byte());
        let sig = one_line(src[n.start_byte()..end].trim_end_matches(['{', ' ', '\n', '\t', '=']));
        self.facts.push_symbol(symbol(n, name, kind, Some(sig), sc.parent, own_visible && sc.exported))
    }

    fn generics_of(&self, n: Node, sc: &Scope) -> HashSet<String> {
        let mut g = sc.generics.clone();
        let mut c = n.walk();
        for tp in n.named_children(&mut c).filter(|k| k.kind() == "type_parameters") {
            let mut c2 = tp.walk();
            for p in tp.named_children(&mut c2).filter(|k| k.kind() == "type_parameter") {
                if let Some(name) = p.named_child(0) {
                    g.insert(text(name, self.src).to_string());
                }
            }
        }
        g
    }

    fn type_decl(&mut self, n: Node, sc: &Scope) {
        let src = self.src;
        let mut c = n.walk();
        let keyword = n.children(&mut c).map(|k| k.kind()).find(|k| matches!(*k, "class" | "struct" | "enum" | "actor" | "extension")).unwrap_or("class");
        let Some(name_node) = n.child_by_field_name("name") else { return };
        let is_ext = keyword == "extension";
        let name = if is_ext { last_type_name(name_node, src).unwrap_or_else(|| text(name_node, src)) } else { text(name_node, src) };
        let kind = match keyword {
            "struct" => SymbolKind::Struct,
            "enum" => SymbolKind::Enum,
            "extension" => SymbolKind::Extension,
            _ => SymbolKind::Class,
        };
        let id = self.define(n, name, kind, sc, is_visible(n, src));
        let inner = Scope { parent: Some(id), exported: self.facts.symbols[id as usize].exported, generics: self.generics_of(n, sc) };
        let body = n.child_by_field_name("body");
        let mut first_inherited = true;
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            if Some(child) == body {
                continue;
            }
            if child.kind() == "inheritance_specifier" {
                if let Some(t) = child.child_by_field_name("inherits_from").and_then(|t| last_type_name(t, src)) {
                    // The first name of a class may be its superclass; everything else conforms.
                    let superclass = keyword == "class" && first_inherited && !COMMON_PROTOCOLS.contains(&t);
                    let kind = if superclass { HierarchyKind::Extends } else { HierarchyKind::Implements };
                    self.facts.hierarchy.push(TypeRelation { symbol: id, target: t.to_string(), kind });
                }
                first_inherited = false;
            }
            // The extended type, the inherited types and the constraints are all type references
            // from this declaration; for an extension the first one is what ties it to its type.
            self.refs(child, Some(id), &inner, &HashSet::new());
        }
        if let Some(b) = body {
            self.decls(b, &inner);
        }
    }

    fn protocol(&mut self, n: Node, sc: &Scope) {
        let src = self.src;
        let Some(name) = field_text(n, "name", src) else { return };
        let id = self.define(n, name, SymbolKind::Trait, sc, is_visible(n, src));
        let inner = Scope { parent: Some(id), exported: self.facts.symbols[id as usize].exported, generics: sc.generics.clone() };
        let body = n.child_by_field_name("body");
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            if Some(child) == body {
                continue;
            }
            if child.kind() == "inheritance_specifier"
                && let Some(t) = child.child_by_field_name("inherits_from").and_then(|t| last_type_name(t, src))
            {
                self.facts.hierarchy.push(TypeRelation { symbol: id, target: t.to_string(), kind: HierarchyKind::Extends });
            }
            self.refs(child, Some(id), &inner, &HashSet::new());
        }
        if let Some(b) = body {
            self.decls(b, &inner);
        }
    }

    fn in_type(&self, sc: &Scope) -> bool {
        sc.parent.is_some_and(|p| {
            matches!(
                self.facts.symbols[p as usize].kind,
                SymbolKind::Class | SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::Extension
            )
        })
    }

    fn function(&mut self, n: Node, name: &str, sc: &Scope) {
        let kind = if self.in_type(sc) { SymbolKind::Method } else { SymbolKind::Function };
        let id = self.define(n, name, kind, sc, is_visible(n, self.src));
        let scope = Scope { generics: self.generics_of(n, sc), ..sc.clone() };
        let bound = bound_names(n, self.src);
        let name_node = n.child_by_field_name("name");
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            if Some(child) != name_node {
                self.refs(child, Some(id), &scope, &bound);
            }
        }
    }

    /// `let x = 1, y = 2` is two symbols over one span. At type level they are fields, at file
    /// level constants or variables.
    fn property(&mut self, n: Node, sc: &Scope) {
        let src = self.src;
        let mut c = n.walk();
        let is_let = n.named_children(&mut c).find(|k| k.kind() == "value_binding_pattern").is_some_and(|b| text(b, src).trim() == "let");
        let kind = if self.in_type(sc) {
            SymbolKind::Field
        } else if is_let {
            SymbolKind::Const
        } else {
            SymbolKind::Variable
        };
        let mut c = n.walk();
        let patterns: Vec<Node> = n.children_by_field_name("name", &mut c).filter(|k| k.kind() == "pattern").collect();
        let mut first = None;
        for p in patterns {
            let mut stack = vec![p];
            while let Some(x) = stack.pop() {
                if let Some(b) = x.child_by_field_name("bound_identifier") {
                    let id = self.define(n, text(b, src), kind, sc, is_visible(n, src));
                    first.get_or_insert(id);
                } else {
                    let mut c2 = x.walk();
                    stack.extend(x.named_children(&mut c2));
                }
            }
        }
        // A computed property's accessors and an initial value are the symbol's own references.
        self.refs(n, first.or(sc.parent), sc, &bound_names(n, src));
    }

    fn push_ref(&mut self, at: Node, name: &str, qualifier: Option<String>, enclosing: Option<u32>, kind: RefKind) {
        self.facts.refs.push(Reference { name: name.to_string(), qualifier, line: at.start_position().row as u32 + 1, enclosing, kind });
    }

    fn type_ref(&mut self, n: Node, enclosing: Option<u32>, sc: &Scope) {
        let src = self.src;
        let mut c = n.walk();
        let names: Vec<&str> = n.named_children(&mut c).filter(|k| k.kind() == "type_identifier").map(|k| text(k, src)).collect();
        if let Some((last, rest)) = names.split_last() {
            let qualifier = (!rest.is_empty()).then(|| rest.join("."));
            if qualifier.is_some() || !(PRIMITIVES.contains(last) || sc.generics.contains(*last)) {
                self.push_ref(n, last, qualifier, enclosing, RefKind::Type);
            }
        }
    }

    /// `a.b.c(…)` as a root expression and a list of member names. Each member is a reference
    /// qualified by everything before it. A bare capitalised root (`Registry`) is a use of that
    /// type in its own right, so the file still depends on it when the member cannot be found.
    fn navigation<'t>(&mut self, n: Node<'t>, is_call: bool, enclosing: Option<u32>, stack: &mut Vec<Node<'t>>) {
        let src = self.src;
        let mut suffixes: Vec<Node<'t>> = Vec::new();
        let mut root = n;
        while root.kind() == "navigation_expression" {
            let Some(suffix) = root.child_by_field_name("suffix").and_then(|s| s.child_by_field_name("suffix")) else { break };
            suffixes.push(suffix);
            match root.child_by_field_name("target") {
                Some(t) => root = t,
                None => break,
            }
        }
        suffixes.reverse();
        // Only a simple name or `self`/`super` roots a qualifier worth keeping; anything else
        // (a call result, a subscript) is walked for its own references.
        let simple_root = matches!(root.kind(), "simple_identifier" | "self_expression" | "super_expression");
        if !simple_root {
            stack.push(root);
        }
        let root_text = text(root, src);
        if simple_root && root.kind() == "simple_identifier" && root_text.starts_with(|c: char| c.is_uppercase()) && !PRIMITIVES.contains(&root_text) {
            self.push_ref(root, root_text, None, enclosing, RefKind::Use);
        }
        for (i, s) in suffixes.iter().enumerate() {
            let prev_end = if i == 0 { root.end_byte() } else { suffixes[i - 1].end_byte() };
            let qualifier = one_line(src[root.start_byte()..prev_end].trim_end_matches(['?', '!']));
            let name = text(*s, src);
            let last = i + 1 == suffixes.len();
            let kind = if last && is_call { RefKind::Call } else { RefKind::Use };
            // A member read off a lowercase receiver (`items.count`) is almost always a library
            // property and resolving it by name would bind it to an unrelated definition. Calls,
            // `self.x` and `Type.x` are worth recording.
            let tail = qualifier.rsplit('.').next().unwrap_or(&qualifier);
            let worth = kind == RefKind::Call || qualifier == "self" || qualifier == "Self" || tail.starts_with(|c: char| c.is_uppercase());
            if worth {
                self.push_ref(*s, name, Some(qualifier), enclosing, kind);
            }
        }
    }

    /// References inside any subtree: calls, qualified members, and type positions.
    fn refs(&mut self, root: Node, enclosing: Option<u32>, sc: &Scope, bound: &HashSet<String>) {
        let src = self.src;
        let mut stack: Vec<Node> = vec![root];
        while let Some(n) = stack.pop() {
            match n.kind() {
                // Attributes name property wrappers and macros, which are never repository code
                // worth an edge, and modifiers hold nothing else.
                "attribute" | "modifiers" | "comment" | "multiline_comment" => continue,
                "user_type" => {
                    self.type_ref(n, enclosing, sc);
                    let mut c = n.walk();
                    stack.extend(n.named_children(&mut c).filter(|k| k.kind() != "type_identifier"));
                    continue;
                }
                "call_expression" => {
                    let mut c = n.walk();
                    let mut kids = n.named_children(&mut c);
                    if let Some(callee) = kids.next() {
                        match callee.kind() {
                            "simple_identifier" => {
                                let name = text(callee, src);
                                if !bound.contains(name) {
                                    self.push_ref(callee, name, None, enclosing, RefKind::Call);
                                }
                            }
                            "navigation_expression" => {
                                let mut pending = Vec::new();
                                self.navigation(callee, true, enclosing, &mut pending);
                                stack.extend(pending);
                            }
                            _ => stack.push(callee),
                        }
                    }
                    stack.extend(kids);
                    continue;
                }
                "navigation_expression" => {
                    let mut pending = Vec::new();
                    self.navigation(n, false, enclosing, &mut pending);
                    stack.extend(pending);
                    continue;
                }
                "simple_identifier" => {
                    let name = text(n, src);
                    if name.starts_with(|c: char| c.is_uppercase()) && !PRIMITIVES.contains(&name) && !sc.generics.contains(name) {
                        self.push_ref(n, name, None, enclosing, RefKind::Use);
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
}

/// Names bound inside a declaration: parameters, `let`/`var`, `if let`, `for` and closure
/// parameters. A call to one of these is a call to a local closure, never to a definition.
fn bound_names(decl: Node, src: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    let mut stack = vec![decl];
    while let Some(n) = stack.pop() {
        if let Some(b) = n.child_by_field_name("bound_identifier") {
            out.insert(text(b, src).to_string());
        }
        if matches!(n.kind(), "parameter" | "lambda_parameter") {
            let mut c = n.walk();
            for name in n.children_by_field_name("name", &mut c).filter(|k| k.kind() == "simple_identifier") {
                out.insert(text(name, src).to_string());
            }
        }
        let mut c = n.walk();
        stack.extend(n.named_children(&mut c));
    }
    out
}
