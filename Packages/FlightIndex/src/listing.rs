//! A commit's file listing, searchable by path without copying it.
//!
//! Every worktree on one commit shares its listing (`View::base`, an `Arc`), but a *kept* view
//! (one the daemon follows between requests, see `service::Freshness`) used to build two maps of
//! its own over it: the base index `refresh` asks "is this path in git?" (path -> `FileRef`, a
//! second copy of every path and blob id) and the stat snapshot `sweep` compares (path -> stat, a
//! third copy of every path). On tessera that was 1.2 MB a worktree, 93 MB for 85 worktrees, to
//! answer lookups the shared listing can answer itself by binary search.
//!
//! A listing from `git ls-tree` is in git's order, which for full paths is byte order, and one
//! derived from a previous commit's is sorted explicitly; `Listing` checks rather than trusts that
//! and keeps a sorted permutation (4 bytes a file) for a listing that is not.

use crate::git::FileRef;
use std::sync::Arc;

#[derive(Clone)]
pub struct Listing {
    files: Arc<Vec<FileRef>>,
    /// Positions in `files` in path order, when `files` itself is not sorted by path.
    order: Option<Arc<[u32]>>,
}

impl Listing {
    pub fn new(files: Arc<Vec<FileRef>>) -> Listing {
        let order = if files.is_sorted_by(|a, b| a.path < b.path) {
            None
        } else {
            let mut o: Vec<u32> = (0..files.len() as u32).collect();
            o.sort_by(|a, b| files[*a as usize].path.cmp(&files[*b as usize].path));
            Some(o.into())
        };
        Listing { files, order }
    }

    pub fn len(&self) -> usize {
        self.files.len()
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    pub fn files(&self) -> &[FileRef] {
        &self.files
    }

    /// The `i`-th file in path order.
    fn sorted(&self, i: usize) -> usize {
        match &self.order {
            Some(o) => o[i] as usize,
            None => i,
        }
    }

    /// The position in `files()` of `path`.
    pub fn find(&self, path: &str) -> Option<usize> {
        let (mut lo, mut hi) = (0, self.files.len());
        while lo < hi {
            let mid = (lo + hi) / 2;
            match self.files[self.sorted(mid)].path.as_str().cmp(path) {
                std::cmp::Ordering::Less => lo = mid + 1,
                std::cmp::Ordering::Greater => hi = mid,
                std::cmp::Ordering::Equal => return Some(self.sorted(mid)),
            }
        }
        None
    }

    pub fn get(&self, path: &str) -> Option<&FileRef> {
        self.find(path).map(|i| &self.files[i])
    }

    /// The paths that start with `prefix`, in path order.
    pub fn with_prefix<'a>(&'a self, prefix: &'a str) -> impl Iterator<Item = &'a str> + 'a {
        let n = self.files.len();
        let path = move |i: usize| self.files[self.sorted(i)].path.as_str();
        let (mut lo, mut hi) = (0, n);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if path(mid) < prefix { lo = mid + 1 } else { hi = mid }
        }
        (lo..n).map(path).take_while(move |p| p.starts_with(prefix))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listing(paths: &[&str]) -> Listing {
        Listing::new(Arc::new(paths.iter().map(|p| FileRef { path: p.to_string(), blob_id: format!("b-{p}"), language: "typescript" }).collect()))
    }

    #[test]
    fn finds_paths_and_prefixes_in_a_sorted_listing() {
        // Byte order, which is git's for full paths: `-` sorts before `/`.
        let l = listing(&["a.ts", "b-e.ts", "b/c.ts", "b/d.ts", "z.ts"]);
        assert!(l.order.is_none());
        assert_eq!(l.find("b/d.ts"), Some(3));
        assert_eq!(l.get("z.ts").map(|f| f.blob_id.as_str()), Some("b-z.ts"));
        assert_eq!(l.find("b"), None);
        assert_eq!(l.with_prefix("b/").collect::<Vec<_>>(), ["b/c.ts", "b/d.ts"]);
        assert_eq!(l.with_prefix("q/").count(), 0);
    }

    #[test]
    fn an_unsorted_listing_is_searched_through_a_permutation() {
        let l = listing(&["z.ts", "b/d.ts", "a.ts", "b/c.ts"]);
        assert!(l.order.is_some());
        assert_eq!(l.find("a.ts"), Some(2));
        assert_eq!(l.find("b/c.ts"), Some(3));
        assert_eq!(l.find("zz.ts"), None);
        assert_eq!(l.with_prefix("b/").collect::<Vec<_>>(), ["b/c.ts", "b/d.ts"]);
    }
}
