//! The trigram index's release gate: for random corpora and random regexes, the blobs the index
//! keeps as candidates include every blob brute force finds a matching line in, so a search that
//! verifies only the candidates returns exactly the brute-force answer.
//!
//! Brute force is the body search's own rule: the case-insensitive regex against each line of
//! `str::lines()`.

use flightindex::git::blob_id;
use flightindex::trigram::{plan, RepoIndex};
use std::collections::BTreeSet;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn pick<'a>(&mut self, v: &[&'a str]) -> &'a str {
        v[self.below(v.len())]
    }
}

/// Code-like tokens, with the case-folding traps: the Kelvin sign and long s fold with ASCII `k`
/// and `s`; `é`/`É` fold with each other but not with ASCII.
const TOKENS: &[&str] = &[
    "foo", "bar", "Baz", "needle", "NEEDLE", "Needle", "fn", "let", "x", "_", "::", "(", ")", "{", "}", " ", " ", "\n", "\r\n", "\t", "0", "42", "é",
    "É", "\u{212A}", "ſ", "k", "s", "S", "struct", "Struct", "impl", "self", "->", "=>", "//", "\"", ".", "*", "+", "?", "[", "]", "|", "^", "$", "\\",
    "KEY", "kEy", "sk", "\u{212A}ey", "ſelf", "Shell",
];

fn doc(r: &mut Rng) -> String {
    (0..r.below(40)).map(|_| r.pick(TOKENS)).collect()
}

/// A random substring of `s` on character boundaries.
fn slice(r: &mut Rng, s: &str) -> String {
    let idx: Vec<usize> = s.char_indices().map(|(i, _)| i).chain(std::iter::once(s.len())).collect();
    let a = idx[r.below(idx.len())];
    let b = idx[r.below(idx.len())];
    let (a, b) = (a.min(b), a.max(b));
    s[a..b].to_string()
}

const ATOMS: &[&str] = &[".", r"\w", r"\d", r"\s", "[a-f]", "[xyz]", "[^a]", "[Kk]", "[éÉ]", r"\b", "^", "$", "[_:]", r"\S+", r"[A-Z]"];
const REPS: &[&str] = &["*", "+", "?", "{2}", "{1,3}", "{0,2}", "*?"];

fn regex(r: &mut Rng, docs: &[String], depth: u32) -> String {
    match if depth == 0 { r.below(3) } else { r.below(7) } {
        0 => {
            let d = &docs[r.below(docs.len())];
            regex::escape(&slice(r, d))
        }
        1 => regex::escape(r.pick(TOKENS)),
        2 => r.pick(ATOMS).to_string(),
        3 => (0..1 + r.below(4)).map(|_| regex(r, docs, depth - 1)).collect(),
        4 => format!("{}|{}", regex(r, docs, depth - 1), regex(r, docs, depth - 1)),
        5 => format!("(?:{}){}", regex(r, docs, depth - 1), r.pick(REPS)),
        _ => format!("({})", regex(r, docs, depth - 1)),
    }
}

fn brute(re: &regex::Regex, docs: &[String]) -> BTreeSet<usize> {
    docs.iter().enumerate().filter(|(_, d)| d.lines().any(|l| re.is_match(l))).map(|(i, _)| i).collect()
}

/// Patterns agents send, which must hold whatever the random grammar draws.
const TYPICAL: &[&str] = &[
    "needle", r"fn\s+\w+", r"self\.\w+", "struct (Baz|Foo)", r"impl.*for", "key", "KEY", r"foo\(", "bar|baz", r"\bself\b", "ſelf", "shell", "é",
    r"needle\s*=>", r"^\s*let", r"x{2,}", "[Kk]ey", r"(?-i)Needle", r"(?i)NEEDLE", "[^a-z]needle",
];

#[test]
fn indexed_candidates_never_miss_a_brute_force_match() {
    let mut r = Rng(0x9e37_79b9_7f4a_7c15);
    let mut cases = 0usize;
    let mut ruled_out = 0usize;
    for corpus in 0..24 {
        let dir = tempfile::tempdir().unwrap();
        let idx = RepoIndex::open(&dir.path().join("t.tri"));
        let mut docs: Vec<String> = (0..60).map(|_| doc(&mut r)).collect();
        docs.sort();
        docs.dedup();
        let ids: Vec<String> = docs.iter().map(|d| blob_id(d.as_bytes())).collect();
        // Three deltas, so a query reads across segments; every other corpus is then merged.
        for part in docs.chunks(docs.len().div_ceil(3)).zip(ids.chunks(docs.len().div_ceil(3))) {
            let items: Vec<(&str, Vec<u8>)> = part.1.iter().map(String::as_str).zip(part.0.iter().map(|d| d.as_bytes().to_vec())).collect();
            idx.add(&items).unwrap();
        }
        assert!(idx.snapshot().segments() >= 2, "corpus {corpus} has deltas");
        if corpus % 2 == 1 {
            idx.merge().unwrap();
            assert_eq!(idx.snapshot().segments(), 1);
        }
        let snap = idx.snapshot();
        let ordinal: Vec<u32> = ids.iter().map(|id| snap.ordinal(id).expect("every doc indexed")).collect();
        let mut patterns: Vec<String> = TYPICAL.iter().map(|s| s.to_string()).collect();
        patterns.extend((0..250).map(|_| regex(&mut r, &docs, 3)));
        for p in patterns {
            let Ok(re) = regex::RegexBuilder::new(&p).case_insensitive(true).build() else { continue };
            let q = plan(&p).unwrap_or_else(|e| panic!("{p:?} compiles but does not plan: {e}"));
            let want = brute(&re, &docs);
            let got: BTreeSet<usize> = match snap.candidates(&q) {
                None => (0..docs.len()).collect(),
                Some(bits) => (0..docs.len()).filter(|&i| bits.contains(ordinal[i])).collect(),
            };
            let missed: Vec<&String> = want.difference(&got).map(|&i| &docs[i]).collect();
            assert!(missed.is_empty(), "pattern {p:?} plan {q:?} misses {missed:?}");
            let verified: BTreeSet<usize> = got.iter().copied().filter(|&i| docs[i].lines().any(|l| re.is_match(l))).collect();
            assert_eq!(verified, want, "{p:?}");
            ruled_out += docs.len() - got.len();
            cases += 1;
        }
    }
    assert!(cases > 5000, "{cases} cases");
    // The gate is only worth something if the index rules blobs out at all.
    assert!(ruled_out > cases, "the index ruled out {ruled_out} blobs over {cases} cases");
}

#[test]
fn reopening_reads_the_same_chain_and_drops_leftovers() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("t.tri");
    let docs = ["fn needle() {}", "let haystack = 1;", "needle again"];
    let ids: Vec<String> = docs.iter().map(|d| blob_id(d.as_bytes())).collect();
    {
        let idx = RepoIndex::open(&path);
        idx.add(&[(ids[0].as_str(), docs[0].as_bytes().to_vec())]).unwrap();
        idx.add(&[(ids[1].as_str(), docs[1].as_bytes().to_vec()), (ids[2].as_str(), docs[2].as_bytes().to_vec())]).unwrap();
    }
    // A merge that died after writing its base: the new base wins, the old chain is ignored.
    std::fs::write(path.join("seg-000099.tri.tmp"), b"half").unwrap();
    let idx = RepoIndex::open(&path);
    let snap = idx.snapshot();
    assert_eq!((snap.blobs(), snap.segments()), (3, 2));
    let bits = snap.candidates(&plan("needle").unwrap()).unwrap();
    let hit: Vec<u32> = bits.iter().collect();
    assert_eq!(hit, vec![snap.ordinal(&ids[0]).unwrap(), snap.ordinal(&ids[2]).unwrap()]);
    idx.merge().unwrap();
    let again = RepoIndex::open(&path);
    assert_eq!((again.snapshot().blobs(), again.snapshot().segments()), (3, 1));
    assert_eq!(again.snapshot().ordinal(&ids[2]), snap.ordinal(&ids[2]), "ordinals survive a merge");
    // Adding a blob already indexed changes nothing.
    again.add(&[(ids[1].as_str(), docs[1].as_bytes().to_vec())]).unwrap();
    assert_eq!(again.snapshot().blobs(), 3);
}

#[test]
fn a_blob_the_writer_cannot_index_is_not_queued_again() {
    use std::sync::Arc;
    let repo = tempfile::tempdir().unwrap();
    let git = |args: &[&str]| assert!(std::process::Command::new("git").args(args).current_dir(repo.path()).output().unwrap().status.success());
    git(&["init", "-q"]);
    let small = "fn needle() {}\n";
    std::fs::write(repo.path().join("a.rs"), small).unwrap();
    git(&["add", "a.rs"]);
    let small_id = blob_id(small.as_bytes());
    let missing = "0123456789012345678901234567890123456789".to_string();
    let store = tempfile::tempdir().unwrap();
    let idx = Arc::new(RepoIndex::open(&store.path().join("t.tri")));
    idx.enqueue(repo.path(), vec![small_id.clone(), missing.clone(), "not-a-sha".into()]);
    idx.settle();
    assert_eq!(idx.snapshot().blobs(), 1);
    assert!(idx.snapshot().ordinal(&small_id).is_some());
    // The writer must not run again for what it already refused.
    idx.enqueue(repo.path(), vec![missing, "not-a-sha".into()]);
    assert!(!idx.is_writing(), "nothing left to index, so no writer");
}
