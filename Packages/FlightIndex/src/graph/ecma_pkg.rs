//! TypeScript and JavaScript references into npm packages: the per-file scope of names bound by
//! imports of package modules (`import { it } from 'vitest'`, `import * as fc from 'fast-check'`,
//! `import path from 'node:path'`, `const assert = require('assert')`), consulted after the
//! file's own resolution exactly like the Elm scope (`elm_pkg`), so a local definition or a
//! repository import always wins and a package name always beats a unique-name guess.
//!
//! Package references are recorded in the same `PkgRefs` side table with
//! `Confidence::Package`, so ranks, the incoming index, rename and move ignore them.

use super::GraphData;
use crate::facts::{Import, ImportKind, RefKind};
use crate::pkgview::{ModuleExports, PkgSymbol};
use crate::resolve::Resolved;
use std::collections::HashMap;
use std::sync::Arc;

/// The package names one TypeScript/JavaScript file can use.
#[derive(Default)]
pub(super) struct EcmaPkgScope {
    /// Local name -> (module, exported name): `import { a as b }` binds `b` to `a`, a default
    /// import binds `default`.
    locals: HashMap<String, (Arc<ModuleExports>, String)>,
    /// `import * as ns` and `const ns = require()`: the module itself.
    quals: HashMap<String, Arc<ModuleExports>>,
}

impl EcmaPkgScope {
    pub(super) fn new(imports: &[Import], resolved: &[Resolved]) -> Option<EcmaPkgScope> {
        let mut s = EcmaPkgScope::default();
        for (imp, r) in imports.iter().zip(resolved) {
            let Resolved::Package(m) = r else { continue };
            if imp.kind != ImportKind::Import {
                continue;
            }
            if let Some(a) = &imp.alias {
                s.quals.insert(a.clone(), m.clone());
                if imp.names.is_empty() {
                    // `const assert = require('assert')`; `assert(x)` calls what it exports.
                    s.locals.insert(a.clone(), (m.clone(), "default".into()));
                }
            }
            for n in imp.names.iter().filter(|n| n.name != "*") {
                s.locals.insert(n.local().to_string(), (m.clone(), n.name.clone()));
            }
        }
        (!s.locals.is_empty() || !s.quals.is_empty()).then_some(s)
    }

    /// The package symbol a reference named `name` (under `qualifier`, of `kind`) means here.
    pub(super) fn lookup(&self, name: &str, qualifier: Option<&str>, kind: RefKind) -> Option<Arc<PkgSymbol>> {
        let ty = kind == RefKind::Type;
        match qualifier {
            None => {
                let (m, orig) = self.locals.get(name)?;
                m.lookup(orig, ty).cloned()
            }
            Some(q) => {
                if let Some(m) = self.quals.get(q)
                    && let Some(hit) = m.lookup(name, ty)
                {
                    return Some(hit.clone());
                }
                let (m, orig) = self.locals.get(q)?;
                m.members.get(orig)?.lookup(name, ty).cloned()
            }
        }
    }
}

impl GraphData {
    /// The npm package modules the view's TypeScript and JavaScript files import, each once.
    pub fn npm_modules(&self) -> Vec<Arc<ModuleExports>> {
        let mut out: Vec<Arc<ModuleExports>> = Vec::new();
        for (i, r) in self.res.iter().enumerate() {
            if !self.files[i].alive || !matches!(self.files[i].language, "typescript" | "tsx" | "javascript") {
                continue;
            }
            for imp in &r.imports {
                if let Resolved::Package(m) = imp
                    && m.package.manager == "npm"
                    && !out.iter().any(|o| Arc::ptr_eq(o, m))
                {
                    out.push(m.clone());
                }
            }
        }
        out
    }

    /// npm package symbols named `name`, or `module.name` (`vitest.expect`, `node:path.join`),
    /// among the exports of the modules the view imports.
    pub(super) fn find_npm_symbols(&self, query: &str, out: &mut Vec<Arc<PkgSymbol>>) {
        let mods = self.npm_modules();
        let split = query.rfind('.').filter(|i| i + 1 < query.len()).map(|i| (&query[..i], &query[i + 1..]));
        for m in &mods {
            let name = match split {
                Some((module, name)) if module == &*m.name => name,
                _ => query,
            };
            for s in [m.values.get(name), m.types.get(name)].into_iter().flatten() {
                if !out.iter().any(|o| **o == **s) {
                    out.push(s.clone());
                }
            }
        }
    }
}
