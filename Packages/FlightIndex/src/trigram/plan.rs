//! A regex to a trigram query: Cox's `analyze` (Regular Expression Matching with a Trigram Index,
//! 2012) over `regex-syntax`'s HIR, on bytes, with ASCII case folded.
//!
//! The query is a necessary condition: every string the regex matches contains the trigrams the
//! query asks for, so a blob whose trigram set fails the query holds no match and need not be read.
//! Nothing here has to be clever to be correct, only conservative: `Query::All` (read everything)
//! is always a right answer, and every rule below either keeps exact information or weakens it.
//!
//! Each subexpression is summarised by an [`Info`]: whether it can match the empty string, the
//! exact set of strings it matches when that set is small, otherwise the sets of prefixes and
//! suffixes every match starts and ends with, and a query every match satisfies. Concatenation
//! crosses the sets (and adds the trigrams that straddle the seam); alternation unions them.
//! Sets are capped so the work stays small: a set too large is cut down to shorter strings, after
//! its trigrams have been added to the query.
//!
//! Case: the body search is case-insensitive, so the parser expands every letter into its case
//! class (`k` into `[Kk\u{212A}]`) and the planner folds ASCII letters to lower case, as the index
//! does to content. Non-ASCII members of a class stay as their UTF-8 bytes, so the Kelvin sign is
//! still looked for as itself: folding only ever merges strings the index also merges.

use regex_syntax::hir::{Class, Hir, HirKind};
use std::collections::BTreeSet;

/// Three bytes, ASCII-folded, as `b0 << 16 | b1 << 8 | b2`.
pub type Trigram = u32;

/// A boolean query over trigrams. `All` matches every blob; it is what a regex with nothing
/// selective in it (`.*`, `\w+`, `ab?`) plans to.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Query {
    All,
    Tri(Trigram),
    And(Vec<Query>),
    Or(Vec<Query>),
}

impl Query {
    pub fn and(self, other: Query) -> Query {
        match (self, other) {
            (Query::All, q) | (q, Query::All) => q,
            (a, b) => {
                let mut parts = Vec::new();
                for q in [a, b] {
                    match q {
                        Query::And(v) => parts.extend(v),
                        q => parts.push(q),
                    }
                }
                parts.sort();
                parts.dedup();
                if parts.len() == 1 { parts.pop().unwrap() } else { Query::And(parts) }
            }
        }
    }

    pub fn or(self, other: Query) -> Query {
        match (self, other) {
            (Query::All, _) | (_, Query::All) => Query::All,
            (a, b) => {
                let mut parts = Vec::new();
                for q in [a, b] {
                    match q {
                        Query::Or(v) => parts.extend(v),
                        q => parts.push(q),
                    }
                }
                parts.sort();
                parts.dedup();
                if parts.len() == 1 { parts.pop().unwrap() } else { Query::Or(parts) }
            }
        }
    }

    /// Every trigram the query names, for tests and the daemon log.
    pub fn trigrams(&self) -> usize {
        match self {
            Query::All => 0,
            Query::Tri(_) => 1,
            Query::And(v) | Query::Or(v) => v.iter().map(Query::trigrams).sum(),
        }
    }
}

/// Exact sets above this size are turned into trigrams plus prefixes and suffixes.
const MAX_EXACT: usize = 7;
/// Prefix and suffix sets above this size are cut to shorter strings.
const MAX_SET: usize = 20;
/// A class with more characters than this is treated as any character.
const MAX_CLASS: u32 = 100;
/// Exact strings this long are turned into trigrams: they say all they can already.
const MAX_LEN: usize = 8;

type Set = BTreeSet<Vec<u8>>;

#[derive(Clone, Debug)]
struct Info {
    can_empty: bool,
    exact: Option<Set>,
    prefix: Set,
    suffix: Set,
    matches: Query,
}

/// Fold ASCII letters to lower case, the one normalisation the index applies to content.
pub fn fold(b: u8) -> u8 {
    b.to_ascii_lowercase()
}

pub fn trigram(a: u8, b: u8, c: u8) -> Trigram {
    (fold(a) as u32) << 16 | (fold(b) as u32) << 8 | fold(c) as u32
}

/// The query for `pattern` parsed as the body search compiles it: case-insensitive, Unicode.
pub fn plan(pattern: &str) -> Result<Query, String> {
    let hir = regex_syntax::ParserBuilder::new().case_insensitive(true).build().parse(pattern).map_err(|e| e.to_string())?;
    Ok(plan_hir(&hir))
}

pub fn plan_hir(hir: &Hir) -> Query {
    let mut info = analyze(hir);
    info.simplify(true);
    info.add_exact();
    info.matches
}

fn single(s: Vec<u8>) -> Set {
    std::iter::once(s).collect()
}

fn empty_string() -> Info {
    Info { can_empty: true, exact: Some(single(Vec::new())), prefix: Set::new(), suffix: Set::new(), matches: Query::All }
}

fn any_char() -> Info {
    Info { can_empty: false, exact: None, prefix: single(Vec::new()), suffix: single(Vec::new()), matches: Query::All }
}

fn any_match() -> Info {
    Info { can_empty: true, ..any_char() }
}

fn exact(set: Set) -> Info {
    let can_empty = set.contains(&Vec::new() as &Vec<u8>);
    let mut info = Info { can_empty, exact: Some(set), prefix: Set::new(), suffix: Set::new(), matches: Query::All };
    info.simplify(false);
    info
}

fn analyze(hir: &Hir) -> Info {
    match hir.kind() {
        HirKind::Empty | HirKind::Look(_) => empty_string(),
        HirKind::Literal(lit) => exact(single(lit.0.iter().map(|&b| fold(b)).collect())),
        HirKind::Class(Class::Unicode(c)) => {
            let count: u32 = c.ranges().iter().map(|r| r.end() as u32 - r.start() as u32 + 1).sum();
            if count == 0 || count > MAX_CLASS {
                return any_char();
            }
            let mut set = Set::new();
            for r in c.ranges() {
                for ch in r.start()..=r.end() {
                    let mut buf = [0u8; 4];
                    set.insert(ch.encode_utf8(&mut buf).bytes().map(fold).collect());
                }
            }
            exact(set)
        }
        HirKind::Class(Class::Bytes(c)) => {
            let count: u32 = c.ranges().iter().map(|r| r.end() as u32 - r.start() as u32 + 1).sum();
            if count == 0 || count > MAX_CLASS {
                return any_char();
            }
            exact(c.ranges().iter().flat_map(|r| r.start()..=r.end()).map(|b| vec![fold(b)]).collect())
        }
        HirKind::Capture(c) => analyze(&c.sub),
        HirKind::Repetition(r) => {
            if r.min == 0 {
                if r.max == Some(1) {
                    return alternate(analyze(&r.sub), empty_string());
                }
                return any_match();
            }
            let mut info = analyze(&r.sub);
            if r.max == Some(1) {
                return info;
            }
            // At least one match of the sub-expression: its prefixes and suffixes still hold, but
            // the exact set no longer does.
            if let Some(e) = info.exact.take() {
                info.add_exact_set(&e);
                info.prefix = e.clone();
                info.suffix = e;
            }
            info.simplify(false);
            info
        }
        HirKind::Concat(subs) => subs.iter().fold(empty_string(), |acc, s| concat(acc, analyze(s))),
        HirKind::Alternation(subs) => {
            let mut it = subs.iter();
            let first = it.next().map(analyze).unwrap_or_else(empty_string);
            it.fold(first, |acc, s| alternate(acc, analyze(s)))
        }
    }
}

fn cross(a: &Set, b: &Set) -> Set {
    let mut out = Set::new();
    for x in a {
        for y in b {
            let mut s = x.clone();
            s.extend_from_slice(y);
            out.insert(s);
        }
    }
    out
}

fn min_len(s: &Set) -> usize {
    s.iter().map(Vec::len).min().unwrap_or(0)
}

/// OR over the strings of `set` of the AND of each one's trigrams; `All` when a string is too
/// short to have one (it could be anywhere).
fn trigrams_of(set: &Set) -> Query {
    if set.is_empty() || min_len(set) < 3 {
        return Query::All;
    }
    let mut or: Option<Query> = None;
    for s in set {
        let and = s.windows(3).map(|w| Query::Tri(trigram(w[0], w[1], w[2]))).fold(Query::All, Query::and);
        or = Some(match or {
            None => and,
            Some(q) => q.or(and),
        });
    }
    or.unwrap_or(Query::All)
}

impl Info {
    fn add_exact(&mut self) {
        if let Some(e) = self.exact.clone() {
            self.add_exact_set(&e);
        }
    }

    fn add_exact_set(&mut self, set: &Set) {
        let q = trigrams_of(set);
        self.matches = std::mem::replace(&mut self.matches, Query::All).and(q);
    }

    fn simplify(&mut self, force: bool) {
        if let Some(e) = &self.exact {
            let n = min_len(e);
            if e.len() > MAX_EXACT || (force && n >= 3) || n >= MAX_LEN {
                let e = self.exact.take().unwrap();
                self.add_exact_set(&e);
                for s in e {
                    if s.len() < 3 {
                        self.prefix.insert(s.clone());
                        self.suffix.insert(s);
                    } else {
                        self.prefix.insert(s[..2].to_vec());
                        self.suffix.insert(s[s.len() - 2..].to_vec());
                    }
                }
            }
        }
        if self.exact.is_none() {
            self.simplify_set(false);
            self.simplify_set(true);
        }
    }

    /// Add the set's trigrams to the query, then shorten its strings to two bytes (and further,
    /// while the set is still too large): what the dropped bytes said is in the query now.
    fn simplify_set(&mut self, suffix: bool) {
        let set = if suffix { &self.suffix } else { &self.prefix };
        let q = trigrams_of(set);
        self.matches = std::mem::replace(&mut self.matches, Query::All).and(q);
        let mut set = std::mem::take(if suffix { &mut self.suffix } else { &mut self.prefix });
        let mut n = 2usize;
        loop {
            set = set.into_iter().map(|s| if s.len() <= n { s } else if suffix { s[s.len() - n..].to_vec() } else { s[..n].to_vec() }).collect();
            if set.len() <= MAX_SET || n == 0 {
                break;
            }
            n -= 1;
        }
        if suffix { self.suffix = set } else { self.prefix = set }
    }
}

fn concat(x: Info, y: Info) -> Info {
    let mut xy = Info { can_empty: x.can_empty && y.can_empty, exact: None, prefix: Set::new(), suffix: Set::new(), matches: x.matches.clone().and(y.matches.clone()) };
    match (&x.exact, &y.exact) {
        (Some(a), Some(b)) => xy.exact = Some(cross(a, b)),
        _ => {
            xy.prefix = match &x.exact {
                Some(a) => cross(a, &y.prefix),
                None if x.can_empty => x.prefix.union(&y.prefix).cloned().collect(),
                None => x.prefix.clone(),
            };
            xy.suffix = match &y.exact {
                Some(b) => cross(&x.suffix, b),
                None if y.can_empty => y.suffix.union(&x.suffix).cloned().collect(),
                None => y.suffix.clone(),
            };
        }
    }
    // The trigrams that straddle the seam: some string of x's suffixes followed by some string of
    // y's prefixes is in every match.
    if x.exact.is_none() && y.exact.is_none() && x.suffix.len() <= MAX_SET && y.prefix.len() <= MAX_SET && min_len(&x.suffix) + min_len(&y.prefix) >= 3 {
        let seam = trigrams_of(&cross(&x.suffix, &y.prefix));
        xy.matches = xy.matches.and(seam);
    }
    xy.simplify(false);
    xy
}

fn alternate(mut x: Info, mut y: Info) -> Info {
    let mut xy = Info { can_empty: x.can_empty || y.can_empty, exact: None, prefix: Set::new(), suffix: Set::new(), matches: Query::All };
    match (x.exact.clone(), y.exact.clone()) {
        (Some(a), Some(b)) => xy.exact = Some(a.union(&b).cloned().collect()),
        (Some(a), None) => {
            xy.prefix = a.union(&y.prefix).cloned().collect();
            xy.suffix = a.union(&y.suffix).cloned().collect();
            x.add_exact();
        }
        (None, Some(b)) => {
            xy.prefix = x.prefix.union(&b).cloned().collect();
            xy.suffix = x.suffix.union(&b).cloned().collect();
            y.add_exact();
        }
        (None, None) => {
            xy.prefix = x.prefix.union(&y.prefix).cloned().collect();
            xy.suffix = x.suffix.union(&y.suffix).cloned().collect();
        }
    }
    xy.matches = x.matches.or(y.matches);
    xy.simplify(false);
    xy
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(s: &str) -> Query {
        let b = s.as_bytes();
        Query::Tri(trigram(b[0], b[1], b[2]))
    }

    fn and(v: &[&str]) -> Query {
        v.iter().map(|s| t(s)).fold(Query::All, Query::and)
    }

    #[test]
    fn a_literal_needs_each_of_its_trigrams_case_folded() {
        assert_eq!(plan("Hello").unwrap(), and(&["hel", "ell", "llo"]));
        assert_eq!(plan("hello").unwrap(), plan("HELLO").unwrap());
    }

    #[test]
    fn nothing_selective_plans_to_all() {
        for p in [".*", "ab", "a.b", r"\w+", "(abc)?", "x*", "^$", "", "[a-z]+", "a|bcd"] {
            assert_eq!(plan(p).unwrap(), Query::All, "{p}");
        }
    }

    #[test]
    fn alternation_ors_and_a_wildcard_splits() {
        assert_eq!(plan("abcd|wxyz").unwrap(), and(&["abc", "bcd"]).or(and(&["wxy", "xyz"])));
        assert_eq!(plan("abc.*xyz").unwrap(), and(&["abc", "xyz"]));
    }

    #[test]
    fn a_small_class_crosses_into_the_trigrams() {
        assert_eq!(plan("ab[cd]").unwrap(), t("abc").or(t("abd")));
    }

    #[test]
    fn a_letter_with_a_non_ascii_case_variant_keeps_it() {
        // `k` folds with the Kelvin sign: a trigram query for `kab` alone would miss it.
        let q = plan("kab").unwrap();
        assert_ne!(q, t("kab"), "{q:?}");
    }
}
