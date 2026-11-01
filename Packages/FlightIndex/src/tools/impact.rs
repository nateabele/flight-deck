//! How `impact` ranks: static importers and co-change partners interleaved, plus the tests that
//! go with the seed.
//!
//! Gethers et al. (ICSE 2012) combined impact analyses that each start from one seed by taking
//! N/2 results from each, not by merging scores; on ArgoUML at top-5 that took precision/recall
//! from 7/4 (one source) to 15/14 (two). A blended score needs weights that suit one repository and
//! not the next, and a raw union lets the longer list (a core file's hundreds of importers) crowd
//! the other out. So `impact` alternates: the next unseen importer, then the next unseen co-change
//! partner, and a file both lists name appears once, at its first position, with both reasons.
//! When one list runs dry the other fills the rest. Any prefix of the result holds about half of
//! each, so whatever cap the output applies keeps the split.
//!
//! Tests are a separate, uncapped group. A test is rarely an importer worth reading first, but
//! the agent needs every one that exercises the seed. Linking by name alone is precise but finds
//! few (100% precision, 11% recall, as cited in ReAssert, arXiv 2011.09784), so name matches come
//! first, then tests that import the seed, then tests that co-change with it.

use crate::cochange::CoChange;
use std::collections::{HashMap, HashSet};
use std::hash::Hash;

/// Co-change partners need at least this many shared commits: one shared commit is a
/// coincidence, and with it every file edited once beside the seed would rank at confidence 1.
pub const MIN_SUPPORT: u32 = 2;

/// Alternate `a` and `b`, skipping what is already taken, until both are exhausted.
pub fn interleave<K: Clone + Eq + Hash>(a: &[K], b: &[K]) -> Vec<K> {
    let mut seen: HashSet<&K> = HashSet::new();
    let mut out = Vec::with_capacity(a.len() + b.len());
    let (mut ia, mut ib) = (a.iter(), b.iter());
    loop {
        let mut took = false;
        for it in [&mut ia, &mut ib] {
            for k in it.by_ref() {
                if seen.insert(k) {
                    out.push(k.clone());
                    took = true;
                    break;
                }
            }
        }
        if !took {
            return out;
        }
    }
}

/// A co-change partner of the seeds, with the counts behind its confidence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Partner {
    pub path: String,
    /// Commits that touched the partner and `seed`.
    pub together: u32,
    /// Commits that touched `seed`: confidence is `together / of`.
    pub of: u32,
    /// The seed that gave the partner its best confidence.
    pub seed: String,
}

/// Partners of any seed, by the best confidence `P(partner changed | seed changed)` over the seeds,
/// then by support, then by path. Seeds are not their own partners.
pub fn ranked_partners(co: &CoChange, seeds: &[&str], min_support: u32) -> Vec<Partner> {
    // Best confidence over the seeds, not the sum: scored with the eval harness (an agent that
    // edited one gold file asks about another), summing and putting the asked file's partners
    // first were within a point of it at P@5 and R@10 on tessera and flight-deck, and the best
    // seed's fraction is the one a row can show.
    let mut best: HashMap<&str, Partner> = HashMap::new();
    for seed in seeds {
        let of = co.touches(seed);
        for (path, together) in co.partners_of(seed, min_support) {
            if seeds.contains(&path) {
                continue;
            }
            let p = Partner { path: path.to_string(), together, of, seed: seed.to_string() };
            match best.get(path) {
                Some(old) if !better(&p, old) => {}
                _ => {
                    best.insert(path, p);
                }
            }
        }
    }
    let mut out: Vec<Partner> = best.into_values().collect();
    out.sort_by(|a, b| if better(a, b) { std::cmp::Ordering::Less } else if better(b, a) { std::cmp::Ordering::Greater } else { a.path.cmp(&b.path) });
    out
}

/// Higher confidence, then more support. Compared as integers (`a.t/a.o > b.t/b.o` iff
/// `a.t*b.o > b.t*a.o`) so equal fractions such as 2/4 and 1/2 tie exactly.
fn better(a: &Partner, b: &Partner) -> bool {
    let (x, y) = (a.together as u64 * b.of.max(1) as u64, b.together as u64 * a.of.max(1) as u64);
    x > y || (x == y && a.together > b.together)
}

/// The lowercase file stem, without its extensions: `src/Expression/Node.elm` -> `node`.
fn stem(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.split('.').next().unwrap_or(name).to_ascii_lowercase()
}

/// What a test file's name says it tests: the stem with the test markers removed.
/// `InfraServiceTests.swift`, `infra_service_test.rs`, `test_infra_service.py`, `infraService.spec.ts`
/// all give the same key as `InfraService.swift` would through `source_key`.
pub fn test_subject(path: &str) -> Option<String> {
    let name = path.rsplit('/').next().unwrap_or(path);
    let mut s = name.split('.').next().unwrap_or(name);
    // Markers are matched with their case or separator: a lowercase `test` suffix alone would
    // turn `contest.rs` into a test of `con.rs`.
    for p in ["test_", "test-"] {
        if let Some(rest) = s.strip_prefix(p) {
            s = rest;
            break;
        }
    }
    for suf in ["Tests", "Test", "Specs", "Spec", "_tests", "_test", "_specs", "_spec", "-tests", "-test", "-spec"] {
        if let Some(rest) = s.strip_suffix(suf) {
            s = rest;
            break;
        }
    }
    let key = s.to_ascii_lowercase().replace(['_', '-'], "");
    (!key.is_empty() && key != "test" && key != "tests" && key != "spec").then_some(key)
}

/// The key a source file is matched on: its stem, lowercase, without `_`/`-`.
pub fn source_key(path: &str) -> String {
    stem(path).replace(['_', '-'], "")
}

/// Why a file is in the ranked list or the tests group, in the order the reasons were found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Why {
    NameMatch,
    Importer { depth: u32 },
    /// `with` names the seed when it is a file of the worktree diff, not the file asked about.
    CoChanged { together: u32, of: u32, with: Option<String> },
}

impl Why {
    pub fn label(&self) -> String {
        match self {
            Why::NameMatch => "name match".into(),
            Why::Importer { depth } => format!("importer depth {depth}"),
            Why::CoChanged { together, of, with: None } => format!("co-changed {together}/{of}"),
            Why::CoChanged { together, of, with: Some(seed) } => format!("co-changed {together}/{of} with {seed}"),
        }
    }
}

/// Reasons keyed by file.
#[derive(Default)]
pub struct Reasons<K: Eq + Hash> {
    by: HashMap<K, Vec<Why>>,
}

impl<K: Eq + Hash + Clone> Reasons<K> {
    pub fn add(&mut self, k: &K, why: Why) {
        let v = self.by.entry(k.clone()).or_default();
        if !v.contains(&why) {
            v.push(why);
        }
    }
    /// The reasons, name match first, then importer, then co-change, whatever order they were
    /// found in: a row reads the same in the ranked list and the tests group.
    pub fn label(&self, k: &K) -> String {
        let Some(v) = self.by.get(k) else { return String::new() };
        let mut v: Vec<&Why> = v.iter().collect();
        v.sort_by_key(|w| match w {
            Why::NameMatch => 0,
            Why::Importer { .. } => 1,
            Why::CoChanged { .. } => 2,
        });
        v.iter().map(|w| w.label()).collect::<Vec<_>>().join("; ")
    }
}

/// The tests linked to the seeds, in the order the group lists them: name matches, then tests that
/// import a seed (`importers`, in their order), then tests that co-change with one (`partners`).
/// `name_matches` are the test files whose name names a seed. Each list may repeat a file another
/// already gave; it is listed once, with every reason.
pub fn order_tests<K: Clone + Eq + Hash>(name_matches: &[K], importers: &[(K, u32)], partners: &[(K, Why)], reasons: &mut Reasons<K>) -> Vec<K> {
    let mut seen: HashSet<K> = HashSet::new();
    let mut out = Vec::new();
    for k in name_matches {
        reasons.add(k, Why::NameMatch);
        if seen.insert(k.clone()) {
            out.push(k.clone());
        }
    }
    for (k, depth) in importers {
        reasons.add(k, Why::Importer { depth: *depth });
        if seen.insert(k.clone()) {
            out.push(k.clone());
        }
    }
    for (k, why) in partners {
        reasons.add(k, why.clone());
        if seen.insert(k.clone()) {
            out.push(k.clone());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interleave_alternates_dedupes_and_lets_the_longer_list_fill() {
        let a = ["i1", "i2", "both", "i3", "i4"];
        let b = ["c1", "both", "c2"];
        assert_eq!(interleave(&a, &b), ["i1", "c1", "i2", "both", "i3", "c2", "i4"]);
        assert_eq!(interleave::<&str>(&[], &["c1"]), ["c1"]);
        // Any prefix holds about half of each: the first 4 of a long importer list and a long
        // co-change list are two and two.
        let a: Vec<String> = (0..50).map(|i| format!("i{i}")).collect();
        let b: Vec<String> = (0..50).map(|i| format!("c{i}")).collect();
        let head = interleave(&a, &b);
        assert_eq!(head.iter().take(4).filter(|k| k.starts_with('c')).count(), 2);
    }

    fn log(commits: &[&[&str]]) -> String {
        commits.iter().map(|c| format!("\x01\n{}\n", c.join("\n"))).collect()
    }

    #[test]
    fn partners_rank_by_confidence_not_raw_count() {
        // `busy.rs` changes in 10 commits, 3 with `seed.rs`; `rare.rs` changes with `seed.rs` in
        // both of its 2. Confidence is about the seed, so the denominator is touches(seed) = 5,
        // and `busy.rs` (3/5) outranks `rare.rs` (2/5); `once.rs` (1/5) lacks support.
        let mut commits: Vec<Vec<&str>> = vec![
            vec!["seed.rs", "busy.rs"],
            vec!["seed.rs", "busy.rs"],
            vec!["seed.rs", "busy.rs", "rare.rs"],
            vec!["seed.rs", "rare.rs", "once.rs"],
            vec!["seed.rs"],
        ];
        for _ in 0..7 {
            commits.push(vec!["busy.rs"]);
        }
        let commits: Vec<&[&str]> = commits.iter().map(Vec::as_slice).collect();
        let co = CoChange::from_log(&log(&commits));
        let p = ranked_partners(&co, &["seed.rs"], MIN_SUPPORT);
        let got: Vec<(&str, u32, u32)> = p.iter().map(|p| (p.path.as_str(), p.together, p.of)).collect();
        assert_eq!(got, [("busy.rs", 3, 5), ("rare.rs", 2, 5)]);
    }

    #[test]
    fn partners_of_several_seeds_take_each_files_best_confidence_and_skip_the_seeds() {
        // `x.rs` co-changes with `a.rs` 2/5 and with `b.rs` 2/2: it ranks at 2/2 via `b.rs`.
        let co = CoChange::from_log(&log(&[&["a.rs", "x.rs"], &["a.rs", "x.rs"], &["a.rs", "y.rs"], &["a.rs", "y.rs"], &["a.rs"], &["b.rs", "x.rs"], &["b.rs", "x.rs"]]));
        let p = ranked_partners(&co, &["a.rs", "b.rs"], MIN_SUPPORT);
        let got: Vec<(&str, u32, u32, &str)> = p.iter().map(|p| (p.path.as_str(), p.together, p.of, p.seed.as_str())).collect();
        assert_eq!(got, [("x.rs", 2, 2, "b.rs"), ("y.rs", 2, 5, "a.rs")]);
    }

    #[test]
    fn a_test_files_name_gives_the_source_key_it_tests() {
        for t in [
            "Tests/FlightDeckTests/InfraServiceTests.swift",
            "Tests/InfraServiceTest.swift",
            "src/infra_service_test.rs",
            "tests/test_infra_service.py",
            "web/infraService.spec.ts",
            "web/infra-service.test.ts",
            "tests/InfraServiceSpec.elm",
        ] {
            assert_eq!(test_subject(t).as_deref(), Some("infraservice"), "{t}");
        }
        assert_eq!(source_key("Sources/FlightDeck/Infra/InfraService.swift"), "infraservice");
        assert_eq!(source_key("src/infra_service.rs"), "infraservice");
        // A file under `tests/` with no marker in its name tests the source of the same name.
        assert_eq!(test_subject("tests/service.rs").as_deref(), Some("service"));
        // A test file with nothing left after the markers names no source.
        assert_eq!(test_subject("tests/test.rs"), None);
    }

    fn co(together: u32, of: u32) -> Why {
        Why::CoChanged { together, of, with: None }
    }

    #[test]
    fn tests_are_ordered_name_import_cochange_once_each_with_every_reason() {
        let mut r = Reasons::default();
        // Found as a co-change partner before the group asked: still labelled name match first.
        r.add(&"t_name", co(4, 5));
        let order = order_tests(&["t_name"], &[("t_imp", 1), ("t_name", 1)], &[("t_co", co(3, 5)), ("t_imp", co(2, 5))], &mut r);
        assert_eq!(order, ["t_name", "t_imp", "t_co"]);
        assert_eq!(r.label(&"t_name"), "name match; importer depth 1; co-changed 4/5");
        assert_eq!(r.label(&"t_imp"), "importer depth 1; co-changed 2/5");
    }
}
