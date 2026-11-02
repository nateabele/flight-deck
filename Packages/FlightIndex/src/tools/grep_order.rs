//! The order of `grep`'s prefix rows before the cut.
//!
//! Shipped: rows from a file named after the query (`grep session` → `SessionStore.swift`,
//! `session.rs`) first, an exact stem before a stem that starts with the query, each tier by file
//! PageRank, then name, path and line. Case is ignored in the stem test, so a lowercase word finds
//! a CamelCase Swift or Elm file.
//!
//! Why the file name and not the symbol name: on the eval harness (200 + 200 tasks, `grep` per
//! term), PageRank alone scored File@1/5/10 3.0/5.7/10.7 on flight-deck and 3.5/8.3/13.2 on
//! tessera; these tiers score 7.0/8.6/13.0 and 8.5/9.4/14.1. An exact-symbol-name tier, in any
//! of its forms (always, only when unique, only for a few matches, only for identifier-shaped
//! queries), lifted File@1 by at most 1.5 and lost File@10 on one repository or the other: in
//! Swift and Elm a name like `body`, `view` or `init` is defined in hundreds of files, while a
//! file is usually named after the one type or module the query means. The pre-PageRank
//! alphabetical order looked best on flight-deck (8.0/8.6/13.2), but only because its path
//! tie-break sorts `Packages/` before `Sources/`; with the tie-break reversed it scored
//! 5.5/5.5/10.4.
//!
//! The eval build (`--features eval`) also takes `order_eval=<policy>` so
//! `examples/eval_grep_order.rs` can score the rejected orderings next to the shipped one.

use crate::query::SymbolHit;
use std::cmp::Reverse;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(feature = "eval"), allow(dead_code))]
pub enum Policy {
    /// The shipped order: exact file stem, then stem prefix, then the rest; PageRank within.
    StemTiers,
    PageRank,
    /// Name, then path: the order before PageRank.
    Alpha,
    /// `Alpha` with the path tie-break reversed (control for the path bias).
    AlphaZPath,
    /// An exact symbol-name tier, always.
    Exact,
    /// An exact symbol-name tier when at most this many rows match exactly.
    ExactFew(usize),
    /// An exact symbol-name tier when the query is identifier-shaped (`SessionStore`, `load_all`).
    ExactIdent,
    /// Only the exact-stem tier.
    Stem,
    /// Only the stem-prefix tier.
    StemPrefix,
    /// Stem prefix, then an exact symbol name.
    StemPrefixExact,
}

#[cfg_attr(not(feature = "eval"), allow(dead_code))]
impl Policy {
    pub fn parse(s: &str) -> Option<Policy> {
        Some(match s {
            "stem_tiers" => Policy::StemTiers,
            "pagerank" => Policy::PageRank,
            "alpha" => Policy::Alpha,
            "alpha_zpath" => Policy::AlphaZPath,
            "exact" => Policy::Exact,
            "unique" => Policy::ExactFew(1),
            "ident" => Policy::ExactIdent,
            "stem" => Policy::Stem,
            "stem_prefix" => Policy::StemPrefix,
            "stem_prefix_exact" => Policy::StemPrefixExact,
            s => Policy::ExactFew(s.strip_prefix("few")?.parse().ok()?),
        })
    }
}

/// Starts with a capital, or has an inner capital, underscore or digit.
fn ident_shaped(q: &str) -> bool {
    q.chars().next().is_some_and(char::is_uppercase) || q.chars().skip(1).any(|c| c.is_uppercase() || c == '_' || c.is_ascii_digit())
}

/// Sorts `hits` (the rows of `grep query`) by `policy`; `file_rank` is the row's file PageRank.
pub fn sort(hits: &mut [SymbolHit], query: &str, policy: Policy, file_rank: impl Fn(&SymbolHit) -> f64) {
    let q = query.trim_end_matches('*');
    let ql = q.to_lowercase();
    match policy {
        Policy::Alpha => return hits.sort_by_cached_key(|h| (h.name.to_lowercase(), h.path.clone(), h.start_line)),
        Policy::AlphaZPath => return hits.sort_by_cached_key(|h| (h.name.to_lowercase(), Reverse(h.path.clone()), h.start_line)),
        _ => {}
    }
    let exact = hits.iter().filter(|h| h.name == q).count();
    let ident = ident_shaped(q);
    let tier = |h: &SymbolHit| -> u8 {
        let stem = h.path.file_stem().and_then(|s| s.to_str()).map(str::to_lowercase);
        let stem_eq = stem.as_deref() == Some(ql.as_str());
        let stem_pre = stem.is_some_and(|s| s.starts_with(&ql));
        let name_eq = h.name == q;
        match policy {
            Policy::StemTiers if stem_eq => 0,
            Policy::StemTiers if stem_pre => 1,
            Policy::StemTiers => 2,
            Policy::Exact => u8::from(!name_eq),
            Policy::ExactFew(k) => u8::from(!(name_eq && exact <= k)),
            Policy::ExactIdent => u8::from(!(name_eq && ident)),
            Policy::Stem => u8::from(!stem_eq),
            Policy::StemPrefix => u8::from(!stem_pre),
            Policy::StemPrefixExact if stem_pre => 0,
            Policy::StemPrefixExact if name_eq => 1,
            Policy::StemPrefixExact => 2,
            Policy::PageRank | Policy::Alpha | Policy::AlphaZPath => 0,
        }
    };
    // PageRank is never negative, so its bit pattern orders like the value.
    hits.sort_by_cached_key(|h| (tier(h), Reverse(file_rank(h).max(0.0).to_bits()), h.name.to_lowercase(), h.path.clone(), h.start_line));
}
