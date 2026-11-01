//! Package symbols in `find` and `refs` (see `pkgview`): `List.map` is elm/core's, and the
//! references to it are the repository's. Answered from the view that answers only; a linked
//! view's package references are not listed.
//!
//! A package symbol is listed when the name is qualified (`List.map`, `Json.Decode.field`) or
//! when no repository symbol matches. An unqualified `map` that the repository defines lists the
//! repository's definitions only: elm/core alone exports seven `map`s, and they would push the
//! definitions people mean out of the limit.

use super::{is_test_path, Ctx};
use crate::pkgview::PkgSymbol;
use std::collections::BTreeMap;
use std::fmt::Write;
use std::sync::Arc;

/// Package symbols `find`/`refs` should show for `name`, given how many repository symbols
/// matched.
pub fn candidates(c: &Ctx, name: &str, repo_hits: usize) -> Vec<Arc<PkgSymbol>> {
    if repo_hits > 0 && !name.contains('.') {
        return Vec::new();
    }
    c.graph.find_package_symbols(name)
}

/// One `find` match block.
pub fn find_block(out: &mut String, s: &PkgSymbol) {
    let _ = writeln!(out, "{} ({})", s.name, s.kind.as_str());
    let _ = writeln!(out, "Package: {}", s.display());
    if let Some(sig) = &s.signature {
        let _ = writeln!(out, "Signature: {sig}");
    }
    let _ = writeln!(out, "Status: package");
}

/// One `refs` candidate section, in the shape of a repository one.
pub fn refs_section(c: &Ctx, out: &mut String, s: &PkgSymbol, include_tests: bool) {
    let g = c.graph;
    let _ = writeln!(out, "Symbol: {} (package {})", s.name, s.kind.as_str());
    let _ = writeln!(out, "Defined in: package {}", s.display());
    let mut by_file: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut n = 0;
    for (fi, ri, _) in g.package_references(&s.module, &s.name).into_iter().filter(|(_, _, t)| ***t == *s) {
        let f = g.file(fi);
        if !include_tests && is_test_path(&f.path) {
            continue;
        }
        let r = &f.facts.refs[ri as usize];
        let enclosing = r.enclosing().map(|e| format!(" in {}", f.symbol(e).name)).unwrap_or_default();
        by_file.entry(g.abs(fi).display().to_string()).or_default().push(format!("  L{} {}{enclosing}", r.line, r.kind.as_str()));
        n += 1;
    }
    if n == 0 {
        let _ = writeln!(out, "No references found.");
    } else {
        let _ = writeln!(out, "References ({n} in {} file(s)):", by_file.len());
    }
    for (path, rows) in by_file {
        let _ = writeln!(out, "{path}");
        for r in rows {
            let _ = writeln!(out, "{r}");
        }
    }
    out.push('\n');
}
