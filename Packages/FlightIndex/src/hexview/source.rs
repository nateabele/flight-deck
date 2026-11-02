//! What a Hex dependency exports, read from its sources under `deps/<name>/lib` with the same
//! extractor that parses the repository's own Elixir files.

use super::{Def, UsingImport};
use crate::facts::{BlobFacts, SymbolKind};
use std::collections::HashMap;
use std::path::Path;

/// Module -> its public definitions, and module -> what its `__using__` imports.
#[derive(Default)]
pub struct SourceModules {
    pub defs: HashMap<String, Vec<Def>>,
    pub using: HashMap<String, Vec<UsingImport>>,
}

/// Every `.ex` file under `lib`, parsed (in parallel, merged in path order). Sources are never
/// `.exs` (scripts, not compiled) and a symlink is not followed: a dependency's tree is plain
/// files. With `using_only`, only files that mention `__using__` are parsed: the caller has the
/// definitions from compiled modules already and needs only what `use` imports.
pub fn read_lib(lib: &Path, using_only: bool) -> SourceModules {
    use rayon::prelude::*;
    let mut files = Vec::new();
    let mut stack = vec![lib.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.filter_map(|e| e.ok()) {
            let Ok(ft) = e.file_type() else { continue };
            let p = e.path();
            if ft.is_dir() {
                stack.push(p);
            } else if ft.is_file() && p.extension().is_some_and(|x| x == "ex") {
                files.push(p);
            }
        }
    }
    files.sort();
    let lang = crate::lang::by_id("elixir").expect("the elixir extractor");
    let parsed: Vec<BlobFacts> = files
        .par_iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .filter(|text| !using_only || text.contains("__using__"))
        .map(|text| lang.extract(&text))
        .collect();
    let mut out = SourceModules::default();
    for facts in &parsed {
        add_file(&mut out, facts);
    }
    out
}

/// The modules of one parsed file: each module's public functions, macros and types (by the
/// nearest enclosing module), and the imports inside its `defmacro __using__`.
pub fn add_file(out: &mut SourceModules, facts: &BlobFacts) {
    let syms = &facts.symbols;
    let module_of = |mut p: Option<u32>| -> Option<&str> {
        while let Some(i) = p {
            let s = &syms[i as usize];
            match s.kind {
                SymbolKind::Module | SymbolKind::Trait => return Some(&s.name),
                // A `defimpl` body is called through its protocol, never by module name.
                SymbolKind::Impl => return None,
                _ => p = s.parent,
            }
        }
        None
    };
    for s in syms {
        if !s.exported {
            continue;
        }
        let kind = match s.kind {
            SymbolKind::Module | SymbolKind::Trait => {
                out.defs.entry(s.name.clone()).or_default();
                continue;
            }
            // A behaviour's `@callback` is for implementers; nobody calls `Behaviour.cb()`.
            SymbolKind::Method if s.signature.as_deref().is_some_and(|g| g.starts_with("@callback") || g.starts_with("@macrocallback")) => continue,
            SymbolKind::Function | SymbolKind::Method => super::DefKind::Function,
            SymbolKind::Macro => super::DefKind::Macro,
            SymbolKind::TypeAlias => super::DefKind::Type,
            _ => continue,
        };
        let Some(module) = module_of(s.parent) else { continue };
        if s.name == "__using__" {
            let imports = facts.imports.iter().filter(|i| i.line >= s.start_line && i.line <= s.end_line);
            let list = out.using.entry(module.to_string()).or_default();
            list.extend(imports.map(UsingImport::from_import));
        }
        out.defs.entry(module.to_string()).or_default().push(Def { kind, name: s.name.clone(), signature: s.signature.clone() });
    }
}
