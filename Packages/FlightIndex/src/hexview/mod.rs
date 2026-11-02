//! Elixir package views: what the standard library and a project's Hex dependencies export, so
//! `Enum.map`, `Jason.encode!` or a bare `assert` resolve to a package symbol instead of to
//! nothing, or to whichever repository function happens to share the name.
//!
//! The same representation as Elm's (`pkgview`): one `PackageId` per (package, version), its
//! modules as `ModuleExports`, parsed once per process and shared by every graph that depends on
//! it. Two sources, both only ever read:
//!
//! - **The standard library** (`elixir`, `ex_unit`, `logger`, `eex`, `mix`, `iex`) of the installed
//!   Elixir, from the `.beam` files of each application's `ebin/` (see `beam`): installed releases
//!   carry no `.ex` sources. Found through `elixir` on `PATH` (symlinks followed), the Homebrew
//!   prefixes, then asdf and mise installs (newest first). `set_elixir_home` overrides it.
//! - **Dependencies** listed in the project's `mix.lock`, from `deps/<name>/lib` sources (see
//!   `source`), parsed once per (name, version). The copy must be the locked version (its
//!   `hex_metadata.config` says so). A compiled copy of that version under `_build/<env>/lib`
//!   adds what metaprogramming defines and no source text shows. A linked worktree rarely has its own `deps/`, so the main
//!   worktree's `deps/` at the same relative path is tried next. A version found nowhere is
//!   skipped, its references stay unresolved, and `status` lists it.
//!
//! Modules export in two namespaces, as Elm's do: `values` (functions and macros, one symbol per
//! name whatever the arity, since a reference carries no arity) and `types` (`@type`s, plus the
//! module itself under its last segment, which no lowercase type name can collide with).

pub mod beam;
pub mod source;

pub use beam::DefKind;

use crate::facts::Import;
use crate::pkgview::{ModuleExports, PackageId, PkgKind, PkgModules, PkgSymbol};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

/// One public definition, before it becomes a `PkgSymbol`.
#[derive(Debug, Clone)]
pub struct Def {
    pub kind: DefKind,
    pub name: String,
    pub signature: Option<String>,
}

/// One import a module's `__using__` puts into the module that `use`s it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsingImport {
    pub module: String,
    /// `import M, only: [a: 1]` names; `None` imports everything.
    pub only: Option<Vec<String>>,
    /// A nested `use` (or `require`: the facts do not tell them apart, and requiring a module
    /// that defines `__using__` without using it is vanishingly rare).
    pub is_use: bool,
    /// `alias M, as: Short` (or plain `alias M`): the short name the user module may then write.
    pub alias: Option<String>,
}

impl UsingImport {
    /// One `alias`, `import`, `use` or `require` fact.
    pub fn from_import(i: &Import) -> UsingImport {
        let module = i.specifier.clone();
        if let Some(a) = &i.alias {
            return UsingImport { module, only: None, is_use: false, alias: Some(a.clone()) };
        }
        if i.names.is_empty() {
            return UsingImport { module, only: None, is_use: true, alias: None };
        }
        let only = (!i.names.iter().any(|n| n.name == "*")).then(|| i.names.iter().map(|n| n.name.clone()).collect());
        UsingImport { module, only, is_use: false, alias: None }
    }

    fn all(module: &str) -> UsingImport {
        UsingImport { module: module.to_string(), only: None, is_use: false, alias: None }
    }

    fn only(module: &str, names: &[&str]) -> UsingImport {
        UsingImport { module: module.to_string(), only: Some(names.iter().map(|n| n.to_string()).collect()), is_use: false, alias: None }
    }
}

/// `use ExUnit.CaseTemplate` turns a module into a case template: `use`-ing it then also does
/// `use ExUnit.Case`, besides importing what its `using do … end` block imports.
pub const CASE_TEMPLATE: &str = "ExUnit.CaseTemplate";
pub const CASE: &str = "ExUnit.Case";

/// What `use` of a standard-library module imports. The `.beam` files cannot say (the imports are
/// inside a `quote`), so this is measured: a module doing `use M` was compiled with Elixir 1.20
/// and its `__ENV__.functions` / `__ENV__.macros` read back. Modules not listed (`GenServer`,
/// `Agent`, `Task`, `Application`, `Mix.Task`, …) import nothing beyond Kernel.
fn stdlib_using(module: &str) -> Option<Vec<UsingImport>> {
    Some(match module {
        "ExUnit.Case" => vec![
            UsingImport::all("ExUnit.Callbacks"),
            UsingImport::all("ExUnit.Assertions"),
            UsingImport::only("ExUnit.Case", &["describe", "test"]),
            UsingImport::all("ExUnit.DocTest"),
        ],
        "ExUnit.CaseTemplate" => vec![
            UsingImport::all("ExUnit.Callbacks"),
            UsingImport::all("ExUnit.Assertions"),
            UsingImport::only("ExUnit.CaseTemplate", &["using"]),
        ],
        "Supervisor" => vec![UsingImport::all("Supervisor.Spec")],
        _ => return None,
    })
}

/// The modules every Elixir file imports without saying so.
pub const AUTO_IMPORTS: &[&str] = &["Kernel", "Kernel.SpecialForms", TYPESPEC];

/// Where the typespec language's built-in types (`term()`, `pos_integer()`, `keyword()`) are put:
/// they belong to no module, and `Kernel.Typespec` is the module that implements them.
pub const TYPESPEC: &str = "Kernel.Typespec";

/// The basic and built-in types of the Elixir typespec reference, usable in any `@spec`/`@type`.
const BUILTIN_TYPES: &[&str] = &[
    "any", "none", "atom", "map", "pid", "port", "reference", "struct", "tuple", "float", "integer", "neg_integer",
    "non_neg_integer", "pos_integer", "list", "nonempty_list", "maybe_improper_list", "nonempty_improper_list",
    "nonempty_maybe_improper_list", "term", "arity", "as_boolean", "binary", "nonempty_binary", "bitstring",
    "nonempty_bitstring", "boolean", "byte", "char", "charlist", "nonempty_charlist", "fun", "function", "identifier",
    "iodata", "iolist", "keyword", "mfa", "module", "no_return", "node", "number", "timeout", "string",
    "nonempty_string",
];

/// One package version's modules.
pub struct ExPackage {
    pub id: Arc<PackageId>,
    pub modules: PkgModules,
    pub using: HashMap<String, Arc<[UsingImport]>>,
}

/// Every module one Elixir project can call: the standard library, then its locked dependencies.
#[derive(Default)]
pub struct ExProject {
    pub packages: Vec<Arc<PackageId>>,
    pub modules: HashMap<String, Arc<ModuleExports>>,
    pub using: HashMap<String, Arc<[UsingImport]>>,
    /// Locked dependencies with no usable copy.
    pub missing: usize,
}

impl ExProject {
    fn add(&mut self, p: &ExPackage) {
        self.packages.push(p.id.clone());
        for (name, m) in &p.modules {
            // A module two packages define goes to the first: the standard library, then the
            // lockfile's order. Mix itself refuses such a project.
            self.modules.entry(name.clone()).or_insert_with(|| m.clone());
        }
        for (name, u) in &p.using {
            self.using.entry(name.clone()).or_insert_with(|| u.clone());
        }
    }
}

// ---- building exports ----------------------------------------------------------------------------

fn build_modules(id: &Arc<PackageId>, defs: HashMap<String, Vec<Def>>) -> PkgModules {
    let mut out = PkgModules::new();
    for (mname, defs) in defs {
        let module: Arc<str> = Arc::from(mname.as_str());
        let mut ex = ModuleExports { package: id.clone(), name: module.clone(), values: HashMap::new(), types: HashMap::new(), ctors_of: HashMap::new(), members: HashMap::new() };
        // name -> (kind, signatures in definition order, deduplicated)
        let mut values: HashMap<String, (PkgKind, Vec<String>)> = HashMap::new();
        let mut types: HashMap<String, Vec<String>> = HashMap::new();
        for d in defs {
            let sig = d.signature.unwrap_or_default();
            let slot = match d.kind {
                DefKind::Type => types.entry(d.name).or_default(),
                DefKind::Function => &mut values.entry(d.name).or_insert((PkgKind::Function, Vec::new())).1,
                DefKind::Macro => {
                    // A name defined both ways reads as a macro.
                    let e = values.entry(d.name).or_insert((PkgKind::Macro, Vec::new()));
                    e.0 = PkgKind::Macro;
                    &mut e.1
                }
            };
            if !sig.is_empty() && !slot.contains(&sig) {
                slot.push(sig);
            }
        }
        let sym = |name: &str, kind: PkgKind, sigs: Vec<String>| {
            let signature = (!sigs.is_empty()).then(|| sigs.join(" | "));
            Arc::new(PkgSymbol { package: id.clone(), module: module.clone(), name: name.to_string(), kind, signature })
        };
        for (n, (kind, sigs)) in values {
            ex.values.insert(n.clone(), sym(&n, kind, sigs));
        }
        for (n, sigs) in types {
            ex.types.insert(n.clone(), sym(&n, PkgKind::Type, sigs));
        }
        let last = mname.rsplit('.').next().unwrap_or(&mname).to_string();
        ex.types.insert(last.clone(), sym(&last, PkgKind::Module, vec![format!("defmodule {mname}")]));
        out.insert(mname, Arc::new(ex));
    }
    out
}

// ---- the process-wide cache --------------------------------------------------------------------

#[derive(Default)]
struct Cache {
    /// Standard library: an application's ebin path -> its package. Dependencies: `hex
    /// name@version` -> its package (one parse per version, whichever checkout it came from).
    loaded: HashMap<String, Arc<ExPackage>>,
    /// Locked versions with no usable copy, for `status`.
    missing: BTreeSet<String>,
    /// Home -> the standard-library-only project every file outside a Mix project gets.
    bare: HashMap<PathBuf, Arc<ExProject>>,
    /// (Elixir root, lockfile text) -> its project, once every locked version was found: the
    /// same in every worktree with that lockfile, wherever its copies were read. Every graph of a
    /// worktree, overlays included, gets a new resolver; without this each would re-read every
    /// `hex_metadata.config` and merge the modules again, and every worktree hold its own copy.
    complete: HashMap<(Option<PathBuf>, String), Arc<ExProject>>,
}

fn cache() -> &'static Mutex<Cache> {
    static C: OnceLock<Mutex<Cache>> = OnceLock::new();
    C.get_or_init(Default::default)
}

pub struct ExStats {
    pub packages: usize,
    pub names: usize,
    pub missing: Vec<String>,
}

pub fn stats() -> ExStats {
    let c = cache().lock().unwrap();
    ExStats {
        packages: c.loaded.len(),
        names: c.loaded.values().flat_map(|p| p.modules.values()).map(|m| m.values.len() + m.types.len()).sum(),
        missing: c.missing.iter().cloned().collect(),
    }
}

fn cached_or(key: String, load: impl FnOnce() -> Option<ExPackage>) -> Option<Arc<ExPackage>> {
    if let Some(p) = cache().lock().unwrap().loaded.get(&key) {
        return Some(p.clone());
    }
    // Parsed outside the lock, as Elm's docs.json are.
    let p = load()?;
    Some(cache().lock().unwrap().loaded.entry(key).or_insert_with(|| Arc::new(p)).clone())
}

// ---- the standard library ----------------------------------------------------------------------

static ELIXIR_HOME_OVERRIDE: RwLock<Option<PathBuf>> = RwLock::new(None);

/// Point standard-library lookups at another Elixir root (the directory holding
/// `lib/elixir/ebin`) for this process; `None` restores discovery. For tests, which must never
/// read the machine's own install.
pub fn set_elixir_home(path: Option<PathBuf>) {
    *ELIXIR_HOME_OVERRIDE.write().unwrap() = path;
}

/// The Elixir root whose standard library package views read.
pub fn elixir_home() -> Option<PathBuf> {
    if let Some(p) = ELIXIR_HOME_OVERRIDE.read().unwrap().clone() {
        return Some(p);
    }
    static FOUND: OnceLock<Option<PathBuf>> = OnceLock::new();
    FOUND.get_or_init(discover_home).clone()
}

fn is_home(p: &Path) -> bool {
    p.join("lib/elixir/ebin/elixir.app").is_file()
}

fn discover_home() -> Option<PathBuf> {
    // `bin/elixir` of a release (Homebrew links it from the prefix): its root is one up.
    let from_bin = |exe: PathBuf| -> Option<PathBuf> {
        let real = std::fs::canonicalize(exe).ok()?;
        let root = real.parent()?.parent()?.to_path_buf();
        is_home(&root).then_some(root)
    };
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut bins: Vec<PathBuf> = std::env::split_paths(&path).map(|d| d.join("elixir")).collect();
    // A daemon started by launchd has a bare PATH.
    bins.extend(["/opt/homebrew/bin/elixir", "/usr/local/bin/elixir", "/usr/bin/elixir"].map(PathBuf::from));
    if let Some(root) = bins.into_iter().find_map(from_bin) {
        return Some(root);
    }
    // asdf and mise keep shims (scripts, not links) on PATH; their installs are roots themselves.
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let mut roots: Vec<PathBuf> = [".asdf/installs/elixir", ".local/share/mise/installs/elixir"]
        .iter()
        .filter_map(|d| std::fs::read_dir(home.join(d)).ok())
        .flatten()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| is_home(p))
        .collect();
    roots.sort_by_key(|p| ver_key(&p.file_name().unwrap_or_default().to_string_lossy()));
    roots.pop()
}

fn ver_key(v: &str) -> Vec<u32> {
    v.split(['.', '-']).map(|p| p.trim_start_matches(|c: char| !c.is_ascii_digit()).parse().unwrap_or(0)).collect()
}

/// The standard library applications package views read; the others (`elixir_*` Erlang modules
/// aside, there are none) are build tools.
const STDLIB_APPS: &[&str] = &["elixir", "ex_unit", "logger", "eex", "mix", "iex"];

/// `{vsn,"1.20.2"}` from an application's `.app` file.
fn app_version(ebin: &Path, app: &str) -> Option<String> {
    let text = std::fs::read_to_string(ebin.join(format!("{app}.app"))).ok()?;
    let at = text.find("{vsn,")? + 5;
    let rest = text[at..].trim_start().strip_prefix('"')?;
    Some(rest[..rest.find('"')?].to_string())
}

/// Module -> definitions, from every Elixir module (`Elixir.*.beam`) of an `ebin` directory.
fn read_ebin(ebin: &Path) -> HashMap<String, Vec<Def>> {
    let mut defs: HashMap<String, Vec<Def>> = HashMap::new();
    for e in std::fs::read_dir(ebin).into_iter().flatten().filter_map(|e| e.ok()) {
        let file = e.file_name().to_string_lossy().to_string();
        let Some(module) = file.strip_prefix("Elixir.").and_then(|f| f.strip_suffix(".beam")) else { continue };
        let Some(exports) = std::fs::read(e.path()).ok().and_then(|b| beam::exports(&b)) else { continue };
        let list = defs.entry(module.to_string()).or_default();
        list.extend(exports.into_iter().map(|d| Def { kind: d.kind, name: d.name, signature: d.signature }));
    }
    defs
}

/// A compiled copy of a locked dependency under `_build/<env>/lib/<app>/ebin` whose `.app` names
/// the locked version (a git dependency's build is taken as it is).
fn built_ebin(build: &Path, l: &Locked) -> Option<PathBuf> {
    let mut envs: Vec<PathBuf> = std::fs::read_dir(build).ok()?.filter_map(|e| e.ok().map(|e| e.path())).collect();
    envs.sort();
    envs.into_iter().map(|e| e.join("lib").join(&l.app).join("ebin")).find(|ebin| match app_version(ebin, &l.app) {
        Some(v) => !l.hex || v == l.version,
        None => false,
    })
}

fn stdlib_app(home: &Path, app: &'static str) -> Option<Arc<ExPackage>> {
    let ebin = home.join("lib").join(app).join("ebin");
    let version = app_version(&ebin, app)?;
    cached_or(format!("stdlib {}", ebin.display()), || {
        let id = Arc::new(PackageId { manager: "elixir", name: app.to_string(), version });
        let mut defs = read_ebin(&ebin);
        if let Some(ts) = defs.get_mut(TYPESPEC) {
            ts.extend(BUILTIN_TYPES.iter().map(|t| Def { kind: DefKind::Type, name: t.to_string(), signature: Some(format!("{t}() (built-in type)")) }));
        }
        let using = defs.keys().filter_map(|m| stdlib_using(m).map(|u| (m.clone(), Arc::from(u)))).collect();
        Some(ExPackage { modules: build_modules(&id, defs), id, using })
    })
}

fn stdlib(home: &Path) -> Vec<Arc<ExPackage>> {
    use rayon::prelude::*;
    STDLIB_APPS.par_iter().filter_map(|a| stdlib_app(home, a)).collect()
}

/// The project a file outside any Mix project gets: the standard library alone.
pub fn bare_project() -> Option<Arc<ExProject>> {
    let home = elixir_home()?;
    if let Some(p) = cache().lock().unwrap().bare.get(&home) {
        return Some(p.clone());
    }
    let mut p = ExProject::default();
    for pkg in stdlib(&home) {
        p.add(&pkg);
    }
    let p = Arc::new(p);
    Some(cache().lock().unwrap().bare.entry(home).or_insert(p).clone())
}

// ---- dependencies ------------------------------------------------------------------------------

/// One `mix.lock` entry: the dependency's app name (its `deps/` directory) and locked version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Locked {
    pub app: String,
    pub version: String,
    /// A Hex package (whose `deps/<app>/hex_metadata.config` names the version); else a git or
    /// path dependency, whose checkout is taken as it is.
    pub hex: bool,
}

/// `"jason": {:hex, :jason, "1.4.4", …}` and `"x": {:git, "url", "sha", …}`, one per line as
/// `mix` writes it.
pub fn parse_mix_lock(text: &str) -> Vec<Locked> {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = RE.get_or_init(|| regex::Regex::new(r#"^\s*"([^"]+)":\s*\{:(hex|git),\s*(?::"[^"]+"|:[\w.]+|"[^"]*"),\s*"([^"]+)""#).unwrap());
    text.lines()
        .filter_map(|l| re.captures(l))
        .map(|c| Locked { app: c[1].to_string(), hex: &c[2] == "hex", version: c[3].to_string() })
        .collect()
}

/// The version a dependency checkout declares in `hex_metadata.config`.
fn hex_version(dir: &Path) -> Option<String> {
    let text = std::fs::read_to_string(dir.join("hex_metadata.config")).ok()?;
    let at = text.find("<<\"version\">>")? + "<<\"version\">>".len();
    let rest = text[at..].trim_start().strip_prefix(',')?.trim_start().strip_prefix("<<\"")?;
    Some(rest[..rest.find('"')?].to_string())
}

/// The main worktree of the repository `root` is a linked worktree of (`.git` is a file naming
/// `<common>/worktrees/<name>`, whose `commondir` leads back to `<common>`), else `None`.
pub fn main_worktree(root: &Path) -> Option<PathBuf> {
    let dotgit = std::fs::read_to_string(root.join(".git")).ok()?;
    let gitdir = root.join(dotgit.trim().strip_prefix("gitdir:")?.trim());
    let common = std::fs::read_to_string(gitdir.join("commondir")).ok()?;
    let common = std::fs::canonicalize(gitdir.join(common.trim())).ok()?;
    (common.file_name()? == ".git").then(|| common.parent().map(Path::to_path_buf)).flatten()
}

fn dependency(dirs: &[PathBuf], l: &Locked) -> Option<Arc<ExPackage>> {
    let mut seen = None;
    for base in dirs {
        let dir = base.join(&l.app);
        if !dir.join("lib").is_dir() {
            continue;
        }
        if l.hex {
            match hex_version(&dir) {
                Some(v) if v == l.version => {}
                v => {
                    seen = seen.or(v);
                    continue;
                }
            }
        }
        let key = format!("{} {}@{}", if l.hex { "hex" } else { "git" }, l.app, l.version);
        return cached_or(key, || {
            let id = Arc::new(PackageId { manager: if l.hex { "hex" } else { "git" }, name: l.app.clone(), version: l.version.clone() });
            // A compiled build of this version has every definition, including those made by
            // metaprogramming (`for m <- [:get, :post], do: defmacro unquote(m)(…)` in
            // Phoenix.ConnTest) that no source text shows, with the docs' signatures; and reading
            // it is quicker than parsing. The sources still say what each `__using__` imports.
            let ebin = base.parent().and_then(|p| built_ebin(&p.join("_build"), l));
            let mut src = source::read_lib(&dir.join("lib"), ebin.is_some());
            for (module, defs) in ebin.as_deref().map(read_ebin).unwrap_or_default() {
                src.defs.entry(module).or_default().extend(defs);
            }
            let using = src.using.into_iter().map(|(m, u)| (m, Arc::from(u))).collect();
            Some(ExPackage { modules: build_modules(&id, src.defs), id, using })
        });
    }
    let why = match seen {
        Some(v) => format!("{}@{} (deps/{} is {v})", l.app, l.version, l.app),
        None => format!("{}@{} (not in deps/)", l.app, l.version),
    };
    cache().lock().unwrap().missing.insert(why);
    None
}

/// The project whose `mix.lock` is `lock` (text) in `lock_dir` (relative to `root`): the standard
/// library, then each locked dependency found under `deps/` here or in the main worktree.
pub fn project(root: &Path, lock_dir: &Path, lock: &str) -> ExProject {
    let mut p = ExProject::default();
    if let Some(home) = elixir_home() {
        for pkg in stdlib(&home) {
            p.add(&pkg);
        }
    }
    let mut dirs = vec![root.join(lock_dir).join("deps")];
    if let Some(main) = main_worktree(root) {
        dirs.push(main.join(lock_dir).join("deps"));
    }
    use rayon::prelude::*;
    let deps: Vec<Option<Arc<ExPackage>>> = parse_mix_lock(lock).par_iter().map(|l| dependency(&dirs, l)).collect();
    for pkg in deps {
        match pkg {
            Some(pkg) => p.add(&pkg),
            None => p.missing += 1,
        }
    }
    p
}

/// Per-resolver memo of the Elixir project above each directory.
#[derive(Default)]
pub struct ProjectCache {
    /// Directory (relative to the root) -> the `mix.lock` directory that governs it, if any.
    lock_of: Mutex<HashMap<String, Option<String>>>,
    projects: Mutex<HashMap<String, Arc<ExProject>>>,
}

impl ProjectCache {
    /// The packages a file at `from` (relative to `root`) can call: those of the nearest
    /// `mix.lock` at or above the nearest `mix.exs` (an umbrella app's lock is the umbrella's),
    /// or the standard library alone outside any Mix project.
    pub fn for_file(&self, root: &Path, from: &str) -> Option<Arc<ExProject>> {
        let dir = Path::new(from).parent().unwrap_or(Path::new(""));
        let key = dir.to_string_lossy().to_string();
        let lock_dir = {
            let mut memo = self.lock_of.lock().unwrap();
            memo.entry(key).or_insert_with(|| find_lock(root, dir)).clone()
        };
        let Some(lock_dir) = lock_dir else { return bare_project() };
        if let Some(p) = self.projects.lock().unwrap().get(&lock_dir) {
            return Some(p.clone());
        }
        let text = std::fs::read_to_string(root.join(&lock_dir).join("mix.lock")).unwrap_or_default();
        let key = (elixir_home(), text);
        let known = cache().lock().unwrap().complete.get(&key).cloned();
        let p = match known {
            Some(p) => p,
            None => {
                let p = Arc::new(project(root, Path::new(&lock_dir), &key.1));
                // A version not found is looked for again by the next resolver: it may have been
                // fetched since.
                if p.missing == 0 {
                    cache().lock().unwrap().complete.insert(key, p.clone());
                }
                p
            }
        };
        Some(self.projects.lock().unwrap().entry(lock_dir).or_insert(p).clone())
    }
}

fn find_lock(root: &Path, dir: &Path) -> Option<String> {
    let mut d = Some(dir);
    let mut in_project = false;
    while let Some(x) = d {
        in_project |= root.join(x).join("mix.exs").is_file();
        if in_project && root.join(x).join("mix.lock").is_file() {
            return Some(x.to_string_lossy().to_string());
        }
        d = x.parent();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mix_lock_entries() {
        let lock = r#"%{
  "jason": {:hex, :jason, "1.4.4", "abc", [:mix], [{:decimal, "~> 1.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "def"},
  "my_dep": {:hex, :"other-name", "0.2.0-rc.1", "abc", [:mix], [], "hexpm", "def"},
  "fork": {:git, "https://example.com/fork.git", "0123456789abcdef", [branch: "main"]},
}"#;
        assert_eq!(
            parse_mix_lock(lock),
            vec![
                Locked { app: "jason".into(), version: "1.4.4".into(), hex: true },
                Locked { app: "my_dep".into(), version: "0.2.0-rc.1".into(), hex: true },
                Locked { app: "fork".into(), version: "0123456789abcdef".into(), hex: false },
            ]
        );
    }
}
