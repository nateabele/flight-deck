//! One repository's reference names, interned to `u32`.
//!
//! A reference used to carry its name and qualifier as two owned `String`s inside a 64-byte
//! struct. On tessera (736k references, 26k distinct names, 3.5k distinct qualifiers) that was
//! 72 MB of a 127 MB first graph: 57 MB of `Vec<Reference>` plus 16 MB of tiny heap strings, the
//! same `map` and `List` copied tens of thousands of times. With every name interned once, a site
//! is five `u32`-sized fields (see `facts::RefSite`) and the whole pool is about 0.55 MB.
//!
//! **Ids belong to the store.** The writer assigns them as it stores facts (`store::Writer`), the
//! `names` table persists them, and they never change or get reused, so they are stable across
//! graphs, worktrees, commits and daemon restarts. They mean nothing outside the file that
//! assigned them, which is why a pool carries that file's `store_id`: a store that is dropped and
//! rebuilt starts its ids over, and facts read from it must not be resolved through a pool filled
//! from the old file.
//!
//! **A pool is a frozen snapshot.** Readers resolve without a lock; a newer snapshot is a clone
//! with the new names appended (rare: across seven tessera commits the pool went from 28.0k to
//! 28.4k ids). Because ids only ever append, any later snapshot resolves everything an earlier one
//! does, so a graph can hold whichever snapshot it was built with.
//!
//! Rejected: `lasso`'s `ThreadedRodeo`/`RodeoReader` (a dependency for ~100 lines, and its keys
//! are its own, not the store's); `Arc<str>` names (still 16 B a reference plus a refcount
//! bump per clone, and nothing to persist); `HashMap<String, u32>` for `get` (stores every name a
//! second time).

use hashbrown::HashTable;
use std::hash::{BuildHasher, BuildHasherDefault, DefaultHasher};

/// An interned name. The value is the row id in the store's `names` table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NameId(pub u32);

/// Text of one id whose name this snapshot does not know (an id another process inserted that we
/// have not read yet). Never in `table`, so `get("")` finds nothing.
const GAP: u32 = u32::MAX;

type Hasher = BuildHasherDefault<DefaultHasher>;

#[derive(Clone, Default)]
pub struct NamePool {
    store_id: u64,
    /// Every name's bytes, back to back.
    buf: String,
    /// `spans[id]` = (start, end) of the name in `buf`; `(GAP, GAP)` for an id not known yet.
    spans: Vec<(u32, u32)>,
    /// Ids, hashed by their text, for `get`.
    table: HashTable<u32>,
}

impl std::fmt::Debug for NamePool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NamePool").field("store_id", &self.store_id).field("len", &self.spans.len()).finish()
    }
}

fn hash(s: &str) -> u64 {
    Hasher::default().hash_one(s)
}

impl NamePool {
    /// An empty pool for the store identified by `store_id` (`store::Reader::store_id`).
    pub fn new(store_id: u64) -> NamePool {
        NamePool { store_id, ..Default::default() }
    }

    pub fn store_id(&self) -> u64 {
        self.store_id
    }

    /// One past the highest id this snapshot knows.
    pub fn len(&self) -> usize {
        self.spans.len()
    }

    pub fn is_empty(&self) -> bool {
        self.spans.is_empty()
    }

    fn text(&self, id: u32) -> Option<&str> {
        match self.spans.get(id as usize) {
            Some(&(s, e)) if s != GAP => Some(&self.buf[s as usize..e as usize]),
            _ => None,
        }
    }

    /// The text of `id`. An id this snapshot does not know resolves to `""`: the engine syncs the
    /// pool past every id it loads (`InternedFacts::name_bound`), so this only happens on a bug,
    /// and a wrong-but-harmless empty name beats taking the daemon down.
    pub fn resolve(&self, id: NameId) -> &str {
        let t = self.text(id.0);
        debug_assert!(t.is_some(), "name id {} unknown to a pool of {}", id.0, self.spans.len());
        t.unwrap_or("")
    }

    pub fn get(&self, s: &str) -> Option<NameId> {
        self.table.find(hash(s), |&id| self.text(id) == Some(s)).map(|&id| NameId(id))
    }

    /// The id of `s`, appending it if new. Only for pools that assign their own ids (tests, an
    /// in-memory index); a pool mirroring a store learns ids with `set`.
    pub fn intern(&mut self, s: &str) -> NameId {
        if let Some(id) = self.get(s) {
            return id;
        }
        let id = NameId(self.spans.len() as u32);
        self.set(id, s);
        id
    }

    /// Record that `id` names `s`, as the store says. Ids between the current end and `id` stay
    /// unknown until their own `set`.
    pub fn set(&mut self, id: NameId, s: &str) {
        let i = id.0 as usize;
        if i >= self.spans.len() {
            self.spans.resize(i + 1, (GAP, GAP));
        }
        if self.spans[i].0 != GAP {
            debug_assert_eq!(self.text(id.0), Some(s), "a store id never changes its name");
            return;
        }
        let start = self.buf.len() as u32;
        self.buf.push_str(s);
        self.spans[i] = (start, self.buf.len() as u32);
        let spans = &self.spans;
        let buf = &self.buf;
        self.table.insert_unique(hash(s), id.0, |&k| {
            let (s, e) = spans[k as usize];
            hash(&buf[s as usize..e as usize])
        });
    }

    /// Drop growth slack. The engine calls it on each new snapshot, which is then frozen.
    pub fn shrink_to_fit(&mut self) {
        self.buf.shrink_to_fit();
        self.spans.shrink_to_fit();
        let (spans, buf) = (&self.spans, &self.buf);
        self.table.shrink_to_fit(|&k| {
            let (s, e) = spans[k as usize];
            hash(&buf[s as usize..e as usize])
        });
    }

    /// Heap bytes held, for the memory budget.
    pub fn heap_bytes(&self) -> usize {
        self.buf.capacity() + self.spans.capacity() * std::mem::size_of::<(u32, u32)>() + self.table.capacity() * (4 + 1)
    }
}
