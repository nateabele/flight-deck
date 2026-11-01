//! What the graphs of one repository share: a file numbering and hash-consed per-file blocks.
//!
//! A cached graph is mostly per-file data: each file's resolution (`FileRes`: its imports, the
//! target of every reference, its file edges) and each file's name table. Graphs of nearby commits
//! compute most of those identically, so a repository keeps one `Share` and every graph built for
//! it hands its per-file results here to be *interned*: a result equal to one some live graph
//! already holds comes back as that graph's `Arc`, and only new results are kept. A graph is then
//! a vector of block pointers plus what is truly per view (path index, name index, incoming
//! references, PageRank).
//!
//! Blocks are keyed by **content**, not by the inputs that produced them. A reference resolved by
//! the unique-name fallback depends on every file of the view (a second definition anywhere
//! retracts it); keying by content makes that a non-issue, because a block whose fallback answer
//! changed simply has different content and is not shared. Nothing can serve a stale edge.
//!
//! Content equality only finds the sharing if the same file has the same index in both graphs:
//! a block names its targets by file index. A graph numbering its files 0..n by path shifts every
//! index after an added or removed path, and measured on 42 tessera worktrees only 24% of blocks
//! were then identical against 81% with a per-repository numbering. So file indices come from
//! `Share::layout`: a path keeps the index it first got, and a graph has a dead slot (a tombstone,
//! as `with_changes` already leaves) for every numbered path it does not contain.

use super::{FileRes, NameMap};
use crate::facts::InternedFacts;
use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex, Weak};

/// Dead slots a graph may carry, as a multiple of its live files. A numbering that has collected
/// this many times more paths than the largest graph laid out with it is restarted (a long-lived
/// daemon on a repository whose files churn), and a view this many times smaller than the
/// numbering (a sparse checkout, a four-file worktree) is laid out on its own, 0..n, so it does
/// not carry the whole repository's slots. Either way only sharing is lost, never correctness:
/// graphs laid out before keep their own numbering.
const MAX_SLACK: usize = 4;

#[derive(Default)]
struct Numbering {
    ids: HashMap<String, u32>,
    /// Live files of the largest graph laid out with this numbering.
    widest: usize,
}

impl Numbering {
    fn assign(&mut self, paths: &[&str]) -> Vec<u32> {
        paths
            .iter()
            .map(|p| match self.ids.get(*p) {
                Some(&i) => i,
                None => {
                    let i = self.ids.len() as u32;
                    self.ids.insert(p.to_string(), i);
                    i
                }
            })
            .collect()
    }
}

#[derive(Default)]
pub struct Share {
    paths: Mutex<Numbering>,
    blocks: Mutex<HashMap<u64, Vec<Weak<FileRes>>>>,
    /// Name tables by the address of the facts they index, with the facts held weakly so a
    /// reused address is recognised as another blob's.
    names: Mutex<HashMap<usize, NameEntry>>,
}

/// A name table and the facts it indexes, both weak.
type NameEntry = (Weak<InternedFacts>, Weak<NameMap>);

/// Distinct live blocks and name tables and their estimated heap bytes.
#[derive(Debug, Clone, Copy, Default)]
pub struct ShareStats {
    pub blocks: usize,
    pub block_bytes: usize,
    pub names: usize,
    pub name_bytes: usize,
}

impl Share {
    pub fn new() -> Share {
        Share::default()
    }

    /// The index of each of `paths` in this repository's numbering (assigning new paths the next
    /// free ones), and the slot count a graph of them needs.
    pub fn layout<'a>(&self, paths: impl ExactSizeIterator<Item = &'a str>) -> (Vec<u32>, usize) {
        let paths: Vec<&str> = paths.collect();
        let n = paths.len();
        let mut num = self.paths.lock().unwrap();
        if num.ids.len() > MAX_SLACK * n {
            return ((0..n as u32).collect(), n);
        }
        num.widest = num.widest.max(n);
        let mut ids = num.assign(&paths);
        if num.ids.len() > MAX_SLACK * num.widest {
            num.ids.clear();
            num.widest = n;
            ids = num.assign(&paths);
        }
        let slots = ids.iter().map(|&i| i as usize + 1).max().unwrap_or(0);
        (ids, slots)
    }

    /// The live block equal to `r`, or `r` itself, now shared.
    pub fn block(&self, mut r: FileRes) -> Arc<FileRes> {
        let mut h = DefaultHasher::new();
        r.hash(&mut h);
        let key = h.finish();
        let mut m = self.blocks.lock().unwrap();
        let bucket = m.entry(key).or_default();
        bucket.retain(|w| w.strong_count() > 0);
        if let Some(a) = bucket.iter().filter_map(Weak::upgrade).find(|a| **a == r) {
            return a;
        }
        r.edges.shrink_to_fit();
        let a = Arc::new(r);
        bucket.push(Arc::downgrade(&a));
        a
    }

    /// The name table of `facts` (name -> local ids), built once for every graph holding them.
    pub fn names(&self, facts: &Arc<InternedFacts>) -> Arc<NameMap> {
        let key = Arc::as_ptr(facts) as usize;
        let mut m = self.names.lock().unwrap();
        if let Some((f, n)) = m.get(&key)
            && f.upgrade().is_some_and(|f| Arc::ptr_eq(&f, facts))
            && let Some(n) = n.upgrade()
        {
            return n;
        }
        let n = Arc::new(super::name_map(facts));
        m.insert(key, (Arc::downgrade(facts), Arc::downgrade(&n)));
        n
    }

    /// Forget blocks and name tables no graph holds any more.
    pub fn prune(&self) {
        self.blocks.lock().unwrap().retain(|_, v| {
            v.retain(|w| w.strong_count() > 0);
            !v.is_empty()
        });
        self.names.lock().unwrap().retain(|_, (f, n)| f.strong_count() > 0 && n.strong_count() > 0);
    }

    pub fn stats(&self) -> ShareStats {
        let mut s = ShareStats::default();
        for a in self.blocks.lock().unwrap().values().flatten().filter_map(Weak::upgrade) {
            s.blocks += 1;
            s.block_bytes += block_bytes(&a);
        }
        for n in self.names.lock().unwrap().values().filter_map(|(_, n)| n.upgrade()) {
            s.names += 1;
            s.name_bytes += super::name_map_bytes(&n);
        }
        s
    }
}

/// Estimated heap bytes of one block (its vectors, the strings they own, the `Arc` header).
pub fn block_bytes(r: &FileRes) -> usize {
    use crate::resolve::Resolved;
    use std::mem::size_of;
    const ALLOC: usize = 16;
    let mut n = size_of::<FileRes>() + 16 + 3 * ALLOC;
    n += r.refs.capacity() * size_of::<super::RefRes>() + r.imports.capacity() * size_of::<Resolved>() + r.edges.capacity() * 4;
    n += r
        .imports
        .iter()
        .map(|x| match x {
            Resolved::File { path, rest } => path.len() + ALLOC + rest.iter().map(|s| s.len() + ALLOC).sum::<usize>(),
            Resolved::External(p) => p.as_os_str().len() + ALLOC,
            Resolved::Unresolved => 0,
        })
        .sum::<usize>();
    n += r.refs.iter().filter_map(|x| x.external.as_deref()).map(|v| ALLOC + v.iter().map(|t| t.path.as_os_str().len() + t.name.len() + 2 * ALLOC).sum::<usize>()).sum::<usize>();
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(prefix: &str, n: usize) -> Vec<String> {
        (0..n).map(|i| format!("{prefix}{i}")).collect()
    }

    #[test]
    fn a_path_keeps_its_index_when_others_appear_and_go() {
        let s = Share::new();
        let (a, slots) = s.layout(["b", "c", "d"].into_iter());
        assert_eq!((a, slots), (vec![0, 1, 2], 3));
        let (b, slots) = s.layout(["a", "b", "d"].into_iter());
        assert_eq!((b, slots), (vec![3, 0, 2], 4), "c's slot stays empty, a is appended");
    }

    #[test]
    fn a_view_much_smaller_than_the_numbering_is_laid_out_on_its_own() {
        let s = Share::new();
        let big = names("f", 100);
        s.layout(big.iter().map(String::as_str));
        let (ids, slots) = s.layout(["f7", "zz"].into_iter());
        assert_eq!((ids, slots), (vec![0, 1], 2));
        // The numbering itself is untouched.
        assert_eq!(s.layout(big.iter().map(String::as_str)).0[7], 7);
    }

    #[test]
    fn a_numbering_that_outgrows_its_views_restarts() {
        let s = Share::new();
        for round in 0..5 {
            let files = names(&format!("r{round}-"), 50);
            let (_, slots) = s.layout(files.iter().map(String::as_str));
            assert!(slots <= MAX_SLACK * 50, "round {round}: {slots} slots for 50 files");
        }
    }
}
