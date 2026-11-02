//! `move` (a definition to another file) and `rename_file` (a file to another path): the two
//! mutators that change what *module* code lives in, so importers have to follow.
//!
//! Supported where the index resolves imports precisely: Elm (module names, `exposing` lists,
//! qualified references), TypeScript/JavaScript (relative specifiers) and Rust (`mod`
//! declarations and `use`/qualified paths inside one crate). A language without that gets a
//! refusal naming the gap rather than a move that leaves its importers broken.

use super::doc::{list_items, remove_item, Doc};
use super::rename::{elm_header, qualifier_ok};
use super::{leading_trivia, select, whole_lines, MutCtx, Plan, Work};
use crate::edit;
use crate::facts::{Import, ImportKind, SymbolKind};
use crate::graph::{SymId, ViewGraph};
use crate::resolve::Resolved;
use crate::tools::args::resolve_path;
use crate::tools::ToolError;
use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

pub(super) fn is_ts(lang: &str) -> bool {
    matches!(lang, "typescript" | "tsx" | "javascript")
}

fn refuse_language(tool: &str, lang: &str) -> ToolError {
    ToolError::failed(format!(
        "{tool} is not supported for {lang} files yet: the index cannot rewrite {lang} imports precisely, and a move that leaves importers pointing at the old place breaks the build. Nothing was changed. (rename works for {lang} by reference sites.)"
    ))
}

// ---- Elm module header ------------------------------------------------------------------------

/// The `exposing ( … )` list of an Elm module header: its entries and the byte offset of `(`.
fn header_list(d: &Doc) -> Option<(Vec<super::doc::Item>, usize)> {
    let (hs, he) = elm_header(d)?;
    let ex = d.masked[hs..he].find("exposing")? + hs;
    let open = d.masked[ex..he].find('(')? + ex;
    let (items, _) = list_items(&d.src.text, &d.masked, open)?;
    Some((items, open))
}

/// Take `name` out of the module's `exposing` list. A module that exposes a name it no longer
/// defines does not compile. A `(..)` list needs no change.
pub fn remove_from_module_exposing(d: &mut Doc, name: &str) -> Option<String> {
    let (items, _) = header_list(d)?;
    let idx = items.iter().position(|i| i.base == name)?;
    let text = d.src.text[items[idx].start..items[idx].end].to_string();
    remove_item(&mut d.edits, &items, idx);
    Some(text)
}

/// The text the module header uses for `name`, if it lists it (`Msg(..)`, `view`).
pub(super) fn module_exposing_item(d: &Doc, name: &str) -> Option<String> {
    let (items, _) = header_list(d)?;
    items.iter().find(|i| i.base == name).map(|i| d.src.text[i.start..i.end].to_string())
}

fn add_to_module_exposing(d: &mut Doc, item: &str) {
    let Some((items, _)) = header_list(d) else { return };
    if items.iter().any(|i| i.base == ".." || i.base.is_empty() && d.src.text[i.start..i.end].contains("..")) || items.iter().any(|i| i.base == item.split('(').next().unwrap_or(item).trim()) {
        return;
    }
    let Some(last) = items.last() else { return };
    // Follow the list's own layout: `, x` on one line, or a newline and a leading comma.
    let sep = if items.len() >= 2 { d.src.text[items[items.len() - 2].end..last.start].to_string() } else { ", ".to_string() };
    d.edits.insert(last.end, format!("{sep}{item}"));
}

// ---- Elm module names -------------------------------------------------------------------------

/// The `source-directories` of the `elm.json` nearest above `file`.
fn elm_roots(file: &Path) -> Option<Vec<PathBuf>> {
    let mut dir = file.parent();
    while let Some(d) = dir {
        let manifest = d.join("elm.json");
        if let Ok(text) = std::fs::read_to_string(&manifest) {
            let json: serde_json::Value = serde_json::from_str(&text).ok()?;
            let dirs: Vec<String> = match json.get("source-directories").and_then(|v| v.as_array()) {
                Some(a) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
                None => vec!["src".to_string()],
            };
            return Some(dirs.iter().map(|s| resolve_path(d, s)).collect());
        }
        dir = d.parent();
    }
    None
}

fn elm_manifest(file: &Path) -> Option<PathBuf> {
    file.ancestors().skip(1).map(|d| d.join("elm.json")).find(|m| m.is_file())
}

/// The module a file at `to` declares, from the source directory that holds it. With no
/// `elm.json`, the directory is the old file's own root (its path minus its module path).
pub(super) fn elm_module_at(old_file: &Path, old_module: &str, to: &Path) -> Result<String, ToolError> {
    let roots = elm_roots(old_file).unwrap_or_else(|| {
        let suffix = format!("{}.elm", old_module.replace('.', "/"));
        let s = old_file.to_string_lossy();
        s.strip_suffix(&suffix).map(|r| vec![PathBuf::from(r.trim_end_matches('/'))]).unwrap_or_default()
    });
    let root = roots.iter().filter(|r| to.starts_with(r)).max_by_key(|r| r.as_os_str().len()).ok_or_else(|| {
        ToolError::failed(format!("{} is not inside an Elm source directory ({}), so no module name can be derived for it", to.display(), roots.iter().map(|r| r.display().to_string()).collect::<Vec<_>>().join(", ")))
    })?;
    let rel = to.strip_prefix(root).unwrap_or(to).with_extension("");
    let parts: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
    if parts.is_empty() || !parts.iter().all(|p| p.chars().next().is_some_and(|c| c.is_ascii_uppercase()) && p.chars().all(|c| c.is_alphanumeric() || c == '_')) {
        return Err(ToolError::failed(format!("{} cannot be an Elm module: each directory and the file name must start with an uppercase letter and use letters, digits or _", to.display())));
    }
    Ok(parts.join("."))
}

// ---- path helpers -----------------------------------------------------------------------------

fn relative_path(from_dir: &Path, to: &Path) -> String {
    let a: Vec<_> = from_dir.components().collect();
    let b: Vec<_> = to.components().collect();
    let common = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut parts: Vec<String> = vec!["..".to_string(); a.len() - common];
    parts.extend(b[common..].iter().map(|c| c.as_os_str().to_string_lossy().to_string()));
    parts.join("/")
}

const TS_EXTS: &[&str] = &["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"];

/// How a file imported as `old_spec` is spelled once it lives at `to`, seen from `importer_dir`:
/// the extension is kept only if the old specifier had one, and `.js` stays `.js` for a `.ts` file.
pub(super) fn new_specifier(old_spec: &str, importer_dir: &Path, to: &Path) -> String {
    let mut rel = relative_path(importer_dir, to);
    let old_ext = old_spec.rsplit_once('.').map(|(_, e)| e).filter(|e| TS_EXTS.contains(e) && old_spec.contains('/'));
    let to_ext = to.extension().and_then(|e| e.to_str()).unwrap_or("");
    let stem = rel.strip_suffix(&format!(".{to_ext}")).unwrap_or(&rel).to_string();
    let index_style = Path::new(&stem).file_name().is_some_and(|n| n == "index") && !old_spec.ends_with("index") && !old_spec.contains("index.");
    rel = if index_style { stem.trim_end_matches("index").trim_end_matches('/').to_string() } else { stem };
    if rel.is_empty() {
        rel = ".".into();
    }
    if let Some(e) = old_ext {
        let keep = match (e, to_ext) {
            ("js", "ts") | ("jsx", "tsx") | ("mjs", "mts") | ("cjs", "cts") => e,
            _ => to_ext,
        };
        rel = format!("{rel}.{keep}");
    }
    if !rel.starts_with('.') {
        rel = format!("./{rel}");
    }
    rel
}

fn lexical(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            o => out.push(o),
        }
    }
    out
}

/// Replace the string literal `old` inside the statement byte range `[s, e)` with `new`.
pub(super) fn replace_literal(d: &mut Doc, s: usize, e: usize, old: &str, new: &str) -> bool {
    let raw = d.src.text[s..e].to_string();
    for q in ['\'', '"', '`'] {
        let needle = format!("{q}{old}{q}");
        if let Some(i) = raw.find(&needle) {
            let at = s + i + 1;
            if !d.edits.touches(at, at + old.len()) {
                d.edits.replace(at, at + old.len(), new);
            }
            return true;
        }
    }
    false
}

// ---- rename_file ------------------------------------------------------------------------------

pub fn rename_file(c: &MutCtx) -> Result<Plan, ToolError> {
    let g = c.graph;
    let from = c.args.path(&["from", "old_path", "file_path"]).ok_or_else(|| ToolError::bad("from is required"))?;
    let to = c.args.path(&["to", "new_path", "to_file"]).ok_or_else(|| ToolError::bad("to is required"))?;
    let fi = g.file_idx(&from).ok_or_else(|| ToolError::failed(format!("{} is not an indexed source file of view {}", from.display(), g.label.worktree.display())))?;
    let lang = g.file(fi).language;
    if !(lang == "elm" || lang == "rust" || is_ts(lang)) {
        return Err(refuse_language("rename_file", lang));
    }
    if to.exists() {
        return Err(ToolError::failed(format!("{} already exists; nothing was changed", to.display())));
    }
    edit::check_within(&g.root, &to).map_err(ToolError::failed)?;
    if to.extension() != from.extension() {
        return Err(ToolError::bad(format!("to must keep the extension of from ({})", from.extension().and_then(|e| e.to_str()).unwrap_or(""))));
    }
    if lang == "rust" {
        let name = |p: &Path| p.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
        if matches!(name(&from).as_str(), "mod.rs" | "lib.rs" | "main.rs") || matches!(name(&to).as_str(), "mod.rs" | "lib.rs" | "main.rs") {
            return Err(ToolError::failed("rename_file refuses mod.rs, lib.rs and main.rs: they are named by their directory or the crate, not by a `mod` line, so renaming one changes the module tree rather than a name. Nothing was changed."));
        }
        if from.parent() != to.parent() {
            return Err(ToolError::failed("rename_file for Rust renames a file within its directory; moving it to another directory also moves its `mod` declaration to a different parent module (use move for items). Nothing was changed."));
        }
        let child_dir = from.with_extension("");
        if child_dir.is_dir() {
            return Err(ToolError::failed(format!("{} has child modules in {}, which must move with it; rename the directory by hand or move the children first. Nothing was changed.", from.display(), child_dir.display())));
        }
    }

    let mut w = Work::new(g);
    w.doc(fi)?; // loaded (and checked against the index) even when the file itself needs no edit
    let from_rel = g.file(fi).path.clone();
    let mut sites = 0usize;
    match lang {
        "elm" => rename_file_elm(&mut w, fi, &from, &to, &mut sites)?,
        "rust" => rename_file_rust(&mut w, fi, &from, &to, &mut sites)?,
        _ => rename_file_ts(&mut w, fi, &from, &to, &mut sites)?,
    }

    // The file's content moves to the new path (with the edits made to it), and the old path goes.
    let old = w.docs.get_mut(&from).expect("the file was loaded");
    let text = old.edits.apply(&old.src.text).map_err(ToolError::failed)?;
    let mode = std::fs::metadata(&from).ok().map(|m| {
        use std::os::unix::fs::PermissionsExt;
        m.permissions().mode()
    });
    old.edits = edit::Edits::default();
    old.deleted = true;
    let mut moved = Doc::new(to.clone(), lang_static(lang), None, text);
    moved.mode = mode;
    w.docs.insert(to.clone(), moved);
    w.notes.push(format!("{sites} importer site(s) rewritten"));
    w.finish(format!("rename_file {} -> {}", from.display(), to.display())).map(|mut p| {
        p.notes.insert(0, format!("moves {from_rel} to {}", to.strip_prefix(&g.root).unwrap_or(&to).display()));
        p
    })
}

fn lang_static(lang: &str) -> &'static str {
    crate::lang::by_id(lang).map(|l| l.id()).unwrap_or("rust")
}

fn rename_file_elm(w: &mut Work, fi: u32, from: &Path, to: &Path, sites: &mut usize) -> Result<(), ToolError> {
    let g = w.g;
    let old_module = g.file(fi).facts.module_name.clone().ok_or_else(|| ToolError::failed(format!("{} has no `module` declaration", from.display())))?;
    let new_module = elm_module_at(from, &old_module, to)?;
    if new_module == old_module {
        return Err(ToolError::failed(format!("{} already declares module {old_module}", from.display())));
    }
    {
        let d = w.doc(fi)?;
        let (hs, he) = elm_header(d).ok_or_else(|| ToolError::failed("could not find the module declaration"))?;
        let at = d.dotted_tokens(&old_module).into_iter().find(|&t| t >= hs && t < he);
        match at {
            Some(t) => {
                d.replace_token(t, old_module.len(), &new_module);
            }
            None => return Err(ToolError::failed(format!("could not find `{old_module}` in the module declaration"))),
        }
    }
    for gi in 0..g.files.len() as u32 {
        if gi == fi || !g.file(gi).alive {
            continue;
        }
        let imports = g.file(gi).facts.imports.clone();
        let mut plain = false;
        let mut rewrites: Vec<usize> = Vec::new();
        for (ii, imp) in imports.iter().enumerate() {
            if matches!(&g.res[gi as usize].imports[ii], Resolved::File { path, .. } if *path == g.file(fi).path) {
                rewrites.push(ii);
                plain |= imp.alias.is_none();
            }
        }
        if rewrites.is_empty() {
            continue;
        }
        let d = w.doc(gi)?;
        *sites += rewrite_elm_importer(d, &imports, &rewrites, plain, &old_module, &new_module);
    }
    if let Some(manifest) = elm_manifest(from).filter(|m| edit::check_within(&g.root, m).is_ok()) {
        let d = w.doc_at(&manifest, "json")?;
        let needle = format!("\"{old_module}\"");
        let hits: Vec<usize> = d.src.text.match_indices(&needle).map(|(i, _)| i).collect();
        for i in hits {
            d.edits.replace(i, i + needle.len(), format!("\"{new_module}\""));
            *sites += 1;
        }
    }
    w.notes.push(format!("module {old_module} becomes {new_module}"));
    Ok(())
}

fn rename_file_ts(w: &mut Work, fi: u32, from: &Path, to: &Path, sites: &mut usize) -> Result<(), ToolError> {
    let g = w.g;
    let from_rel = g.file(fi).path.clone();
    let to_dir = to.parent().unwrap_or(Path::new("/")).to_path_buf();
    for gi in 0..g.files.len() as u32 {
        let node = g.file(gi);
        if !node.alive {
            continue;
        }
        let imports = node.facts.imports.clone();
        for (ii, imp) in imports.iter().enumerate() {
            let target = match &g.res[gi as usize].imports[ii] {
                Resolved::File { path, .. } => path.clone(),
                _ => continue,
            };
            let importer_dir = if gi == fi { to_dir.clone() } else { g.abs(gi).parent().unwrap_or(Path::new("/")).to_path_buf() };
            let new_spec = if target == from_rel {
                if gi == fi {
                    continue;
                }
                new_specifier(&imp.specifier, &importer_dir, to)
            } else if gi == fi && !to_dir.eq(from.parent().unwrap_or(Path::new("/"))) && imp.specifier.starts_with('.') {
                // The moved file's own relative imports must still reach their targets.
                new_specifier(&imp.specifier, &importer_dir, &g.root.join(&target))
            } else {
                continue;
            };
            if new_spec == imp.specifier {
                continue;
            }
            let d = w.doc(gi)?;
            let (a, b) = d.extent(imp.line as usize);
            let (s, e) = d.lines_bytes(a, b);
            if replace_literal(d, s, e, &imp.specifier, &new_spec) {
                *sites += 1;
            } else {
                w.warnings.push(format!("{}:L{}: could not find the specifier '{}' to rewrite", g.abs(gi).display(), imp.line, imp.specifier));
            }
        }
    }
    Ok(())
}

/// Rust path segments of a `use` statement before any `{` or `as`: `(segment, byte range)`.
fn use_segments(d: &Doc, s: usize, e: usize) -> Vec<(String, usize, usize)> {
    let text = &d.masked[s..e];
    let start = text.find("use ").map(|i| i + 4).unwrap_or(0);
    let end = text[start..].find(['{', ';']).map(|i| start + i).unwrap_or(text.len());
    let path = &text[start..end];
    let path = path.split(" as ").next().unwrap_or(path);
    let mut out = Vec::new();
    let mut at = start;
    for seg in path.split("::") {
        let lead = seg.len() - seg.trim_start().len();
        let name = seg.trim();
        if !name.is_empty() {
            out.push((name.to_string(), s + at + lead, s + at + lead + name.len()));
        }
        at += seg.len() + 2;
    }
    out
}

fn rename_file_rust(w: &mut Work, fi: u32, from: &Path, to: &Path, sites: &mut usize) -> Result<(), ToolError> {
    let g = w.g;
    let old_stem = from.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    let new_stem = to.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    let from_rel = g.file(fi).path.clone();
    let resolver = g.resolver();
    let is_target = |gi: u32, segs: &[String]| matches!(resolver.rust_path(&g.file(gi).path, segs), Resolved::File { path, rest } if path == from_rel && rest.is_empty());
    let mut found_decl = false;
    for gi in 0..g.files.len() as u32 {
        let node = g.file(gi);
        if !node.alive {
            continue;
        }
        let imports = node.facts.imports.clone();
        let refs = node.facts.refs.clone();
        let mut binds_local = false;
        let mut edits_here: Vec<(usize, usize)> = Vec::new(); // (byte start, len) of segments to rename
        let mut doc_needed = false;
        // Pass 1: find what to rewrite without borrowing the doc mutably.
        let probe = {
            let d = w.doc(gi)?;
            let mut v: Vec<(usize, usize)> = Vec::new();
            for imp in &imports {
                let (a, b) = d.extent(imp.line as usize);
                let (s, e) = d.lines_bytes(a, b);
                if imp.kind == ImportKind::ModDecl {
                    if imp.specifier == old_stem
                        && matches!(resolver.rust_path(&node.path, &["self".into(), old_stem.clone()]), Resolved::File { path, .. } if path == from_rel)
                        && let Some(t) = d.tokens_in(s, e, &old_stem).first()
                    {
                        v.push((*t, old_stem.len()));
                        found_decl = true;
                    }
                    continue;
                }
                let segs = use_segments(d, s, e);
                let names: Vec<String> = segs.iter().map(|x| x.0.clone()).collect();
                for (k, (name, ss, se)) in segs.iter().enumerate() {
                    if *name == old_stem && is_target(gi, &names[..=k]) {
                        v.push((*ss, se - ss));
                        if k + 1 == segs.len() && !d.masked[*se..e].contains(" as ") {
                            binds_local = true;
                        }
                    }
                }
                // `use crate::{a, old}` / `use super::{old}`: the module named as a list entry.
                if let Some(open) = d.masked[s..e].find('{').map(|i| s + i)
                    && let Some((items, _)) = list_items(&d.src.text, &d.masked, open)
                {
                    for it in items.iter().filter(|it| it.base == old_stem) {
                        let mut full = names.clone();
                        full.push(it.base.clone());
                        if is_target(gi, &full) {
                            v.push((it.start, old_stem.len()));
                            if !d.src.text[it.start..it.end].contains(" as ") {
                                binds_local = true;
                            }
                        }
                    }
                }
            }
            for r in &refs {
                let Some(q) = g.qualifier(r) else { continue };
                let segs: Vec<String> = q.split("::").map(String::from).collect();
                for (k, seg) in segs.iter().enumerate() {
                    if *seg != old_stem || !(is_target(gi, &segs[..=k]) || (k == 0 && binds_local)) {
                        continue;
                    }
                    for tok in d.line_tokens(r.line as usize, g.name(r.name)) {
                        if qualifier_ok(&d.masked, tok, Some(q)) {
                            let q_start = tok - q.len() - 2;
                            let off: usize = segs[..k].iter().map(|s| s.len() + 2).sum();
                            if &d.masked[q_start..tok - 2] == q {
                                v.push((q_start + off, old_stem.len()));
                            }
                        }
                    }
                }
            }
            v
        };
        for (at, len) in probe {
            if !edits_here.contains(&(at, len)) {
                edits_here.push((at, len));
                doc_needed = true;
            }
        }
        if doc_needed {
            let d = w.doc(gi)?;
            for (at, len) in edits_here {
                *sites += d.replace_token(at, len, &new_stem) as usize;
            }
        }
    }
    if !found_decl {
        w.warnings.push(format!("no `mod {old_stem};` declaration of {} was found; add `mod {new_stem};` where the module belongs", from.display()));
    }
    Ok(())
}

// ---- move -------------------------------------------------------------------------------------

/// An import statement to add to a file.
pub(super) struct NewImport {
    pub(super) text: String,
}

fn lang_of_path(to: &Path) -> Option<&'static str> {
    crate::lang::for_path(to).map(|l| l.id())
}

fn same_family(a: &str, b: &str) -> bool {
    a == b || (is_ts(a) && is_ts(b))
}

/// `crate::a::b` for the module of `file`, if it is in the same crate as `from_file`.
fn rust_module_path(g: &ViewGraph, file_rel: &str, from_rel: &str) -> Option<String> {
    let r = g.resolver();
    let (root_a, segs) = r.rust_crate_of(file_rel)?;
    let (root_b, _) = r.rust_crate_of(from_rel)?;
    (root_a == root_b).then(|| std::iter::once("crate".to_string()).chain(segs).collect::<Vec<_>>().join("::"))
}

pub fn move_symbol(c: &MutCtx) -> Result<Plan, ToolError> {
    let g = c.graph;
    let t = select(c, super::SYMBOL)?;
    let to = c.args.path(&["to_file", "to", "destination"]).ok_or_else(|| ToolError::bad("to_file is required"))?;
    let sf = t.id.file;
    let lang = g.file(sf).language;
    if !(lang == "elm" || lang == "rust" || is_ts(lang)) {
        return Err(refuse_language("move", lang));
    }
    let from_path = g.abs(sf);
    if to == from_path {
        return Err(ToolError::bad("to_file is the file the symbol is already in"));
    }
    edit::check_within(&g.root, &to).map_err(ToolError::failed)?;
    let sym = g.symbol(t.id).clone();
    if sym.parent.is_some() || matches!(t.kind, SymbolKind::Impl | SymbolKind::Field | SymbolKind::Module | SymbolKind::Method) {
        return Err(ToolError::failed(format!("only top-level definitions can be moved; {} is a {} inside another definition. Nothing was changed.", t.name, t.kind.as_str())));
    }
    let to_lang = lang_of_path(&to).ok_or_else(|| ToolError::failed(format!("{} is not a file type the index handles", to.display())))?;
    if !same_family(lang, to_lang) {
        return Err(ToolError::failed(format!("cannot move a {lang} definition into a {to_lang} file")));
    }
    let ti = g.file_idx(&to);
    if to.exists() && ti.is_none() {
        return Err(ToolError::failed(format!("{} exists but is not an indexed source file of this view (ignored, too large or unsupported)", to.display())));
    }
    if let Some(ti) = ti
        && g.file(ti).facts.symbols.iter().any(|s| s.parent.is_none() && s.name == t.name && s.kind != SymbolKind::Impl)
    {
        return Err(ToolError::failed(format!("{} already defines `{}`; nothing was changed", to.display(), t.name)));
    }

    let sfile = g.file(sf);
    let inside = |local: u32| {
        let mut cur = Some(local);
        while let Some(c) = cur {
            if c == t.id.local {
                return true;
            }
            cur = sfile.symbol(c).parent;
        }
        false
    };
    let moved: Vec<u32> = sfile.facts.symbols.iter().filter(|s| inside(s.local_id)).map(|s| s.local_id).collect();
    let in_block = |line: u32| line >= t.start_line && line <= t.end_line;

    let mut w = Work::new(g);
    let (block, first_line, last_line) = {
        let d = w.doc(sf)?;
        if !whole_lines(d, &t, sym.start_col, sym.end_col) {
            return Err(ToolError::failed(format!("{} shares its lines with other code; move cannot cut it out by line. Nothing was changed.", t.name)));
        }
        let first = leading_trivia(d, t.start_line as usize);
        let (a, b) = d.lines_bytes(first, t.end_line as usize);
        let mut text = d.src.text[a..b].to_string();
        // Visibility the destination needs: the move changes who can see it.
        if !sym.exported && lang != "elm" {
            let first_code = t.start_line as usize - first;
            let mut lines: Vec<String> = text.split_inclusive('\n').map(String::from).collect();
            if let Some(l) = lines.get_mut(first_code) {
                let prefix = if lang == "rust" { "pub(crate) " } else { "export " };
                let ws = l.len() - l.trim_start().len();
                l.insert_str(ws, prefix);
            }
            text = lines.concat();
        }
        (text, first, t.end_line as usize)
    };

    // What the moved code needs imported at its new home, and who among its neighbours it uses.
    let mut needed: BTreeSet<usize> = BTreeSet::new();
    let mut siblings: Vec<String> = Vec::new();
    let mut sibling_items: Vec<String> = Vec::new();
    let mut used_names: HashSet<String> = HashSet::new();
    for (ri, r) in sfile.facts.refs.iter().enumerate() {
        if !(in_block(r.line) || r.enclosing().is_some_and(&inside)) {
            continue;
        }
        let res = &g.res[sf as usize].refs[ri];
        if res.target.is_some_and(|tid| tid.file == sf && inside(tid.local)) {
            continue;
        }
        used_names.insert(g.name(r.name).to_string());
        if let Some(q) = g.qualifier(r) {
            used_names.insert(q.split(['.', ':']).next().unwrap_or(q).to_string());
        }
        if let Some(tid) = res.target
            && tid.file == sf
        {
            let sib = g.symbol(tid);
            siblings.push(sib.name.clone());
            // What Elm's `exposing` calls it: a constructor travels with its type.
            sibling_items.push(match (sib.kind, sib.parent) {
                (SymbolKind::Constructor, Some(p)) => format!("{}(..)", sfile.symbol(p).name),
                _ => sib.name.clone(),
            });
            continue;
        }
        let binding = sfile.facts.imports.iter().enumerate().find(|(ii, imp)| {
            let local = |n: &str| imp.names.iter().any(|x| x.local() == n && x.name != "*");
            match g.qualifier(r) {
                Some(q) => {
                    let first = q.split(['.', ':']).next().unwrap_or(q);
                    let whole_alias = imp.alias.as_deref() == Some(q) || (imp.alias.is_none() && imp.specifier == q);
                    whole_alias || imp.alias.as_deref() == Some(first) || local(first) || (lang == "rust" && imp.specifier.rsplit("::").next() == Some(first))
                }
                None => {
                    local(g.name(r.name))
                        || (imp.names.iter().any(|x| x.name == "*") && res.target.is_some_and(|tid| matches!(&g.res[sf as usize].imports[*ii], Resolved::File { path, .. } if *path == g.file(tid.file).path)))
                }
            }
        });
        if let Some((ii, _)) = binding {
            needed.insert(ii);
        }
    }
    siblings.sort();
    siblings.dedup();
    sibling_items.sort();
    sibling_items.dedup();

    // Uses of the moved code from what stays behind.
    let uses_after = moved.iter().any(|&l| {
        g.incoming.get(&SymId { file: sf, local: l }).unwrap_or(&[]).iter().any(|&(fi, ri)| {
            let r = &g.file(fi).facts.refs[ri as usize];
            fi == sf && !(in_block(r.line) || r.enclosing().is_some_and(&inside))
        })
    });
    if !siblings.is_empty() {
        if lang == "elm" && uses_after {
            return Err(ToolError::failed(format!(
                "refusing: {} uses {} from {} and {} still uses {} back, so moving it would make the two Elm modules import each other (Elm rejects import cycles). Move {} along with it, or move {} first. Nothing was changed.",
                t.name, siblings.join(", "), t.path.display(), t.path.display(), t.name, siblings.join(", "), t.name
            )));
        }
        let private: Vec<&String> = siblings.iter().filter(|n| sfile.facts.symbols.iter().any(|s| &s.name == *n && s.parent.is_none() && !s.exported)).collect();
        if lang != "elm" && !private.is_empty() {
            return Err(ToolError::failed(format!(
                "refusing: {} uses {} from {}, which {} not exported, so the new file could not import {}. Export them (or move them too) first. Nothing was changed.",
                t.name, private.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "), t.path.display(), if private.len() == 1 { "is" } else { "are" }, if private.len() == 1 { "it" } else { "them" }
            )));
        }
    }

    // ---- destination text ----
    let s_dir = from_path.parent().unwrap_or(Path::new("/")).to_path_buf();
    let to_dir = to.parent().unwrap_or(Path::new("/")).to_path_buf();
    let to_rel = to.strip_prefix(&g.root).map(|p| p.to_string_lossy().replace('\\', "/")).unwrap_or_default();
    let elm_names = if lang == "elm" {
        let old_module = sfile.facts.module_name.clone().ok_or_else(|| ToolError::failed("the source file has no `module` declaration"))?;
        let new_module = match ti {
            Some(ti) => g.file(ti).facts.module_name.clone().ok_or_else(|| ToolError::failed("the destination file has no `module` declaration"))?,
            None => elm_module_at(&from_path, &old_module, &to)?,
        };
        Some((old_module, new_module))
    } else {
        None
    };
    // Rust: the path others use to reach the destination, and the `mod` line a new file needs.
    let rust_to_path = if lang == "rust" {
        let p = rust_module_path(g, &to_rel, &sfile.path);
        // A file that does not exist yet has no entry in the resolver, so derive it from its place in the tree.
        match (p, ti) {
            (Some(p), _) => Some(p),
            (None, None) => derive_new_rust_module_path(g, &to, &sfile.path),
            _ => None,
        }
    } else {
        None
    };
    if lang == "rust" && rust_to_path.is_none() {
        return Err(ToolError::failed(format!("{} is not in the same crate as {}, or is not reachable from its module tree, so `use` paths to it cannot be written. Nothing was changed.", to.display(), from_path.display())));
    }

    // Statements the destination needs, copied from the source's imports.
    let mut dest_imports: Vec<String> = Vec::new();
    for &ii in &needed {
        let imp = &sfile.facts.imports[ii];
        if let Some(text) = import_for_destination(w.doc(sf)?, g, imp, &used_names, lang, &s_dir, &to_dir, &sfile.path)
            && !dest_imports.contains(&text)
        {
            dest_imports.push(text);
        }
    }
    // The moved code's own neighbours, when they are exported: import them from the old module.
    if !siblings.is_empty() {
        let text = match lang {
            "elm" => {
                let (old_module, _) = elm_names.as_ref().expect("elm");
                format!("import {old_module} exposing ({})", sibling_items.join(", "))
            }
            "rust" => format!("use {}::{{{}}};", rust_module_path(g, &sfile.path, &sfile.path).unwrap_or_else(|| "crate".into()), siblings.join(", ")),
            _ => format!("import {{ {} }} from '{}';", siblings.join(", "), new_specifier("./x", &to_dir, &from_path)),
        };
        dest_imports.push(text);
    }

    // The item the destination exposes (Elm) and the importers add.
    let elm_item = if lang == "elm" {
        let d = w.doc(sf)?;
        let listed = module_exposing_item(d, &t.name);
        Some(listed.unwrap_or_else(|| if t.kind == SymbolKind::Enum { format!("{}(..)", t.name) } else { t.name.clone() }))
    } else {
        None
    };

    // ---- edit the destination ----
    let mut block_text = block.clone();
    let nl_style = w.doc(sf)?.nl();
    if nl_style == "\r\n" {
        block_text = block_text.replace("\r\n", "\n").replace('\n', "\r\n");
    }
    let block_trim = block_text.trim_end_matches(['\n', '\r']).to_string();
    match ti {
        Some(ti) => {
            let d = w.doc(ti)?;
            let existing: Vec<String> = d.src.text.lines().map(|l| l.trim().to_string()).collect();
            let fresh: Vec<&String> = dest_imports.iter().filter(|s| !existing.contains(&s.trim().to_string())).collect();
            let timports = g.file(ti).facts.imports.clone();
            if !fresh.is_empty() && timports.is_empty() {
                // No imports yet: they go together, with a blank line between them and what follows.
                let at = top_insert_line(d);
                let body = fresh.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("\n");
                let text = if d.src.line(at).trim().is_empty() { body } else { format!("{body}\n") };
                d.insert_lines_before(at, &text);
            } else {
                for stmt in fresh {
                    let at = import_line(d, &timports, stmt);
                    d.insert_lines_before(at, stmt);
                }
            }
            let gap = if lang == "elm" { "\n\n" } else { "\n" };
            let end = d.src.line_count() + 1;
            d.insert_lines_before(end, &format!("{gap}{block_trim}"));
            if let Some(item) = &elm_item {
                add_to_module_exposing(d, item);
            }
        }
        None => {
            if lang == "elm" {
                dest_imports.sort();
            }
            let body = dest_imports.join("\n");
            let mut text = String::new();
            if let Some((_, new_module)) = &elm_names {
                text.push_str(&format!("module {new_module} exposing ({})\n\n", elm_item.as_deref().unwrap_or("..")));
            }
            if !body.is_empty() {
                text.push_str(&body);
                text.push_str(if lang == "elm" { "\n\n\n" } else { "\n\n" });
            }
            text.push_str(&block_trim);
            text.push('\n');
            let mut nd = Doc::new(to.clone(), lang_static(to_lang), None, text);
            nd.mode = std::fs::metadata(&from_path).ok().map(|m| {
                use std::os::unix::fs::PermissionsExt;
                m.permissions().mode()
            });
            w.docs.insert(to.clone(), nd);
            if lang == "rust" {
                register_rust_module(&mut w, &to)?;
            }
        }
    }

    // ---- edit the source: cut the block, fix its header, import it back if it is still used ----
    {
        let d = w.doc(sf)?;
        let (mut a, mut b) = (first_line, last_line);
        let blank = |d: &Doc, l: usize| l >= 1 && l <= d.src.line_count() && d.src.line(l).trim().is_empty();
        if blank(d, a.saturating_sub(1)) && b == d.src.line_count() {
            a -= 1;
        }
        // Trailing blank lines go too when blank lines precede the block, so the neighbours keep
        // the gap they had (Elm puts two between declarations).
        if a == 1 || blank(d, a - 1) {
            while blank(d, b + 1) && b < d.src.line_count() {
                b += 1;
            }
        }
        d.delete_lines(a, b);
        if lang == "elm" {
            remove_from_module_exposing(d, &t.name);
            // The neighbours the moved code reaches back for must be exposed to be imported.
            for item in &sibling_items {
                add_to_module_exposing(d, item);
            }
        }
    }

    // ---- everyone who used it ----
    let mut added: HashSet<(PathBuf, String)> = HashSet::new();
    let mut sites = 0usize;
    let mut by_name_only = 0usize;
    for gi in 0..g.files.len() as u32 {
        let node = g.file(gi);
        if !node.alive {
            continue;
        }
        // References in this file to the moved symbols, outside the moved block.
        let mut uses: Vec<(usize, bool)> = Vec::new(); // (ref index, qualified)
        for &l in &moved {
            for &(fi, ri) in g.incoming.get(&SymId { file: sf, local: l }).unwrap_or(&[]) {
                if fi != gi {
                    continue;
                }
                let r = &node.facts.refs[ri as usize];
                if gi == sf && (in_block(r.line) || r.enclosing().is_some_and(&inside)) {
                    continue;
                }
                if g.res[gi as usize].refs[ri as usize].confidence == crate::graph::Confidence::Fallback {
                    by_name_only += 1;
                }
                uses.push((ri as usize, r.qualifier().is_some()));
            }
        }
        // Import statements of this file that land on the source file and name the symbol.
        let imps: Vec<usize> = node
            .facts
            .imports
            .iter()
            .enumerate()
            .filter(|(ii, imp)| {
                matches!(&g.res[gi as usize].imports[*ii], Resolved::File { path, .. } if *path == sfile.path)
                    && (imp.names.iter().any(|n| n.name == t.name || n.name == "*") || imp.alias.is_some() || imp.kind == ImportKind::Import)
            })
            .map(|(ii, _)| ii)
            .collect();
        if uses.is_empty() && !imps.iter().any(|&ii| node.facts.imports[ii].names.iter().any(|n| n.name == t.name)) {
            continue;
        }
        let is_dest = ti == Some(gi);
        if gi == sf && !uses_after && uses.is_empty() {
            continue;
        }
        let rels = RelocCx { g, t_name: &t.name, lang, sfile_rel: &sfile.path, from_path: &from_path, to: &to, elm: elm_names.as_ref(), elm_item: elm_item.as_deref(), rust_to: rust_to_path.as_deref() };
        let d = w.doc(gi)?;
        let stmts = rewrite_user(d, &rels, gi, &uses, &imps, is_dest, &mut sites)?;
        for s in stmts {
            if added.insert((d.path.clone(), s.text.clone())) {
                let imports = g.file(gi).facts.imports.clone();
                let at = import_line(d, &imports, &s.text);
                d.insert_lines_before(at, &s.text);
            }
        }
    }
    if by_name_only > 0 {
        w.warnings.push(format!("{by_name_only} reference(s) to {} were matched by name only (no import justified them); check that they still resolve", t.name));
    }
    w.notes.push(format!("moves {} ({}) from {} to {}; {sites} importer site(s) rewritten", t.name, t.kind.as_str(), from_path.display(), to.display()));
    if ti.is_none() {
        w.notes.push(format!("creates {}", to.display()));
    }
    w.finish(format!("move {} ({}) to {}", t.name, t.kind.as_str(), to.display()))
}

pub(super) struct RelocCx<'a> {
    pub(super) g: &'a ViewGraph,
    pub(super) t_name: &'a str,
    pub(super) lang: &'a str,
    pub(super) sfile_rel: &'a str,
    pub(super) from_path: &'a Path,
    pub(super) to: &'a Path,
    pub(super) elm: Option<&'a (String, String)>,
    pub(super) elm_item: Option<&'a str>,
    pub(super) rust_to: Option<&'a str>,
}

/// Where a new import statement goes: for Elm in alphabetical place among the imports (elm-format
/// keeps them sorted), elsewhere after the last one.
pub(super) fn import_line(d: &Doc, imports: &[Import], stmt: &str) -> usize {
    if d.elm()
        && let Some(name) = stmt.strip_prefix("import ").and_then(|r| r.split_whitespace().next())
        && let Some(next) = imports.iter().filter(|i| i.specifier.as_str() > name).min_by(|a, b| a.specifier.cmp(&b.specifier))
    {
        return next.line as usize;
    }
    d.after_last_import(imports).unwrap_or_else(|| top_insert_line(d))
}

/// Where a new `mod` line or top-of-file import goes in a file with no imports: below module
/// docs, inner attributes and the Elm header.
fn top_insert_line(d: &Doc) -> usize {
    let total = d.src.line_count();
    if d.elm() {
        let Some((_, he)) = elm_header(d) else { return 1 };
        let mut l = d.src.line_of(he.saturating_sub(1)) + 1;
        while l <= total && d.src.line(l).trim().is_empty() {
            l += 1;
        }
        if l <= total && d.src.line(l).starts_with("{-") {
            let mut end = l;
            while end <= total && !d.src.line(end).contains("-}") {
                end += 1;
            }
            // A doc comment directly above a declaration documents that declaration; only one
            // followed by a blank line or the imports is the module's own.
            let next = d.src.line(end + 1);
            if end >= total || next.trim().is_empty() || next.starts_with("import ") {
                l = end + 1;
            }
        }
        return l.min(total + 1);
    }
    let mut l = 1;
    while l <= total {
        let t = d.src.line(l).trim();
        if t.starts_with("//!") || t.starts_with("#![") || t.starts_with("#!") || t.starts_with("'use strict'") || t.starts_with("\"use strict\"") {
            l += 1;
        } else {
            break;
        }
    }
    l
}

/// The statement a destination needs to get what an import of the source gave the moved code.
#[allow(clippy::too_many_arguments)]
fn import_for_destination(d: &Doc, g: &ViewGraph, imp: &Import, used: &HashSet<String>, lang: &str, s_dir: &Path, to_dir: &Path, from_rel: &str) -> Option<String> {
    let (a, b) = d.extent(imp.line as usize);
    let (s, e) = d.lines_bytes(a, b);
    let raw = d.src.text[s..e].trim_end().to_string();
    match lang {
        "elm" => Some(raw),
        l if is_ts(l) => {
            let keep: Vec<String> = imp.names.iter().filter(|n| n.name != "*" && n.name != "default" && used.contains(n.local())).map(|n| match &n.alias {
                Some(al) => format!("{} as {al}", n.name),
                None => n.name.clone(),
            }).collect();
            let default = imp.names.iter().find(|n| n.name == "default").and_then(|n| n.alias.clone()).filter(|n| used.contains(n));
            let ns = imp.alias.clone().filter(|a| imp.names.iter().any(|n| n.name == "*") && used.contains(a));
            if keep.is_empty() && default.is_none() && ns.is_none() {
                return None;
            }
            let spec = if imp.specifier.starts_with('.') {
                let target = lexical(&s_dir.join(&imp.specifier));
                let rel = relative_path(to_dir, &target);
                if rel.starts_with('.') { rel } else { format!("./{rel}") }
            } else {
                imp.specifier.clone()
            };
            let mut parts: Vec<String> = Vec::new();
            parts.extend(default);
            parts.extend(ns.map(|n| format!("* as {n}")));
            if !keep.is_empty() {
                parts.push(format!("{{ {} }}", keep.join(", ")));
            }
            let ty = if raw.trim_start().starts_with("import type") { " type" } else { "" };
            let semi = if raw.trim_end().ends_with(';') { ";" } else { "" };
            Some(format!("import{ty} {} from '{spec}'{semi}", parts.join(", ")))
        }
        "rust" => {
            // `self::` and `super::` mean something else in a different module: spell the path from the crate.
            let first = imp.specifier.split("::").next().unwrap_or("");
            let vis = if raw.trim_start().starts_with("pub") { "pub " } else { "" };
            let path = if matches!(first, "self" | "super") {
                let segs: Vec<String> = imp.specifier.split("::").map(String::from).collect();
                match g.resolver().rust_path(from_rel, &segs) {
                    Resolved::File { path, rest } => {
                        let base = rust_module_path(g, &path, from_rel)?;
                        std::iter::once(base).chain(rest).collect::<Vec<_>>().join("::")
                    }
                    _ => return None,
                }
            } else {
                imp.specifier.clone()
            };
            let items: Vec<String> = imp.names.iter().filter(|n| n.name == "*" || n.name == "self" || used.contains(n.local())).map(|n| match (&n.alias, n.name.as_str()) {
                (_, "*") => "*".into(),
                (Some(al), name) => format!("{name} as {al}"),
                (None, name) => name.to_string(),
            }).collect();
            match items.len() {
                0 if imp.names.is_empty() => Some(format!("{vis}use {path};")),
                0 => None,
                1 => Some(format!("{vis}use {path}::{};", items[0])),
                _ => Some(format!("{vis}use {path}::{{{}}};", items.join(", "))),
            }
        }
        _ => None,
    }
}

/// For a Rust file that does not exist yet: `crate::` + its directory's module path + its stem,
/// worked out from the parent module's own place in the tree.
fn derive_new_rust_module_path(g: &ViewGraph, to: &Path, source_rel: &str) -> Option<String> {
    let dir = to.parent()?;
    let stem = to.file_stem()?.to_str()?;
    let (parent_rel, _) = rust_parent_module_file(g, dir)?;
    let base = rust_module_path(g, &parent_rel, source_rel)?;
    Some(format!("{base}::{stem}"))
}

/// The file that declares modules for files in `dir`: `dir/mod.rs`, `dir/lib.rs`, `dir/main.rs`,
/// or the sibling `<dir>.rs`.
fn rust_parent_module_file(g: &ViewGraph, dir: &Path) -> Option<(String, u32)> {
    let mut candidates = vec![dir.join("mod.rs"), dir.join("lib.rs"), dir.join("main.rs")];
    if let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) {
        candidates.push(parent.join(format!("{}.rs", name.to_string_lossy())));
    }
    candidates.into_iter().find_map(|c| g.file_idx(&c).map(|i| (g.file(i).path.clone(), i)))
}

fn register_rust_module(w: &mut Work, to: &Path) -> Result<(), ToolError> {
    let g = w.g;
    let dir = to.parent().ok_or_else(|| ToolError::failed("the destination has no directory"))?;
    let stem = to.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let (_, pi) = rust_parent_module_file(g, dir).ok_or_else(|| {
        ToolError::failed(format!("{} is a new module but no parent module file (mod.rs, lib.rs, main.rs or {}.rs) was found in {} to declare it; create the module first. Nothing was changed.", to.display(), dir.file_name().and_then(|n| n.to_str()).unwrap_or(""), dir.display()))
    })?;
    let imports = g.file(pi).facts.imports.clone();
    let d = w.doc(pi)?;
    let at = d.after_last_import(&imports).unwrap_or_else(|| top_insert_line(d));
    d.insert_lines_before(at, &format!("mod {stem};"));
    Ok(())
}

/// The edits one file needs because the symbol left the source. Returns the import statements to
/// add (the caller dedupes and places them).
pub(super) fn rewrite_user(d: &mut Doc, cx: &RelocCx, gi: u32, uses: &[(usize, bool)], imps: &[usize], is_dest: bool, sites: &mut usize) -> Result<Vec<NewImport>, ToolError> {
    let g = cx.g;
    let node = g.file(gi);
    let mut add: Vec<NewImport> = Vec::new();
    let name = cx.t_name;
    // 1. Take the name out of imports of the source file.
    let (removed_item, had_named) = drop_from_imports(d, g, gi, imps, name, cx.lang, sites);

    if is_dest {
        // The destination refers to it locally now: qualified uses lose their qualifier.
        for &(ri, qualified) in uses {
            if !qualified {
                continue;
            }
            let r = &node.facts.refs[ri];
            let q = g.qualifier(r).unwrap_or("");
            for tok in d.line_tokens(r.line as usize, g.name(r.name)) {
                if qualifier_ok(&d.masked, tok, Some(q)) {
                    let sep = if cx.lang == "rust" { 2 } else { 1 };
                    let start = tok - q.len() - sep;
                    if !d.edits.touches(start, tok) {
                        d.edits.replace(start, tok, "");
                        *sites += 1;
                    }
                }
            }
        }
        return Ok(add);
    }

    // 2. Point qualified uses at the new home, and add what the file needs to import.
    let unqualified = uses.iter().any(|&(_, q)| !q);
    match cx.lang {
        "elm" => {
            let (_, new_module) = cx.elm.expect("elm names");
            let existing = node.facts.imports.iter().find(|i| i.specifier == *new_module);
            let qn = existing.and_then(|i| i.alias.clone()).unwrap_or_else(|| new_module.clone());
            let mut need_plain = false;
            for &(ri, qualified) in uses {
                if !qualified {
                    continue;
                }
                let r = &node.facts.refs[ri];
                let q = g.qualifier(r).unwrap_or("");
                for tok in d.line_tokens(r.line as usize, g.name(r.name)) {
                    if qualifier_ok(&d.masked, tok, Some(q)) && tok > q.len() {
                        let start = tok - q.len() - 1;
                        if d.masked[start..tok - 1] == *q && !d.edits.touches(start, tok) {
                            d.edits.replace(start, tok - 1, qn.clone());
                            *sites += 1;
                            need_plain = true;
                        }
                    }
                }
            }
            if unqualified || (need_plain && existing.is_none()) || (removed_item.is_some() && had_named) {
                let item = removed_item.clone().or_else(|| unqualified.then(|| cx.elm_item.unwrap_or(name).to_string()));
                // A file that already imports the module only needs the item exposed.
                let stmt = match item {
                    Some(it) if unqualified || removed_item.is_some() => format!("import {new_module} exposing ({it})"),
                    _ => format!("import {new_module}"),
                };
                if existing.is_none() || unqualified || removed_item.is_some() {
                    add.push(NewImport { text: stmt });
                }
            }
        }
        l if is_ts(l) => {
            let spec = {
                let importer_dir = g.abs(gi).parent().unwrap_or(Path::new("/")).to_path_buf();
                new_specifier("./x", &importer_dir, cx.to)
            };
            let mut ns_uses = false;
            for &(ri, qualified) in uses {
                if !qualified {
                    continue;
                }
                let r = &node.facts.refs[ri];
                let q = g.qualifier(r).unwrap_or("");
                let ns = node.facts.imports.iter().any(|i| i.alias.as_deref() == Some(q));
                if !ns {
                    continue;
                }
                for tok in d.line_tokens(r.line as usize, g.name(r.name)) {
                    if qualifier_ok(&d.masked, tok, Some(q)) && tok > q.len() {
                        let start = tok - q.len() - 1;
                        if !d.edits.touches(start, tok) {
                            d.edits.replace(start, tok, "");
                            *sites += 1;
                            ns_uses = true;
                        }
                    }
                }
            }
            let semi = if d.src.text.contains(";\n") { ";" } else { "" };
            if let Some(item) = removed_item.clone().or_else(|| (ns_uses || unqualified).then(|| name.to_string())) {
                add.push(NewImport { text: format!("import {{ {item} }} from '{spec}'{semi}") });
            }
        }
        "rust" => {
            let to_path = cx.rust_to.expect("rust destination path");
            let g_mod = rust_module_path(g, &node.path, cx.sfile_rel);
            if g_mod.is_none() {
                return Err(ToolError::failed(format!("{} is in a different crate from {}; its `use` of {name} cannot be rewritten automatically. Nothing was changed.", g.abs(gi).display(), cx.from_path.display())));
            }
            for &(ri, qualified) in uses {
                if !qualified {
                    continue;
                }
                let r = &node.facts.refs[ri];
                let q = g.qualifier(r).unwrap_or("");
                if matches!(q, "self" | "Self") {
                    continue;
                }
                for tok in d.line_tokens(r.line as usize, g.name(r.name)) {
                    if qualifier_ok(&d.masked, tok, Some(q)) && tok >= q.len() + 2 {
                        let start = tok - q.len() - 2;
                        if d.masked[start..tok - 2] == *q && !d.edits.touches(start, tok - 2) {
                            d.edits.replace(start, tok - 2, to_path.to_string());
                            *sites += 1;
                        }
                    }
                }
            }
            let item = removed_item.clone().or_else(|| unqualified.then(|| name.to_string()));
            if let Some(item) = item {
                add.push(NewImport { text: format!("use {to_path}::{item};") });
            }
        }
        _ => {}
    }
    Ok(add)
}

/// Take `name` out of the import statements `imps` of file `gi` (an Elm `exposing` entry, a
/// TypeScript `{ … }` entry or the whole statement, a Rust `use` entry). Returns the text of the
/// removed entry, and whether any statement named it.
pub(super) fn drop_from_imports(d: &mut Doc, g: &ViewGraph, gi: u32, imps: &[usize], name: &str, lang: &str, sites: &mut usize) -> (Option<String>, bool) {
    let node = g.file(gi);
    let mut removed_item: Option<String> = None;
    let mut had_named = false;
    for &ii in imps {
        let imp = &node.facts.imports[ii];
        if !imp.names.iter().any(|n| n.name == name) {
            continue;
        }
        had_named = true;
        let (a, b) = d.extent(imp.line as usize);
        let (s, e) = d.lines_bytes(a, b);
        match lang {
            "elm" => {
                if let Some(ex) = d.masked[s..e].find("exposing").map(|i| s + i)
                    && let Some(open) = d.masked[ex..e].find('(').map(|i| ex + i)
                    && let Some((items, close)) = list_items(&d.src.text, &d.masked, open)
                    && let Some(idx) = items.iter().position(|i| i.base == name)
                {
                    removed_item = Some(d.src.text[items[idx].start..items[idx].end].to_string());
                    if items.len() == 1 {
                        let from = d.masked[..ex].trim_end().len();
                        d.edits.replace(from, close + 1, "");
                    } else {
                        remove_item(&mut d.edits, &items, idx);
                    }
                    *sites += 1;
                }
            }
            l if is_ts(l) => {
                let reexport = imp.kind == ImportKind::Reexport;
                let item = imp.names.iter().find(|n| n.name == name).map(|n| match &n.alias {
                    Some(al) => format!("{name} as {al}"),
                    None => name.to_string(),
                });
                removed_item = item.clone();
                let others = imp.names.iter().filter(|n| n.name != name).count() + imp.alias.is_some() as usize;
                if others == 0 {
                    d.edits.replace(s, e, "");
                } else if let Some(open) = d.masked[s..e].find('{').map(|i| s + i)
                    && let Some((items, _)) = list_items(&d.src.text, &d.masked, open)
                    && items.len() > 1
                    && let Some(idx) = items.iter().position(|i| i.base == name)
                {
                    remove_item(&mut d.edits, &items, idx);
                } else {
                    // The only named entry sits beside a default or namespace binding: rebuild the statement.
                    let default = imp.names.iter().find(|n| n.name == "default").and_then(|n| n.alias.clone());
                    let mut parts: Vec<String> = default.into_iter().collect();
                    parts.extend(imp.alias.iter().map(|a| format!("* as {a}")));
                    let raw = d.src.text[s..e].trim_end().to_string();
                    let semi = if raw.ends_with(';') { ";" } else { "" };
                    let kw = if reexport { "export" } else { "import" };
                    d.edits.replace(s, e, format!("{kw} {} from '{}'{semi}{}", parts.join(", "), imp.specifier, d.nl()));
                }
                *sites += 1;
            }
            "rust" => {
                let braces = d.masked[s..e].find('{').map(|i| s + i);
                match braces.and_then(|o| list_items(&d.src.text, &d.masked, o)) {
                    Some((items, _)) if items.len() > 1 => {
                        if let Some(idx) = items.iter().position(|i| i.base == name) {
                            removed_item = Some(d.src.text[items[idx].start..items[idx].end].to_string());
                            remove_item(&mut d.edits, &items, idx);
                        }
                    }
                    _ => {
                        removed_item = imp.names.iter().find(|n| n.name == name).map(|n| match &n.alias {
                            Some(al) => format!("{name} as {al}"),
                            None => name.to_string(),
                        });
                        d.edits.replace(s, e, "");
                    }
                }
                *sites += 1;
            }
            _ => {}
        }
    }
    (removed_item, had_named)
}

/// An Elm file that imports a renamed module: its `import` lines, and, if one of them is
/// unaliased (`plain`), every qualified use, since the module's full name is how the file refers
/// to it everywhere (`Old.Name.f`); aliased, only the import line names it.
pub(super) fn rewrite_elm_importer(d: &mut Doc, imports: &[Import], rewrites: &[usize], plain: bool, old_module: &str, new_module: &str) -> usize {
    let mut n = 0;
    for t in d.dotted_tokens(old_module) {
        let on_import_line = rewrites.iter().any(|&ii| {
            let (a, b) = d.extent(imports[ii].line as usize);
            let (s, e) = d.lines_bytes(a, b);
            t >= s && t < e && d.masked[s..t].trim_start().starts_with("import")
        });
        if plain || on_import_line {
            n += d.replace_token(t, old_module.len(), new_module) as usize;
        }
    }
    n
}
