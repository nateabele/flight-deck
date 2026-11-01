//! Python.

use super::util::*;
use super::Language;
use crate::facts::*;
use std::collections::HashSet;
use tree_sitter::Node;

pub struct Python;

impl Language for Python {
    fn id(&self) -> &'static str {
        "python"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["py", "pyi"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        let mut facts = BlobFacts { line_count: line_count(source), ..Default::default() };
        let lang = tree_sitter_python::LANGUAGE.into();
        let Some(tree) = parse(&lang, source) else { return facts };
        let root = tree.root_node();
        let mut w = Walker { src: source, facts: &mut facts, imported: HashSet::new(), all: None };
        // Imports first, wherever they sit (inside `try`, `if TYPE_CHECKING`, a function): the
        // names they bind decide which bare identifiers are worth recording as references, and
        // recording every local variable instead would drown the facts in unresolvable noise.
        w.collect_imports(root);
        w.walk(root, None, None, Scope::Module);
        w.apply_dunder_all();
        facts
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Scope {
    Module,
    Class,
    /// Inside a def: nested defs and classes are locals, not symbols.
    Function,
}

/// Builtins that are called constantly and never defined by the repository.
const BUILTIN_CALLS: &[&str] = &[
    "print", "len", "range", "str", "int", "float", "bool", "list", "dict", "set", "tuple", "frozenset", "bytes",
    "isinstance", "issubclass", "getattr", "setattr", "hasattr", "delattr", "super", "type", "open", "sorted",
    "reversed", "enumerate", "zip", "map", "filter", "min", "max", "sum", "any", "all", "abs", "round", "repr",
    "iter", "next", "id", "hash", "vars", "dir", "callable", "format", "ord", "chr", "input", "property",
    "staticmethod", "classmethod", "object", "Exception", "ValueError", "TypeError", "KeyError", "RuntimeError",
];

/// Annotation names that are never a definition in the repository.
const BUILTIN_TYPES: &[&str] = &[
    "int", "str", "float", "bool", "bytes", "list", "dict", "set", "tuple", "frozenset", "object", "None", "type",
    "Any", "List", "Dict", "Set", "Tuple", "Optional", "Union", "Callable", "Iterable", "Iterator", "Sequence",
    "Mapping", "Type", "ClassVar", "Literal", "Self", "Awaitable", "Generator", "AsyncIterator",
];

struct Walker<'a> {
    src: &'a str,
    facts: &'a mut BlobFacts,
    /// Local names bound by imports (`import a.b` binds `a`).
    imported: HashSet<String>,
    all: Option<HashSet<String>>,
}

fn is_public(name: &str) -> bool {
    !name.starts_with('_') || (name.starts_with("__") && name.ends_with("__") && name.len() > 4)
}

impl<'a> Walker<'a> {
    fn collect_imports(&mut self, root: Node) {
        let src = self.src;
        let mut stack = vec![root];
        while let Some(n) = stack.pop() {
            match n.kind() {
                "import_statement" => {
                    let mut c = n.walk();
                    for item in n.children_by_field_name("name", &mut c) {
                        let (dotted, alias) = match item.kind() {
                            "aliased_import" => (
                                item.child_by_field_name("name").map(|d| text(d, src)),
                                item.child_by_field_name("alias").map(|a| text(a, src)),
                            ),
                            _ => (Some(text(item, src)), None),
                        };
                        let Some(dotted) = dotted else { continue };
                        let bound = alias.unwrap_or_else(|| dotted.split('.').next().unwrap_or(dotted));
                        self.imported.insert(bound.to_string());
                        self.facts.imports.push(Import {
                            specifier: dotted.to_string(),
                            alias: alias.map(str::to_string),
                            names: vec![],
                            line: n.start_position().row as u32 + 1,
                            kind: ImportKind::Import,
                        });
                    }
                }
                "import_from_statement" => {
                    let Some(module) = field_text(n, "module_name", src) else { continue };
                    if module == "__future__" {
                        continue;
                    }
                    let mut names = Vec::new();
                    let mut c = n.walk();
                    for item in n.children_by_field_name("name", &mut c) {
                        let (name, alias) = match item.kind() {
                            "aliased_import" => (
                                item.child_by_field_name("name").map(|d| text(d, src)),
                                item.child_by_field_name("alias").map(|a| text(a, src)),
                            ),
                            _ => (Some(text(item, src)), None),
                        };
                        if let Some(name) = name {
                            self.imported.insert(alias.unwrap_or(name).to_string());
                            names.push(ImportName { name: name.to_string(), alias: alias.map(str::to_string), subs: false });
                        }
                    }
                    let mut c = n.walk();
                    if n.children(&mut c).any(|k| k.kind() == "wildcard_import") {
                        names.push(ImportName::plain("*"));
                    }
                    self.facts.imports.push(Import {
                        specifier: module.to_string(),
                        alias: None,
                        names,
                        line: n.start_position().row as u32 + 1,
                        kind: ImportKind::Import,
                    });
                }
                _ => {
                    let mut c = n.walk();
                    let kids: Vec<Node> = n.named_children(&mut c).collect();
                    stack.extend(kids.into_iter().rev());
                }
            }
        }
    }

    fn walk_children(&mut self, n: Node, parent: Option<u32>, enclosing: Option<u32>, scope: Scope) {
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            self.walk(child, parent, enclosing, scope);
        }
    }

    fn walk(&mut self, n: Node, parent: Option<u32>, enclosing: Option<u32>, scope: Scope) {
        let src = self.src;
        match n.kind() {
            // Imports were read up front and bind names, they reference nothing.
            "import_statement" | "import_from_statement" | "future_import_statement" => {}
            "decorated_definition" => {
                let mut c = n.walk();
                let mut def = None;
                for child in n.named_children(&mut c) {
                    if child.kind() == "decorator" {
                        self.decorator(child, enclosing);
                    } else {
                        def = Some(child);
                    }
                }
                if let Some(d) = def {
                    self.definition(d, n, parent, enclosing, scope);
                }
            }
            "function_definition" | "class_definition" => self.definition(n, n, parent, enclosing, scope),
            "expression_statement" if scope != Scope::Function => {
                let mut handled = false;
                if let Some(a) = n.named_child(0) {
                    match a.kind() {
                        "assignment" => handled = self.assignment(n, a, parent, scope),
                        "augmented_assignment" if a.child_by_field_name("left").is_some_and(|l| text(l, src) == "__all__") => {
                            self.read_dunder_all(a);
                        }
                        _ => {}
                    }
                }
                if !handled {
                    self.walk_children(n, parent, enclosing, scope);
                }
            }
            "call" => {
                let Some(f) = n.child_by_field_name("function") else { return };
                match f.kind() {
                    "identifier" => {
                        let name = text(f, src);
                        if !BUILTIN_CALLS.contains(&name) {
                            self.push_ref(f, name, None, enclosing, RefKind::Call);
                        }
                    }
                    "attribute" => {
                        if let (Some(obj), Some(attr)) = (f.child_by_field_name("object"), f.child_by_field_name("attribute")) {
                            self.push_ref(attr, text(attr, src), Some(one_line(text(obj, src))), enclosing, RefKind::Call);
                            self.walk(obj, parent, enclosing, scope);
                        }
                    }
                    _ => self.walk(f, parent, enclosing, scope),
                }
                if let Some(args) = n.child_by_field_name("arguments") {
                    self.walk_children(args, parent, enclosing, scope);
                }
            }
            "attribute" => {
                let (Some(obj), Some(attr)) = (n.child_by_field_name("object"), n.child_by_field_name("attribute")) else { return };
                if self.root_is_imported(obj) {
                    self.push_ref(attr, text(attr, src), Some(one_line(text(obj, src))), enclosing, RefKind::Use);
                } else {
                    self.walk(obj, parent, enclosing, scope);
                }
            }
            "type" => self.type_refs(n, enclosing),
            "identifier" => {
                let name = text(n, src);
                if self.imported.contains(name) && !is_binding_site(n) {
                    self.push_ref(n, name, None, enclosing, RefKind::Use);
                }
            }
            _ => self.walk_children(n, parent, enclosing, scope),
        }
    }

    fn root_is_imported(&self, mut n: Node) -> bool {
        while n.kind() == "attribute" {
            match n.child_by_field_name("object") {
                Some(o) => n = o,
                None => return false,
            }
        }
        n.kind() == "identifier" && self.imported.contains(text(n, self.src))
    }

    fn push_ref(&mut self, at: Node, name: &str, qualifier: Option<String>, enclosing: Option<u32>, kind: RefKind) {
        self.facts.refs.push(Reference { name: name.to_string(), qualifier, line: at.start_position().row as u32 + 1, enclosing, kind });
    }

    fn decorator(&mut self, d: Node, enclosing: Option<u32>) {
        let src = self.src;
        let Some(e) = d.named_child(0) else { return };
        match e.kind() {
            "identifier" => self.push_ref(e, text(e, src), None, enclosing, RefKind::Call),
            "attribute" => {
                if let (Some(obj), Some(attr)) = (e.child_by_field_name("object"), e.child_by_field_name("attribute")) {
                    self.push_ref(attr, text(attr, src), Some(one_line(text(obj, src))), enclosing, RefKind::Call);
                }
            }
            _ => self.walk(e, None, enclosing, Scope::Function),
        }
    }

    /// Type positions: every name inside an annotation is a type reference.
    fn type_refs(&mut self, root: Node, enclosing: Option<u32>) {
        let src = self.src;
        let mut stack = vec![root];
        while let Some(n) = stack.pop() {
            match n.kind() {
                "identifier" => {
                    let name = text(n, src);
                    if !BUILTIN_TYPES.contains(&name) {
                        self.push_ref(n, name, None, enclosing, RefKind::Type);
                    }
                }
                "attribute" => {
                    if let (Some(obj), Some(attr)) = (n.child_by_field_name("object"), n.child_by_field_name("attribute")) {
                        self.push_ref(attr, text(attr, src), Some(one_line(text(obj, src))), enclosing, RefKind::Type);
                    }
                }
                _ => {
                    let mut c = n.walk();
                    stack.extend(n.named_children(&mut c));
                }
            }
        }
    }

    /// A `def` or `class`. `span` is the decorated wrapper when there is one, so the symbol's range
    /// covers the decorators a reader needs to see.
    fn definition(&mut self, n: Node, span: Node, parent: Option<u32>, enclosing: Option<u32>, scope: Scope) {
        let src = self.src;
        let is_class = n.kind() == "class_definition";
        if scope == Scope::Function {
            // A local def/class is not addressable from outside; its references belong to the
            // symbol around it.
            self.walk_children(n, parent, enclosing, Scope::Function);
            return;
        }
        let Some(name) = field_text(n, "name", src) else { return };
        let kind = match (is_class, scope) {
            (true, _) => SymbolKind::Class,
            (false, Scope::Class) => SymbolKind::Method,
            (false, _) => SymbolKind::Function,
        };
        let end = n.child_by_field_name("body").map(|b| b.start_byte()).unwrap_or(n.end_byte());
        let sig = one_line(src[n.start_byte()..end].trim_end_matches([':', ' ', '\n', '\t', '\\']));
        let id = self.facts.push_symbol(symbol(span, name, kind, Some(sig), parent, is_public(name)));
        let name_node = n.child_by_field_name("name");
        let body = n.child_by_field_name("body");
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            if Some(child) == name_node {
                continue;
            }
            if is_class && child.kind() == "argument_list" && Some(child) != body {
                self.bases(child, id);
            } else if Some(child) == body {
                let inner = if is_class { Scope::Class } else { Scope::Function };
                self.walk_children(child, Some(id), Some(id), inner);
            } else {
                // Parameters (defaults and annotations), return type, type parameters.
                self.walk(child, parent, Some(id), Scope::Function);
            }
        }
    }

    fn bases(&mut self, args: Node, class: u32) {
        let src = self.src;
        let mut c = args.walk();
        for b in args.named_children(&mut c) {
            let (name, qualifier) = match b.kind() {
                "identifier" => (text(b, src), None),
                "attribute" => match (b.child_by_field_name("object"), b.child_by_field_name("attribute")) {
                    (Some(o), Some(a)) => (text(a, src), Some(one_line(text(o, src)))),
                    _ => continue,
                },
                // `metaclass=Meta`, `*bases`, subscripted generics: not plain inheritance.
                _ => continue,
            };
            if name != "object" {
                self.facts.hierarchy.push(TypeRelation { symbol: class, target: name.to_string(), kind: HierarchyKind::Extends });
            }
            self.push_ref(b, name, qualifier, Some(class), RefKind::Type);
        }
    }

    /// `NAME = value` / `NAME: type = value` at module or class level. Returns whether it was
    /// consumed (a tuple-unpacking target is left to the generic walk).
    fn assignment(&mut self, stmt: Node, a: Node, parent: Option<u32>, scope: Scope) -> bool {
        let src = self.src;
        let Some(left) = a.child_by_field_name("left").filter(|l| l.kind() == "identifier") else { return false };
        let name = text(left, src);
        if name == "__all__" {
            self.read_dunder_all(a);
            return true;
        }
        let kind = match scope {
            Scope::Class => SymbolKind::Field,
            _ if name.chars().any(|c| c.is_alphabetic()) && name.chars().all(|c| c.is_uppercase() || c.is_ascii_digit() || c == '_') => SymbolKind::Const,
            _ => SymbolKind::Variable,
        };
        let sig = match a.child_by_field_name("type") {
            Some(t) => one_line(&format!("{name}: {}", text(t, src))),
            None => name.to_string(),
        };
        let id = self.facts.push_symbol(symbol(stmt, name, kind, Some(sig), parent, is_public(name)));
        if let Some(t) = a.child_by_field_name("type") {
            self.type_refs(t, Some(id));
        }
        if let Some(r) = a.child_by_field_name("right") {
            self.walk(r, parent, Some(id), Scope::Function);
        }
        true
    }

    fn read_dunder_all(&mut self, assignment: Node) {
        let Some(right) = assignment.child_by_field_name("right") else { return };
        let all = self.all.get_or_insert_with(HashSet::new);
        let mut stack = vec![right];
        while let Some(n) = stack.pop() {
            if n.kind() == "string_content" {
                all.insert(text(n, self.src).to_string());
            }
            let mut c = n.walk();
            stack.extend(n.named_children(&mut c));
        }
    }

    /// `__all__` is the author's own statement of the public API and beats the underscore rule.
    fn apply_dunder_all(&mut self) {
        if let Some(all) = &self.all {
            for s in self.facts.symbols.iter_mut().filter(|s| s.parent.is_none()) {
                s.exported = all.contains(&s.name);
            }
        }
    }
}

/// An identifier that is being declared rather than used: a parameter name, a keyword-argument
/// name, or the member side of `x.name`.
fn is_binding_site(n: Node) -> bool {
    let Some(p) = n.parent() else { return false };
    match p.kind() {
        "parameters" | "lambda_parameters" | "typed_parameter" | "list_splat_pattern" | "dictionary_splat_pattern" => true,
        "default_parameter" | "typed_default_parameter" | "keyword_argument" => p.child_by_field_name("name") == Some(n),
        "attribute" => p.child_by_field_name("attribute") == Some(n),
        _ => false,
    }
}
