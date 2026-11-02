//! npm package views: what a TypeScript or JavaScript dependency exports, read from the
//! declaration files (`.d.ts`) its installed copy under `node_modules` ships, or from
//! `@types/<name>`.
//!
//! A bare import specifier (`react`, `@scope/pkg/sub`, `node:path`) is resolved the way the
//! TypeScript compiler resolves one for types: the nearest `node_modules/<name>` above the
//! importing file (never above the worktree root), the package's `exports` map (conditions
//! `types`, `typings`, `import`, `node`, `module`, `default`, `require`, in that priority, with
//! one `*` pattern), else `types`/`typings`/`main`/`index.d.ts`; a `.js` target means the `.d.ts`
//! beside it. A package without declarations falls back to `@types/<name>` (`@scope/x` ->
//! `@types/scope__x`), and a name no package provides to the ambient `declare module "<name>"`
//! blocks of `@types/node` (`path`, `node:fs`, `fs/promises`). A package whose real directory is
//! not under any `node_modules` (a workspace or `file:` link back into a repository) is left
//! alone: it is source, not a package.
//!
//! The declaration files are parsed with tree-sitter into scopes (the file, each `declare module
//! "x"` body, each namespace) and resolved lazily, one exported name at a time: re-exports
//! (`export { a as b } from`, `export *`, `export * as ns`), `export =`, `export default`, imports
//! (`import x = require()`), and across packages (vitest re-exports `describe` from
//! `@vitest/runner`). A symbol belongs to the file and scope that declare it, so a name reached
//! through two packages is one symbol. Members are one level deep, which is all a reference
//! holds (`vi.fn`, `fc.constantFrom`, `assert.strictEqual`, `path.join`): a namespace's
//! declarations, a class's members, or the members of a constant's declared type (`declare const
//! vi: VitestUtils`), with the members of interfaces it `extends`.
//!
//! Parsed files and module tables are shared process-wide per `(package, version, file)`: about
//! 140 tessera worktrees can each have a `node_modules/vitest@3.2.7`, and it is read once.
//! Nothing is ever written under `node_modules`.

use super::{ModuleExports, PackageId, PkgKind, PkgSymbol};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;
use tree_sitter::Node;

/// How many re-export, import and `extends` hops one lookup may take. Bundled declaration
/// chunks import each other in cycles; a lookup that goes round one stops here.
const MAX_DEPTH: u8 = 16;

// ---- parsed declaration files ------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Decl {
    kind: PkgKind,
    sig: String,
    /// A variable's declared type when it names one (`VitestUtils`, `Chai.ChaiStatic`,
    /// `TestAPI<{}>` -> `TestAPI`): where its members come from.
    ty: Option<String>,
}

#[derive(Debug, Default)]
struct Scope {
    values: HashMap<String, Decl>,
    types: HashMap<String, Decl>,
    /// Namespace name -> its body scopes (declarations merge).
    namespaces: HashMap<String, Vec<usize>>,
    /// Interface or class name -> its members (merged across declarations).
    members: HashMap<String, Vec<(String, String)>>,
    extends: HashMap<String, Vec<String>>,
    /// Local name -> (specifier, imported name). `*` binds the module, `=` its `export =` value;
    /// an empty specifier is `import Z = ns.Q` (a local alias of `ns.Q`).
    imports: HashMap<String, (String, String)>,
    /// `export { local as exported }`.
    exports: Vec<(String, String)>,
    /// `export { imported as exported } from spec`; `*` imported is `export * as exported`.
    from: Vec<(String, String, String)>,
    stars: Vec<String>,
    export_eq: Option<String>,
    default: Option<String>,
    /// Declared with `export`.
    exported: HashSet<String>,
    /// Has an `export { … }` list or `export =`: then only what is exported explicitly is
    /// exported. Otherwise a declaration file exports every top-level declaration.
    explicit: bool,
    /// Has a top-level import or export (a module, not a global script).
    is_module: bool,
    parent: Option<usize>,
    /// Prefix of the names declared here: `Chai.` inside `namespace Chai`.
    prefix: String,
    /// The module symbols declared here are reported under.
    module: Arc<str>,
    /// `declare module "x" { … }` bodies (file scope only).
    ambient: Vec<(String, usize)>,
}

impl Scope {
    fn declares(&self, name: &str) -> bool {
        self.values.contains_key(name) || self.types.contains_key(name) || self.namespaces.contains_key(name)
    }
}

/// What a name means at one place: its value and type symbols and the members `name.member`
/// reaches.
#[derive(Debug, Default, Clone)]
struct Binding {
    value: Option<Arc<PkgSymbol>>,
    ty: Option<Arc<PkgSymbol>>,
    members: Option<Arc<ModuleExports>>,
}

impl Binding {
    fn is_empty(&self) -> bool {
        self.value.is_none() && self.ty.is_none() && self.members.is_none()
    }
}

/// One parsed declaration file of one package version.
struct DtsFile {
    package: Arc<PackageId>,
    /// The package directory and the absolute path of the copy this was read from (relative
    /// specifiers resolve against it).
    root: PathBuf,
    path: PathBuf,
    scopes: Vec<Scope>,
    syms: Mutex<HashMap<(usize, String, u8), Arc<PkgSymbol>>>,
    bindings: PerName<Binding>,
    type_tables: PerName<Option<Arc<ModuleExports>>>,
    ns_tables: PerName<Arc<ModuleExports>>,
}

/// A memo keyed by (scope, name).
type PerName<T> = Mutex<HashMap<(usize, String), T>>;

/// Where a type is declared: file, scope, name.
type TypeLoc = (Arc<DtsFile>, usize, String);

// ---- parsing ------------------------------------------------------------------------------------

fn text<'a>(n: Node, src: &'a str) -> &'a str {
    &src[n.byte_range()]
}

fn field<'a>(n: Node, f: &str, src: &'a str) -> Option<&'a str> {
    n.child_by_field_name(f).map(|c| text(c, src))
}

fn unquote(s: &str) -> String {
    s.trim_matches(['"', '\'', '`']).to_string()
}

fn one_line(s: &str) -> String {
    let mut out = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if out.len() > 200 {
        let mut cut = 200;
        while !out.is_char_boundary(cut) {
            cut -= 1;
        }
        out.truncate(cut);
        out.push('…');
    }
    out
}

/// A declaration's text up to its body, on one line.
fn signature(n: Node, src: &str) -> String {
    let end = n.child_by_field_name("body").map(|b| b.start_byte()).unwrap_or(n.end_byte());
    one_line(src[n.start_byte()..end].trim_end_matches(['{', ' ', '\n', '\t', ';']))
}

/// The type name a type annotation names, without type arguments: `Chai.ChaiStatic`.
fn named_type(n: Node, src: &str) -> Option<String> {
    match n.kind() {
        "type_annotation" => n.named_child(0).and_then(|c| named_type(c, src)),
        "type_identifier" | "nested_type_identifier" | "identifier" => Some(text(n, src).to_string()),
        "generic_type" => n.child_by_field_name("name").and_then(|c| named_type(c, src)),
        _ => None,
    }
}

struct Parser<'a> {
    src: &'a str,
    scopes: Vec<Scope>,
}

fn parse_dts(src: &str, module: Arc<str>) -> Vec<Scope> {
    let mut p = Parser { src, scopes: vec![Scope { module, ..Default::default() }] };
    let mut parser = tree_sitter::Parser::new();
    if parser.set_language(&tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()).is_ok()
        && let Some(tree) = parser.parse(src, None)
    {
        let root = tree.root_node();
        let mut c = root.walk();
        p.scopes[0].is_module = root.named_children(&mut c).any(|n| matches!(n.kind(), "import_statement" | "export_statement"));
        p.body(root, 0);
    }
    p.scopes
}

impl<'a> Parser<'a> {
    fn child_scope(&mut self, parent: usize, prefix: String, module: Arc<str>) -> usize {
        self.scopes.push(Scope { parent: Some(parent), prefix, module, ..Default::default() });
        self.scopes.len() - 1
    }

    fn body(&mut self, n: Node, s: usize) {
        let mut c = n.walk();
        let kids: Vec<Node> = n.named_children(&mut c).collect();
        for k in kids {
            self.stmt(k, s, false);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn decl(&mut self, s: usize, name: &str, kind: PkgKind, sig: String, ty: Option<String>, value: bool, typ: bool, exported: bool) {
        let d = Decl { kind, sig, ty };
        let sc = &mut self.scopes[s];
        // The first declaration wins (overloads), except that a namespace yields to the function,
        // class, constant or interface it merges with (`namespace path {…}` then `const path:
        // path.PlatformPath`): the namespace's names stay reachable through `namespaces`.
        let put = |map: &mut HashMap<String, Decl>| {
            if map.get(name).is_none_or(|old| old.kind == PkgKind::Namespace && kind != PkgKind::Namespace) {
                map.insert(name.to_string(), d.clone());
            }
        };
        if value {
            put(&mut sc.values);
        }
        if typ {
            put(&mut sc.types);
        }
        if exported {
            sc.exported.insert(name.to_string());
        }
    }

    fn members(&mut self, s: usize, owner: &str, body: Node) {
        let src = self.src;
        let mut c = body.walk();
        let mut out = Vec::new();
        for m in body.named_children(&mut c) {
            let name = match m.kind() {
                "method_signature" | "method_definition" | "abstract_method_signature" | "property_signature" | "public_field_definition" => field(m, "name", src),
                // Enum members.
                "property_identifier" => Some(text(m, src)),
                "enum_assignment" => field(m, "name", src),
                _ => None,
            };
            if let Some(name) = name {
                out.push((unquote(name), one_line(text(m, src).trim_end_matches([';', ',']))));
            }
        }
        self.scopes[s].members.entry(owner.to_string()).or_default().extend(out);
    }

    fn stmt(&mut self, n: Node, s: usize, exported: bool) {
        let src = self.src;
        match n.kind() {
            "import_statement" => self.import(n, s),
            "import_alias" => {
                let mut c = n.walk();
                let parts: Vec<Node> = n.named_children(&mut c).collect();
                if let [name, target, ..] = parts.as_slice() {
                    self.scopes[s].imports.insert(text(*name, src).to_string(), (String::new(), text(*target, src).to_string()));
                }
            }
            "export_statement" => self.export(n, s),
            "ambient_declaration" => {
                let mut c = n.walk();
                let kids: Vec<Node> = n.named_children(&mut c).collect();
                for k in kids {
                    self.stmt(k, s, exported);
                }
            }
            "module" => {
                // `declare module "x" { … }`. In a module file it augments another module, which
                // this view does not merge; in a script it declares one.
                let Some(name) = n.child_by_field_name("name") else { return };
                if name.kind() != "string" {
                    return self.namespace(n, s, exported);
                }
                if s != 0 || self.scopes[0].is_module {
                    return;
                }
                let mname = unquote(text(name, src));
                let child = self.child_scope(s, String::new(), Arc::from(mname.as_str()));
                if let Some(b) = n.child_by_field_name("body") {
                    let mut c = b.walk();
                    self.scopes[child].is_module = b.named_children(&mut c).any(|n| matches!(n.kind(), "import_statement" | "export_statement"));
                    self.body(b, child);
                }
                self.scopes[0].ambient.push((mname, child));
            }
            "internal_module" => self.namespace(n, s, exported),
            "expression_statement" => {
                if let Some(inner) = n.named_child(0).filter(|i| i.kind() == "internal_module") {
                    self.namespace(inner, s, exported);
                }
            }
            "function_signature" | "function_declaration" | "generator_function_declaration" => {
                if let Some(name) = field(n, "name", src) {
                    self.decl(s, name, PkgKind::Function, signature(n, src), None, true, false, exported);
                }
            }
            "class_declaration" | "abstract_class_declaration" | "class" => {
                let Some(name) = field(n, "name", src) else { return };
                self.decl(s, name, PkgKind::Class, signature(n, src), None, true, true, exported);
                let mut c = n.walk();
                let heritage: Vec<String> = n
                    .named_children(&mut c)
                    .filter(|h| h.kind() == "class_heritage")
                    .flat_map(|h| {
                        let mut hc = h.walk();
                        h.named_children(&mut hc).collect::<Vec<_>>()
                    })
                    .filter_map(|cl| {
                        let t = cl.child_by_field_name("value").or_else(|| cl.named_child(0))?;
                        named_type(t, src).or_else(|| (t.kind() == "member_expression").then(|| text(t, src).to_string()))
                    })
                    .collect();
                self.scopes[s].extends.entry(name.to_string()).or_default().extend(heritage);
                if let Some(b) = n.child_by_field_name("body") {
                    self.members(s, name, b);
                }
            }
            "interface_declaration" => {
                let Some(name) = field(n, "name", src) else { return };
                self.decl(s, name, PkgKind::Interface, signature(n, src), None, false, true, exported);
                let mut c = n.walk();
                for ch in n.named_children(&mut c) {
                    if ch.kind() == "extends_type_clause" {
                        let mut cc = ch.walk();
                        let ext: Vec<String> = ch.named_children(&mut cc).filter_map(|t| named_type(t, src)).collect();
                        self.scopes[s].extends.entry(name.to_string()).or_default().extend(ext);
                    }
                }
                if let Some(b) = n.child_by_field_name("body") {
                    self.members(s, name, b);
                }
            }
            "type_alias_declaration" => {
                if let Some(name) = field(n, "name", src) {
                    let sig = one_line(text(n, src).trim_end_matches(';'));
                    self.decl(s, name, PkgKind::TypeAlias, sig, None, false, true, exported);
                    if let Some(v) = n.child_by_field_name("value") {
                        self.type_shape(s, name, v);
                    }
                }
            }
            "enum_declaration" => {
                let Some(name) = field(n, "name", src) else { return };
                self.decl(s, name, PkgKind::Enum, signature(n, src), None, true, true, exported);
                if let Some(b) = n.child_by_field_name("body") {
                    self.members(s, name, b);
                }
            }
            "lexical_declaration" | "variable_declaration" => {
                let mut c = n.walk();
                let kids: Vec<Node> = n.named_children(&mut c).filter(|d| d.kind() == "variable_declarator").collect();
                for d in kids {
                    let Some(nn) = d.child_by_field_name("name").filter(|x| x.kind() == "identifier") else { continue };
                    let name = text(nn, src);
                    // The members of `x` are those of its declared type, kept under `#x`.
                    let ty = d.child_by_field_name("type").map(|t| {
                        let key = format!("#{name}");
                        self.type_shape(s, &key, t);
                        key
                    });
                    let sig = one_line(text(d, src));
                    self.decl(s, name, PkgKind::Variable, sig, ty, true, false, exported);
                }
            }
            _ => {}
        }
    }

    /// Where the members of a type expression come from, recorded under `key`: the members of
    /// object literals in it, and the named types (`extends`) and `typeof x` values it combines.
    /// `A & B & { c: … }` has the members of all three; `Omit<typeof assert, "ok">` those of
    /// `assert` (the omission is not modelled); an object literal passed as a type argument
    /// (`ChainableFunction<…, { each: … }>`, how vitest declares `it.each`) contributes its own.
    fn type_shape(&mut self, s: usize, key: &str, n: Node) {
        let src = self.src;
        match n.kind() {
            "type_annotation" | "intersection_type" | "union_type" | "parenthesized_type" => {
                let mut c = n.walk();
                let kids: Vec<Node> = n.named_children(&mut c).collect();
                for k in kids {
                    self.type_shape(s, key, k);
                }
            }
            "object_type" => self.members(s, key, n),
            "type_identifier" | "nested_type_identifier" => self.scopes[s].extends.entry(key.to_string()).or_default().push(text(n, src).to_string()),
            "type_query" => {
                if let Some(x) = n.named_child(0) {
                    self.scopes[s].extends.entry(key.to_string()).or_default().push(format!("typeof {}", text(x, src)));
                }
            }
            "generic_type" => {
                let Some(name) = field(n, "name", src) else { return };
                let mut args = Vec::new();
                if let Some(ta) = n.child_by_field_name("type_arguments") {
                    let mut c = ta.walk();
                    args = ta.named_children(&mut c).collect();
                }
                if matches!(name, "Omit" | "Pick" | "Partial" | "Required" | "Readonly" | "NonNullable") {
                    if let Some(first) = args.first() {
                        self.type_shape(s, key, *first);
                    }
                    return;
                }
                self.scopes[s].extends.entry(key.to_string()).or_default().push(name.to_string());
                for a in args.into_iter().filter(|a| a.kind() == "object_type") {
                    self.members(s, key, a);
                }
            }
            _ => {}
        }
    }

    fn namespace(&mut self, n: Node, s: usize, exported: bool) {
        let src = self.src;
        let Some(full) = field(n, "name", src) else { return };
        // `namespace A.B {}` is `namespace A { namespace B {} }`.
        let mut cur = s;
        let mut exported = exported;
        for seg in full.split('.') {
            self.decl(cur, seg, PkgKind::Namespace, format!("namespace {full}"), None, true, true, exported);
            let prefix = format!("{}{seg}.", self.scopes[cur].prefix);
            let module = self.scopes[cur].module.clone();
            let child = self.child_scope(cur, prefix, module);
            self.scopes[cur].namespaces.entry(seg.to_string()).or_default().push(child);
            cur = child;
            exported = true;
        }
        if let Some(b) = n.child_by_field_name("body") {
            self.body(b, cur);
        }
    }

    fn import(&mut self, n: Node, s: usize) {
        let src = self.src;
        let mut c = n.walk();
        let kids: Vec<Node> = n.named_children(&mut c).collect();
        let spec = n.child_by_field_name("source").map(|x| unquote(text(x, src)));
        for k in kids {
            match k.kind() {
                "import_require_clause" => {
                    let (Some(id), Some(spec)) = (k.named_child(0), k.child_by_field_name("source")) else { continue };
                    self.scopes[s].imports.insert(text(id, src).to_string(), (unquote(text(spec, src)), "=".into()));
                }
                "import_clause" => {
                    let Some(spec) = spec.clone() else { continue };
                    let mut cc = k.walk();
                    for part in k.named_children(&mut cc) {
                        match part.kind() {
                            "identifier" => {
                                self.scopes[s].imports.insert(text(part, src).to_string(), (spec.clone(), "default".into()));
                            }
                            "namespace_import" => {
                                if let Some(id) = part.named_child(0) {
                                    self.scopes[s].imports.insert(text(id, src).to_string(), (spec.clone(), "*".into()));
                                }
                            }
                            "named_imports" => {
                                let mut c3 = part.walk();
                                for sp in part.named_children(&mut c3) {
                                    let Some(name) = field(sp, "name", src) else { continue };
                                    let local = field(sp, "alias", src).unwrap_or(name);
                                    self.scopes[s].imports.insert(local.to_string(), (spec.clone(), unquote(name)));
                                }
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
    }

    fn export(&mut self, n: Node, s: usize) {
        let src = self.src;
        if let Some(source) = n.child_by_field_name("source") {
            let spec = unquote(text(source, src));
            let mut c = n.walk();
            let mut any = false;
            for part in n.named_children(&mut c) {
                match part.kind() {
                    "export_clause" => {
                        any = true;
                        let mut cc = part.walk();
                        for sp in part.named_children(&mut cc) {
                            let Some(name) = field(sp, "name", src) else { continue };
                            let exported = field(sp, "alias", src).unwrap_or(name);
                            self.scopes[s].from.push((unquote(exported), spec.clone(), unquote(name)));
                        }
                    }
                    "namespace_export" => {
                        any = true;
                        if let Some(id) = part.named_child(0) {
                            self.scopes[s].from.push((unquote(text(id, src)), spec.clone(), "*".into()));
                        }
                    }
                    _ => {}
                }
            }
            if !any {
                self.scopes[s].stars.push(spec);
            }
            return;
        }
        if let Some(d) = n.child_by_field_name("declaration") {
            return self.stmt(d, s, true);
        }
        if let Some(v) = n.child_by_field_name("value") {
            match v.kind() {
                "identifier" => self.scopes[s].default = Some(text(v, src).to_string()),
                "class" | "class_declaration" | "function_expression" | "function_declaration" | "function_signature" => {
                    if let Some(name) = field(v, "name", src) {
                        self.stmt(v, s, false);
                        self.scopes[s].default = Some(name.to_string());
                    }
                }
                _ => {}
            }
            return;
        }
        let t = text(n, src);
        let mut c = n.walk();
        let kids: Vec<Node> = n.named_children(&mut c).collect();
        if t.trim_start_matches("export").trim_start().starts_with('=') {
            if let Some(id) = kids.first() {
                self.scopes[s].export_eq = Some(text(*id, src).to_string());
                self.scopes[s].explicit = true;
            }
            return;
        }
        for part in kids {
            if part.kind() == "export_clause" {
                self.scopes[s].explicit = true;
                let mut cc = part.walk();
                for sp in part.named_children(&mut cc) {
                    let Some(name) = field(sp, "name", src) else { continue };
                    let exported = field(sp, "alias", src).unwrap_or(name);
                    self.scopes[s].exports.push((unquote(exported), name.to_string()));
                }
            } else if matches!(part.kind(), "class_declaration" | "function_declaration" | "function_signature" | "abstract_class_declaration") {
                // `export default class X {}` / `export default function f()`.
                if let Some(name) = field(part, "name", src) {
                    self.stmt(part, s, false);
                    self.scopes[s].default = Some(name.to_string());
                }
            }
        }
    }
}

// ---- package.json and file locations ------------------------------------------------------------

#[derive(Debug)]
struct PkgJson {
    name: String,
    version: String,
    types: Option<String>,
    main: Option<String>,
    exports: Option<serde_json::Value>,
}

fn pkg_json(dir: &Path) -> Option<Arc<PkgJson>> {
    type Seen = HashMap<PathBuf, (Option<SystemTime>, Arc<PkgJson>)>;
    static C: OnceLock<Mutex<Seen>> = OnceLock::new();
    let path = dir.join("package.json");
    let mtime = std::fs::metadata(&path).ok()?.modified().ok();
    let cache = C.get_or_init(Default::default);
    if let Some((t, p)) = cache.lock().unwrap().get(&path)
        && *t == mtime
    {
        return Some(p.clone());
    }
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).ok()?).ok()?;
    let s = |k: &str| json.get(k).and_then(|v| v.as_str()).map(String::from);
    let dir_name = || {
        let base = dir.file_name()?.to_string_lossy().to_string();
        let scope = dir.parent()?.file_name()?.to_string_lossy().to_string();
        Some(if scope.starts_with('@') { format!("{scope}/{base}") } else { base })
    };
    let p = Arc::new(PkgJson {
        name: s("name").or_else(dir_name).unwrap_or_default(),
        version: s("version").unwrap_or_else(|| "0.0.0".into()),
        types: s("types").or_else(|| s("typings")),
        main: s("main"),
        exports: json.get("exports").cloned(),
    });
    cache.lock().unwrap().insert(path, (mtime, p.clone()));
    Some(p)
}

/// The declaration file a specifier target means: itself if it is one, the `.d.ts` beside a
/// `.js`, `<p>.d.ts`, or `<p>/index.d.ts`.
fn dts_for(p: &Path) -> Option<PathBuf> {
    let s = p.to_string_lossy();
    if [".d.ts", ".d.mts", ".d.cts"].iter().any(|e| s.ends_with(e)) {
        return p.is_file().then(|| p.to_path_buf());
    }
    let mut cands: Vec<String> = Vec::new();
    for (ext, dts) in [(".js", ".d.ts"), (".mjs", ".d.mts"), (".cjs", ".d.cts"), (".jsx", ".d.ts"), (".ts", ".d.ts")] {
        if let Some(stem) = s.strip_suffix(ext) {
            cands.push(format!("{stem}{dts}"));
            cands.push(format!("{stem}.d.ts"));
        }
    }
    cands.push(format!("{s}.d.ts"));
    cands.push(format!("{}/index.d.ts", s.trim_end_matches('/')));
    cands.into_iter().map(PathBuf::from).find(|c| c.is_file())
}

/// Condition keys in the order they are tried. TypeScript reads `types` first, and every other
/// condition may name a `.js` file with its declarations beside it.
const CONDITIONS: &[&str] = &["types", "typings", "import", "node", "module", "default", "require"];

fn targets(v: &serde_json::Value, star: Option<&str>, out: &mut Vec<String>) {
    match v {
        serde_json::Value::String(s) => out.push(match star {
            Some(st) => s.replace('*', st),
            None => s.clone(),
        }),
        serde_json::Value::Array(a) => a.iter().for_each(|x| targets(x, star, out)),
        serde_json::Value::Object(o) => {
            for k in CONDITIONS {
                if let Some(x) = o.get(*k) {
                    targets(x, star, out);
                }
            }
        }
        _ => {}
    }
}

/// The relative targets an `exports` map gives `key` (`.` or `./sub`).
fn export_targets(ex: &serde_json::Value, key: &str) -> Vec<String> {
    let mut out = Vec::new();
    let subpaths = ex.as_object().is_some_and(|o| o.keys().any(|k| k.starts_with('.')));
    if !subpaths {
        if key == "." {
            targets(ex, None, &mut out);
        }
        return out;
    }
    let o = ex.as_object().unwrap();
    if let Some(v) = o.get(key) {
        targets(v, None, &mut out);
        return out;
    }
    // The longest matching `*` pattern.
    let mut best: Option<(&str, String)> = None;
    for (k, _) in o.iter() {
        if let Some((pre, post)) = k.split_once('*')
            && key.len() >= pre.len() + post.len()
            && key.starts_with(pre)
            && key.ends_with(post)
            && best.as_ref().is_none_or(|(b, _)| b.len() < k.len())
        {
            best = Some((k, key[pre.len()..key.len() - post.len()].to_string()));
        }
    }
    if let Some((k, star)) = best {
        targets(&o[k], Some(&star), &mut out);
    }
    out
}

/// The declaration file of `sub` ("" for the package itself) in the package at `dir`.
fn types_path(dir: &Path, pj: &PkgJson, sub: &str) -> Option<PathBuf> {
    if let Some(ex) = &pj.exports {
        let key = if sub.is_empty() { ".".to_string() } else { format!("./{sub}") };
        let found = export_targets(ex, &key).iter().find_map(|t| dts_for(&dir.join(t.trim_start_matches("./"))));
        if found.is_some() {
            return found;
        }
        // An `exports` map without declarations: older layouts still put them where `types` says.
    }
    if sub.is_empty() {
        let fields = [pj.types.as_deref(), pj.main.as_deref(), Some("index.d.ts")];
        return fields.into_iter().flatten().find_map(|t| dts_for(&dir.join(t.trim_start_matches("./"))));
    }
    dts_for(&dir.join(sub))
}

/// `@scope/name/sub/path` -> (`@scope/name`, `sub/path`).
fn split_spec(spec: &str) -> (&str, &str) {
    let mut n = 0;
    let parts = if spec.starts_with('@') { 2 } else { 1 };
    for (i, ch) in spec.char_indices() {
        if ch == '/' {
            n += 1;
            if n == parts {
                return (&spec[..i], &spec[i + 1..]);
            }
        }
    }
    (spec, "")
}

/// The name a package is imported by: `@types/node` -> `node`, `@types/scope__x` -> `@scope/x`.
fn public_name(name: &str) -> String {
    match name.strip_prefix("@types/") {
        Some(t) => match t.split_once("__") {
            Some((scope, n)) => format!("@{scope}/{n}"),
            None => t.to_string(),
        },
        None => name.to_string(),
    }
}

/// Is the real directory of a package under some `node_modules`? A workspace or `file:` link
/// back into a repository is not: it is source the graph already has.
fn installed(dir: &Path) -> bool {
    std::fs::canonicalize(dir).map(|p| p.components().any(|c| c.as_os_str() == "node_modules")).unwrap_or(false)
}

// ---- process-wide caches -------------------------------------------------------------------------

type FileKey = (String, String, String);

#[derive(Default)]
struct Cache {
    files: HashMap<FileKey, Arc<DtsFile>>,
    entries: HashMap<(FileKey, usize), Arc<ModuleExports>>,
    ambient: HashMap<(String, String), Arc<HashMap<String, PathBuf>>>,
}

fn cache() -> &'static Mutex<Cache> {
    static C: OnceLock<Mutex<Cache>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// npm package versions read and module tables built, for `status`.
pub fn stats() -> (usize, usize) {
    let c = cache().lock().unwrap();
    let pkgs: HashSet<(&str, &str)> = c.files.keys().map(|(n, v, _)| (n.as_str(), v.as_str())).collect();
    let names = c.entries.values().map(|m| m.values.len() + m.types.len()).sum();
    (pkgs.len(), names)
}

/// The parsed declaration file at `path` of the package at `root`.
fn load(package: &Arc<PackageId>, root: &Path, path: &Path) -> Option<Arc<DtsFile>> {
    let rel = path.strip_prefix(root).unwrap_or(path).to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
    let key = (package.name.clone(), package.version.clone(), rel.clone());
    if let Some(f) = cache().lock().unwrap().files.get(&key) {
        return Some(f.clone());
    }
    let src = std::fs::read_to_string(path).ok()?;
    let public = public_name(&package.name);
    let stem = rel.trim_end_matches(".d.ts").trim_end_matches(".d.mts").trim_end_matches(".d.cts");
    let entry = pkg_json(root).and_then(|pj| types_path(root, &pj, "")).is_some_and(|e| e == path);
    let module: Arc<str> = if entry || stem == "index" { Arc::from(public.as_str()) } else { Arc::from(format!("{public}/{stem}").as_str()) };
    // Parsed outside the lock, like `elm_package`: a duplicate parse beats a stalled resolver.
    let f = Arc::new(DtsFile {
        package: package.clone(),
        root: root.to_path_buf(),
        path: path.to_path_buf(),
        scopes: parse_dts(&src, module),
        syms: Default::default(),
        bindings: Default::default(),
        type_tables: Default::default(),
        ns_tables: Default::default(),
    });
    Some(cache().lock().unwrap().files.entry(key).or_insert(f).clone())
}

fn file_key(f: &DtsFile) -> FileKey {
    let rel = f.path.strip_prefix(&f.root).unwrap_or(&f.path).to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
    (f.package.name.clone(), f.package.version.clone(), rel)
}

/// The package directory `dir`, as (id, entry declaration file and scope) for `sub`.
fn package_module(dir: &Path, sub: &str, spec: &str) -> Option<(Arc<DtsFile>, usize)> {
    if !installed(dir) {
        return None;
    }
    let pj = pkg_json(dir)?;
    let path = types_path(dir, &pj, sub)?;
    let id = Arc::new(PackageId { manager: "npm", name: pj.name.clone(), version: pj.version.clone() });
    let f = load(&id, dir, &path)?;
    if f.scopes[0].is_module {
        return Some((f, 0));
    }
    // A global script (`@types/chai@4`, `@types/mocha`): the module is its `declare module`.
    let want = [spec.to_string(), public_name(&pj.name)];
    let hit = f.scopes[0].ambient.iter().find(|(n, _)| want.contains(n)).map(|(_, i)| *i);
    hit.map(|i| (f, i))
}

/// Which file (relative to `dir`) of the `@types/node` at `dir` declares each `declare module
/// "x"`, following its `/// <reference path>` lines from `index.d.ts`. Found by scanning the
/// text: only the files a view imports from (`path`, `fs`, `assert`, of about 60) are parsed.
fn ambient_modules(dir: &Path) -> Option<Arc<HashMap<String, PathBuf>>> {
    let pj = pkg_json(dir)?;
    let key = (pj.name.clone(), pj.version.clone());
    if let Some(m) = cache().lock().unwrap().ambient.get(&key) {
        return Some(m.clone());
    }
    let mut out = HashMap::new();
    let mut seen = HashSet::new();
    let mut todo = vec![types_path(dir, &pj, "")?];
    while let Some(p) = todo.pop() {
        if !seen.insert(p.clone()) || seen.len() > 400 {
            continue;
        }
        let Ok(src) = std::fs::read_to_string(&p) else { continue };
        for line in src.lines().take_while(|l| l.trim().is_empty() || l.trim_start().starts_with("//") || l.trim_start().starts_with("/*") || l.trim_start().starts_with('*')) {
            if let Some(rest) = line.trim().strip_prefix("/// <reference path=") {
                let r = rest.trim_start_matches(['"', '\'']).split(['"', '\'']).next().unwrap_or("");
                todo.push(p.parent().unwrap_or(dir).join(r));
            }
        }
        for line in src.lines() {
            if let Some(rest) = line.strip_prefix("declare module ")
                && let Some(q) = rest.chars().next().filter(|c| *c == '"' || *c == '\'')
                && let Some(name) = rest[1..].split(q).next()
            {
                // Relative: another copy of the same version answers from its own directory.
                out.entry(name.to_string()).or_insert_with(|| p.strip_prefix(dir).unwrap_or(&p).to_path_buf());
            }
        }
    }
    let out = Arc::new(out);
    cache().lock().unwrap().ambient.insert(key, out.clone());
    Some(out)
}

fn mangle(name: &str) -> String {
    match name.strip_prefix('@') {
        Some(s) => s.replacen('/', "__", 1),
        None => name.to_string(),
    }
}

/// Resolve a bare specifier from directory `start`, looking in `node_modules` of it and its
/// ancestors, no higher than `stop`.
fn resolve_bare(start: &Path, stop: Option<&Path>, spec: &str) -> Option<(Arc<DtsFile>, usize)> {
    let dirs: Vec<&Path> = start.ancestors().take_while(|d| stop.is_none_or(|s| d.starts_with(s))).collect();
    let builtin = spec.starts_with("node:");
    if !builtin {
        let (name, sub) = split_spec(spec);
        for d in &dirs {
            let nm = d.join("node_modules");
            if !nm.is_dir() {
                continue;
            }
            if let Some(hit) = package_module(&nm.join(name), sub, spec) {
                return Some(hit);
            }
            if !name.starts_with("@types/")
                && let Some(hit) = package_module(&nm.join("@types").join(mangle(name)), sub, spec)
            {
                return Some(hit);
            }
        }
    }
    for d in &dirs {
        let node = d.join("node_modules/@types/node");
        if node.is_dir() {
            let m = ambient_modules(&node)?;
            let name = [spec, spec.trim_start_matches("node:")].into_iter().find(|n| m.contains_key(*n))?;
            let pj = pkg_json(&node)?;
            let id = Arc::new(PackageId { manager: "npm", name: pj.name.clone(), version: pj.version.clone() });
            let f = load(&id, &node, &node.join(&m[name]))?;
            let i = f.scopes[0].ambient.iter().find(|(n, _)| n == name)?.1;
            return Some((f, i));
        }
    }
    None
}

/// The module a specifier written in declaration file `f` names.
fn resolve_from(f: &DtsFile, spec: &str) -> Option<(Arc<DtsFile>, usize)> {
    let dir = f.path.parent()?;
    if spec.starts_with('.') || spec.starts_with('/') {
        let p = dts_for(&dir.join(spec))?;
        let g = load(&f.package, &f.root, &normalize(&p))?;
        return Some((g, 0));
    }
    resolve_bare(dir, None, spec)
}

fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            o => out.push(o.as_os_str()),
        }
    }
    out
}

// ---- resolution ---------------------------------------------------------------------------------

thread_local! {
    /// Lookups in progress on this thread: a cycle (`interface A extends B`, `B extends A`;
    /// two chunks that `export *` each other) answers empty instead of recursing.
    static ACTIVE: std::cell::RefCell<HashSet<(usize, usize, String)>> = Default::default();
}

fn guarded<T>(f: &DtsFile, s: usize, tag: String, run: impl FnOnce() -> T) -> Option<T> {
    let key = (f as *const DtsFile as usize, s, tag);
    if !ACTIVE.with(|a| a.borrow_mut().insert(key.clone())) {
        return None;
    }
    let out = run();
    ACTIVE.with(|a| a.borrow_mut().remove(&key));
    Some(out)
}

fn sym(f: &DtsFile, s: usize, name: &str, kind: PkgKind, sig: &str, ns: u8) -> Arc<PkgSymbol> {
    let key = (s, name.to_string(), ns);
    if let Some(x) = f.syms.lock().unwrap().get(&key) {
        return x.clone();
    }
    let sc = &f.scopes[s];
    let x = Arc::new(PkgSymbol { package: f.package.clone(), module: sc.module.clone(), name: format!("{}{name}", sc.prefix), kind, signature: Some(sig.to_string()) });
    f.syms.lock().unwrap().entry(key).or_insert(x).clone()
}

fn table(f: &DtsFile, name: &str) -> ModuleExports {
    ModuleExports { package: f.package.clone(), name: Arc::from(name), values: HashMap::new(), types: HashMap::new(), ctors_of: HashMap::new(), members: HashMap::new() }
}

/// Several member tables as one, the first one's entries winning.
fn merge(f: &DtsFile, name: &str, parts: Vec<Arc<ModuleExports>>) -> Option<Arc<ModuleExports>> {
    if parts.len() <= 1 {
        return parts.into_iter().next();
    }
    let mut t = table(f, name);
    for p in parts {
        for (k, v) in &p.values {
            t.values.entry(k.clone()).or_insert_with(|| v.clone());
        }
        for (k, v) in &p.types {
            t.types.entry(k.clone()).or_insert_with(|| v.clone());
        }
        for (k, v) in &p.members {
            t.members.entry(k.clone()).or_insert_with(|| v.clone());
        }
    }
    Some(Arc::new(t))
}

/// What `name`, declared in scope `s` of `f`, binds.
fn decl_binding(f: &Arc<DtsFile>, s: usize, name: &str, d: u8) -> Binding {
    let key = (s, name.to_string());
    if let Some(b) = f.bindings.lock().unwrap().get(&key) {
        return b.clone();
    }
    if d > MAX_DEPTH {
        return Binding::default();
    }
    let Some(b) = guarded(f, s, format!("b:{name}"), || {
        let sc = &f.scopes[s];
        let value = sc.values.get(name).map(|dc| sym(f, s, name, dc.kind, &dc.sig, 0));
        let ty = sc.types.get(name).map(|dc| sym(f, s, name, dc.kind, &dc.sig, 1));
        let mut parts = Vec::new();
        match sc.values.get(name) {
            Some(Decl { kind: PkgKind::Variable, ty: Some(t), .. }) => parts.extend(type_members(f, s, t, d + 1)),
            Some(Decl { kind: PkgKind::Class | PkgKind::Enum, .. }) => parts.extend(type_members(f, s, name, d + 1)),
            _ => {}
        }
        if sc.namespaces.contains_key(name) {
            parts.extend(ns_table(f, s, name, d + 1));
        }
        let members = merge(f, name, parts);
        Binding { value, ty, members }
    }) else {
        return Binding::default();
    };
    f.bindings.lock().unwrap().insert(key, b.clone());
    b
}

/// The members of interface, class or enum `name` declared in scope `s`, with those of the types
/// it extends.
fn type_members(f: &Arc<DtsFile>, s: usize, name: &str, d: u8) -> Option<Arc<ModuleExports>> {
    let key = (s, name.to_string());
    if let Some(t) = f.type_tables.lock().unwrap().get(&key) {
        return t.clone();
    }
    if d > MAX_DEPTH {
        return None;
    }
    let out = guarded(f, s, format!("t:{name}"), || {
        let sc = &f.scopes[s];
        let mut t = table(f, &format!("{}.{}{name}", sc.module, sc.prefix));
        for (m, sig) in sc.members.get(name).into_iter().flatten() {
            t.values.entry(m.clone()).or_insert_with(|| sym(f, s, &format!("{}.{m}", name.trim_start_matches('#')), PkgKind::Member, sig, 2));
        }
        for ext in sc.extends.get(name).into_iter().flatten() {
            let et = match ext.strip_prefix("typeof ") {
                Some(v) => local_binding(f, s, v, d + 1).members,
                None => type_loc(f, s, ext, d + 1).and_then(|(g, gs, n)| type_members(&g, gs, &n, d + 1)),
            };
            if let Some(et) = et {
                for (k, v) in &et.values {
                    t.values.entry(k.clone()).or_insert_with(|| v.clone());
                }
            }
        }
        (!t.values.is_empty()).then(|| Arc::new(t))
    })?;
    f.type_tables.lock().unwrap().insert(key, out.clone());
    out
}

/// Everything namespace `name` of scope `s` declares (all its bodies).
fn ns_table(f: &Arc<DtsFile>, s: usize, name: &str, d: u8) -> Option<Arc<ModuleExports>> {
    let key = (s, name.to_string());
    if let Some(t) = f.ns_tables.lock().unwrap().get(&key) {
        return Some(t.clone());
    }
    let t = guarded(f, s, format!("n:{name}"), || {
        let sc = &f.scopes[s];
        let mut t = table(f, &format!("{}.{}{name}", sc.module, sc.prefix));
        for &n in sc.namespaces.get(name).into_iter().flatten() {
            let body = &f.scopes[n];
            let names: BTreeSet<&String> = body.values.keys().chain(body.types.keys()).chain(body.namespaces.keys()).collect();
            for k in names {
                let b = decl_binding(f, n, k, d + 1);
                insert(&mut t, k, b);
            }
        }
        Arc::new(t)
    })?;
    f.ns_tables.lock().unwrap().insert(key, t.clone());
    Some(t)
}

fn insert(t: &mut ModuleExports, name: &str, b: Binding) {
    if let Some(v) = b.value {
        t.values.entry(name.to_string()).or_insert(v);
    }
    if let Some(ty) = b.ty {
        t.types.entry(name.to_string()).or_insert(ty);
    }
    if let Some(m) = b.members {
        t.members.entry(name.to_string()).or_insert(m);
    }
}

fn member_of(b: &Binding, name: &str) -> Binding {
    let Some(m) = &b.members else { return Binding::default() };
    Binding { value: m.values.get(name).cloned(), ty: m.types.get(name).cloned(), members: m.members.get(name).cloned() }
}

/// What `qname` (`x`, `ns.Q`) means inside scope `s`: its declarations, then its imports, then
/// the enclosing scopes'.
fn local_binding(f: &Arc<DtsFile>, s: usize, qname: &str, d: u8) -> Binding {
    if d > MAX_DEPTH {
        return Binding::default();
    }
    let mut segs = qname.split('.');
    let head = segs.next().unwrap_or("");
    let mut cur = Some(s);
    let mut b = Binding::default();
    while let Some(i) = cur {
        let sc = &f.scopes[i];
        if sc.declares(head) {
            b = decl_binding(f, i, head, d + 1);
            break;
        }
        if let Some((spec, imp)) = sc.imports.get(head) {
            b = if spec.is_empty() { local_binding(f, i, imp, d + 1) } else { import_binding(f, spec, imp, d + 1) };
            break;
        }
        cur = sc.parent;
    }
    for seg in segs {
        b = member_of(&b, seg);
    }
    b
}

fn import_binding(f: &Arc<DtsFile>, spec: &str, imported: &str, d: u8) -> Binding {
    let Some((g, gs)) = resolve_from(f, spec) else { return Binding::default() };
    match imported {
        "*" => Binding { members: Some(module_table(&g, gs)), ..Default::default() },
        "=" => export_binding(&g, gs, "default", d + 1),
        n => export_binding(&g, gs, n, d + 1),
    }
}

/// What the module whose body is scope `s` of `f` exports as `name`. `default` is the default
/// export, or the `export =` value.
fn export_binding(f: &Arc<DtsFile>, s: usize, name: &str, d: u8) -> Binding {
    if d > MAX_DEPTH {
        return Binding::default();
    }
    let sc = &f.scopes[s];
    if let Some(eq) = &sc.export_eq {
        let b = local_binding(f, s, eq, d + 1);
        return if name == "default" { b } else { member_of(&b, name) };
    }
    if name == "default" {
        return match &sc.default {
            Some(l) => local_binding(f, s, l, d + 1),
            None => sc.exports.iter().find(|(e, _)| e == "default").map(|(_, l)| local_binding(f, s, l, d + 1)).unwrap_or_default(),
        };
    }
    if let Some((_, l)) = sc.exports.iter().find(|(e, _)| e == name) {
        return local_binding(f, s, l, d + 1);
    }
    if let Some((_, spec, imp)) = sc.from.iter().find(|(e, _, _)| e == name) {
        return import_binding(f, spec, imp, d + 1);
    }
    if (!sc.explicit || sc.exported.contains(name)) && sc.declares(name) {
        return decl_binding(f, s, name, d + 1);
    }
    for spec in &sc.stars {
        let b = import_binding(f, spec, name, d + 1);
        if !b.is_empty() {
            return b;
        }
    }
    Binding::default()
}

/// Every name the module whose body is scope `s` of `f` exports.
fn export_names(f: &Arc<DtsFile>, s: usize, out: &mut BTreeSet<String>) {
    guarded(f, s, "names".into(), || {
        let sc = &f.scopes[s];
        if let Some(eq) = &sc.export_eq {
            let b = local_binding(f, s, eq, 0);
            out.extend(b.members.iter().flat_map(|m| m.names().chain(m.members.keys())).cloned());
            if b.value.is_some() || b.ty.is_some() {
                out.insert("default".into());
            }
            return;
        }
        if sc.default.is_some() {
            out.insert("default".into());
        }
        out.extend(sc.exports.iter().map(|(e, _)| e.clone()));
        out.extend(sc.from.iter().map(|(e, _, _)| e.clone()));
        for n in sc.values.keys().chain(sc.types.keys()).chain(sc.namespaces.keys()) {
            if !sc.explicit || sc.exported.contains(n) {
                out.insert(n.clone());
            }
        }
        for spec in &sc.stars {
            if let Some((g, gs)) = resolve_from(f, spec) {
                let mut more = BTreeSet::new();
                export_names(&g, gs, &mut more);
                more.remove("default");
                out.extend(more);
            }
        }
    });
}

/// Where type `qname` named inside scope `s` of `f` is declared.
fn type_loc(f: &Arc<DtsFile>, s: usize, qname: &str, d: u8) -> Option<TypeLoc> {
    if d > MAX_DEPTH {
        return None;
    }
    let path: Vec<&str> = qname.split('.').collect();
    let head = path[0];
    let mut cur = Some(s);
    while let Some(i) = cur {
        let sc = &f.scopes[i];
        if sc.declares(head) {
            return type_loc_in(f, i, &path);
        }
        if let Some((spec, imp)) = sc.imports.get(head) {
            if spec.is_empty() {
                return type_loc(f, i, &join(imp, &path[1..]), d + 1);
            }
            let (g, gs) = resolve_from(f, spec)?;
            return match imp.as_str() {
                "*" => export_type_loc(&g, gs, &path[1..], d + 1),
                "=" => {
                    let eq = g.scopes[gs].export_eq.clone()?;
                    type_loc(&g, gs, &join(&eq, &path[1..]), d + 1)
                }
                n => {
                    let mut p = vec![n];
                    p.extend(&path[1..]);
                    export_type_loc(&g, gs, &p, d + 1)
                }
            };
        }
        cur = sc.parent;
    }
    None
}

fn join(head: &str, rest: &[&str]) -> String {
    std::iter::once(head).chain(rest.iter().copied()).collect::<Vec<_>>().join(".")
}

/// `path` among the declarations of scope `s` itself: a type, or namespaces leading to one.
fn type_loc_in(f: &Arc<DtsFile>, s: usize, path: &[&str]) -> Option<TypeLoc> {
    let sc = &f.scopes[s];
    match path {
        [one] => sc.types.contains_key(*one).then(|| (f.clone(), s, one.to_string())),
        [ns, rest @ ..] => sc.namespaces.get(*ns)?.iter().find_map(|&n| type_loc_in(f, n, rest)),
        [] => None,
    }
}

/// `path` (an exported name, then namespace members) of the module whose body is scope `s`.
fn export_type_loc(f: &Arc<DtsFile>, s: usize, path: &[&str], d: u8) -> Option<TypeLoc> {
    if d > MAX_DEPTH || path.is_empty() {
        return None;
    }
    let sc = &f.scopes[s];
    if let Some(eq) = &sc.export_eq {
        return type_loc(f, s, &join(eq, path), d + 1);
    }
    if let Some((_, l)) = sc.exports.iter().find(|(e, _)| e == path[0]) {
        return type_loc(f, s, &join(l, &path[1..]), d + 1);
    }
    if let Some((_, spec, imp)) = sc.from.iter().find(|(e, _, _)| e == path[0]) {
        let (g, gs) = resolve_from(f, spec)?;
        if imp == "*" {
            return export_type_loc(&g, gs, &path[1..], d + 1);
        }
        let mut p = vec![imp.as_str()];
        p.extend(&path[1..]);
        return export_type_loc(&g, gs, &p, d + 1);
    }
    if (!sc.explicit || sc.exported.contains(path[0])) && sc.declares(path[0]) {
        return type_loc_in(f, s, path);
    }
    sc.stars.iter().find_map(|spec| {
        let (g, gs) = resolve_from(f, spec)?;
        export_type_loc(&g, gs, path, d + 1)
    })
}

/// The export table of the module whose body is scope `s` of `f`, built once per process.
fn module_table(f: &Arc<DtsFile>, s: usize) -> Arc<ModuleExports> {
    let key = (file_key(f), s);
    if let Some(m) = cache().lock().unwrap().entries.get(&key) {
        return m.clone();
    }
    let built = guarded(f, s, "module".into(), || {
        let mut names = BTreeSet::new();
        export_names(f, s, &mut names);
        let mut t = table(f, &f.scopes[s].module);
        for n in names {
            let b = export_binding(f, s, &n, 0);
            insert(&mut t, &n, b);
        }
        Arc::new(t)
    });
    match built {
        Some(t) => cache().lock().unwrap().entries.entry(key).or_insert(t).clone(),
        // Asked for while being built (two modules that `import * as` each other).
        None => Arc::new(table(f, &f.scopes[s].module)),
    }
}

/// The exports of the package module a bare specifier (`react`, `@scope/pkg/sub`, `node:path`)
/// names for a file in directory `dir` of the worktree at `root`, if declarations for it are
/// installed.
pub fn resolve(root: &Path, dir: &Path, spec: &str) -> Option<Arc<ModuleExports>> {
    let (f, s) = resolve_bare(dir, Some(root), spec)?;
    Some(module_table(&f, s))
}
