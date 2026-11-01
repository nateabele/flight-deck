//! Words of symbols, and a BM25F index over them: what `grep` ranks by when the query is a
//! sentence rather than a name, and what `find` and prefix `grep` fall back to when no name
//! matches.
//!
//! A symbol's document has three fields: the words of its name, the words of its parent's name
//! (the type of a method), and the words of its file's path plus its Elm module. Words come from
//! splitting on camelCase, snake_case and separators, then a light stemmer (plural `-s`, `-ies`,
//! `-sses`, `-ing`, `-ed`), applied to queries and documents alike so odd stems still meet.
//! Scoring is BM25F (k1 1.2, b 0.75 per field, weights 1/1/1). Impl and Field symbols are not
//! documents. Whole identifiers (`infrapreflight`) are not indexed: measured no gain and ~40%
//! more memory. See `docs/superpowers/specs/2026-11-01-index-tool-contract.md` (grep, find).
//!
//! The index belongs to a graph (`GraphData::words`) and is built the first time a ranked query
//! asks for it, never at graph build, so a graph nobody searches by words pays nothing.

use crate::facts::SymbolKind;
use crate::graph::{GraphData, SymId};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock};

/// Words a request is made of that never name code. Applied to queries only.
pub const STOPWORDS: &[&str] = &[
    "the", "and", "for", "with", "that", "this", "from", "into", "not", "are", "was", "were", "but", "its", "it's", "has", "have",
    "had", "now", "when", "then", "than", "one", "two", "all", "any", "each", "every", "only", "also", "own", "out", "off", "via",
    "who", "what", "which", "where", "why", "how", "can", "cannot", "does", "doesn", "don", "did", "will", "would", "should",
    "could", "may", "must", "never", "always", "still", "just", "same", "new", "old", "more", "less", "most", "some", "other",
    "they", "them", "their", "there", "these", "those", "our", "you", "your", "his", "her", "being", "been", "too", "very",
    "fix", "fixes", "feat", "docs", "chore", "test", "tests", "round", "add", "adds", "added", "use", "uses", "used", "make",
    "makes", "instead", "without", "while", "after", "before", "about", "over", "under", "between", "per", "again", "once",
];

/// A query keeps at most this many of its words; the rest of a long paragraph only dilutes.
pub const MAX_QUERY_TOKENS: usize = 12;

const FIELDS: usize = 3; // name, parent, path
const K1: f64 = 1.2;
const B: f64 = 0.75;

/// `InfraPreflight.checkTofu` / `check_tofu` / `Sources/Infra/x.swift` -> lowercase words.
pub fn split_words(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    for chunk in s.split(|c: char| !c.is_alphanumeric()) {
        let chars: Vec<char> = chunk.chars().collect();
        let mut cur = String::new();
        for i in 0..chars.len() {
            let c = chars[i];
            let boundary = i > 0
                && ((c.is_uppercase() && (chars[i - 1].is_lowercase() || chars[i - 1].is_ascii_digit()))
                    || (c.is_uppercase() && i + 1 < chars.len() && chars[i + 1].is_lowercase() && chars[i - 1].is_uppercase()));
            if boundary && !cur.is_empty() {
                out.push(std::mem::take(&mut cur).to_lowercase());
            }
            cur.push(c);
        }
        if !cur.is_empty() {
            out.push(cur.to_lowercase());
        }
    }
    out.retain(|w| w.len() >= 2);
    out
}

/// A light English stemmer: `queries` -> `query`, `classes` -> `class`, `loading` -> `load`,
/// `refused` -> `refus`, `exports` -> `export`; `status`, `glass` and `axis` keep their `s`. Naive
/// on purpose (`alias` -> `alia`): queries and documents are stemmed alike, so a stem only has to
/// be the same on both sides.
pub fn stem(w: &str) -> String {
    let n = w.len();
    if n > 4 && w.ends_with("ies") {
        return format!("{}y", &w[..n - 3]);
    }
    if n > 4 && w.ends_with("sses") {
        return w[..n - 2].to_string();
    }
    if n > 5 && w.ends_with("ing") {
        return w[..n - 3].to_string();
    }
    if n > 4 && w.ends_with("ed") && !w.ends_with("eed") {
        return w[..n - 2].to_string();
    }
    if n > 3 && w.ends_with('s') && !w.ends_with("ss") && !w.ends_with("us") && !w.ends_with("is") {
        return w[..n - 1].to_string();
    }
    w.to_string()
}

/// The stemmed words of an identifier, path or module name: what a document is made of.
pub fn doc_words(s: &str) -> Vec<String> {
    split_words(s).iter().map(|w| stem(w)).collect()
}

/// Identifier-shaped words of a request that could name code: three or more characters, not a
/// stopword, deduplicated case-insensitively with the original case kept, at most
/// `MAX_QUERY_TOKENS`.
pub fn query_tokens(text: &str) -> Vec<String> {
    static IDENT: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"[A-Za-z_][A-Za-z0-9_]*").unwrap());
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for m in IDENT.find_iter(text) {
        let w = m.as_str();
        let lower = w.to_lowercase();
        if w.len() < 3 || STOPWORDS.contains(&lower.as_str()) || !seen.insert(lower) {
            continue;
        }
        out.push(w.to_string());
        if out.len() == MAX_QUERY_TOKENS {
            break;
        }
    }
    out
}

/// The words a request is scored by: its tokens split and stemmed, stopwords dropped, each once,
/// in the order they first appear.
pub fn query_words(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for token in query_tokens(text) {
        for w in split_words(&token) {
            if STOPWORDS.contains(&w.as_str()) {
                continue;
            }
            let s = stem(&w);
            if !STOPWORDS.contains(&s.as_str()) && !out.contains(&s) {
                out.push(s);
            }
        }
    }
    out
}

/// BM25F over one document per symbol of a graph. Terms are interned; a posting is
/// `(document, term frequency per field)`.
pub struct WordIndex {
    terms: HashMap<Box<str>, u32>,
    postings: Vec<Vec<(u32, [u16; FIELDS])>>,
    doc_len: Vec<[u16; FIELDS]>,
    avg_len: [f64; FIELDS],
    docs: Vec<SymId>,
}

fn indexed(k: SymbolKind) -> bool {
    !matches!(k, SymbolKind::Impl | SymbolKind::Field)
}

impl WordIndex {
    pub fn build(g: &GraphData) -> WordIndex {
        let mut terms: HashMap<Box<str>, u32> = HashMap::new();
        let mut postings: Vec<Vec<(u32, [u16; FIELDS])>> = Vec::new();
        let mut intern = |w: &str, postings: &mut Vec<Vec<(u32, [u16; FIELDS])>>| -> u32 {
            if let Some(&i) = terms.get(w) {
                return i;
            }
            let i = postings.len() as u32;
            terms.insert(w.into(), i);
            postings.push(Vec::new());
            i
        };
        let mut doc_len: Vec<[u16; FIELDS]> = Vec::new();
        let mut docs: Vec<SymId> = Vec::new();
        let mut tf: Vec<(u32, [u16; FIELDS])> = Vec::new();
        for fi in (0..g.files.len() as u32).filter(|i| g.file(*i).alive) {
            let node = g.file(fi);
            if !node.facts.symbols.iter().any(|s| indexed(s.kind)) {
                continue;
            }
            let mut path_words = doc_words(&node.path);
            if let Some(m) = &node.facts.module_name {
                path_words.extend(doc_words(m));
            }
            let path_ids: Vec<u32> = path_words.iter().map(|w| intern(w, &mut postings)).collect();
            for s in node.facts.symbols.iter().filter(|s| indexed(s.kind)) {
                let doc = docs.len() as u32;
                let name_ids: Vec<u32> = doc_words(&s.name).iter().map(|w| intern(w, &mut postings)).collect();
                let parent_ids: Vec<u32> = s.parent.map(|p| doc_words(&node.symbol(p).name).iter().map(|w| intern(w, &mut postings)).collect()).unwrap_or_default();
                tf.clear();
                for (field, ids) in [&name_ids, &parent_ids, &path_ids].into_iter().enumerate() {
                    for &t in ids {
                        match tf.iter_mut().find(|(x, _)| *x == t) {
                            Some((_, f)) => f[field] = f[field].saturating_add(1),
                            None => {
                                let mut f = [0u16; FIELDS];
                                f[field] = 1;
                                tf.push((t, f));
                            }
                        }
                    }
                }
                for &(t, f) in &tf {
                    postings[t as usize].push((doc, f));
                }
                let len = |v: &Vec<u32>| v.len().min(u16::MAX as usize) as u16;
                doc_len.push([len(&name_ids), len(&parent_ids), len(&path_ids)]);
                docs.push(SymId { file: fi, local: s.local_id });
            }
        }
        let n = doc_len.len().max(1) as f64;
        let mut avg_len = [0.0; FIELDS];
        for l in &doc_len {
            for k in 0..FIELDS {
                avg_len[k] += l[k] as f64;
            }
        }
        for a in avg_len.iter_mut() {
            *a = (*a / n).max(1e-9);
        }
        for p in postings.iter_mut() {
            p.shrink_to_fit();
        }
        terms.shrink_to_fit();
        doc_len.shrink_to_fit();
        docs.shrink_to_fit();
        WordIndex { terms, postings, doc_len, avg_len, docs }
    }

    /// Number of documents (indexed symbols).
    pub fn len(&self) -> usize {
        self.docs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.docs.is_empty()
    }

    /// Every symbol with at least one of `words`, best first (ties in index order):
    /// `(score, symbol)`. `words` are query words (`query_words`), already stemmed.
    pub fn search(&self, words: &[String]) -> Vec<(f64, SymId)> {
        let n = self.docs.len() as f64;
        let mut acc = vec![0.0f64; self.docs.len()];
        let mut touched: Vec<u32> = Vec::new();
        for w in words {
            let Some(&t) = self.terms.get(w.as_str()) else { continue };
            let p = &self.postings[t as usize];
            let df = p.len() as f64;
            let idf = ((n - df + 0.5) / (df + 0.5) + 1.0).ln();
            for &(d, tf) in p {
                let l = &self.doc_len[d as usize];
                let mut wtf = 0.0;
                for k in 0..FIELDS {
                    if tf[k] > 0 {
                        wtf += tf[k] as f64 / (1.0 - B + B * l[k] as f64 / self.avg_len[k]);
                    }
                }
                if wtf > 0.0 {
                    if acc[d as usize] == 0.0 {
                        touched.push(d);
                    }
                    acc[d as usize] += idf * wtf * (K1 + 1.0) / (wtf + K1);
                }
            }
        }
        let mut out: Vec<(f64, u32)> = touched.into_iter().map(|d| (acc[d as usize], d)).collect();
        out.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
        out.into_iter().map(|(s, d)| (s, self.docs[d as usize])).collect()
    }

    /// Estimated heap bytes, from capacities (term strings with a flat allocator overhead).
    pub fn bytes(&self) -> usize {
        use std::mem::size_of;
        const ALLOC: usize = 16;
        let mut n = self.terms.capacity() * (size_of::<Box<str>>() + 4 + 8) + self.terms.keys().map(|k| k.len() + ALLOC).sum::<usize>();
        n += self.postings.capacity() * size_of::<Vec<(u32, [u16; FIELDS])>>();
        n += self.postings.iter().map(|p| p.capacity() * size_of::<(u32, [u16; FIELDS])>() + if p.capacity() > 0 { ALLOC } else { 0 }).sum::<usize>();
        n += self.doc_len.capacity() * size_of::<[u16; FIELDS]>() + self.docs.capacity() * size_of::<SymId>();
        n
    }
}

impl GraphData {
    /// The graph's word index, built on first use (about 20 ms and 5 MB for a 44k-symbol graph).
    pub fn words(&self) -> Arc<WordIndex> {
        self.words.get_or_init(|| Arc::new(WordIndex::build(self))).clone()
    }

    /// The word index if a query has built it: what the byte estimate counts.
    pub fn words_if_built(&self) -> Option<&WordIndex> {
        self.words.get().map(|w| &**w)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_identifiers_into_words() {
        assert_eq!(split_words("InfraPreflight.checkTofu"), ["infra", "preflight", "check", "tofu"]);
        assert_eq!(split_words("HTTPServer_load2Files"), ["http", "server", "load2", "files"]);
        assert_eq!(split_words("Sources/FlightDeck/x.swift"), ["sources", "flight", "deck", "swift"]);
    }

    #[test]
    fn stems_plurals_and_verb_endings_lightly() {
        for (w, s) in [
            ("queries", "query"),
            ("classes", "class"),
            ("loading", "load"),
            ("ring", "ring"),
            ("refused", "refus"),
            ("agreed", "agreed"),
            ("bed", "bed"),
            ("exports", "export"),
            ("status", "status"),
            ("glass", "glass"),
            ("axis", "axis"),
            ("gas", "gas"),
        ] {
            assert_eq!(stem(w), s, "{w}");
        }
    }

    #[test]
    fn a_query_is_its_stemmed_identifier_words_without_stopwords() {
        assert_eq!(query_words("fix: an export the preview says release would refuse"), ["export", "preview", "say", "release", "refuse"]);
        assert_eq!(query_words("InfraPreflight checks tofu_versions"), ["infra", "preflight", "check", "tofu", "version"]);
        // Words under three letters and repeats are dropped; case does not matter.
        assert_eq!(query_words("UI ok Release release"), ["release"]);
        assert!(query_words("the and of").is_empty());
    }
}
