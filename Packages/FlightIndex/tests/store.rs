mod common;
use flightindex::facts::*;
use flightindex::git::{FileRef, Overlay};
use flightindex::store::*;
use std::path::Path;

fn sample() -> BlobFacts {
    BlobFacts {
        module_name: Some("A".into()),
        line_count: 7,
        symbols: vec![
            Symbol { local_id: 0, name: "T".into(), kind: SymbolKind::Enum, start_line: 1, start_col: 0, end_line: 3, end_col: 1, signature: Some("type T".into()), parent: None, exported: true },
            Symbol { local_id: 1, name: "C".into(), kind: SymbolKind::Constructor, start_line: 2, start_col: 4, end_line: 2, end_col: 9, signature: None, parent: Some(0), exported: false },
        ],
        imports: vec![Import {
            specifier: "B".into(),
            alias: Some("X".into()),
            names: vec![ImportName { name: "f".into(), alias: Some("g".into()), subs: false }, ImportName { name: "T".into(), alias: None, subs: true }],
            line: 2,
            kind: ImportKind::Import,
        }],
        refs: vec![Reference { name: "f".into(), qualifier: Some("X".into()), line: 5, enclosing: Some(1), kind: RefKind::Call }],
        hierarchy: vec![TypeRelation { symbol: 0, target: "Base".into(), kind: HierarchyKind::Implements }],
    }
}

fn parsed(blob: &str, facts: Option<BlobFacts>) -> ParsedBlob {
    ParsedBlob { blob_id: blob.into(), language: "elm", parser_version: 1, facts }
}

fn fref(path: &str, blob: &str) -> FileRef {
    FileRef { path: path.into(), blob_id: blob.into(), language: "elm" }
}

#[test]
fn facts_round_trip_through_a_reader() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    w.put_facts(&[parsed("b1", Some(sample())), parsed("b2", None)]).unwrap();
    let r = Reader::open(root.path(), repo).unwrap();
    assert_eq!(r.get_facts("b1", "elm", 1).unwrap(), Some(sample()));
    assert!(r.has_facts("b2", "elm", 1).unwrap(), "a skipped blob is recorded");
    assert_eq!(r.get_facts("b2", "elm", 1).unwrap().unwrap().symbols.len(), 0);
    assert!(!r.has_facts("b1", "elm", 2).unwrap(), "parser version is part of the key");
    assert!(!r.has_facts("b1", "rust", 1).unwrap(), "language is part of the key");
    // re-inserting a key is a no-op, not an error and not a duplicate
    w.put_facts(&[parsed("b1", Some(sample()))]).unwrap();
    assert_eq!(w.stats().unwrap().facts, 2);
    assert_eq!(w.stats().unwrap().symbols, 2);
}

#[test]
fn a_reader_never_creates_a_database() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    assert!(Reader::open(root.path(), repo).is_err());
    assert!(!db_path(root.path(), repo).exists());
}

#[test]
fn one_database_file_per_repository() {
    let root = tempfile::tempdir().unwrap();
    let a = db_path(root.path(), Path::new("/x/app/.git"));
    let b = db_path(root.path(), Path::new("/y/app/.git"));
    assert_ne!(a, b, "two repos named app must not collide");
    assert!(a.file_name().unwrap().to_string_lossy().starts_with("app-"));
    assert_eq!(a, db_path(root.path(), Path::new("/x/app/.git")));
}

#[test]
fn schema_mismatch_rebuilds_the_file() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    {
        let mut w = Writer::open(root.path(), repo).unwrap();
        w.put_facts(&[parsed("b1", Some(sample()))]).unwrap();
    }
    let path = db_path(root.path(), repo);
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute("UPDATE meta SET value = '0' WHERE key = 'schema_version'", []).unwrap();
    drop(conn);
    assert!(Reader::open(root.path(), repo).is_err(), "a reader never rebuilds");
    let w = Writer::open(root.path(), repo).unwrap();
    assert_eq!(w.stats().unwrap().facts, 0, "derived data is dropped and rebuilt");
    assert!(Reader::open(root.path(), repo).is_ok());
}

#[test]
fn a_garbage_file_is_replaced() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    std::fs::write(db_path(root.path(), repo), b"this is not sqlite, not even close to it at all").unwrap();
    let w = Writer::open(root.path(), repo).unwrap();
    assert_eq!(w.stats().unwrap().facts, 0);
}

#[test]
fn trees_and_worktree_overlays_persist() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    w.put_tree("c1", &[fref("a.elm", "b1"), fref("b.elm", "b2")]).unwrap();
    let wt = root.path();
    w.set_worktree(wt, Some("c1"), &[Overlay::Present(fref("a.elm", "b3")), Overlay::Deleted("b.elm".into())]).unwrap();
    let r = Reader::open(root.path(), repo).unwrap();
    assert_eq!(r.get_tree("c1").unwrap().unwrap().len(), 2);
    assert!(r.get_tree("nope").unwrap().is_none());
    let ov = r.get_overlay(wt).unwrap();
    assert_eq!(ov, vec![Overlay::Present(fref("a.elm", "b3")), Overlay::Deleted("b.elm".into())]);
}

#[test]
fn gc_keeps_what_is_referenced_and_drops_the_rest() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    let live_wt = tempfile::tempdir().unwrap();
    let gone_wt = root.path().join("removed-worktree"); // never existed on disk
    w.put_facts(&["in-tree", "in-overlay", "in-old-tree", "in-ref-tree", "orphan"].map(|b| parsed(b, Some(sample()))))
        .unwrap();
    w.put_tree("head", &[fref("a.elm", "in-tree")]).unwrap();
    w.put_tree("old", &[fref("a.elm", "in-old-tree")]).unwrap();
    w.put_tree("refd", &[fref("a.elm", "in-ref-tree")]).unwrap();
    w.set_worktree(live_wt.path(), Some("head"), &[Overlay::Present(fref("x.elm", "in-overlay"))]).unwrap();
    w.set_worktree(&gone_wt, Some("old"), &[]).unwrap();
    w.set_known_refs(&[("refs/heads/main".into(), "refd".into())]).unwrap();

    let stats = w.gc().unwrap();
    assert_eq!(stats, GcStats { worktrees_dropped: 1, trees_dropped: 1, facts_dropped: 2 });
    for kept in ["in-tree", "in-overlay", "in-ref-tree"] {
        assert!(w.has_facts(kept, "elm", 1).unwrap(), "{kept} must survive");
    }
    for dropped in ["in-old-tree", "orphan"] {
        assert!(!w.has_facts(dropped, "elm", 1).unwrap(), "{dropped} must be collected");
    }
    assert_eq!(w.stats().unwrap().symbols, 6, "child rows cascade with their facts");
}

#[test]
fn gc_drops_stale_parser_versions() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    let mut old = parsed("b1", Some(sample()));
    old.parser_version = 0;
    w.put_facts(&[old, parsed("b1", Some(sample()))]).unwrap();
    w.put_tree("c", &[fref("a.elm", "b1")]).unwrap();
    w.set_worktree(root.path(), Some("c"), &[]).unwrap();
    assert_eq!(w.gc().unwrap().facts_dropped, 1);
    assert!(w.has_facts("b1", "elm", 1).unwrap());
}

#[test]
fn incremental_vacuum_returns_freed_pages() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    let batch: Vec<_> = (0..300).map(|i| parsed(&format!("blob{i}"), Some(sample()))).collect();
    w.put_facts(&batch).unwrap();
    assert_eq!(w.stats().unwrap().free_pages, 0);
    w.gc().unwrap(); // nothing references them
    let freed_before = w.stats().unwrap().free_pages;
    assert!(freed_before > 10, "gc leaves free pages behind: {freed_before}");
    let freed = w.incremental_vacuum(5).unwrap();
    assert_eq!(freed, 5);
    w.incremental_vacuum(0).unwrap();
    assert_eq!(w.stats().unwrap().free_pages, 0);
}

fn table_rows(root: &Path, repo: &Path, table: &str) -> Option<i64> {
    let conn = rusqlite::Connection::open(db_path(root, repo)).unwrap();
    conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).ok()
}

/// Facts are only ever read a whole blob at a time, so a blob is one columnar chunk (see
/// `chunk`), not a row per symbol, import, reference and relation.
#[test]
fn a_blob_is_stored_as_one_chunk_not_a_row_per_fact() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    w.put_facts(&[parsed("b1", Some(sample())), parsed("b2", None)]).unwrap();
    for t in ["symbols", "imports", "refs", "hierarchy"] {
        assert_eq!(table_rows(root.path(), repo, t), None, "no `{t}` table");
    }
    assert_eq!(table_rows(root.path(), repo, "chunks"), Some(1), "one chunk for the parsed blob, none for the skipped one");
    assert_eq!(w.stats().unwrap().symbols, 2);
    assert_eq!(Reader::open(root.path(), repo).unwrap().get_facts("b1", "elm", 1).unwrap(), Some(sample()));
}

#[test]
fn gc_drops_the_chunks_of_collected_facts() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    w.put_facts(&["kept", "orphan1", "orphan2"].map(|b| parsed(b, Some(sample())))).unwrap();
    w.put_tree("c", &[fref("a.elm", "kept")]).unwrap();
    w.set_worktree(root.path(), Some("c"), &[]).unwrap();
    assert_eq!(w.gc().unwrap().facts_dropped, 2);
    assert_eq!(table_rows(root.path(), repo, "chunks"), Some(1));
    assert_eq!(w.get_facts("kept", "elm", 1).unwrap(), Some(sample()));
}
