//! The two per-view indexes as sorted arrays instead of hash maps of vectors.
//!
//! Once blocks are shared (see `blocks`), what each cached graph still owns is mostly its name
//! index (every definition by name) and its incoming-reference index (every resolved reference by
//! target). As `HashMap<String, Vec<SymId>>` and `HashMap<SymId, Vec<(u32, u32)>>` they cost a
//! string copy, a vector header and an allocation per key: on tessera about 40k names and 120k
//! targets a graph. Here each is two flat vectors searched by binary search, with the same answers
//! in the same order.
//!
//! **Layers.** An overlay graph (a worktree with local edits) differs from its base graph in a
//! handful of files, yet a flat index of its own would copy every entry of the base's: 4.3 MB a
//! dirty tessera worktree, two thirds of what the overlay graph owned. So an overlay's index can
//! be a *layer* over its base's: the base's entries minus those of the `masked` files (the files
//! whose entries may differ), plus the masked files' own entries. Entries are added in file order,
//! and a file's entries all come from one side, so a lookup merges the two runs by file and
//! returns exactly what a flat index of the same entries returns, in the same order. One level
//! only: a layer is never built over a layer (`over` refuses), so a lookup is at most two runs.

use super::SymId;
use std::borrow::Cow;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

fn hash_name(name: &str) -> u64 {
    let mut h = DefaultHasher::new();
    name.hash(&mut h);
    h.finish()
}

/// The base an overlay's index is layered over, and the files of the base whose entries do not
/// count (ascending).
#[derive(Clone)]
struct Layer<T> {
    base: Arc<T>,
    masked: Vec<u32>,
}

impl<T> Layer<T> {
    fn keeps(&self, file: u32) -> bool {
        self.masked.binary_search(&file).is_err()
    }
}

/// `base` (the unmasked part of a base run, in file order) and `own` (the masked files' entries,
/// in file order) merged by file: what one flat index of both would hold, borrowed when one side
/// is empty.
fn merge<'a, T: Clone>(base: Vec<&'a T>, base_all: &'a [T], own: &'a [T], file: impl Fn(&T) -> u32) -> Cow<'a, [T]> {
    if own.is_empty() && base.len() == base_all.len() {
        return Cow::Borrowed(base_all);
    }
    if base.is_empty() {
        return Cow::Borrowed(own);
    }
    let mut out = Vec::with_capacity(base.len() + own.len());
    let (mut b, mut o) = (base.into_iter().peekable(), own.iter().peekable());
    loop {
        match (b.peek(), o.peek()) {
            (Some(x), Some(y)) if file(x) <= file(y) => out.push(b.next().unwrap().clone()),
            (Some(_), Some(_)) | (None, Some(_)) => out.push(o.next().unwrap().clone()),
            (Some(_), None) => out.push(b.next().unwrap().clone()),
            (None, None) => break,
        }
    }
    Cow::Owned(out)
}

/// Definitions by name. Entries are sorted by (hash of name, name, insertion order), so one
/// name's definitions are contiguous and in the order they were added.
#[derive(Clone, Default)]
pub struct NameIndex {
    hashes: Vec<u64>,
    ids: Vec<SymId>,
    layer: Option<Layer<NameIndex>>,
}

impl NameIndex {
    /// `entries` in the order a lookup should return them; `name_of` gives each id's name.
    pub fn build<'a>(entries: Vec<SymId>, name_of: impl Fn(SymId) -> &'a str) -> NameIndex {
        let mut keyed: Vec<(u64, &str, usize, SymId)> = entries.into_iter().enumerate().map(|(i, id)| (hash_name(name_of(id)), name_of(id), i, id)).collect();
        keyed.sort_unstable_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(b.1)).then(a.2.cmp(&b.2)));
        NameIndex { hashes: keyed.iter().map(|k| k.0).collect(), ids: keyed.iter().map(|k| k.3).collect(), layer: None }
    }

    /// `base`'s entries but those of the `masked` files (ascending), plus `entries`, every one of
    /// a masked file and in file order. `None` when `base` is itself a layer: build a flat index.
    pub fn over<'a>(base: &Arc<NameIndex>, masked: Vec<u32>, entries: Vec<SymId>, name_of: impl Fn(SymId) -> &'a str) -> Option<NameIndex> {
        if base.layer.is_some() {
            return None;
        }
        debug_assert!(masked.is_sorted() && entries.iter().all(|e| masked.binary_search(&e.file).is_ok()));
        let mut ix = NameIndex::build(entries, name_of);
        ix.layer = Some(Layer { base: base.clone(), masked });
        Some(ix)
    }

    /// The entries whose name hashes like `name`'s, without comparing names.
    fn hash_run(&self, name: &str) -> &[SymId] {
        let h = hash_name(name);
        let lo = self.hashes.partition_point(|x| *x < h);
        let hi = lo + self.hashes[lo..].partition_point(|x| *x == h);
        &self.ids[lo..hi]
    }

    /// This index's own definitions named `name`.
    fn own<'b>(&self, name: &str, name_of: &impl Fn(SymId) -> &'b str) -> &[SymId] {
        let run = self.hash_run(name);
        // Within one hash, names are sorted: a collision is a neighbouring run.
        let start = run.partition_point(|id| name_of(*id) < name);
        let end = start + run[start..].partition_point(|id| name_of(*id) == name);
        &run[start..end]
    }

    /// Every definition named `name`, in insertion order; `name_of` as given to `build`.
    pub fn get<'a, 'b>(&'a self, name: &str, name_of: impl Fn(SymId) -> &'b str) -> Option<Cow<'a, [SymId]>> {
        let own = self.own(name, &name_of);
        let found = match &self.layer {
            None => Cow::Borrowed(own),
            Some(l) => {
                // `name_of` reads this graph's files, so it is asked only about files the base
                // still describes: a masked file may now be a tombstone with no symbols at all.
                // The run of one hash is (but for a 64-bit collision) the run of one name.
                let all = l.base.hash_run(name);
                let kept: Vec<&SymId> = all.iter().filter(|id| l.keeps(id.file) && name_of(**id) == name).collect();
                merge(kept, all, own, |id| id.file)
            }
        };
        (!found.is_empty()).then_some(found)
    }

    /// Bytes this index owns (a layer's base is the base graph's).
    pub fn bytes(&self) -> usize {
        self.hashes.capacity() * 8 + self.ids.capacity() * std::mem::size_of::<SymId>() + self.layer.as_ref().map_or(0, |l| l.masked.capacity() * 4)
    }
}

/// Resolved references by target: for each target symbol, (file, index into that file's refs)
/// of every reference to it, in the order they were added.
#[derive(Clone, Default)]
pub struct Incoming {
    keys: Vec<SymId>,
    /// `refs[starts[i]..starts[i + 1]]` reference `keys[i]`.
    starts: Vec<u32>,
    refs: Vec<(u32, u32)>,
    layer: Option<Layer<Incoming>>,
}

impl Incoming {
    /// From (target, (file, ref index)) pairs in the order each target's list should keep.
    pub fn build(pairs: Vec<(SymId, (u32, u32))>) -> Incoming {
        let mut pairs = pairs;
        pairs.sort_by_key(|p| p.0); // stable: each target keeps its insertion order
        let mut inc = Incoming { keys: Vec::new(), starts: Vec::new(), refs: Vec::with_capacity(pairs.len()), layer: None };
        for (t, r) in pairs {
            if inc.keys.last() != Some(&t) {
                inc.keys.push(t);
                inc.starts.push(inc.refs.len() as u32);
            }
            inc.refs.push(r);
        }
        inc.starts.push(inc.refs.len() as u32);
        inc.keys.shrink_to_fit();
        inc.starts.shrink_to_fit();
        inc
    }

    /// `base`'s references but those made from the `masked` files (ascending), plus `pairs`, every
    /// one made from a masked file and in file order. `None` when `base` is itself a layer.
    pub fn over(base: &Arc<Incoming>, masked: Vec<u32>, pairs: Vec<(SymId, (u32, u32))>) -> Option<Incoming> {
        if base.layer.is_some() {
            return None;
        }
        debug_assert!(masked.is_sorted() && pairs.iter().all(|p| masked.binary_search(&p.1.0).is_ok()));
        let mut inc = Incoming::build(pairs);
        inc.layer = Some(Layer { base: base.clone(), masked });
        Some(inc)
    }

    fn own(&self, target: &SymId) -> &[(u32, u32)] {
        match self.keys.binary_search(target) {
            Ok(i) => &self.refs[self.starts[i] as usize..self.starts[i + 1] as usize],
            Err(_) => &[],
        }
    }

    pub fn get(&self, target: &SymId) -> Option<Cow<'_, [(u32, u32)]>> {
        let own = self.own(target);
        let found = match &self.layer {
            None => Cow::Borrowed(own),
            Some(l) => {
                let all = l.base.own(target);
                let kept: Vec<&(u32, u32)> = all.iter().filter(|r| l.keeps(r.0)).collect();
                merge(kept, all, own, |r| r.0)
            }
        };
        (!found.is_empty()).then_some(found)
    }

    /// Bytes this index owns (a layer's base is the base graph's).
    pub fn bytes(&self) -> usize {
        self.keys.capacity() * std::mem::size_of::<SymId>() + self.starts.capacity() * 4 + self.refs.capacity() * 8 + self.layer.as_ref().map_or(0, |l| l.masked.capacity() * 4)
    }

    pub fn is_layer(&self) -> bool {
        self.layer.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(file: u32, local: u32) -> SymId {
        SymId { file, local }
    }

    #[test]
    fn a_name_lookup_returns_that_name_s_definitions_in_insertion_order() {
        let names = ["b", "a", "b", "c", "a"];
        let entries: Vec<SymId> = (0..names.len() as u32).map(|i| id(i, 0)).collect();
        let name_of = |s: SymId| names[s.file as usize];
        let ix = NameIndex::build(entries, name_of);
        assert_eq!(ix.get("a", name_of).as_deref(), Some(&[id(1, 0), id(4, 0)][..]));
        assert_eq!(ix.get("b", name_of).as_deref(), Some(&[id(0, 0), id(2, 0)][..]));
        assert_eq!(ix.get("c", name_of).as_deref(), Some(&[id(3, 0)][..]));
        assert_eq!(ix.get("d", name_of), None);
    }

    #[test]
    fn incoming_keeps_each_target_s_references_in_insertion_order() {
        let inc = Incoming::build(vec![(id(2, 1), (5, 0)), (id(0, 3), (1, 1)), (id(2, 1), (0, 7)), (id(0, 3), (1, 2))]);
        assert_eq!(inc.get(&id(2, 1)).as_deref(), Some(&[(5, 0), (0, 7)][..]));
        assert_eq!(inc.get(&id(0, 3)).as_deref(), Some(&[(1, 1), (1, 2)][..]));
        assert_eq!(inc.get(&id(1, 0)), None);
    }

    /// Names of (file, local): the base's files, and after the edit files 1 and 3 changed, file 2
    /// is gone (a tombstone with no symbols) and file 5 is new.
    fn base_name(s: SymId) -> &'static str {
        [["x", "y", "x"], ["y", "z", "w"], ["x", "x", "q"], ["z", "y", "x"], ["y", "x", "z"]][s.file as usize][s.local as usize]
    }
    fn edited_name(s: SymId) -> &'static str {
        match s.file {
            1 => ["x", "q", "y"][s.local as usize],
            2 => panic!("asked the name of a removed file's symbol"),
            3 => ["w"][s.local as usize],
            5 => ["x", "y"][s.local as usize],
            _ => base_name(s),
        }
    }
    fn defs(files: &[(u32, u32)]) -> Vec<SymId> {
        files.iter().flat_map(|&(f, n)| (0..n).map(move |l| id(f, l))).collect()
    }

    #[test]
    fn a_layered_name_index_answers_what_a_flat_one_of_the_same_entries_does() {
        let base = Arc::new(NameIndex::build(defs(&[(0, 3), (1, 3), (2, 3), (3, 3), (4, 3)]), base_name));
        let flat = NameIndex::build(defs(&[(0, 3), (1, 3), (3, 1), (4, 3), (5, 2)]), edited_name);
        let layer = NameIndex::over(&base, vec![1, 2, 3, 5], defs(&[(1, 3), (3, 1), (5, 2)]), edited_name).unwrap();
        for n in ["x", "y", "z", "w", "q", "none"] {
            assert_eq!(layer.get(n, edited_name), flat.get(n, edited_name), "{n}");
        }
        assert!(NameIndex::over(&Arc::new(layer), vec![], vec![], edited_name).is_none(), "never a layer over a layer");
    }

    #[test]
    fn a_layered_incoming_index_answers_what_a_flat_one_of_the_same_references_does() {
        // (target, (from file, ref index)) in file order, as `finalize` adds them.
        let base_pairs = vec![(id(0, 0), (1, 0)), (id(2, 1), (1, 1)), (id(0, 0), (2, 0)), (id(0, 0), (3, 0)), (id(2, 1), (3, 1)), (id(4, 0), (4, 0))];
        let own = vec![(id(0, 0), (2, 0)), (id(4, 0), (2, 1)), (id(0, 0), (5, 0)), (id(2, 1), (5, 1))];
        let mut all: Vec<_> = base_pairs.iter().copied().filter(|p| ![2, 5].contains(&p.1.0)).chain(own.iter().copied()).collect();
        all.sort_by_key(|p| p.1);
        let flat = Incoming::build(all);
        let layer = Incoming::over(&Arc::new(Incoming::build(base_pairs)), vec![2, 5], own).unwrap();
        for t in [id(0, 0), id(2, 1), id(4, 0), id(9, 9)] {
            assert_eq!(layer.get(&t), flat.get(&t), "{t:?}");
        }
        assert!(layer.bytes() < flat.bytes(), "a layer owns only the masked files' references");
    }
}
