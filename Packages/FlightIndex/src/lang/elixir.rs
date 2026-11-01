//! Elixir. Everything is a macro call in this grammar (`defmodule`, `def`, `alias` are all `call`
//! nodes), so the extractor dispatches on the called identifier instead of on node kinds.

use super::util::*;
use super::Language;
use crate::facts::*;
use std::collections::{HashMap, HashSet};
use tree_sitter::Node;

pub struct Elixir;

impl Language for Elixir {
    fn id(&self) -> &'static str {
        "elixir"
    }

    fn parser_version(&self) -> u32 {
        1
    }

    fn extensions(&self) -> &'static [&'static str] {
        &["ex", "exs"]
    }

    fn extract(&self, source: &str) -> BlobFacts {
        let mut facts = BlobFacts { line_count: line_count(source), ..Default::default() };
        let lang = tree_sitter_elixir::LANGUAGE.into();
        let Some(tree) = parse(&lang, source) else { return facts };
        let mut w = Walker {
            src: source,
            facts: &mut facts,
            frames: vec![Frame::default()],
            defined: HashSet::new(),
            imported: HashSet::new(),
            wildcard: false,
        };
        w.walk(tree.root_node(), Ctx { parent: None, enclosing: None, body: false, in_type: false });
        w.drop_unbound_local_calls();
        facts
    }
}

/// Kernel functions and special forms that are called everywhere and never defined by the
/// repository. Recording them would add a reference per `if` that can only ever resolve wrongly.
const KERNEL: &[&str] = &[
    "if", "unless", "case", "cond", "with", "for", "fn", "try", "receive", "raise", "reraise", "throw", "exit",
    "quote", "unquote", "super", "send", "spawn", "spawn_link", "apply", "inspect", "to_string", "is_nil",
    "is_atom", "is_binary", "is_boolean", "is_float", "is_function", "is_integer", "is_list", "is_map",
    "is_number", "is_pid", "is_tuple", "is_struct", "length", "elem", "hd", "tl", "map_size", "tuple_size",
    "byte_size", "abs", "max", "min", "round", "trunc", "div", "rem", "not", "and", "or", "put_in", "get_in",
    "update_in", "struct", "self", "node", "binding", "ok", "error", "when", "in", "def", "defp", "defmacro",
    "defmacrop", "defmodule", "defstruct", "defexception", "defprotocol", "defimpl", "defdelegate", "defguard",
    "defguardp", "alias", "import", "require", "use", "__MODULE__", "__ENV__", "sigil_r", "sigil_s", "sigil_w",
];

/// One module scope: what `alias` has bound, the `@spec`s waiting for their `def`, and the
/// function symbols already made (so a second clause extends the first).
#[derive(Default, Clone)]
struct Frame {
    full: String,
    aliases: HashMap<String, String>,
    specs: HashMap<(String, usize), String>,
    fns: HashMap<(String, usize, bool, bool), u32>,
    symbol: Option<u32>,
}

#[derive(Clone, Copy)]
struct Ctx {
    parent: Option<u32>,
    enclosing: Option<u32>,
    /// Directly in a module body (possibly under an `if`), where `def` defines a symbol; inside a
    /// function body it is just a call, e.g. in a `quote`.
    body: bool,
    /// Inside `@type`/`@spec`: calls there are type references.
    in_type: bool,
}

struct Walker<'a> {
    src: &'a str,
    facts: &'a mut BlobFacts,
    frames: Vec<Frame>,
    defined: HashSet<String>,
    imported: HashSet<String>,
    wildcard: bool,
}

impl<'a> Walker<'a> {
    fn frame(&mut self) -> &mut Frame {
        self.frames.last_mut().unwrap()
    }

    fn line(n: Node) -> u32 {
        n.start_position().row as u32 + 1
    }

    /// `A.B` as written -> the module it names: the first segment goes through `alias`, and
    /// `__MODULE__` is the enclosing module.
    fn expand(&self, written: &str) -> String {
        let frame = self.frames.last().unwrap();
        let (first, rest) = match written.split_once('.') {
            Some((f, r)) => (f, Some(r)),
            None => (written, None),
        };
        let head = if first == "__MODULE__" {
            frame.full.clone()
        } else {
            frame.aliases.get(first).cloned().unwrap_or_else(|| first.to_string())
        };
        match rest {
            Some(r) => format!("{head}.{r}"),
            None => head,
        }
    }

    fn push_ref(&mut self, at: Node, name: &str, qualifier: Option<String>, enclosing: Option<u32>, kind: RefKind) {
        self.facts.refs.push(Reference { name: name.to_string(), qualifier, line: Self::line(at), enclosing, kind });
    }

    /// A reference to the module `full` (`Foo.Bar` -> qualifier `Foo`, name `Bar`).
    fn module_ref(&mut self, at: Node, full: &str, enclosing: Option<u32>, kind: RefKind) {
        let (q, name) = split_qualified(full, ".");
        let (q, name) = (q.map(str::to_string), name.to_string());
        self.push_ref(at, &name, q, enclosing, kind);
    }

    fn walk_children(&mut self, n: Node, ctx: Ctx) {
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            self.walk(child, ctx);
        }
    }

    fn walk(&mut self, n: Node, ctx: Ctx) {
        let src = self.src;
        match n.kind() {
            "call" => self.call(n, ctx),
            "unary_operator" if text(n, src).starts_with('@') => self.attribute(n, ctx),
            "struct" => {
                if let Some(m) = n.named_child(0) {
                    let written = text(m, src);
                    let full = self.expand(written);
                    self.module_ref(m, &full, ctx.enclosing, RefKind::Type);
                }
                let mut c = n.walk();
                for child in n.named_children(&mut c).skip(1) {
                    self.walk(child, ctx);
                }
            }
            "alias" => {
                let full = self.expand(text(n, src));
                self.module_ref(n, &full, ctx.enclosing, RefKind::Use);
            }
            "dot" => {
                // A dot outside a call target: `Foo.Bar.baz` without parens is still a call, but a
                // bare `Foo.Bar.Baz` alias is a module mention.
                if let Some(l) = n.child_by_field_name("left") {
                    self.walk(l, ctx);
                }
            }
            _ => self.walk_children(n, ctx),
        }
    }

    fn call(&mut self, n: Node, ctx: Ctx) {
        let src = self.src;
        let Some(target) = n.child_by_field_name("target") else { return self.walk_children(n, ctx) };
        match target.kind() {
            "identifier" => {
                let name = text(target, src);
                match name {
                    "defmodule" => self.module(n, ctx, SymbolKind::Module),
                    "defprotocol" => self.module(n, ctx, SymbolKind::Trait),
                    "defimpl" => self.defimpl(n, ctx),
                    "def" | "defp" | "defmacro" | "defmacrop" | "defguard" | "defguardp" | "defdelegate" if ctx.body => {
                        self.function(n, name, ctx)
                    }
                    "defstruct" | "defexception" if ctx.body => self.defstruct(n, ctx),
                    "alias" | "import" | "require" | "use" => self.import(n, name),
                    _ => {
                        if !KERNEL.contains(&name) {
                            let kind = if ctx.in_type { RefKind::Type } else { RefKind::Call };
                            self.push_ref(target, name, None, ctx.enclosing, kind);
                        }
                        self.walk_children_except(n, target, ctx);
                    }
                }
            }
            "dot" => {
                let (left, right) = (target.child_by_field_name("left"), target.child_by_field_name("right"));
                if let (Some(l), Some(r)) = (left, right) {
                    let kind = if ctx.in_type { RefKind::Type } else { RefKind::Call };
                    match l.kind() {
                        // `Mod.fun()`, `__MODULE__.fun()`. A variable or atom on the left
                        // (`conn.assigns`, `:ets.insert`) names no repository module.
                        "alias" => {
                            let q = self.expand(text(l, src));
                            self.push_ref(r, text(r, src), Some(q), ctx.enclosing, kind);
                        }
                        "identifier" if text(l, src) == "__MODULE__" => {
                            let q = self.expand("__MODULE__");
                            self.push_ref(r, text(r, src), Some(q), ctx.enclosing, kind);
                        }
                        _ => self.walk(l, ctx),
                    }
                }
                self.walk_children_except(n, target, ctx);
            }
            _ => self.walk_children(n, ctx),
        }
    }

    fn walk_children_except(&mut self, n: Node, skip: Node, ctx: Ctx) {
        let mut c = n.walk();
        for child in n.named_children(&mut c) {
            if child != skip {
                self.walk(child, ctx);
            }
        }
    }

    fn args(n: Node) -> Option<Node> {
        let mut c = n.walk();
        n.named_children(&mut c).find(|k| k.kind() == "arguments")
    }

    fn do_block(n: Node) -> Option<Node> {
        let mut c = n.walk();
        n.named_children(&mut c).find(|k| k.kind() == "do_block")
    }

    /// `defmodule Foo.Bar do … end` and `defprotocol`: a symbol named by the full dotted name, with
    /// a fresh alias scope that inherits the parent's (as Elixir's lexical scoping does).
    fn module(&mut self, n: Node, ctx: Ctx, kind: SymbolKind) {
        let src = self.src;
        let Some(name_node) = Self::args(n).and_then(|a| a.named_child(0)) else { return };
        let written = text(name_node, src);
        let parent_full = self.frame().full.clone();
        let full = if parent_full.is_empty() { written.to_string() } else { format!("{parent_full}.{written}") };
        let sig = format!("{} {written}", if kind == SymbolKind::Trait { "defprotocol" } else { "defmodule" });
        let id = self.facts.push_symbol(symbol(n, &full, kind, Some(sig), ctx.parent, true));
        // A nested module is usable by its short name in the module that contains it.
        if !parent_full.is_empty() {
            let first = written.split('.').next().unwrap_or(written);
            let head = format!("{parent_full}.{first}");
            self.frame().aliases.insert(first.to_string(), head);
        }
        let mut frame = self.frames.last().unwrap().clone();
        frame.full = full;
        frame.symbol = Some(id);
        frame.specs.clear();
        frame.fns.clear();
        self.frames.push(frame);
        if let Some(block) = Self::do_block(n) {
            self.walk_children(block, Ctx { parent: Some(id), enclosing: Some(id), body: true, in_type: false });
        }
        self.frames.pop();
    }

    /// `defimpl Proto, for: Target do … end`: an impl of `Proto` for `Target`.
    fn defimpl(&mut self, n: Node, ctx: Ctx) {
        let src = self.src;
        let Some(args) = Self::args(n) else { return };
        let Some(proto_node) = args.named_child(0).filter(|p| p.kind() == "alias") else { return };
        let proto = self.expand(text(proto_node, src));
        // `for:` may be absent inside a module (the module itself), a name, or a list of names.
        let mut targets: Vec<String> = Vec::new();
        let mut c = args.walk();
        for kw in args.named_children(&mut c).filter(|k| k.kind() == "keywords") {
            let mut c2 = kw.walk();
            for pair in kw.named_children(&mut c2) {
                if pair.child_by_field_name("key").is_some_and(|k| text(k, src).trim_end_matches([':', ' ']) == "for")
                    && let Some(v) = pair.child_by_field_name("value")
                {
                    let mut stack = vec![v];
                    while let Some(x) = stack.pop() {
                        if x.kind() == "alias" {
                            targets.push(self.expand(text(x, src)));
                        } else if x.kind() == "identifier" && text(x, src) == "__MODULE__" {
                            targets.push(self.expand("__MODULE__"));
                        } else {
                            let mut c3 = x.walk();
                            stack.extend(x.named_children(&mut c3));
                        }
                    }
                }
            }
        }
        if targets.is_empty() {
            targets.push(self.frame().full.clone());
        }
        for target in targets {
            let sig = format!("defimpl {proto}, for: {target}");
            let id = self.facts.push_symbol(symbol(n, &target, SymbolKind::Impl, Some(sig), ctx.parent, true));
            self.facts.hierarchy.push(TypeRelation { symbol: id, target: proto.clone(), kind: HierarchyKind::Implements });
            self.module_ref(proto_node, &proto, Some(id), RefKind::Type);
            let mut frame = self.frames.last().unwrap().clone();
            frame.full = format!("{proto}.{target}");
            frame.symbol = Some(id);
            frame.specs.clear();
            frame.fns.clear();
            self.frames.push(frame);
            if let Some(block) = Self::do_block(n) {
                self.walk_children(block, Ctx { parent: Some(id), enclosing: Some(id), body: true, in_type: false });
            }
            self.frames.pop();
        }
    }

    fn container_kind(&self, parent: Option<u32>) -> SymbolKind {
        match parent.map(|p| self.facts.symbols[p as usize].kind) {
            Some(SymbolKind::Trait | SymbolKind::Impl) => SymbolKind::Method,
            _ => SymbolKind::Function,
        }
    }

    /// `def`/`defp`/`defmacro`/… The name and arity come from the head, which may carry a `when`
    /// guard. Clauses with the same name and arity are one symbol that grows to span them all.
    fn function(&mut self, n: Node, keyword: &str, ctx: Ctx) {
        let src = self.src;
        let Some(args) = Self::args(n) else { return };
        let Some(mut head) = args.named_child(0) else { return };
        let mut guard = None;
        if head.kind() == "binary_operator" && text(head, src).contains(" when ") {
            guard = head.child_by_field_name("right");
            if let Some(l) = head.child_by_field_name("left") {
                head = l;
            }
        }
        let Some(target_node) = n.child_by_field_name("target") else { return };
        let (name_node, arity) = match head.kind() {
            "call" => {
                let Some(t) = head.child_by_field_name("target").filter(|t| t.kind() == "identifier") else {
                    return self.walk_children(n, ctx);
                };
                let arity = Self::args(head).map(|a| a.named_child_count()).unwrap_or(0);
                (t, arity)
            }
            "identifier" => (head, 0),
            _ => return self.walk_children(n, ctx), // operator definitions: `def a + b`
        };
        let name = text(name_node, src).to_string();
        let private = matches!(keyword, "defp" | "defmacrop" | "defguardp");
        let is_macro = matches!(keyword, "defmacro" | "defmacrop" | "defguard" | "defguardp");
        let key = (name.clone(), arity, private, is_macro);
        let existing = self.frame().fns.get(&key).copied();
        let id = match existing {
            Some(id) => {
                let s = &mut self.facts.symbols[id as usize];
                s.end_line = n.end_position().row as u32 + 1;
                s.end_col = n.end_position().column as u32;
                id
            }
            None => {
                let kind = if is_macro { SymbolKind::Macro } else { self.container_kind(ctx.parent) };
                let mut sig = format!("{keyword} {name}/{arity}");
                if let Some(spec) = self.frame().specs.get(&(name.clone(), arity)) {
                    sig = format!("{sig} ({spec})");
                }
                let id = self.facts.push_symbol(symbol(n, &name, kind, Some(one_line(&sig)), ctx.parent, !private));
                self.frame().fns.insert(key, id);
                self.defined.insert(name.clone());
                id
            }
        };
        let inner = Ctx { parent: ctx.parent, enclosing: Some(id), body: false, in_type: false };
        if keyword == "defdelegate" {
            // `defdelegate foo(a), to: Other.Mod` is a call into `Other.Mod.foo`.
            self.delegate(n, args, &name, id);
        }
        // The head's argument patterns (`%Foo{}`), its guard, then the keyword body and `do` block.
        // The head's own name is the definition, not a call.
        if head.kind() == "call" {
            if let Some(ha) = Self::args(head) {
                self.walk_children(ha, inner);
            }
        }
        if let Some(guard) = guard {
            self.walk(guard, inner);
        }
        let mut c = n.walk();
        for child in n.named_children(&mut c).filter(|k| *k != target_node) {
            if child.kind() == "arguments" {
                let mut c2 = child.walk();
                for a in child.named_children(&mut c2).skip(1) {
                    self.walk(a, inner);
                }
            } else {
                self.walk(child, inner);
            }
        }
    }

    fn delegate(&mut self, n: Node, args: Node, name: &str, id: u32) {
        let src = self.src;
        let mut stack = vec![args];
        while let Some(x) = stack.pop() {
            if x.kind() == "pair"
                && x.child_by_field_name("key").is_some_and(|k| text(k, src).trim_end_matches([':', ' ']) == "to")
                && let Some(v) = x.child_by_field_name("value")
                && v.kind() == "alias"
            {
                let q = self.expand(text(v, src));
                self.push_ref(n, name, Some(q), Some(id), RefKind::Call);
                return;
            }
            let mut c = x.walk();
            stack.extend(x.named_children(&mut c));
        }
    }

    /// `defstruct [:a, :b]` / `defstruct a: nil`: one `__struct__` symbol (what `%Mod{}` expands
    /// to) with a field per key. It is not named after the module so `find Foo` returns the module.
    fn defstruct(&mut self, n: Node, ctx: Ctx) {
        let src = self.src;
        let id = self.facts.push_symbol(symbol(n, "__struct__", SymbolKind::Struct, Some(one_line(text(n, src))), ctx.parent, true));
        let mut names: Vec<(Node, String)> = Vec::new();
        let mut stack: Vec<Node> = Self::args(n).into_iter().collect();
        while let Some(x) = stack.pop() {
            match x.kind() {
                "atom" => names.push((x, text(x, src).trim_start_matches(':').trim_matches('"').to_string())),
                "pair" => {
                    if let Some(k) = x.child_by_field_name("key") {
                        names.push((k, text(k, src).trim_end_matches([':', ' ']).to_string()));
                    }
                    continue; // the default value is not a field name
                }
                _ => {}
            }
            let mut c = x.walk();
            let mut kids: Vec<Node> = x.named_children(&mut c).collect();
            kids.reverse();
            stack.extend(kids);
        }
        for (at, name) in names {
            self.facts.push_symbol(symbol(at, &name, SymbolKind::Field, Some(name.clone()), Some(id), true));
        }
    }

    /// `alias`, `import`, `require`, `use`.
    fn import(&mut self, n: Node, keyword: &str) {
        let src = self.src;
        let Some(args) = Self::args(n) else { return };
        let Some(first) = args.named_child(0) else { return };
        let line = Self::line(n);
        let mut opts: HashMap<String, Node> = HashMap::new();
        let mut c = args.walk();
        for kw in args.named_children(&mut c).filter(|k| k.kind() == "keywords") {
            let mut c2 = kw.walk();
            for pair in kw.named_children(&mut c2) {
                if let (Some(k), Some(v)) = (pair.child_by_field_name("key"), pair.child_by_field_name("value")) {
                    opts.insert(text(k, src).trim_end_matches([':', ' ']).to_string(), v);
                }
            }
        }
        let push = |w: &mut Self, spec: String, alias: Option<String>, names: Vec<ImportName>| {
            w.facts.imports.push(Import { specifier: spec, alias, names, line, kind: ImportKind::Import });
        };
        match keyword {
            "alias" => {
                let mut targets: Vec<(String, Option<String>)> = Vec::new();
                match first.kind() {
                    "alias" => {
                        let full = self.expand(text(first, src));
                        let short = opts.get("as").map(|a| text(*a, src).to_string());
                        targets.push((full, short));
                    }
                    // `alias Foo.{A, B.C}`
                    "dot" => {
                        let base = first.child_by_field_name("left").map(|l| self.expand(text(l, src)));
                        let group = first.child_by_field_name("right").filter(|r| r.kind() == "tuple");
                        if let (Some(base), Some(group)) = (base, group) {
                            let mut c3 = group.walk();
                            for item in group.named_children(&mut c3).filter(|i| i.kind() == "alias") {
                                targets.push((format!("{base}.{}", text(item, src)), None));
                            }
                        }
                    }
                    _ => {}
                }
                for (full, short) in targets {
                    let short = short.unwrap_or_else(|| full.rsplit('.').next().unwrap_or(&full).to_string());
                    self.frame().aliases.insert(short.clone(), full.clone());
                    push(self, full, Some(short), vec![]);
                }
            }
            "import" | "require" | "use" => {
                if !matches!(first.kind(), "alias") && !(first.kind() == "identifier" && text(first, src) == "__MODULE__") {
                    return;
                }
                let spec = self.expand(text(first, src));
                let mut names = Vec::new();
                if keyword == "import" {
                    match opts.get("only").filter(|v| v.kind() == "list") {
                        Some(list) => {
                            let mut stack = vec![*list];
                            while let Some(x) = stack.pop() {
                                if x.kind() == "pair"
                                    && let Some(k) = x.child_by_field_name("key")
                                {
                                    let nm = text(k, src).trim_end_matches([':', ' ']).to_string();
                                    self.imported.insert(nm.clone());
                                    names.push(ImportName::plain(nm));
                                    continue;
                                }
                                let mut c3 = x.walk();
                                stack.extend(x.named_children(&mut c3));
                            }
                        }
                        None => {
                            self.wildcard = true;
                            names.push(ImportName::plain("*"));
                        }
                    }
                }
                push(self, spec, None, names);
            }
            _ => {}
        }
    }

    /// `@behaviour`, `@type`, `@spec`, `@callback`; anything else (`@doc`, `@foo value`) holds no
    /// symbol, but its value may still call things.
    fn attribute(&mut self, n: Node, ctx: Ctx) {
        let src = self.src;
        let Some(call) = n.child_by_field_name("operand").filter(|o| o.kind() == "call") else { return };
        let Some(name) = call.child_by_field_name("target").map(|t| text(t, src)) else { return };
        let Some(args) = Self::args(call) else { return };
        let type_ctx = Ctx { in_type: true, ..ctx };
        match name {
            "moduledoc" | "doc" | "typedoc" | "dialyzer" | "compile" | "impl" => {}
            "behaviour" => {
                if let (Some(m), Some(owner)) = (args.named_child(0), self.frames.last().and_then(|f| f.symbol)) {
                    let target = self.expand(text(m, src));
                    self.module_ref(m, &target, Some(owner), RefKind::Type);
                    self.facts.hierarchy.push(TypeRelation { symbol: owner, target, kind: HierarchyKind::Implements });
                }
            }
            "type" | "typep" | "opaque" => {
                let Some(def) = args.named_child(0).filter(|d| d.kind() == "binary_operator") else { return };
                let Some(left) = def.child_by_field_name("left") else { return };
                let head = if left.kind() == "call" { left.child_by_field_name("target") } else { Some(left) };
                let Some(head) = head else { return };
                let id = self.facts.push_symbol(symbol(
                    n,
                    text(head, src),
                    SymbolKind::TypeAlias,
                    Some(one_line(text(n, src))),
                    ctx.parent,
                    name != "typep",
                ));
                self.defined.insert(text(head, src).to_string());
                if let Some(r) = def.child_by_field_name("right") {
                    self.walk(r, Ctx { enclosing: Some(id), ..type_ctx });
                }
            }
            "spec" | "callback" | "macrocallback" => {
                let Some(def) = args.named_child(0).filter(|d| d.kind() == "binary_operator") else { return };
                let Some(left) = def.child_by_field_name("left") else { return };
                let head = if left.kind() == "binary_operator" { left.child_by_field_name("left") } else { Some(left) };
                // `@spec f(a) :: b when a: x` has the head under a `when`; unwrap one level.
                let head = head.and_then(|h| if h.kind() == "call" { Some(h) } else { None });
                let Some(head) = head else { return };
                let Some(fname) = head.child_by_field_name("target").map(|t| text(t, src).to_string()) else { return };
                let arity = Self::args(head).map(|a| a.named_child_count()).unwrap_or(0);
                if name == "spec" {
                    let spec = one_line(text(n, src));
                    self.frame().specs.insert((fname, arity), spec);
                    self.walk(def, Ctx { in_type: true, ..ctx });
                } else {
                    let id = self.facts.push_symbol(symbol(
                        n,
                        &fname,
                        SymbolKind::Method,
                        Some(one_line(text(n, src))),
                        ctx.parent,
                        true,
                    ));
                    self.walk(def, Ctx { enclosing: Some(id), in_type: true, ..ctx });
                }
            }
            _ => {
                let mut c = args.walk();
                for a in args.named_children(&mut c) {
                    self.walk(a, ctx);
                }
            }
        }
    }

    /// Keep a bare `foo()` only if the file could have bound it: defined here, imported by name,
    /// or any wildcard import / `use` that might bring it in.
    fn drop_unbound_local_calls(&mut self) {
        let (defined, imported, wildcard) = (&self.defined, &self.imported, self.wildcard);
        self.facts.refs.retain(|r| {
            r.qualifier.is_some()
                || r.name.starts_with(|c: char| c.is_uppercase())
                || r.kind != RefKind::Call && r.kind != RefKind::Type
                || defined.contains(&r.name)
                || imported.contains(&r.name)
                || wildcard
        });
    }
}
