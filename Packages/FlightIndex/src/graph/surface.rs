//! A file's export surface: the part of its facts that resolving *another* file can read. An
//! overlay edit that leaves it unchanged cannot change any other file's resolution, so
//! `with_changes` skips re-resolving the edited file's importers and reference dependents.

use crate::facts::InternedFacts;
use std::hash::{Hash, Hasher};

/// Hash of everything another file's resolution may read from `f`.
///
/// **The rule: anything a resolver reads from a file other than the one being resolved must be
/// in this hash**, or an importer silently keeps a stale answer after an edit the hash called
/// "same surface". The readers of another file's facts, today:
///
/// * `elm_modules` (built by `reindex`): `module_name`.
/// * `lookup_in_file`: symbol names, `local_id` (the `SymId` it returns), `parent`, `exported`,
///   `kind`; and, to follow re-exports, every import's `specifier`, `kind`, `alias` and names
///   (`resolve_import` sees the whole `Import`).
/// * `unqualified_visible`, `member_of`, `member_of_enclosing`: names, `parent`, `kind`, and the
///   parent symbol's name.
/// * `default_export`: top-level exported symbols' names, `kind`, `local_id` (and the path, which
///   an edit in place cannot change).
/// * `rust_item`: through `lookup_in_file` and `member_of`.
/// * `fallback` and `name_index`: names and `kind`/`parent` of every candidate (name-set changes
///   are also caught by the soft-hit rule in `with_changes`).
/// * `elixir_module`, `elixir_import`, `elixir_ref`: module symbols' names and `kind`, then
///   `member_of`.
/// * `swift_ref`, `swift_keys`: candidates' names, `kind`, `parent` and parent name (the keys come
///   from the referencing file's own imports and paths).
///
/// * Swift receiver types (`facts.types`, read through `GraphData::swift_types`): not hashed. A
///   change to what another file's property or return type says is found by `with_changes`
///   itself (`SwiftTypes::changed_names`), which re-resolves every Swift file whose receivers
///   mention it, whatever this hash says about the importers.
///
/// Left out on purpose: positions, signatures, `line_count`, the file's own references, and
/// import line numbers. No resolution reads them from another file; queries read positions live
/// from the target's facts. If a future `RefRes` stores something line-dependent (a target line),
/// it must join the hash. `hierarchy` is not read across files by the graph today; it is hashed
/// anyway because Swift and Rust extension/impl relations are exactly the kind of cross-file fact
/// a resolver may start reading, and an edit that only changes it is rare.
///
/// Fields are hashed one by one, never through serde, so a new `InternedFacts` field joins the
/// surface only when someone decides it should. Lengths are hashed before each list so element
/// boundaries cannot alias.
pub fn surface_hash(f: &InternedFacts) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    f.module_name.hash(&mut h);
    f.symbols.len().hash(&mut h);
    for s in &f.symbols {
        // `local_id` equals the position today; hashing both keeps order significant either way.
        (s.local_id, &s.name, s.kind.as_str(), s.parent, s.exported).hash(&mut h);
    }
    f.imports.len().hash(&mut h);
    for i in &f.imports {
        (&i.specifier, &i.alias, i.kind.as_str(), i.names.len()).hash(&mut h);
        for n in &i.names {
            (&n.name, &n.alias, n.subs).hash(&mut h);
        }
    }
    f.hierarchy.len().hash(&mut h);
    for r in &f.hierarchy {
        (r.symbol, &r.target, r.kind.as_str()).hash(&mut h);
    }
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::facts::*;
    use crate::names::NameId;

    fn sym(id: u32, name: &str) -> Symbol {
        Symbol { local_id: id, name: name.into(), kind: SymbolKind::Function, start_line: 1, start_col: 0, end_line: 1, end_col: 1, signature: None, parent: None, exported: true }
    }

    fn base() -> InternedFacts {
        InternedFacts {
            module_name: Some("M".into()),
            line_count: 3,
            symbols: vec![sym(0, "a"), sym(1, "b")],
            imports: vec![Import { specifier: "./x".into(), alias: None, names: vec![ImportName::plain("y")], line: 1, kind: ImportKind::Reexport }],
            refs: vec![],
            hierarchy: vec![],
            types: Default::default(),
            name_bound: 0,
        }
    }

    #[test]
    fn positions_signatures_refs_and_import_lines_are_not_surface() {
        let mut f = base();
        f.line_count = 99;
        f.symbols[0].start_line = 40;
        f.symbols[0].end_col = 7;
        f.symbols[1].signature = Some("b : Int".into());
        f.imports[0].line = 12;
        f.refs.push(RefSite::new(NameId(0), None, 2, None, RefKind::Call));
        assert_eq!(surface_hash(&base()), surface_hash(&f));
    }

    #[test]
    fn every_cross_file_field_is_surface() {
        let h = surface_hash(&base());
        type Edit = Box<dyn Fn(&mut InternedFacts)>;
        let changed: Vec<(&str, Edit)> = vec![
            ("module name", Box::new(|f| f.module_name = Some("N".into()))),
            ("symbol order", Box::new(|f| f.symbols.swap(0, 1))),
            ("symbol name", Box::new(|f| f.symbols[1].name = "c".into())),
            ("symbol kind", Box::new(|f| f.symbols[1].kind = SymbolKind::Struct)),
            ("symbol parent", Box::new(|f| f.symbols[1].parent = Some(0))),
            ("exported", Box::new(|f| f.symbols[1].exported = false)),
            ("import specifier", Box::new(|f| f.imports[0].specifier = "./w".into())),
            ("import alias", Box::new(|f| f.imports[0].alias = Some("q".into()))),
            ("import kind", Box::new(|f| f.imports[0].kind = ImportKind::Import)),
            ("import name", Box::new(|f| f.imports[0].names[0].name = "*".into())),
            ("import name alias", Box::new(|f| f.imports[0].names[0].alias = Some("v".into()))),
            ("import subs", Box::new(|f| f.imports[0].names[0].subs = true)),
            ("hierarchy", Box::new(|f| f.hierarchy.push(TypeRelation { symbol: 0, target: "P".into(), kind: HierarchyKind::Implements }))),
        ];
        for (what, edit) in changed {
            let mut f = base();
            edit(&mut f);
            assert_ne!(h, surface_hash(&f), "{what} must change the surface");
        }
    }
}
