//! What `impact` would otherwise derive from the whole graph on every call, kept with the graph.
//!
//! Profiled through the daemon on tessera (`interop/src/index.ts`, `designer/src/Main.elm`), the
//! tool itself took 1.5 / 2.3 ms a call (p50), and most of it was not the ranking: the tests group
//! named a test by its file name only after scanning all ~4,800 live files twice, deriving each
//! one's source key and test subject (1.0-1.3 ms), and every co-change partner was looked up by
//! path in the view after the ranking (0.06-0.15 ms, more with many partners). Both depend only on
//! the graph (and, for partners, on the repository's co-change at its HEAD), so they are built
//! once, and the tool takes 0.45 / 1.2 ms. What is left is per-request bookkeeping of the importer
//! lists and reasons, which this does not touch:
//!
//! - the name tables, on the first `impact` of a graph: how many live non-test files of each
//!   language share a source key, and the live test files whose name gives each subject;
//! - each seed's partners among the view's files, with the commits that touched the seed, the
//!   first time that seed is asked about under one co-change.
//!
//! A graph's data never changes after it is built, so neither table can go stale within one
//! graph. A derived graph (`with_changes`, a rebuild) starts without them (`GraphData` resets the
//! slot), and the partner memo is tied to the `CoChange` it was read from, so a HEAD move that
//! replaces the co-change leaves the old memo unused.

use super::impact::{self, Partner};
use super::is_test_path;
use crate::cochange::CoChange;
use crate::graph::GraphData;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, Weak};

type Key = (String, &'static str);
/// The co-change a memo was read from, and each seed's partners under it.
type Memo = (Weak<CoChange>, HashMap<String, Arc<SeedPartners>>);

/// One seed's co-change partners that the view has, at least `MIN_SUPPORT` commits each, in
/// `CoChange::partners_of` order (most commits first, then path), with `touches(seed)`.
#[derive(Debug, Default)]
pub struct SeedPartners {
    pub of: u32,
    pub partners: Vec<(String, u32)>,
}

pub struct ImpactIndex {
    /// (source key, language) -> live non-test files with that key.
    sources: HashMap<Key, u32>,
    /// (test subject, language) -> live test files whose name gives it, ascending.
    tests: HashMap<Key, Vec<u32>>,
    partners: Mutex<Memo>,
}

impl ImpactIndex {
    pub fn build(g: &GraphData) -> ImpactIndex {
        Self::from_files(g.files.iter().enumerate().filter(|(_, f)| f.alive).map(|(i, f)| (i as u32, f.path.as_str(), f.language)))
    }

    /// From the live files as (index, path relative to the root, language).
    pub fn from_files<'a>(files: impl Iterator<Item = (u32, &'a str, &'static str)>) -> ImpactIndex {
        let mut sources: HashMap<Key, u32> = HashMap::new();
        let mut tests: HashMap<Key, Vec<u32>> = HashMap::new();
        for (i, path, language) in files {
            if !is_test_path(path) {
                *sources.entry((impact::source_key(path), language)).or_default() += 1;
            } else if let Some(subject) = impact::test_subject(path) {
                tests.entry((subject, language)).or_default().push(i);
            }
        }
        for v in tests.values_mut() {
            v.sort_unstable();
        }
        ImpactIndex { sources, tests, partners: Mutex::new((Weak::new(), HashMap::new())) }
    }

    /// The test files whose name names one of `seeds` (each given as its source key and language),
    /// in file order, each once, but `except`. A stem such as `index` or `types` names many
    /// sources; a test is matched by name only when its subject is unique among the sources of
    /// that language.
    pub fn name_matches(&self, seeds: &[Key], except: u32) -> Vec<u32> {
        let mut out: Vec<u32> = Vec::new();
        for k in seeds {
            if self.sources.get(k) == Some(&1) {
                out.extend(self.tests.get(k).into_iter().flatten().filter(|i| **i != except));
            }
        }
        out.sort_unstable();
        out.dedup();
        out
    }

    /// `seed`'s partners among the files `has` admits, read from `co` once per seed.
    pub fn partners(&self, co: &Arc<CoChange>, seed: &str, has: impl Fn(&str) -> bool) -> Arc<SeedPartners> {
        let mut m = self.partners.lock().unwrap_or_else(|e| e.into_inner());
        if !Weak::ptr_eq(&m.0, &Arc::downgrade(co)) {
            *m = (Arc::downgrade(co), HashMap::new());
        }
        m.1.entry(seed.to_string())
            .or_insert_with(|| {
                let partners = co.partners_of(seed, impact::MIN_SUPPORT).into_iter().filter(|(p, _)| has(p)).map(|(p, n)| (p.to_string(), n)).collect();
                Arc::new(SeedPartners { of: co.touches(seed), partners })
            })
            .clone()
    }
}

/// `impact::ranked_partners` over the view's files, from each seed's memoised partners: the same
/// rows in the same order, since whether a file is in the view does not depend on the ranking.
pub fn ranked_partners(index: &ImpactIndex, co: &Arc<CoChange>, seeds: &[&str], has: impl Fn(&str) -> bool) -> Vec<Partner> {
    let lists: Vec<(&str, Arc<SeedPartners>)> = seeds.iter().map(|s| (*s, index.partners(co, s, &has))).collect();
    impact::rank_partner_lists(lists.iter().map(|(s, p)| (*s, p.of, p.partners.iter().map(|(path, n)| (path.as_str(), *n)))), seeds)
}

/// Whether the view has `path` (relative to its root).
pub fn has_file(g: &GraphData, path: &str) -> bool {
    g.index.contains_key(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn log(commits: &[&[&str]]) -> String {
        commits.iter().map(|c| format!("\x01\n{}\n", c.join("\n"))).collect()
    }

    fn index(paths: &[&'static str]) -> ImpactIndex {
        ImpactIndex::from_files(paths.iter().enumerate().map(|(i, p)| (i as u32, *p, "rust")))
    }

    #[test]
    fn memoised_partners_rank_as_the_uncached_ranking_filtered_to_the_view() {
        // Partners of two seeds with ties, a file outside the view and a seed partnering a seed.
        let co = Arc::new(CoChange::from_log(&log(&[
            &["a.rs", "x.rs", "gone.rs"],
            &["a.rs", "x.rs", "gone.rs"],
            &["a.rs", "y.rs", "z.rs"],
            &["a.rs", "y.rs", "z.rs", "b.rs"],
            &["a.rs", "b.rs"],
            &["b.rs", "x.rs"],
            &["b.rs", "x.rs"],
            &["b.rs", "w.rs"],
            &["b.rs", "w.rs"],
        ])));
        let idx = index(&["a.rs", "b.rs", "x.rs", "y.rs", "z.rs", "w.rs"]);
        let has = |p: &str| p != "gone.rs";
        for seeds in [&["a.rs"][..], &["b.rs"], &["a.rs", "b.rs"], &["b.rs", "a.rs"], &["nowhere.rs", "a.rs"]] {
            let want: Vec<Partner> = impact::ranked_partners(&co, seeds, impact::MIN_SUPPORT).into_iter().filter(|p| has(&p.path)).collect();
            assert_eq!(ranked_partners(&idx, &co, seeds, has), want, "{seeds:?}");
            assert_eq!(ranked_partners(&idx, &co, seeds, has), want, "the memoised second call, {seeds:?}");
        }
    }

    #[test]
    fn a_new_co_change_replaces_the_memo() {
        let idx = index(&["a.rs", "x.rs", "y.rs"]);
        let old = Arc::new(CoChange::from_log(&log(&[&["a.rs", "x.rs"], &["a.rs", "x.rs"]])));
        assert_eq!(idx.partners(&old, "a.rs", |_| true).partners, [("x.rs".to_string(), 2)]);
        let new = Arc::new(CoChange::from_log(&log(&[&["a.rs", "y.rs"], &["a.rs", "y.rs"], &["a.rs", "y.rs"]])));
        let p = idx.partners(&new, "a.rs", |_| true);
        assert_eq!((p.of, &p.partners[..]), (3, &[("y.rs".to_string(), 3)][..]));
    }

    #[test]
    fn name_matches_need_a_unique_source_and_come_in_file_order_once() {
        let idx = index(&["src/node.rs", "tests/node_test.rs", "src/types.rs", "lib/types.rs", "tests/types_test.rs", "tests/test_node.rs", "src/edit.rs", "tests/edit_test.rs"]);
        let key = |s: &str| (impact::source_key(s), "rust");
        assert_eq!(idx.name_matches(&[key("src/node.rs")], u32::MAX), [1, 5]);
        assert_eq!(idx.name_matches(&[key("src/types.rs")], u32::MAX), Vec::<u32>::new(), "two sources named types");
        assert_eq!(idx.name_matches(&[key("src/edit.rs"), key("src/node.rs"), key("src/node.rs")], 5), [1, 7]);
        assert_eq!(idx.name_matches(&[(impact::source_key("src/node.rs"), "python")], u32::MAX), Vec::<u32>::new(), "another language");
    }
}
