//! Package views: what a dependency exports, read from the package manager's own cache.
//!
//! A reference to `List.map` or `Json.Decode.field` names a symbol that lives in no file of the
//! view. Before this module every such reference was unresolved (60% of tessera's unresolved
//! references were Elm package names), and a bare `String` bound to whichever repository symbol
//! happened to be the only one called `String` (`Confidence::Fallback`), which made one
//! constructor in `Expression/Token.elm` the top symbol of `map` at 78x the next one.
//!
//! A package view is the export table of one `(package, version)`, parsed once per process from
//! the cache and shared by every project, worktree and graph that depends on it (about 140 tessera
//! worktrees share one `elm.json`). Symbols are named the way SCIP names them: manager, package,
//! version, then descriptors (`elm elm/core 1.0.5 List/map.`), so another ecosystem's cache (Cargo
//! registry sources, Hex, npm `node_modules`, SwiftPM checkouts) can plug in as another
//! `PackageId::manager` without changing what a resolved reference holds.
//!
//! The caches are only ever read. A version without `docs.json` (8 of 172 in the measured cache:
//! downloaded, never built) is skipped, its references stay unresolved as before, and `status`
//! lists it. A miss is not cached, so a package built later is picked up by the next project load.

pub mod cargo;

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

pub mod npm;

/// One package at one version, as a package manager names it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PackageId {
    /// `elm`, `npm`, `cargo` (crates and std/core/alloc, see `cargo`); `hex`, `swiftpm` later.
    pub manager: &'static str,
    /// `elm/core`
    pub name: String,
    /// `1.0.5`
    pub version: String,
}

impl std::fmt::Display for PackageId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}@{}", self.name, self.version)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PkgKind {
    Function,
    /// A union type (`type Maybe a = …`).
    Type,
    TypeAlias,
    Constructor,
    Operator,
    /// TypeScript declarations (`npm`): a class, an interface, a `const`/`let`/`var`, a
    /// namespace, an enum, and a member of a class, interface or enum.
    Class,
    Interface,
    Variable,
    Namespace,
    Enum,
    Member,
    /// Rust: a trait.
    Trait,
    /// Rust: an exported `macro_rules!`.
    Macro,
    /// Rust: a function of an `impl` or `trait` block; its module ends with the type's name.
    Method,
    /// Rust: a `const` or `static`.
    Const,
}

impl PkgKind {
    pub fn as_str(self) -> &'static str {
        match self {
            PkgKind::Function => "function",
            PkgKind::Type => "type",
            PkgKind::TypeAlias => "type_alias",
            PkgKind::Constructor => "constructor",
            PkgKind::Operator => "operator",
            PkgKind::Class => "class",
            PkgKind::Interface => "interface",
            PkgKind::Variable => "variable",
            PkgKind::Namespace => "namespace",
            PkgKind::Enum => "enum",
            PkgKind::Member => "member",
            PkgKind::Trait => "trait",
            PkgKind::Macro => "macro",
            PkgKind::Method => "method",
            PkgKind::Const => "const",
        }
    }
}

/// A symbol a package exports.
#[derive(Debug)]
pub struct PkgSymbol {
    pub package: Arc<PackageId>,
    pub module: Arc<str>,
    pub name: String,
    pub kind: PkgKind,
    /// The type as `docs.json` writes it (`(a -> b) -> List.List a -> List.List b`).
    pub signature: Option<String>,
}

impl PkgSymbol {
    /// `elm/core@1.0.5 List.map`, `std@1.96.0 collections::hash::map::HashMap::new`: what
    /// `find`/`refs` print. A Rust crate-root item has no module (`serde_json@1.0.140 json`).
    pub fn display(&self) -> String {
        match (self.package.manager, self.module.is_empty()) {
            ("cargo", true) => format!("{} {}", self.package, self.name),
            ("cargo", false) => format!("{} {}::{}", self.package, self.module, self.name),
            _ => format!("{} {}.{}", self.package, self.module, self.name),
        }
    }

    /// The SCIP symbol string: `elm elm/core 1.0.5 List/map.` (a type descriptor ends `#`), and
    /// for a crate `cargo alloc 1.96.0 vec/Vec#new().` (a member's type is a type descriptor).
    pub fn scip(&self) -> String {
        let suffix = match self.kind {
            PkgKind::Type | PkgKind::TypeAlias | PkgKind::Class | PkgKind::Interface | PkgKind::Enum | PkgKind::Trait => "#",
            PkgKind::Namespace => "/",
            PkgKind::Method => "().",
            PkgKind::Macro => "!",
            _ => ".",
        };
        let p = &self.package;
        if p.manager != "cargo" {
            return format!("{} {} {} {}/{}{suffix}", p.manager, p.name, p.version, self.module.replace('.', "/"), self.name);
        }
        let mut path = String::new();
        let segs: Vec<&str> = self.module.split("::").filter(|s| !s.is_empty()).collect();
        let member = matches!(self.kind, PkgKind::Method) || matches!(self.kind, PkgKind::Constructor | PkgKind::Const) && segs.last().is_some_and(|s| s.starts_with(char::is_uppercase));
        for (i, s) in segs.iter().enumerate() {
            path.push_str(s);
            path.push_str(if member && i + 1 == segs.len() { "#" } else { "/" });
        }
        format!("{} {} {} {path}{}{suffix}", p.manager, p.name, p.version, self.name)
    }
}

impl PartialEq for PkgSymbol {
    fn eq(&self, o: &PkgSymbol) -> bool {
        self.package == o.package && self.module == o.module && self.name == o.name && self.kind == o.kind
    }
}

impl Eq for PkgSymbol {}

impl std::hash::Hash for PkgSymbol {
    fn hash<H: std::hash::Hasher>(&self, h: &mut H) {
        (&self.package, &self.module, &self.name, self.kind).hash(h);
    }
}

/// What one module of a package exports, in Elm's two namespaces.
#[derive(Debug)]
pub struct ModuleExports {
    pub package: Arc<PackageId>,
    pub name: Arc<str>,
    /// Functions, constructors, operators and record aliases (which double as constructor
    /// functions): everything a value position can name.
    pub values: HashMap<String, Arc<PkgSymbol>>,
    /// Union types and aliases.
    pub types: HashMap<String, Arc<PkgSymbol>>,
    /// Union type -> its constructors, for `exposing (Maybe(..))`.
    pub ctors_of: HashMap<String, Vec<String>>,
    /// Value name -> what `name.member` reaches (npm: a namespace's declarations, a class's
    /// members, the members of a constant's declared type). Empty for Elm, whose qualified names
    /// are module names.
    pub members: HashMap<String, Arc<ModuleExports>>,
}

/// Two views of one module are the same module: identity is (package, module), never contents.
impl PartialEq for ModuleExports {
    fn eq(&self, o: &ModuleExports) -> bool {
        self.package == o.package && self.name == o.name
    }
}
impl Eq for ModuleExports {}

impl std::hash::Hash for ModuleExports {
    fn hash<H: std::hash::Hasher>(&self, h: &mut H) {
        (&self.package, &self.name).hash(h);
    }
}

impl ModuleExports {
    /// `name` in the namespace a reference of `type_position` looks in, then in the other: the
    /// extractor calls a constructor in a pattern a `use` and a record alias in a signature a
    /// `type`, and a miss there is still a hit here.
    pub fn lookup(&self, name: &str, type_position: bool) -> Option<&Arc<PkgSymbol>> {
        let (first, second) = if type_position { (&self.types, &self.values) } else { (&self.values, &self.types) };
        first.get(name).or_else(|| second.get(name))
    }

    pub fn names(&self) -> impl Iterator<Item = &String> {
        self.values.keys().chain(self.types.keys())
    }
}

/// Module name -> exports, for one package version.
pub type PkgModules = HashMap<String, Arc<ModuleExports>>;

// ---- where the caches are --------------------------------------------------------------------

static ELM_HOME_OVERRIDE: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Point Elm package lookups at another `ELM_HOME` for this process (`None` restores the
/// default). For tests and embedders: a test must never read the real `~/.elm`, whose contents
/// differ from machine to machine, and an environment variable cannot be set safely while other
/// test threads run.
pub fn set_elm_home(path: Option<PathBuf>) {
    *ELM_HOME_OVERRIDE.write().unwrap() = path;
}

/// `ELM_HOME` as the Elm compiler finds it: the override, `$ELM_HOME`, else `~/.elm`.
pub fn elm_home() -> Option<PathBuf> {
    if let Some(p) = ELM_HOME_OVERRIDE.read().unwrap().clone() {
        return Some(p);
    }
    if let Some(p) = std::env::var_os("ELM_HOME").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(p));
    }
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".elm"))
}

fn elm_packages_dir(home: &Path) -> PathBuf {
    home.join("0.19.1").join("packages")
}

// ---- the process-wide cache --------------------------------------------------------------------

#[derive(Default)]
struct Cache {
    /// docs.json path -> parsed modules. Keyed by path, so an `ELM_HOME` change never serves one
    /// cache's exports for another's.
    loaded: HashMap<PathBuf, Arc<PkgModules>>,
    /// `author/name@version` whose docs.json is missing or unreadable, for `status`.
    missing: BTreeSet<String>,
}

fn cache() -> &'static Mutex<Cache> {
    static C: OnceLock<Mutex<Cache>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// What `status` reports: package versions parsed, exported names, and versions skipped for want
/// of a docs.json.
pub struct PackageStats {
    pub packages: usize,
    pub names: usize,
    /// Elm versions without docs.json.
    pub missing_docs: Vec<String>,
    /// Rust crates read, and those that could not be (see `cargo::stats`).
    pub crates: cargo::CrateStats,
}

pub fn stats() -> PackageStats {
    let (npm_packages, npm_names) = npm::stats();
    let c = cache().lock().unwrap();
    let crates = cargo::stats();
    PackageStats {
        packages: c.loaded.len() + npm_packages,
        names: c.loaded.values().flat_map(|m| m.values()).map(|m| m.values.len() + m.types.len()).sum::<usize>() + npm_names,
        missing_docs: c.missing.iter().cloned().collect(),
        crates,
    }
}

/// The exports of one Elm package version, parsed on first use.
pub fn elm_package(home: &Path, name: &str, version: &str) -> Option<Arc<PkgModules>> {
    let path = elm_packages_dir(home).join(name).join(version).join("docs.json");
    if let Some(m) = cache().lock().unwrap().loaded.get(&path) {
        return Some(m.clone());
    }
    // Parsed outside the lock: two threads may both parse a package once, which is cheaper than
    // making every other lookup wait behind a 1 MB JSON parse.
    let id = Arc::new(PackageId { manager: "elm", name: name.to_string(), version: version.to_string() });
    let parsed = std::fs::read_to_string(&path).ok().and_then(|t| parse_docs(&t, &id));
    let mut c = cache().lock().unwrap();
    match parsed {
        Some(m) => {
            c.missing.remove(&id.to_string());
            Some(c.loaded.entry(path).or_insert_with(|| Arc::new(m)).clone())
        }
        None => {
            c.missing.insert(id.to_string());
            None
        }
    }
}

/// Parse a docs.json (`[{name, comment, unions, aliases, values, binops}]`; the schema is the same
/// in every one of the 164 files of the measured cache).
pub fn parse_docs(text: &str, id: &Arc<PackageId>) -> Option<PkgModules> {
    use serde_json::Value;
    let json: Value = serde_json::from_str(text).ok()?;
    let s = |v: &Value, k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
    let list = |v: &Value, k: &str| v.get(k).and_then(|x| x.as_array()).cloned().unwrap_or_default();
    let mut out = PkgModules::new();
    for m in json.as_array()? {
        let Some(mname) = s(m, "name") else { continue };
        let module: Arc<str> = Arc::from(mname.as_str());
        let mut ex = ModuleExports { package: id.clone(), name: module.clone(), values: HashMap::new(), types: HashMap::new(), ctors_of: HashMap::new(), members: HashMap::new() };
        let sym = |name: &str, kind: PkgKind, signature: Option<String>| {
            Arc::new(PkgSymbol { package: id.clone(), module: module.clone(), name: name.to_string(), kind, signature })
        };
        for v in list(m, "values") {
            if let Some(n) = s(&v, "name") {
                ex.values.insert(n.clone(), sym(&n, PkgKind::Function, s(&v, "type")));
            }
        }
        for v in list(m, "binops") {
            if let Some(n) = s(&v, "name") {
                ex.values.insert(n.clone(), sym(&n, PkgKind::Operator, s(&v, "type")));
            }
        }
        for a in list(m, "aliases") {
            if let Some(n) = s(&a, "name") {
                let ty = s(&a, "type");
                // `type alias Point = { x : Float }` is also the constructor `Point 1 2`.
                if ty.as_deref().is_some_and(|t| t.trim_start().starts_with('{')) {
                    ex.values.insert(n.clone(), sym(&n, PkgKind::TypeAlias, ty.clone()));
                }
                ex.types.insert(n.clone(), sym(&n, PkgKind::TypeAlias, ty));
            }
        }
        for u in list(m, "unions") {
            let Some(n) = s(&u, "name") else { continue };
            let args: Vec<String> = list(&u, "args").iter().filter_map(|a| a.as_str().map(String::from)).collect();
            let head = std::iter::once(n.clone()).chain(args).collect::<Vec<_>>().join(" ");
            let mut ctors = Vec::new();
            for c in list(&u, "cases") {
                let Some(cn) = c.get(0).and_then(|x| x.as_str()) else { continue };
                let fields: Vec<String> = c.get(1).and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                let sig = fields.iter().map(|f| format!("{f} -> ")).collect::<String>() + &head;
                ex.values.insert(cn.to_string(), sym(cn, PkgKind::Constructor, Some(sig)));
                ctors.push(cn.to_string());
            }
            ex.types.insert(n.clone(), sym(&n, PkgKind::Type, Some(format!("type {head}"))));
            ex.ctors_of.insert(n, ctors);
        }
        if &*module == "List" && !ex.types.contains_key("List") {
            // `List` is a compiler built-in: neither List.elm nor docs.json declares it, yet
            // `import List exposing (List)` is implicit. Without this the measured 7,533 `List`
            // type references of tessera stayed unresolved.
            ex.types.insert("List".into(), sym("List", PkgKind::Type, Some("type List a".into())));
        }
        out.insert(mname, Arc::new(ex));
    }
    Some(out)
}

// ---- versions --------------------------------------------------------------------------------

fn ver_key(v: &str) -> Vec<u32> {
    v.split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

/// Does `version` satisfy an elm.json constraint (`"1.0.0 <= v < 2.0.0"`, or an exact version)?
pub fn version_in_range(constraint: &str, version: &str) -> bool {
    let parts: Vec<&str> = constraint.split_whitespace().collect();
    match parts.as_slice() {
        [lo, lop, "v", hop, hi] => {
            let (lo, hi, v) = (ver_key(lo), ver_key(hi), ver_key(version));
            let lo_ok = if *lop == "<=" { v >= lo } else { v > lo };
            let hi_ok = if *hop == "<" { v < hi } else { v <= hi };
            lo_ok && hi_ok
        }
        [exact] => ver_key(exact) == ver_key(version),
        _ => false,
    }
}

/// The highest installed version of `name` satisfying `constraint`.
fn installed_version(home: &Path, name: &str, constraint: &str) -> Option<String> {
    let dir = elm_packages_dir(home).join(name);
    let mut vs: Vec<String> = std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).filter(|v| version_in_range(constraint, v)).collect();
    vs.sort_by_key(|v| ver_key(v));
    vs.pop()
}

// ---- one project's dependencies ---------------------------------------------------------------

/// The package modules an Elm project (one `elm.json`) can import.
#[derive(Debug, Default)]
pub struct ProjectPackages {
    pub packages: Vec<Arc<PackageId>>,
    /// Module name -> its exports. A module two dependencies both provide goes to the first
    /// (dependencies before test-dependencies): Elm itself rejects such a project.
    pub modules: HashMap<String, Arc<ModuleExports>>,
}

/// Read the dependencies of the `elm.json` text: an application's `direct` dependencies (exact
/// versions; `indirect` ones cannot be imported) and a package's ranges (the highest installed
/// version in each). Test-dependencies count for every file: the extractor cannot tell `tests/`
/// apart from `src/`, and code that uses a test module outside the tests does not compile anyway.
pub fn elm_project_packages(elm_json: &str, home: Option<&Path>) -> ProjectPackages {
    let mut p = ProjectPackages::default();
    let Some(home) = home else { return p };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(elm_json) else { return p };
    let application = json.get("type").and_then(|t| t.as_str()) == Some("application");
    for section in ["dependencies", "test-dependencies"] {
        let deps = json.get(section);
        let deps = if application { deps.and_then(|d| d.get("direct")) } else { deps };
        for (name, c) in deps.and_then(|d| d.as_object()).into_iter().flatten() {
            let Some(c) = c.as_str() else { continue };
            let version = if application { Some(c.to_string()) } else { installed_version(home, name, c) };
            let Some(version) = version else {
                cache().lock().unwrap().missing.insert(format!("{name}@{c} (not installed)"));
                continue;
            };
            let Some(mods) = elm_package(home, name, &version) else { continue };
            if let Some(m) = mods.values().next() {
                p.packages.push(m.package.clone());
            }
            for (mname, ex) in mods.iter() {
                p.modules.entry(mname.clone()).or_insert_with(|| ex.clone());
            }
        }
    }
    p
}

// ---- Elm's implicit imports ------------------------------------------------------------------

/// What a default import exposes unqualified.
pub enum Exposing {
    Nothing,
    /// `exposing (..)`
    All,
    /// Names; a `Type(..)` entry is `(type, true)`.
    Names(&'static [(&'static str, bool)]),
}

/// Every Elm module imports these first, exactly as elm/compiler 0.19.1 writes them in
/// `compiler/src/Elm/Compiler/Imports.hs`: (module, alias, exposing). The research list had the
/// modules right but not the exposings or the `Cmd`/`Sub` aliases.
pub const ELM_DEFAULT_IMPORTS: &[(&str, Option<&str>, Exposing)] = &[
    ("Basics", None, Exposing::All),
    ("Debug", None, Exposing::Nothing),
    ("List", None, Exposing::Names(&[("List", false), ("::", false)])),
    ("Maybe", None, Exposing::Names(&[("Maybe", true)])),
    ("Result", None, Exposing::Names(&[("Result", true)])),
    ("String", None, Exposing::Names(&[("String", false)])),
    ("Char", None, Exposing::Names(&[("Char", false)])),
    ("Tuple", None, Exposing::Nothing),
    ("Platform", None, Exposing::Names(&[("Program", false)])),
    ("Platform.Cmd", Some("Cmd"), Exposing::Names(&[("Cmd", false)])),
    ("Platform.Sub", Some("Sub"), Exposing::Names(&[("Sub", false)])),
];
