//! Package views of the Apple SDK for Swift: what `import Foundation`, `import SwiftUI` or
//! `import XCTest` make nameable, read from the active SDK's own files.
//!
//! Before this module 134,317 of flight-deck's 259,070 Swift references were unresolved, and the
//! compiler's index store resolves 118,805 of those outside the repository: `XCTAssertEqual`,
//! `UUID`, `URL`, `FileManager`, `String`, `Text`. A package view binds them to the SDK
//! declaration (`Confidence::Package`, as Elm's packages do), so `refs UUID` lists the uses of
//! Foundation's `UUID`, and a reference nothing in the repository defines says where it comes
//! from instead of nothing. Measured against that store: 98,917 references bound, 0.995 of the
//! checkable ones to the declaration the compiler chose, 35,400 left unresolved.
//!
//! One module's surface is read from two places, both read-only:
//! - its Swift interface (`Foo.swiftmodule/<arch>.swiftinterface`, see `interface`): the
//!   declarations a library-evolution module publishes, one per line, as the compiler prints them;
//! - its Objective-C and C headers (`Foo.framework/Headers`, see `clang`) with the module's API
//!   notes: the classes, protocols, enums, typedefs, functions and properties the Clang importer
//!   brings in, under the Swift names the notes, `NS_SWIFT_NAME` and a reduced form of the
//!   importer's omit-needless-words rule give them (`NSFileManager.defaultManager` ->
//!   `FileManager.default`).
//!
//! The compiler itself (`swift-symbolgraph-extract`) would give the exact surface, but it took
//! 113 s and 1.2 GB for Foundation and wrote 456 MB of JSON for SwiftUI at load 50; the text
//! here misses some renames, which the index store measures (`examples/swiftres.rs`).
//!
//! Modules are parsed on first use and kept for the process, keyed by SDK path and version: once
//! per SDK version, shared by every graph, worktree and repository. Symbols are named the way
//! SCIP names them (`swift-sdk macosx 26.5 Foundation/UUID#`), next to Elm's in `pkgview`.

mod clang;
mod interface;

use crate::pkgview::{PackageId, PkgKind, PkgSymbol};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

// ---- where the SDK is -------------------------------------------------------------------------

/// The SDK a process resolves Swift references against.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Sdk {
    /// `.../MacOSX.sdk`
    pub root: PathBuf,
    /// The platform's developer directory (`.../MacOSX.platform/Developer`), where XCTest lives.
    pub platform_dev: Option<PathBuf>,
    /// `macosx`
    pub name: String,
    /// `26.5`
    pub version: String,
}

type SdkOverride = Option<Option<Sdk>>;
static SDK_OVERRIDE: RwLock<SdkOverride> = RwLock::new(None);

/// Use `sdk` instead of the one `xcrun` selects, for this process (`None` turns Swift package
/// views off). For tests and embedders: a test must never read the real SDK, whose contents
/// differ from machine to machine.
pub fn set_sdk(sdk: Option<Sdk>) {
    *SDK_OVERRIDE.write().unwrap() = Some(sdk);
}

/// The active SDK: the override, else `xcrun --show-sdk-path` (asked once per process; none on a
/// machine without Xcode or the Command Line Tools, where Swift has no package views).
pub fn sdk() -> Option<Sdk> {
    if let Some(s) = SDK_OVERRIDE.read().unwrap().clone() {
        return s;
    }
    static XCRUN: OnceLock<Option<Sdk>> = OnceLock::new();
    XCRUN.get_or_init(xcrun_sdk).clone()
}

fn xcrun(arg: &str) -> Option<String> {
    let o = std::process::Command::new("xcrun").args(["--sdk", "macosx", arg]).output().ok()?;
    let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
    (o.status.success() && !s.is_empty()).then_some(s)
}

fn xcrun_sdk() -> Option<Sdk> {
    let root = PathBuf::from(xcrun("--show-sdk-path")?);
    let version = xcrun("--show-sdk-version").unwrap_or_default();
    let platform_dev = xcrun("--show-sdk-platform-path").map(|p| PathBuf::from(p).join("Developer"));
    Some(Sdk { root, platform_dev, name: "macosx".into(), version })
}

// ---- one module's surface ---------------------------------------------------------------------

/// A member of an SDK type, with the type of its value (a property's type, a function's result)
/// when the declaration spells one, so a receiver chain can step through it.
#[derive(Debug)]
pub struct Member {
    pub sym: Arc<PkgSymbol>,
    pub ty: Option<String>,
}

/// One type's members as one module declares them (in the type itself or in extensions), and the
/// supertypes and protocols it names.
#[derive(Debug, Default)]
pub struct TypeInfo {
    pub members: HashMap<String, Member>,
    pub supers: Vec<String>,
    /// This module declares the type itself (not only extensions of it).
    pub declared: bool,
}

/// What one SDK module declares.
#[derive(Debug)]
pub struct SwiftModule {
    pub name: String,
    pub package: Arc<PackageId>,
    /// Top-level names: types, functions, variables, macros.
    pub top: HashMap<String, Arc<PkgSymbol>>,
    /// Swift type name (`FileManager`, `FileManager.DirectoryEnumerator`) -> members.
    pub types: HashMap<String, TypeInfo>,
    /// Objective-C name -> Swift name, where they differ (`NSFileManager` -> `FileManager`).
    pub objc_names: HashMap<String, String>,
    /// Modules an `import` of this one also makes visible (`@_exported import`, the frameworks
    /// an umbrella header includes).
    pub reexports: Vec<String>,
}

impl SwiftModule {
    fn new(name: &str, package: Arc<PackageId>) -> SwiftModule {
        SwiftModule { name: name.into(), package, top: HashMap::new(), types: HashMap::new(), objc_names: HashMap::new(), reexports: Vec::new() }
    }

    pub fn names(&self) -> usize {
        self.top.len() + self.types.values().map(|t| t.members.len()).sum::<usize>()
    }

    fn sym(&self, module: &str, name: &str, kind: PkgKind, signature: Option<String>) -> Arc<PkgSymbol> {
        Arc::new(PkgSymbol { package: self.package.clone(), module: Arc::from(module), name: name.to_string(), kind, signature })
    }

    fn add_top(&mut self, decl_module: &str, name: &str, kind: PkgKind, signature: Option<String>) {
        if !self.top.contains_key(name) {
            let s = self.sym(decl_module, name, kind, signature);
            self.top.insert(name.to_string(), s);
        }
    }

    fn add_member(&mut self, decl_module: &str, ty: &str, name: &str, kind: PkgKind, signature: Option<String>, value_ty: Option<String>) {
        if let Some(prev) = self.types.get(ty).and_then(|t| t.members.get(name)) {
            // One name, two Objective-C methods (`removeItem(atPath:)`, `removeItem(at:)`): the
            // URL form, which Swift code calls far more (removeItem: 442 to 0 in flight-deck).
            let url_over_path = |p: &str, n: &str| p.contains("Path") && !p.contains("URL") && n.contains("URL");
            match (prev.sym.signature.as_deref(), signature.as_deref()) {
                (Some(p), Some(n)) if p.starts_with("@method") && n.starts_with("@method") && url_over_path(p, n) => {}
                _ => return,
            }
        }
        let s = self.sym(&format!("{decl_module}.{ty}"), name, kind, signature);
        self.types.entry(ty.to_string()).or_default().members.insert(name.to_string(), Member { sym: s, ty: value_ty });
    }

    fn mark_declared(&mut self, ty: &str) {
        self.types.entry(ty.to_string()).or_default().declared = true;
    }

    fn add_supers(&mut self, ty: &str, supers: impl IntoIterator<Item = String>) {
        if ty.is_empty() {
            return;
        }
        let t = self.types.entry(ty.to_string()).or_default();
        for s in supers {
            if !s.is_empty() && s != ty && !t.supers.contains(&s) {
                t.supers.push(s);
            }
        }
    }
}

// ---- the process-wide cache -------------------------------------------------------------------

/// The modules visible through one set of imports, nearest first.
pub type Closure = Arc<Vec<Arc<SwiftModule>>>;

#[derive(Default)]
struct Cache {
    loaded: HashMap<(Sdk, String), Option<Arc<SwiftModule>>>,
    missing: BTreeSet<String>,
    /// (SDK, imports) -> their closure: every Swift file of a repository asks with one of a few
    /// hundred import sets.
    closures: HashMap<(Sdk, Vec<String>), Closure>,
}

fn cache() -> &'static Mutex<Cache> {
    static C: OnceLock<Mutex<Cache>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// What `status` reports: SDK modules parsed, the names they declare, and modules imported that
/// the SDK has no surface for (a repository module, a package checkout, a C module like `Darwin`).
pub struct SdkStats {
    pub sdk: Option<String>,
    pub modules: usize,
    pub names: usize,
    pub missing: Vec<String>,
}

pub fn stats() -> SdkStats {
    let c = cache().lock().unwrap();
    let live: Vec<&Arc<SwiftModule>> = c.loaded.values().flatten().collect();
    SdkStats {
        sdk: sdk().map(|s| format!("{}@{}", s.name, s.version)),
        modules: live.len(),
        names: live.iter().map(|m| m.names()).sum(),
        missing: c.missing.iter().cloned().collect(),
    }
}

/// The surface of SDK module `name`, parsed on first use; `None` when the SDK has no such module.
pub fn module(sdk: &Sdk, name: &str) -> Option<Arc<SwiftModule>> {
    let key = (sdk.clone(), name.to_string());
    if let Some(m) = cache().lock().unwrap().loaded.get(&key) {
        return m.clone();
    }
    // Parsed outside the lock: two threads may both parse a module once, which is cheaper than
    // making every other lookup wait behind a two-megabyte interface.
    let parsed = load(sdk, name).map(Arc::new);
    let mut c = cache().lock().unwrap();
    if parsed.is_none() {
        c.missing.insert(name.to_string());
    }
    c.loaded.entry(key).or_insert(parsed).clone()
}

/// Modules every Swift file imports without saying so.
pub const IMPLICIT: &[&str] = &["Swift", "_Concurrency", "_StringProcessing"];

/// `imports` and every module they re-export, each once, nearest first, then the implicit
/// modules: the SDK modules whose names a file importing `imports` can use.
pub fn closure(sdk: &Sdk, imports: &[&str]) -> Closure {
    let key = (sdk.clone(), imports.iter().map(|s| s.to_string()).collect::<Vec<_>>());
    if let Some(c) = cache().lock().unwrap().closures.get(&key) {
        return c.clone();
    }
    let c = Arc::new(compute_closure(sdk, imports));
    cache().lock().unwrap().closures.entry(key).or_insert(c).clone()
}

fn compute_closure(sdk: &Sdk, imports: &[&str]) -> Vec<Arc<SwiftModule>> {
    let mut out: Vec<Arc<SwiftModule>> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let mut queue: std::collections::VecDeque<String> = imports.iter().chain(IMPLICIT).map(|s| s.to_string()).collect();
    while let Some(n) = queue.pop_front() {
        if seen.contains(&n) || seen.len() > 400 {
            continue;
        }
        seen.push(n.clone());
        if let Some(m) = module(sdk, &n) {
            queue.extend(m.reexports.iter().cloned());
            out.push(m);
        }
    }
    out
}

// ---- finding a module's files -----------------------------------------------------------------

fn frameworks_dirs(sdk: &Sdk) -> Vec<PathBuf> {
    let mut v = vec![sdk.root.join("System/Library/Frameworks"), sdk.root.join("System/Library/SubFrameworks")];
    if let Some(p) = &sdk.platform_dev {
        v.push(p.join("Library/Frameworks"));
    }
    v.push(sdk.root.join("System/iOSSupport/System/Library/Frameworks"));
    v
}

/// `Name.framework` in the SDK, including one nested in an umbrella (`CoreServices.framework/
/// Frameworks/LaunchServices.framework`).
fn framework(sdk: &Sdk, name: &str) -> Option<PathBuf> {
    let fw = format!("{name}.framework");
    for d in frameworks_dirs(sdk) {
        let p = d.join(&fw);
        if p.is_dir() {
            return Some(p);
        }
    }
    for d in frameworks_dirs(sdk) {
        for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
            let p = e.path().join("Frameworks").join(&fw);
            if p.is_dir() {
                return Some(p);
            }
        }
    }
    None
}

/// The textual interface of a `.swiftmodule` directory, for the SDK's architecture.
fn interface_in(dir: &Path) -> Option<PathBuf> {
    if !dir.is_dir() {
        return None;
    }
    for arch in ["arm64e-apple-macos", "arm64-apple-macos", "x86_64-apple-macos"] {
        let p = dir.join(format!("{arch}.swiftinterface"));
        if p.is_file() {
            return Some(p);
        }
    }
    let mut any: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.to_string_lossy().ends_with("-apple-macos.swiftinterface"))
        .collect();
    any.sort();
    any.into_iter().next()
}

fn swift_interface(sdk: &Sdk, name: &str, fw: Option<&Path>) -> Option<PathBuf> {
    let module = format!("{name}.swiftmodule");
    if let Some(p) = fw.and_then(|f| interface_in(&f.join("Modules").join(&module))) {
        return Some(p);
    }
    let mut dirs = vec![sdk.root.join("usr/lib/swift")];
    if let Some(p) = &sdk.platform_dev {
        dirs.push(p.join("usr/lib"));
    }
    dirs.into_iter().find_map(|d| interface_in(&d.join(&module)))
}

fn load(sdk: &Sdk, name: &str) -> Option<SwiftModule> {
    let pkg = Arc::new(PackageId { manager: "swift-sdk", name: sdk.name.clone(), version: sdk.version.clone() });
    let fw = framework(sdk, name);
    let iface = swift_interface(sdk, name, fw.as_deref());
    let headers = fw.as_ref().map(|f| f.join("Headers")).filter(|h| h.is_dir());
    if iface.is_none() && headers.is_none() {
        return None;
    }
    let mut m = SwiftModule::new(name, pkg);
    if let Some(h) = &headers {
        clang::parse_framework(&mut m, h, name, sdk);
    }
    if let Some(i) = iface
        && let Ok(text) = std::fs::read_to_string(&i)
    {
        interface::parse(&mut m, &text);
    }
    m.reexports.retain(|r| r != name);
    Some(m)
}

// ---- lookups ----------------------------------------------------------------------------------

/// A type name as a declaration writes it, reduced to the name members are filed under:
/// `Swift.Array<Element>` and `[Int]` are `Array`, `Foundation.URL?` is `URL`.
pub fn base_type(t: &str) -> Option<String> {
    let t = t.trim().trim_start_matches("some ").trim_start_matches("any ").trim_start_matches("inout ").trim();
    let t = t.trim_end_matches(['?', '!']);
    if t.starts_with('[') {
        return Some(if t.contains(':') { "Dictionary" } else { "Array" }.into());
    }
    if t.starts_with('(') || t.is_empty() {
        return None;
    }
    let head = t.split('<').next().unwrap_or(t).trim();
    if head.contains(['-', ' ', '&', '(']) {
        return None;
    }
    let head = head.trim_end_matches(".Type");
    let parts: Vec<&str> = head.split('.').collect();
    // Drop a leading module name (`Swift.`, `Foundation.`): interfaces qualify every SDK type
    // with its module exactly once.
    let keep = if parts.len() > 1 && is_known_module(parts[0]) { &parts[1..] } else { &parts[..] };
    let s = keep.join(".");
    (!s.is_empty()).then_some(s)
}

fn is_known_module(s: &str) -> bool {
    matches!(
        s,
        "Swift" | "_Concurrency" | "_StringProcessing" | "Foundation" | "FoundationEssentials" | "SwiftUI" | "SwiftUICore" | "AppKit" | "UIKit"
            | "Combine" | "CoreGraphics" | "CoreFoundation" | "Dispatch" | "ObjectiveC" | "Darwin" | "XCTest" | "Observation" | "os" | "OSLog"
            | "Network" | "CryptoKit" | "CoreData" | "CoreText" | "Security" | "WebKit" | "UniformTypeIdentifiers" | "Testing" | "CoreTransferable"
            | "DeveloperToolsSupport" | "System" | "Synchronization" | "QuartzCore" | "CoreImage" | "AVFoundation" | "Metal" | "ImageIO"
    )
}

/// Is `s` imported from a C or Objective-C header (its signature is the C declaration)?
fn from_clang(s: &PkgSymbol) -> bool {
    s.signature.as_deref().is_some_and(|g| g.starts_with('@') || g.starts_with("c "))
}

/// `name` among the top-level names of `modules`, nearest first; a Swift declaration beats a C
/// one of another module (`CGFloat` is CoreFoundation's Swift struct, not CoreGraphics' typedef).
pub fn lookup_top(modules: &[Arc<SwiftModule>], name: &str) -> Option<Arc<PkgSymbol>> {
    let mut first: Option<&Arc<PkgSymbol>> = None;
    for s in modules.iter().filter_map(|m| m.top.get(name)) {
        if !from_clang(s) {
            return Some(s.clone());
        }
        first.get_or_insert(s);
    }
    first.cloned()
}

/// Is `s` a value a bare, uncalled name can mean: a variable or constant (`stdout`,
/// `kCFBooleanTrue`), or a type? A function or macro named bare without a call (`line`, `type`) is
/// almost always a local of the same name the extractor saw.
pub fn is_value(s: &PkgSymbol) -> bool {
    match s.kind {
        PkgKind::Type | PkgKind::TypeAlias | PkgKind::Constructor => true,
        _ => s.signature.as_deref().is_some_and(|g| g.starts_with("c var ") || g.starts_with("@property ") || g.contains("var ") || g.contains("let ")),
    }
}

/// Is `ty` a type one of `modules` declares (at top level or nested)?
pub fn is_type(modules: &[Arc<SwiftModule>], ty: &str) -> bool {
    modules.iter().any(|m| m.types.contains_key(ty) || m.top.get(ty).is_some_and(|s| matches!(s.kind, PkgKind::Type | PkgKind::TypeAlias)))
}

/// Member `name` of SDK type `ty` or of a supertype or protocol it names, as any of `modules`
/// declares it (an extension in another module counts: Swift makes extension members visible
/// through any import). Breadth first, so the type's own member beats an inherited one.
pub fn lookup_member<'a>(modules: &'a [Arc<SwiftModule>], ty: &str, name: &str) -> Option<&'a Member> {
    // `_StringProcessing` extends every `BidirectionalCollection` with regex overloads
    // (`contains(_: Regex)`, `split(separator: Regex)`) that apply to strings only and lose to
    // the standard library's and Foundation's for anything else: measured against the index
    // store, they were the wrong pick 850 times out of 850. Only its own names come from it.
    let (regex, rest): (Vec<&Arc<SwiftModule>>, Vec<&Arc<SwiftModule>>) = modules.iter().partition(|m| m.name == "_StringProcessing");
    member_in(&rest, ty, name).or_else(|| member_in(&regex, ty, name))
}

/// Level by level from `ty` through its supertypes. Within a level, the module declaring a type
/// first (the standard library's `Sequence.sorted`, not Foundation's `sorted(using:)`), then the
/// nearest module (Foundation's `StringProtocol.contains` for a `String`).
fn member_in<'a>(modules: &[&'a Arc<SwiftModule>], ty: &str, name: &str) -> Option<&'a Member> {
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    seen.insert(ty);
    let mut level: Vec<&str> = vec![ty];
    while !level.is_empty() && seen.len() < 64 {
        let mut next: Vec<&str> = Vec::new();
        let mut nearest: Option<&'a Member> = None;
        for m in modules {
            for t in &level {
                let key = m.objc_names.get(*t).map(String::as_str).unwrap_or(t);
                let Some(ti) = m.types.get(key) else { continue };
                if let Some(mem) = ti.members.get(name) {
                    if ti.declared {
                        return Some(mem);
                    }
                    nearest.get_or_insert(mem);
                }
                for s in &ti.supers {
                    if seen.insert(s.as_str()) {
                        next.push(s.as_str());
                    }
                }
            }
        }
        if nearest.is_some() {
            return nearest;
        }
        level = next;
    }
    None
}

// ---- the index store as the answer key --------------------------------------------------------

/// Does the index-store USR `usr` name the package symbol `s`? An SDK symbol imported from
/// Objective-C or C records its C declaration as its signature (`@interface NSFileManager`), whose
/// last word is the name its USR carries.
pub fn symbol_matches(usr: &str, s: &PkgSymbol) -> bool {
    let objc = s.signature.as_deref().filter(|sig| sig.starts_with('@') || sig.starts_with("c ")).and_then(|sig| sig.rsplit(' ').next());
    let module = s.module.split('.').next().unwrap_or("");
    // A declaration moved between modules (`@_originallyDefinedIn`) is named by either in USRs:
    // the store has `CGFloat` under CoreFoundation, where it lives, and `Text` under SwiftUI,
    // where it was first defined.
    usr_matches(usr, module, &s.name, objc) || moved_modules(module).iter().any(|m| usr_matches(usr, m, &s.name, objc))
}

/// Pairs (original module, module declaring it now) the parsed interfaces' `@_originallyDefinedIn`
/// attributes named.
fn moves() -> &'static Mutex<BTreeSet<(String, String)>> {
    static M: OnceLock<Mutex<BTreeSet<(String, String)>>> = OnceLock::new();
    M.get_or_init(Default::default)
}

pub(crate) fn record_move(original: &str, now: &str) {
    if original != now {
        let mut m = moves().lock().unwrap();
        if !m.contains(&(original.to_string(), now.to_string())) {
            m.insert((original.to_string(), now.to_string()));
        }
    }
}

/// The modules declarations of `module` moved to or from.
fn moved_modules(module: &str) -> Vec<String> {
    moves().lock().unwrap().iter().filter_map(|(o, n)| if o == module { Some(n.clone()) } else if n == module { Some(o.clone()) } else { None }).collect()
}

/// Does the index-store USR `usr` name the declaration `name` of `module`? A Swift USR
/// (`s:10Foundation4UUIDV`) carries the declaring module (or the module of the extension that
/// declares a member, `...10FoundationE...`) and the name, length-prefixed; an Objective-C or C
/// one (`c:objc(cs)NSFileManager`, `c:@F@CGRectMake`) carries only the C name, which `objc_name`
/// gives when the Swift name differs. A selector matches by its first piece.
pub fn usr_matches(usr: &str, module: &str, name: &str, objc_name: Option<&str>) -> bool {
    if let Some(c) = usr.strip_prefix("c:") {
        let last = c.rsplit(['@', ')']).next().unwrap_or(c);
        let want = objc_name.unwrap_or(name);
        return last == want || last == name || (want.ends_with(':') && last.starts_with(want));
    }
    let Some(m) = usr.strip_prefix("s:") else { return false };
    let b = m.as_bytes();
    let ident = format!("{}{module}", module.len());
    let module_ok = m.starts_with(&ident)
        || m.contains(&format!("{ident}E"))
        // A Swift overlay's member of an Objective-C class (`s:So10XCTestCaseC0A0E11fulfillment`):
        // the extension's module is spelled with word substitutions.
        || m.starts_with("So")
        || (module == "Swift" && (b.first() == Some(&b's') || (b.first() == Some(&b'S') && b.get(1) != Some(&b'c') && b.get(1) != Some(&b'o'))))
        || (module == "_Concurrency" && m.starts_with("Sc"));
    module_ok && (contains_ident(m, name) || std_subst(m).is_some_and(|n| n == name) || contains_word_prefix(m, name))
}

/// Does the mangled text hold `name` spelled with word substitutions: a `0`, then a literal prefix
/// of the name ending at a word boundary, then a substitution (`06accentC0` is `accentColor`)?
fn contains_word_prefix(m: &str, name: &str) -> bool {
    let b = name.as_bytes();
    (3..name.len()).filter(|&k| b[k].is_ascii_uppercase()).any(|k| {
        let needle = format!("0{k}{}", &name[..k]);
        m.match_indices(&needle).any(|(i, _)| m.as_bytes().get(i + needle.len()).is_some_and(u8::is_ascii_uppercase))
    })
}

/// The standard library's one-letter type substitutions (`Si` is `Swift.Int`).
const STD_SUBST: &[(u8, &str)] = &[
    (b'a', "Array"), (b'b', "Bool"), (b'D', "Dictionary"), (b'd', "Double"), (b'f', "Float"), (b'h', "Set"),
    (b'i', "Int"), (b'J', "Character"), (b'N', "ClosedRange"), (b'n', "Range"), (b'O', "ObjectIdentifier"),
    (b'p', "UnsafeMutablePointer"), (b'P', "UnsafePointer"), (b'q', "Optional"), (b'R', "UnsafeBufferPointer"),
    (b'r', "UnsafeMutableBufferPointer"), (b'S', "String"), (b's', "Substring"), (b'u', "UInt"),
    (b'V', "UnsafeRawPointer"), (b'v', "UnsafeMutableRawPointer"), (b'W', "UnsafeRawBufferPointer"),
    (b'w', "UnsafeMutableRawBufferPointer"), (b'E', "Encodable"), (b'e', "Decodable"), (b'H', "Hashable"),
    (b'L', "Comparable"), (b'Q', "Equatable"), (b'T', "Sequence"), (b'l', "Collection"), (b'K', "BidirectionalCollection"),
    (b'k', "RandomAccessCollection"), (b'M', "MutableCollection"), (b'm', "RangeReplaceableCollection"),
    (b'j', "Numeric"), (b'Z', "SignedInteger"), (b'z', "BinaryInteger"), (b'x', "Strideable"), (b'Y', "RawRepresentable"),
    (b't', "IteratorProtocol"), (b'I', "DefaultIndices"), (b'F', "FloatingPoint"), (b'B', "BinaryFloatingPoint"),
    (b'U', "UnsignedInteger"), (b'G', "RandomNumberGenerator"), (b'y', "StringProtocol"), (b'X', "RangeExpression"),
];

/// The concurrency library's (`ScT` is `_Concurrency.Task`).
const CONCURRENCY_SUBST: &[(u8, &str)] = &[
    (b'A', "Actor"), (b'C', "CheckedContinuation"), (b'c', "UnsafeContinuation"), (b'E', "CancellationError"),
    (b'e', "UnownedSerialExecutor"), (b'F', "Executor"), (b'f', "SerialExecutor"), (b'G', "TaskGroup"),
    (b'g', "ThrowingTaskGroup"), (b'h', "TaskExecutor"), (b'I', "AsyncIteratorProtocol"), (b'i', "AsyncSequence"),
    (b'J', "UnownedJob"), (b'M', "MainActor"), (b'P', "TaskPriority"), (b'S', "AsyncStream"), (b's', "AsyncThrowingStream"),
    (b'T', "Task"), (b't', "UnsafeCurrentTask"),
];

/// The standard-library type a USR body that is one substitution and a kind letter names (`Si`
/// is `Int`, `ScT` is `Task`).
fn std_subst(m: &str) -> Option<&'static str> {
    let b = m.as_bytes();
    if b.first() != Some(&b'S') {
        return None;
    }
    if b.get(1) == Some(&b'c') {
        return (m.len() <= 4).then(|| CONCURRENCY_SUBST.iter().find(|(k, _)| Some(k) == b.get(2)).map(|(_, n)| *n)).flatten();
    }
    if m.len() > 3 {
        return None;
    }
    STD_SUBST.iter().find(|(k, _)| Some(k) == b.get(1)).map(|(_, n)| *n)
}

/// Does the mangled text hold `name` as a length-prefixed identifier?
fn contains_ident(rest: &str, name: &str) -> bool {
    let needle = format!("{}{name}", name.len());
    let b = rest.as_bytes();
    rest.match_indices(&needle).any(|(i, _)| i == 0 || !b[i - 1].is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usrs_name_their_module_and_declaration() {
        assert!(usr_matches("s:10Foundation4UUIDV", "Foundation", "UUID", None));
        assert!(!usr_matches("s:10Foundation4UUIDV", "SwiftUI", "UUID", None));
        assert!(usr_matches("s:6XCTest14XCTAssertEqualyyx_xyXKSSyXKs12StaticStringVSutSQRzlF", "XCTest", "XCTAssertEqual", None));
        assert!(usr_matches("s:SS", "Swift", "String", None));
        assert!(usr_matches("s:ScT", "_Concurrency", "Task", None));
        assert!(usr_matches("s:ScM", "_Concurrency", "MainActor", None));
        assert!(usr_matches("s:s5printyyypd_SS9separatorSS10terminatortF", "Swift", "print", None));
        assert!(usr_matches("s:STsE3mapySayqd__Gqd__7ElementQzKXEKlF", "Swift", "map", None));
        assert!(usr_matches("s:So13NSFileManagerC10FoundationE3urlyF", "Foundation", "url", None), "a member an extension in Foundation declares");
        assert!(usr_matches("c:objc(cs)NSFileManager", "Foundation", "FileManager", Some("NSFileManager")));
        assert!(usr_matches("c:objc(cs)NSFileManager(cpy)defaultManager", "Foundation", "default", Some("defaultManager")));
        assert!(usr_matches("c:objc(cs)NSFileManager(im)removeItemAtURL:error:", "Foundation", "removeItem", Some("removeItemAtURL:")));
        assert!(!usr_matches("c:objc(cs)NSFileManager", "Foundation", "Bundle", Some("NSBundle")));
        assert!(usr_matches("s:So10XCTestCaseC0A0E11fulfillment2of7timeout12enforceOrderySaySo0A11ExpectationCG_SdSbtYaF", "XCTest", "fulfillment", None));
        assert!(usr_matches("s:7SwiftUI5ColorV06accentC0ACvpZ", "SwiftUI", "accentColor", None), "a name spelled with a word substitution");
        assert!(!usr_matches("s:10Foundation14UUIDStringValueV", "Foundation", "UUID", None), "the length prefix delimits the name");
    }

    #[test]
    fn base_types_drop_modules_generics_and_optionals() {
        assert_eq!(base_type("Swift.Array<Element>").as_deref(), Some("Array"));
        assert_eq!(base_type("[Swift.Int]").as_deref(), Some("Array"));
        assert_eq!(base_type("[Swift.String : Any]").as_deref(), Some("Dictionary"));
        assert_eq!(base_type("Foundation.URL?").as_deref(), Some("URL"));
        assert_eq!(base_type("Foundation.FileManager.DirectoryEnumerator").as_deref(), Some("FileManager.DirectoryEnumerator"));
        assert_eq!(base_type("(Swift.Int) -> Swift.Bool"), None);
    }
}
