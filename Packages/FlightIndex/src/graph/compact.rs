//! The two per-view indexes as sorted arrays instead of hash maps of vectors.
//!
//! Once blocks are shared (see `blocks`), what each cached graph still owns is mostly its name
//! index (every definition by name) and its incoming-reference index (every resolved reference by
//! target). As `HashMap<String, Vec<SymId>>` and `HashMap<SymId, Vec<(u32, u32)>>` they cost a
//! string copy, a vector header and an allocation per key: on tessera about 40k names and 120k
//! targets a graph. Here each is two flat vectors searched by binary search, with the same answers
//! in the same order.

use super::SymId;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

fn hash_name(name: &str) -> u64 {
    let mut h = DefaultHasher::new();
    name.hash(&mut h);
    h.finish()
}

/// Definitions by name. Entries are sorted by (hash of name, name, insertion order), so one
/// name's definitions are contiguous and in the order they were added.
#[derive(Clone, Default)]
pub struct NameIndex {
    hashes: Vec<u64>,
    ids: Vec<SymId>,
}

impl NameIndex {
    /// `entries` in the order a lookup should return them; `name_of` gives each id's name.
    pub fn build<'a>(entries: Vec<SymId>, name_of: impl Fn(SymId) -> &'a str) -> NameIndex {
        let mut keyed: Vec<(u64, &str, usize, SymId)> = entries.into_iter().enumerate().map(|(i, id)| (hash_name(name_of(id)), name_of(id), i, id)).collect();
        keyed.sort_unstable_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(b.1)).then(a.2.cmp(&b.2)));
        NameIndex { hashes: keyed.iter().map(|k| k.0).collect(), ids: keyed.iter().map(|k| k.3).collect() }
    }

    /// Every definition named `name`, in insertion order; `name_of` as given to `build`.
    pub fn get<'a, 'b>(&'a self, name: &str, name_of: impl Fn(SymId) -> &'b str) -> Option<&'a [SymId]> {
        let h = hash_name(name);
        let lo = self.hashes.partition_point(|x| *x < h);
        let hi = lo + self.hashes[lo..].partition_point(|x| *x == h);
        let run = &self.ids[lo..hi];
        // Within one hash, names are sorted: a collision is a neighbouring run.
        let start = run.partition_point(|id| name_of(*id) < name);
        let end = start + run[start..].partition_point(|id| name_of(*id) == name);
        (end > start).then(|| &run[start..end])
    }

    pub fn bytes(&self) -> usize {
        self.hashes.capacity() * 8 + self.ids.capacity() * std::mem::size_of::<SymId>()
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
}

impl Incoming {
    /// From (target, (file, ref index)) pairs in the order each target's list should keep.
    pub fn build(pairs: Vec<(SymId, (u32, u32))>) -> Incoming {
        let mut pairs = pairs;
        pairs.sort_by_key(|p| p.0); // stable: each target keeps its insertion order
        let mut inc = Incoming { keys: Vec::new(), starts: Vec::new(), refs: Vec::with_capacity(pairs.len()) };
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

    pub fn get(&self, target: &SymId) -> Option<&[(u32, u32)]> {
        let i = self.keys.binary_search(target).ok()?;
        Some(&self.refs[self.starts[i] as usize..self.starts[i + 1] as usize])
    }

    pub fn bytes(&self) -> usize {
        self.keys.capacity() * std::mem::size_of::<SymId>() + self.starts.capacity() * 4 + self.refs.capacity() * 8
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
        assert_eq!(ix.get("a", name_of), Some(&[id(1, 0), id(4, 0)][..]));
        assert_eq!(ix.get("b", name_of), Some(&[id(0, 0), id(2, 0)][..]));
        assert_eq!(ix.get("c", name_of), Some(&[id(3, 0)][..]));
        assert_eq!(ix.get("d", name_of), None);
    }

    #[test]
    fn incoming_keeps_each_target_s_references_in_insertion_order() {
        let inc = Incoming::build(vec![(id(2, 1), (5, 0)), (id(0, 3), (1, 1)), (id(2, 1), (0, 7)), (id(0, 3), (1, 2))]);
        assert_eq!(inc.get(&id(2, 1)), Some(&[(5, 0), (0, 7)][..]));
        assert_eq!(inc.get(&id(0, 3)), Some(&[(1, 1), (1, 2)][..]));
        assert_eq!(inc.get(&id(1, 0)), None);
    }
}
