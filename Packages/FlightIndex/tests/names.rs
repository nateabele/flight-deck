//! The per-repository name pool and the compact reference sites built on it.

mod common;
use flightindex::facts::*;
use flightindex::names::{NameId, NamePool};
use flightindex::store::*;
use std::path::Path;

#[test]
fn a_reference_site_is_twenty_bytes() {
    // 736k sites on tessera: at the old 64 B plus two heap strings each they were 72 MB of a
    // 127 MB first graph. 20 B is name + qualifier + line + enclosing as u32s plus the kind.
    assert!(std::mem::size_of::<RefSite>() <= 20, "RefSite is {} B", std::mem::size_of::<RefSite>());
}

#[test]
fn interning_is_stable_and_append_only() {
    let mut p = NamePool::new(7);
    let a = p.intern("map");
    let b = p.intern("List");
    assert_eq!(p.intern("map"), a, "the same text gets the same id");
    assert_ne!(a, b);
    assert_eq!(p.resolve(a), "map");
    assert_eq!(p.resolve(b), "List");
    assert_eq!(p.get("List"), Some(b));
    assert_eq!(p.get("nope"), None);
    assert_eq!(p.len(), 2);
    assert_eq!(p.store_id(), 7);
    // A later snapshot keeps every earlier id: a graph built on the old one stays readable with
    // the new one.
    let mut q = p.clone();
    let c = q.intern("Dict");
    assert_eq!(q.resolve(a), "map");
    assert_eq!(q.resolve(c), "Dict");
    assert_eq!(p.get("Dict"), None, "the old snapshot is untouched");
}

#[test]
fn ids_set_out_of_order_fill_the_gap_until_known() {
    // Another process can insert names between two of ours, so the ids this process learns are
    // not always contiguous.
    let mut p = NamePool::new(1);
    p.set(NameId(2), "c");
    assert_eq!(p.len(), 3);
    assert_eq!(p.resolve(NameId(2)), "c");
    assert_eq!(p.get("c"), Some(NameId(2)));
    p.set(NameId(0), "a");
    assert_eq!(p.resolve(NameId(0)), "a");
    assert_eq!(p.get("a"), Some(NameId(0)));
    assert_eq!(p.get(""), None, "a gap is not a name");
}

fn sample() -> BlobFacts {
    BlobFacts {
        module_name: Some("A".into()),
        line_count: 9,
        symbols: vec![Symbol {
            local_id: 0, name: "go".into(), kind: SymbolKind::Function, start_line: 1, start_col: 0, end_line: 9, end_col: 1,
            signature: None, parent: None, exported: true,
        }],
        imports: vec![],
        refs: vec![
            Reference { name: "map".into(), qualifier: Some("List".into()), line: 2, enclosing: Some(0), kind: RefKind::Call },
            Reference { name: "Just".into(), qualifier: None, line: 3, enclosing: None, kind: RefKind::Use },
            Reference { name: "List".into(), qualifier: None, line: 4, enclosing: Some(0), kind: RefKind::Type },
        ],
        hierarchy: vec![],
        types: Default::default(),
    }
}

fn parsed(blob: &str, facts: Option<BlobFacts>) -> ParsedBlob {
    ParsedBlob { blob_id: blob.into(), language: "elm", parser_version: 1, facts }
}

#[test]
fn stored_sites_resolve_to_the_parsed_names() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    w.put_facts(&[parsed("b1", Some(sample()))]).unwrap();

    let r = Reader::open(root.path(), repo).unwrap();
    let f = r.get_interned("b1", "elm", 1).unwrap().unwrap();
    let mut pool = NamePool::new(r.store_id());
    r.load_names(&mut pool).unwrap();
    assert!(f.name_bound as usize <= pool.len());
    let back: Vec<Reference> = f.refs.iter().map(|s| s.to_reference(&pool)).collect();
    assert_eq!(back, sample().refs);
    assert_eq!(f.refs.capacity(), f.refs.len(), "the refs Vec is sized exactly, not grown by doubling");
    // `List` as a name and as a qualifier is one pool entry.
    assert_eq!(f.refs[0].qualifier(), Some(f.refs[2].name));
}

#[test]
fn ids_survive_a_reopen_and_new_blobs_only_append() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let first = {
        let mut w = Writer::open(root.path(), repo).unwrap();
        w.put_facts(&[parsed("b1", Some(sample()))]).unwrap();
        Reader::open(root.path(), repo).unwrap().get_interned("b1", "elm", 1).unwrap().unwrap()
    };
    let mut w = Writer::open(root.path(), repo).unwrap();
    let mut other = sample();
    other.refs.insert(0, Reference { name: "brandNew".into(), qualifier: None, line: 1, enclosing: None, kind: RefKind::Call });
    w.put_facts(&[parsed("b2", Some(other))]).unwrap();
    let r = Reader::open(root.path(), repo).unwrap();
    let again = r.get_interned("b1", "elm", 1).unwrap().unwrap();
    assert_eq!(again.refs, first.refs, "a reopened writer reuses the stored ids");
    let b2 = r.get_interned("b2", "elm", 1).unwrap().unwrap();
    assert_eq!(b2.refs[1..], first.refs[..], "shared names share ids across blobs");
    assert!(b2.refs[0].name.0 >= first.name_bound, "a new name gets a new id past the old ones");
}

#[test]
fn a_rebuilt_store_has_a_new_identity() {
    // Ids are only meaningful for the file that assigned them. A store dropped and rebuilt
    // (schema bump, corruption, retention) restarts its ids, so the engine must not resolve
    // facts from the new file through a pool it filled from the old one.
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let a = Writer::open(root.path(), repo).unwrap().store_id();
    remove_repo_db(root.path(), repo);
    let b = Writer::open(root.path(), repo).unwrap().store_id();
    assert_ne!(a, b);
    assert_eq!(Reader::open(root.path(), repo).unwrap().store_id(), b);
}

#[test]
fn string_facts_still_round_trip() {
    let root = tempfile::tempdir().unwrap();
    let repo = Path::new("/x/app/.git");
    let mut w = Writer::open(root.path(), repo).unwrap();
    w.put_facts(&[parsed("b1", Some(sample()))]).unwrap();
    assert_eq!(w.get_facts("b1", "elm", 1).unwrap(), Some(sample()));
}

#[test]
fn interning_in_memory_round_trips() {
    let mut pool = NamePool::new(0);
    let f = InternedFacts::intern(sample(), &mut pool);
    assert_eq!(f.refs.iter().map(|s| s.to_reference(&pool)).collect::<Vec<_>>(), sample().refs);
    assert_eq!(f.symbols, sample().symbols);
    assert_eq!(f.name_bound as usize, pool.len());
}
