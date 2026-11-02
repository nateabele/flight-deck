//! Swift references into the SDK (see `crate::pkgview_swift`): the SDK modules one file can name,
//! and the package symbol a reference the repository's own resolution left without a target
//! means. Consulted only after `swift_ref` found nothing, so a repository declaration always wins,
//! as it does for the compiler (a module's own `Task` shadows the standard library's).
//!
//! What binds:
//! - an unqualified name (`UUID`, `XCTAssertEqual`, `print`) that a visible SDK module declares
//!   at top level;
//! - `Module.name` (`Foundation.UUID`) and `Type.member` (`FileManager.default`, `Date.now`) when
//!   the type is the SDK's or a repository type inherits the member from one;
//! - `receiver.member` when the receiver's type is known (the repository's own ladder, then
//!   stepping through SDK members' declared types: `FileManager.default.createDirectory`), and
//!   the member is that type's or a supertype's.
//!
//! An untyped receiver (`x.map`) stays unresolved: which `map` it is depends on a type nothing
//! here knows.

use super::swift_types::{segments, OPAQUE};
use super::GraphData;
use crate::facts::{RefKind, RefSite};
use crate::pkgview::PkgSymbol;
use crate::pkgview_swift::{self as sdk, SwiftModule};
use std::sync::Arc;

/// The SDK modules one Swift file sees: its imports that are not repository modules, what they
/// re-export, and the implicit standard library.
pub(super) struct SwiftPkgScope {
    modules: sdk::Closure,
}

impl GraphData {
    /// `None` without an SDK (no Xcode, Linux): Swift then has no package views.
    pub(super) fn swift_pkg_scope(&self, f: u32) -> Option<SwiftPkgScope> {
        let sdk = sdk::sdk()?;
        let node = &self.files[f as usize];
        let mut imports: Vec<&str> = Vec::new();
        for imp in &node.facts.imports {
            let m = imp.specifier.split('.').next().unwrap_or("");
            if !m.is_empty() && self.resolver.swift_modules_named(m).is_empty() && !imports.contains(&m) {
                imports.push(m);
            }
        }
        Some(SwiftPkgScope { modules: sdk::closure(&sdk, &imports) })
    }

    /// The SDK declaration reference `r` of file `f` names, if the scope has one.
    pub(super) fn swift_pkg_ref(&self, f: u32, r: &RefSite, scope: &SwiftPkgScope) -> Option<Arc<PkgSymbol>> {
        let name = self.name(r.name);
        if matches!(name, "self" | "Self" | "super" | "init" | "Type") {
            return None;
        }
        let mods = &scope.modules;
        let hit = self.swift_pkg_lookup(f, r, name, mods)?;
        // `type`, `line`, `value` used bare and uncalled are locals of the same name; only a
        // call can mean a function there.
        let bare_use = r.kind != RefKind::Call && self.qualifier(r).is_none() && name.starts_with(|c: char| c.is_lowercase());
        (!bare_use || sdk::is_value(&hit)).then_some(hit)
    }

    fn swift_pkg_lookup(&self, f: u32, r: &RefSite, name: &str, mods: &[Arc<SwiftModule>]) -> Option<Arc<PkgSymbol>> {
        match self.qualifier(r) {
            // A member the enclosing type inherits from an SDK class (`expectation(...)` in an
            // `XCTestCase`) shadows a top-level name, as in Swift's own lookup. A capitalised
            // name is nearly always a type or a global function (`UUID`, `XCTAssertEqual`), so
            // the cheap top-level lookup goes first for those.
            None => {
                let member = || self.swift_receiver_type(f, "self", r.line, r.enclosing()).filter(|t| t != OPAQUE).and_then(|t| self.swift_sdk_member(&t, name, mods)).map(|m| m.sym.clone());
                if name.starts_with(|c: char| c.is_uppercase()) { sdk::lookup_top(mods, name).or_else(member) } else { member().or_else(|| sdk::lookup_top(mods, name)) }
            }
            Some(q) => {
                if let Some(m) = mods.iter().find(|m| m.name == q) {
                    return m.top.get(name).cloned();
                }
                let ty = self.swift_sdk_receiver(f, q, r, mods)?;
                self.swift_sdk_member(&ty, name, mods).map(|m| m.sym.clone())
            }
        }
    }

    /// Member `name` of `ty` from the SDK: `ty`'s own when it is an SDK type, else that of the
    /// nearest SDK supertype a repository type names (`final class Panel: NSPanel`).
    fn swift_sdk_member<'a>(&self, ty: &str, name: &str, mods: &'a [Arc<SwiftModule>]) -> Option<&'a sdk::Member> {
        self.swift_types.lineage(ty).iter().filter(|t| !self.swift_is_repo_type(t)).find_map(|t| sdk::lookup_member(mods, t, name))
    }

    /// The type of receiver text `q` (`self`, `FileManager`, `url`, `FileManager.default`), as
    /// the repository's ladder types it, else by stepping through SDK members' declared types.
    fn swift_sdk_receiver(&self, f: u32, q: &str, r: &RefSite, mods: &[Arc<SwiftModule>]) -> Option<String> {
        let segs = segments(q)?;
        let (root, rest) = segs.split_first()?;
        let mut ty: String = if root.name.starts_with(|c: char| c.is_uppercase()) && root.name != "Self" {
            // A type used as a namespace (`FileManager`, `Foundation.URL`), or built (`URL(...)`).
            root.name.to_string()
        } else if root.call {
            return None; // a function's result: the SDK's top-level functions record no type
        } else {
            match self.swift_receiver_type_any(f, root.name, r.line, r.enclosing()) {
                Some(t) if t != OPAQUE => match t.strip_prefix('[') {
                    Some(inner) => if inner.contains(':') { "Dictionary" } else { "Array" }.to_string(),
                    None => t,
                },
                _ => return None,
            }
        };
        let mut rest = rest;
        // `Foundation.URL.init`: a module qualifier in front of a type.
        if let Some(m) = mods.iter().find(|m| m.name == ty)
            && let Some((next, tail)) = rest.split_first()
            && m.top.contains_key(next.name)
        {
            ty = next.name.to_string();
            rest = tail;
        }
        for s in rest {
            if s.name == "self" {
                continue;
            }
            if s.call && s.name == "init" {
                continue;
            }
            let next = if self.swift_is_repo_type(&ty) {
                if s.call { self.swift_types.ret(&ty, s.name) } else { self.swift_types.prop(&ty, s.name) }
            } else {
                None
            };
            ty = match next {
                Some(t) => t,
                None => self.swift_sdk_member(&ty, s.name, mods)?.ty.clone()?,
            };
        }
        Some(ty)
    }

    /// SDK symbols the view's Swift files can name, for `find`: `UUID`, `Foundation.UUID`, or a
    /// member as `FileManager.default`.
    pub(super) fn find_swift_package_symbols(&self, query: &str) -> Vec<Arc<PkgSymbol>> {
        let Some(sdk) = sdk::sdk() else { return Vec::new() };
        let mut imports: Vec<&str> = Vec::new();
        for f in self.files.iter().filter(|f| f.alive && f.language == "swift") {
            for imp in &f.facts.imports {
                let m = imp.specifier.split('.').next().unwrap_or("");
                if !m.is_empty() && !imports.contains(&m) && self.resolver.swift_modules_named(m).is_empty() {
                    imports.push(m);
                }
            }
        }
        if imports.is_empty() && !self.files.iter().any(|f| f.alive && f.language == "swift") {
            return Vec::new();
        }
        let mods = sdk::closure(&sdk, &imports);
        let hit = match query.rsplit_once('.') {
            None => sdk::lookup_top(&mods, query),
            Some((q, name)) => match mods.iter().find(|m| m.name == q) {
                Some(m) => m.top.get(name).cloned(),
                None => sdk::lookup_member(&mods, q, name).map(|m| m.sym.clone()),
            },
        };
        hit.into_iter().collect()
    }
}
