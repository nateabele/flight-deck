//! `rename`: change a definition's name and every place the index says uses it.
//!
//! Sites come from three places, all facts the index already holds:
//!
//! * the definition itself (its span in the defining file, plus Elm's `module … exposing` header);
//! * every reference the graph resolved to the definition (`incoming`: line, name, qualifier);
//! * every import statement that names it and lands on its file, following re-exports.
//!
//! The occurrence on a site's line is found by identifier match on the comment-and-string-free
//! text, and a qualified reference (`List.map`, `self.open()`) must carry the qualifier the
//! extractor recorded. A name an importer *aliased* (`import { helper as h }`) keeps its alias:
//! only occurrences spelled like the old name are rewritten.

use super::doc::Doc;
use super::{select, MutCtx, Plan, Work};
use crate::facts::{Symbol, SymbolKind};
use crate::graph::ViewGraph;
use crate::resolve::Resolved;
use crate::tools::ToolError;
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// Does the identifier at `tok` carry the qualifier a reference recorded? A plain reference must
/// not be a member access (`x.open` is not a use of the free function `open`).
pub fn qualifier_ok(masked: &str, tok: usize, q: Option<&str>) -> bool {
    let before = &masked[..tok];
    let sep = before.ends_with('.') || before.ends_with("::");
    match q {
        None => !sep,
        Some(q) => {
            if before.ends_with(&format!("{q}.")) || before.ends_with(&format!("{q}::")) {
                return true;
            }
            // `a.b.c()` records `a.b` or `b` depending on the language; accept the last segment.
            let last = q.rsplit(['.', ':']).next().unwrap_or(q);
            sep && before.trim_end_matches(['.', ':']).ends_with(last)
        }
    }
}

pub(super) fn valid_name(lang: &str, kind: SymbolKind, new: &str) -> Result<(), String> {
    let mut chars = new.chars();
    let first = chars.next().ok_or("new_name is empty")?;
    let allowed = |c: char| c.is_alphanumeric() || c == '_' || (lang != "elm" && c == '$') || (lang == "elm" && c == '\'');
    if !(first.is_alphabetic() || first == '_' || (lang != "elm" && first == '$')) || !new.chars().all(allowed) {
        return Err(format!("'{new}' is not a valid identifier"));
    }
    if lang == "elm" {
        let upper = matches!(kind, SymbolKind::Enum | SymbolKind::TypeAlias | SymbolKind::Constructor);
        if upper != first.is_uppercase() {
            return Err(format!("an Elm {} must start with {} letter: '{new}'", kind.as_str(), if upper { "an uppercase" } else { "a lowercase" }));
        }
    }
    Ok(())
}

/// The import-statement tokens that are the imported *name* (not the module, not an alias).
pub(super) fn import_token_ok(d: &Doc, tok: usize, stmt_start: usize, stmt_end: usize, old_len: usize) -> bool {
    let before = d.masked[stmt_start..tok].trim_end();
    if before.ends_with(" as") || before == "as" || before.ends_with("\nas") {
        return false;
    }
    let after = &d.masked[tok + old_len..stmt_end];
    match d.lang {
        "elm" => d.masked[stmt_start..tok].contains("exposing"),
        "typescript" | "tsx" | "javascript" => {
            let open = d.masked[stmt_start..tok].rfind('{');
            let closed = d.masked[stmt_start..tok].rfind('}');
            matches!((open, closed), (Some(o), c) if c.is_none_or(|c| c < o))
        }
        "rust" => !after.trim_start().starts_with("::"),
        _ => true,
    }
}

/// Byte offsets of the definition's own name token(s).
fn definition_sites(d: &Doc, s: &Symbol, old: &str) -> Vec<usize> {
    let (start, end) = (s.start_line as usize, s.end_line as usize);
    if d.elm() && matches!(s.kind, SymbolKind::Function | SymbolKind::Const) {
        // The annotation `name : T` and the clause `name args =` both begin in column 0.
        return (start..=end)
            .filter_map(|l| {
                let ls = d.src.line_start(l);
                d.line_tokens(l, old).into_iter().find(|&t| t == ls)
            })
            .collect();
    }
    let from = d.src.line_start(start) + s.start_col as usize;
    for l in start..=end.min(start + 30) {
        let hit = d.line_tokens(l, old).into_iter().find(|&t| t >= from && (t == 0 || d.masked.as_bytes()[t - 1].is_ascii_whitespace()));
        if let Some(t) = hit {
            return vec![t];
        }
    }
    Vec::new()
}

/// The `module … exposing (…)` header of an Elm file, as a byte range.
pub(super) fn elm_header(d: &Doc) -> Option<(usize, usize)> {
    let first = (1..=d.src.line_count().min(40)).find(|&l| {
        let t = d.src.line(l);
        t.starts_with("module ") || t.starts_with("port module ") || t.starts_with("effect module ")
    })?;
    let (a, b) = d.extent(first);
    Some(d.lines_bytes(a, b))
}

pub fn rename(c: &MutCtx) -> Result<Plan, ToolError> {
    let new = c.args.str(&["new_name", "to_name"]).ok_or_else(|| ToolError::bad("new_name is required"))?;
    let t = select(c, &["old_name", "symbol", "name", "symbol_name"])?;
    let g = c.graph;
    let old = t.name.clone();
    let lang = g.file(t.id.file).language;
    let tf = t.id.file;
    if new == old {
        return Err(ToolError::bad(format!("new_name is the same as the old name '{old}'")));
    }
    valid_name(lang, t.kind, &new).map_err(ToolError::bad)?;
    if t.kind == SymbolKind::Field {
        return Err(ToolError::failed(format!("rename of a field is not supported: the index does not record where '{old}' is read or written as a member, so a rename would miss uses and leave the code broken")));
    }
    if lang == "rust" && t.kind == SymbolKind::Module {
        return Err(ToolError::failed(format!("renaming the Rust module '{old}' also renames its file and the `mod` line that names it: use rename_file")));
    }

    // Rust splits a type across `struct Foo` and every `impl Foo`, and the resolver may bind a
    // reference to either, so references to any of them are references to the type.
    let mut targets = vec![t.id];
    if lang == "rust" {
        let file = g.file(tf);
        targets.extend(file.facts.symbols.iter().filter(|s| s.kind == SymbolKind::Impl && s.name == old).map(|s| crate::graph::SymId { file: tf, local: s.local_id }));
    }

    // Reference sites: file -> line -> the qualifiers recorded there.
    let mut sites: RefSites = BTreeMap::new();
    for id in &targets {
        for &(fi, ri) in g.incoming.get(id).unwrap_or_default().iter() {
            let r = &g.file(fi).facts.refs[ri as usize];
            if g.name(r.name) == old {
                sites.entry(fi).or_default().entry(r.line).or_default().push(g.qualifier(r).map(String::from));
            }
        }
    }

    // Members reached through a renamed type: `Store::new()` records a reference to `new` whose
    // qualifier is `Store`, and the `Store` in it is not a reference of its own.
    let mut member_sites: BTreeMap<u32, Vec<(u32, String, String)>> = BTreeMap::new();
    if matches!(t.kind, SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::Interface | SymbolKind::Class | SymbolKind::TypeAlias) {
        for (fi, node) in g.files.iter().enumerate().filter(|(_, n)| n.alive) {
            for (ri, r) in node.facts.refs.iter().enumerate() {
                let Some(q) = g.qualifier(r) else { continue };
                if q.rsplit(['.', ':']).next() != Some(old.as_str()) {
                    continue;
                }
                let Some(tid) = g.res[fi].refs[ri].target else { continue };
                let owner = g.file(tid.file).symbol(tid.local).parent.map(|p| g.file(tid.file).symbol(p));
                if owner.is_some_and(|o| o.name == old && (tid.file == tf || o.kind == SymbolKind::Impl)) {
                    member_sites.entry(fi as u32).or_default().push((r.line, g.name(r.name).to_string(), q.to_string()));
                }
            }
        }
    }

    // Import sites: every statement naming the symbol that lands on its file, or on a file that
    // re-exports it from there.
    let import_sites = follow_reexports(g, HashSet::from([tf]), BTreeMap::new(), &old);

    if !c.args.flag(&["allow_collision"], false) {
        let mut clashes: Vec<String> = Vec::new();
        let file = g.file(tf);
        let me = file.symbol(t.id.local);
        for s in &file.facts.symbols {
            if s.name == new && s.parent == me.parent && s.local_id != t.id.local {
                clashes.push(format!("{} already defines `{new}` ({}) at L{}", g.abs(tf).display(), s.kind.as_str(), s.start_line));
            }
        }
        let touched: BTreeSet<u32> = sites.keys().chain(import_sites.keys()).copied().chain([tf]).collect();
        clashes.extend(collisions(g, &touched, Some(tf), &old, &new));
        refuse_collisions(clashes, &old, &new)?;
    }

    let mut w = Work::new(g);
    let mut counts = (0usize, 0usize, 0usize); // definition, reference, import
    let sym = g.file(tf).symbol(t.id.local).clone();

    {
        let d = w.doc(tf)?;
        let defs = definition_sites(d, &sym, &old);
        if defs.is_empty() {
            return Err(ToolError::failed(format!("could not find the name `{old}` in the definition at {}:L{}; nothing was changed", t.path.display(), t.start_line)));
        }
        for at in defs {
            counts.0 += d.replace_token(at, old.len(), &new) as usize;
        }
        // Impl blocks of a renamed Rust type are rewritten through their reference sites.
        if d.elm()
            && let Some((hs, he)) = elm_header(d)
        {
            let exposing = d.masked[hs..he].find("exposing").map(|i| hs + i);
            if let Some(ex) = exposing {
                for at in d.tokens_in(ex, he, &old) {
                    counts.0 += d.replace_token(at, old.len(), &new) as usize;
                }
            }
        }
    }

    counts.1 += rewrite_refs(&mut w, &sites, &old, &new)?;

    for (fi, list) in &member_sites {
        let d = w.doc(*fi)?;
        for (line, name, q) in list {
            for tok in d.line_tokens(*line as usize, name) {
                if !qualifier_ok(&d.masked, tok, Some(q)) {
                    continue;
                }
                let sep = if d.masked[..tok].ends_with("::") { 2 } else { 1 };
                let Some(pos) = tok.checked_sub(sep + old.len()) else { continue };
                if d.masked[pos..pos + old.len()] == *old {
                    counts.1 += d.replace_token(pos, old.len(), &new) as usize;
                }
            }
        }
    }

    counts.2 += rewrite_imports(&mut w, &import_sites, &old, &new)?;
    warn_left_alone(&mut w, &old);

    w.notes.push(format!("{} definition, {} reference, {} import site(s) rewritten", counts.0, counts.1, counts.2));
    w.finish(format!("rename {old} -> {new} ({} in {})", t.kind.as_str(), t.path.display()))
}

/// Reference sites: file -> line -> the qualifiers recorded there.
pub(super) type RefSites = BTreeMap<u32, BTreeMap<u32, Vec<Option<String>>>>;

/// Import statements naming `old` that land on a file in `providers` (or on a file that
/// re-exports it from there), added to `sites`: file -> import indices.
pub(super) fn follow_reexports(g: &ViewGraph, mut providers: HashSet<u32>, mut sites: BTreeMap<u32, BTreeSet<usize>>, old: &str) -> BTreeMap<u32, BTreeSet<usize>> {
    for _ in 0..3 {
        let mut grew = false;
        for (fi, node) in g.files.iter().enumerate().filter(|(_, n)| n.alive) {
            for (ii, imp) in node.facts.imports.iter().enumerate() {
                let lands = matches!(&g.res[fi].imports[ii], Resolved::File { path, .. } if g.index.get(path).is_some_and(|i| providers.contains(i)));
                if lands && imp.names.iter().any(|n| n.name == old) {
                    sites.entry(fi as u32).or_default().insert(ii);
                    if providers.insert(fi as u32) {
                        grew = true;
                    }
                }
            }
        }
        if !grew {
            break;
        }
    }
    sites
}

/// Files in `touched` (other than `defining`) where `new` is already a top-level name or imported.
pub(super) fn collisions(g: &ViewGraph, touched: &BTreeSet<u32>, defining: Option<u32>, old: &str, new: &str) -> Vec<String> {
    let mut clashes = Vec::new();
    for &fi in touched {
        let f = g.file(fi);
        if Some(fi) != defining {
            for s in f.facts.symbols.iter().filter(|s| s.name == new && s.parent.is_none() && s.kind != SymbolKind::Impl) {
                clashes.push(format!("{} defines `{new}` ({}) at L{}, where `{old}` is used", g.abs(fi).display(), s.kind.as_str(), s.start_line));
            }
        }
        for imp in &f.facts.imports {
            if imp.names.iter().any(|n| n.local() == new) {
                clashes.push(format!("{} imports `{new}` at L{}", g.abs(fi).display(), imp.line));
            }
        }
    }
    clashes
}

pub(super) fn refuse_collisions(mut clashes: Vec<String>, old: &str, new: &str) -> Result<(), ToolError> {
    if clashes.is_empty() {
        return Ok(());
    }
    clashes.sort();
    clashes.dedup();
    Err(ToolError::failed(format!("refusing: renaming {old} to {new} would collide; nothing was changed. Pass allow_collision=true to rename anyway.\n  {}", clashes.join("\n  "))))
}

/// Rewrite `old` to `new` at each reference site whose qualifier matches. Returns the count.
pub(super) fn rewrite_refs(w: &mut Work, sites: &RefSites, old: &str, new: &str) -> Result<usize, ToolError> {
    let mut n = 0;
    for (fi, lines) in sites {
        let abs = w.g.abs(*fi);
        let d = w.doc(*fi)?;
        let mut missed: Vec<u32> = Vec::new();
        for (line, quals) in lines {
            let mut hit = false;
            for tok in d.line_tokens(*line as usize, old) {
                if quals.iter().any(|q| qualifier_ok(&d.masked, tok, q.as_deref())) {
                    hit = true;
                    n += d.replace_token(tok, old.len(), new) as usize;
                }
            }
            if !hit {
                missed.push(*line);
            }
        }
        if !missed.is_empty() {
            let lines: Vec<String> = missed.iter().map(|l| format!("L{l}")).collect();
            w.warnings.push(format!("{}: could not locate `{old}` at {} (a reference the index recorded on that line); check by hand", abs.display(), lines.join(", ")));
        }
    }
    Ok(n)
}

/// Rewrite the imported name `old` (never a module or an alias) in the given import statements.
pub(super) fn rewrite_imports(w: &mut Work, sites: &BTreeMap<u32, BTreeSet<usize>>, old: &str, new: &str) -> Result<usize, ToolError> {
    let mut n = 0;
    for (fi, iis) in sites {
        let imports = w.g.file(*fi).facts.imports.clone();
        let d = w.doc(*fi)?;
        for ii in iis {
            let (a, b) = d.extent(imports[*ii].line as usize);
            let (s, e) = d.lines_bytes(a, b);
            for tok in d.tokens_in(s, e, old) {
                if import_token_ok(d, tok, s, e, old.len()) {
                    n += d.replace_token(tok, old.len(), new) as usize;
                }
            }
        }
    }
    Ok(n)
}

/// Occurrences of the old name in the files involved that no recorded site covered: another
/// definition with the same name, or a reference the extractor does not see (a template
/// literal, a macro). Reported, never rewritten.
pub(super) fn warn_left_alone(w: &mut Work, old: &str) {
    let mut left: Vec<String> = Vec::new();
    for d in w.docs.values() {
        if !d.edits.is_empty() {
            for tok in d.tokens_in(0, d.masked.len(), old) {
                if !d.edits.touches(tok, tok + old.len()) {
                    left.push(format!("{}:L{}", d.path.display(), d.src.line_of(tok)));
                }
            }
        }
    }
    if !left.is_empty() {
        let n = left.len();
        left.truncate(12);
        w.warnings.push(format!("{n} other occurrence(s) of `{old}` in the files involved were left alone (not resolved to this symbol): {}{}", left.join(", "), if n > 12 { ", …" } else { "" }));
    }
}
