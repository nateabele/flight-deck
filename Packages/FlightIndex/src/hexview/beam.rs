//! What a compiled Elixir module exports, read from its `.beam` file without running Erlang.
//!
//! Installed Elixir releases (Homebrew, the precompiled zips asdf and mise unpack) ship `ebin/`
//! directories only, no `.ex` sources, so the standard library's surface comes from two chunks:
//!
//! - `Docs` (EEP-48): every public function and macro with its signature, plus the module's
//!   `@type`s. A compressed external term (zlib), decoded by the small reader below.
//! - `ExpT` + `AtU8`: the export table, for a module compiled without docs. Names and arities only;
//!   a macro is exported as `MACRO-name` with one extra argument.

use std::collections::BTreeMap;

/// One exported definition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BeamDef {
    pub kind: DefKind,
    pub name: String,
    pub arity: u32,
    /// `map(enumerable, fun)`, as the docs write it; `None` from the export table.
    pub signature: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum DefKind {
    Function,
    Macro,
    Type,
}

/// The chunks of a BEAM file (`FOR1 <size> BEAM` then `<id> <size> <data>` padded to 4 bytes).
fn chunks(bin: &[u8]) -> Option<BTreeMap<[u8; 4], &[u8]>> {
    if bin.len() < 12 || &bin[0..4] != b"FOR1" || &bin[8..12] != b"BEAM" {
        return None;
    }
    let mut out = BTreeMap::new();
    let mut i = 12;
    while i + 8 <= bin.len() {
        let id: [u8; 4] = bin[i..i + 4].try_into().ok()?;
        let len = u32::from_be_bytes(bin[i + 4..i + 8].try_into().ok()?) as usize;
        let data = bin.get(i + 8..i + 8 + len)?;
        out.insert(id, data);
        i += 8 + len.div_ceil(4) * 4;
    }
    Some(out)
}

/// The definitions a module exports: from `Docs` when the module has docs, else the export table.
/// `None` for a file that is not a BEAM file.
pub fn exports(bin: &[u8]) -> Option<Vec<BeamDef>> {
    let c = chunks(bin)?;
    if let Some(d) = c.get(b"Docs").and_then(|d| docs(d)) {
        return Some(d);
    }
    let atoms = atom_table(c.get(b"AtU8")?)?;
    export_table(c.get(b"ExpT")?, &atoms)
}

// ---- Docs ------------------------------------------------------------------------------------

/// `{docs_v1, Anno, BeamLanguage, Format, ModuleDoc, Metadata, Docs}` with each doc
/// `{{Kind, Name, Arity}, Anno, Signatures, Doc, Metadata}`.
fn docs(data: &[u8]) -> Option<Vec<BeamDef>> {
    let term = etf::decode(data)?;
    let t = term.tuple()?;
    if t.first()?.atom()? != "docs_v1" {
        return None;
    }
    let mut out = Vec::new();
    for d in t.get(6)?.list()? {
        let Some(d) = d.tuple() else { continue };
        let Some(key) = d.first().and_then(|k| k.tuple()) else { continue };
        let (Some(kind), Some(name), Some(arity)) = (key.first().and_then(|k| k.atom()), key.get(1).and_then(|k| k.atom()), key.get(2).and_then(|k| k.int())) else {
            continue;
        };
        let kind = match kind {
            "function" => DefKind::Function,
            "macro" => DefKind::Macro,
            "type" => DefKind::Type,
            _ => continue, // callbacks are for implementers, not callers
        };
        let signature = d.get(2).and_then(|s| s.list()).and_then(|l| l.first()).and_then(|s| s.text());
        out.push(BeamDef { kind, name: name.to_string(), arity: arity as u32, signature });
    }
    Some(out)
}

// ---- export table ----------------------------------------------------------------------------

/// `AtU8`: a count, then each atom's length and UTF-8 bytes. A negative count (OTP 28 and later)
/// means each length is in the compact term encoding instead of one byte.
fn atom_table(data: &[u8]) -> Option<Vec<String>> {
    let count = i32::from_be_bytes(data.get(0..4)?.try_into().ok()?);
    let compact = count < 0;
    let mut i = 4;
    let mut out = Vec::with_capacity(count.unsigned_abs() as usize);
    for _ in 0..count.unsigned_abs() {
        let len = if compact {
            let (len, used) = compact_uint(data.get(i..)?)?;
            i += used;
            len
        } else {
            i += 1;
            *data.get(i - 1)? as usize
        };
        out.push(String::from_utf8_lossy(data.get(i..i + len)?).into_owned());
        i += len;
    }
    Some(out)
}

/// An unsigned integer in the compact term encoding (tag bits 0-2 are ignored): a 4-bit value in
/// the high nibble, an 11-bit value over two bytes, or a byte count and that many bytes.
fn compact_uint(b: &[u8]) -> Option<(usize, usize)> {
    let first = *b.first()? as usize;
    if first & 0x08 == 0 {
        return Some((first >> 4, 1));
    }
    if first & 0x10 == 0 {
        return Some((((first & 0xe0) << 3) | *b.get(1)? as usize, 2));
    }
    let n = (first >> 5) + 2;
    if n > 8 {
        return None; // a length field over 2^64 is not an atom length
    }
    let v = b.get(1..1 + n)?.iter().fold(0usize, |v, x| (v << 8) | *x as usize);
    Some((v, 1 + n))
}

/// `ExpT`: a count, then (function atom, arity, label) as 32-bit words. Atom indexes are 1-based.
fn export_table(data: &[u8], atoms: &[String]) -> Option<Vec<BeamDef>> {
    let word = |i: usize| data.get(i..i + 4).and_then(|w| w.try_into().ok()).map(u32::from_be_bytes);
    let count = word(0)? as usize;
    let mut out = Vec::new();
    for e in 0..count {
        let (atom, arity) = (word(4 + e * 12)? as usize, word(8 + e * 12)?);
        let name = atoms.get(atom.checked_sub(1)?)?;
        if matches!(name.as_str(), "__info__" | "module_info") {
            continue;
        }
        let def = match name.strip_prefix("MACRO-") {
            Some(m) => BeamDef { kind: DefKind::Macro, name: m.to_string(), arity: arity.saturating_sub(1), signature: None },
            None => BeamDef { kind: DefKind::Function, name: name.clone(), arity, signature: None },
        };
        out.push(def);
    }
    Some(out)
}

/// The Erlang external term format, as far as EEP-48 docs use it.
pub(crate) mod etf {
    #[derive(Debug, Clone, PartialEq)]
    pub enum Term {
        Int(i64),
        /// An integer too large for `i64`, or a float: docs never need its value.
        Number,
        Atom(String),
        Binary(Vec<u8>),
        Tuple(Vec<Term>),
        /// The proper elements; an improper tail is dropped.
        List(Vec<Term>),
        Map(Vec<(Term, Term)>),
    }

    impl Term {
        pub fn atom(&self) -> Option<&str> {
            match self {
                Term::Atom(a) => Some(a),
                _ => None,
            }
        }
        pub fn int(&self) -> Option<i64> {
            match self {
                Term::Int(i) => Some(*i),
                _ => None,
            }
        }
        pub fn tuple(&self) -> Option<&[Term]> {
            match self {
                Term::Tuple(t) => Some(t),
                _ => None,
            }
        }
        pub fn list(&self) -> Option<&[Term]> {
            match self {
                Term::List(l) => Some(l),
                _ => None,
            }
        }
        /// A binary or a charlist, as text.
        pub fn text(&self) -> Option<String> {
            match self {
                Term::Binary(b) => Some(String::from_utf8_lossy(b).into_owned()),
                Term::List(l) => l.iter().map(|c| c.int().and_then(|i| char::from_u32(i as u32))).collect(),
                _ => None,
            }
        }
    }

    /// `131` then a term, or `131 80 <size:32> <zlib stream>` for a compressed one.
    pub fn decode(data: &[u8]) -> Option<Term> {
        if *data.first()? != 131 {
            return None;
        }
        let owned;
        let body: &[u8] = if *data.get(1)? == 80 {
            let size = u32::from_be_bytes(data.get(2..6)?.try_into().ok()?) as usize;
            owned = miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(data.get(6..)?, size).ok()?;
            &owned
        } else {
            &data[1..]
        };
        let mut r = Reader { b: body, i: 0, depth: 0 };
        r.term()
    }

    struct Reader<'a> {
        b: &'a [u8],
        i: usize,
        depth: u32,
    }

    impl Reader<'_> {
        fn take(&mut self, n: usize) -> Option<&[u8]> {
            let s = self.b.get(self.i..self.i.checked_add(n)?)?;
            self.i += n;
            Some(s)
        }
        fn u8(&mut self) -> Option<u8> {
            self.take(1).map(|s| s[0])
        }
        fn u16(&mut self) -> Option<usize> {
            self.take(2).map(|s| u16::from_be_bytes([s[0], s[1]]) as usize)
        }
        fn u32(&mut self) -> Option<usize> {
            self.take(4).map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]]) as usize)
        }
        fn items(&mut self, n: usize) -> Option<Vec<Term>> {
            // A corrupt length cannot make us allocate more than the input could hold.
            let mut v = Vec::with_capacity(n.min(self.b.len() - self.i));
            for _ in 0..n {
                v.push(self.term()?);
            }
            Some(v)
        }
        fn term(&mut self) -> Option<Term> {
            self.depth += 1;
            if self.depth > 256 {
                return None;
            }
            let t = self.term_inner();
            self.depth -= 1;
            t
        }
        fn term_inner(&mut self) -> Option<Term> {
            Some(match self.u8()? {
                97 => Term::Int(self.u8()? as i64),
                98 => Term::Int(self.u32()? as u32 as i32 as i64),
                70 => {
                    self.take(8)?;
                    Term::Number
                }
                110 | 111 => {
                    let n = if self.b.get(self.i - 1) == Some(&110) { self.u8()? as usize } else { self.u32()? };
                    let sign = self.u8()?;
                    let digits = self.take(n)?;
                    if n <= 7 {
                        let v = digits.iter().rev().fold(0i64, |v, d| (v << 8) | *d as i64);
                        Term::Int(if sign == 0 { v } else { -v })
                    } else {
                        Term::Number
                    }
                }
                100 | 118 => {
                    let n = self.u16()?;
                    Term::Atom(String::from_utf8_lossy(self.take(n)?).into_owned())
                }
                115 | 119 => {
                    let n = self.u8()? as usize;
                    Term::Atom(String::from_utf8_lossy(self.take(n)?).into_owned())
                }
                104 => {
                    let n = self.u8()? as usize;
                    Term::Tuple(self.items(n)?)
                }
                105 => {
                    let n = self.u32()?;
                    Term::Tuple(self.items(n)?)
                }
                106 => Term::List(Vec::new()),
                107 => {
                    let n = self.u16()?;
                    Term::List(self.take(n)?.iter().map(|c| Term::Int(*c as i64)).collect())
                }
                108 => {
                    let n = self.u32()?;
                    let items = self.items(n)?;
                    self.term()?; // the tail: `[]` for a proper list
                    Term::List(items)
                }
                109 => {
                    let n = self.u32()?;
                    Term::Binary(self.take(n)?.to_vec())
                }
                77 => {
                    let n = self.u32()?;
                    self.u8()?;
                    Term::Binary(self.take(n)?.to_vec())
                }
                116 => {
                    let n = self.u32()?;
                    let mut m = Vec::with_capacity(n.min(self.b.len() - self.i));
                    for _ in 0..n {
                        let k = self.term()?;
                        let v = self.term()?;
                        m.push((k, v));
                    }
                    Term::Map(m)
                }
                _ => return None,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_lengths() {
        assert_eq!(compact_uint(&[0x50]), Some((5, 1)));
        // 11-bit form: high 3 bits of the value in bits 5-7, low 8 in the next byte.
        assert_eq!(compact_uint(&[0x28, 0x2c]), Some((300, 2)));
        assert_eq!(compact_uint(&[0x18, 0x01, 0x00]), Some((256, 3)));
    }

    #[test]
    fn uncompressed_terms() {
        // {docs_v1, [], [<<"f(a)">>]} with a small atom, a nil and a list of one binary.
        let mut b = vec![131, 104, 3, 119, 7];
        b.extend(b"docs_v1");
        b.extend([106, 108, 0, 0, 0, 1, 109, 0, 0, 0, 4]);
        b.extend(b"f(a)");
        b.push(106);
        let t = etf::decode(&b).unwrap();
        let t = t.tuple().unwrap();
        assert_eq!(t[0].atom(), Some("docs_v1"));
        assert_eq!(t[2].list().unwrap()[0].text().as_deref(), Some("f(a)"));
    }

    #[test]
    fn not_a_beam_file() {
        assert!(exports(b"not a beam").is_none());
    }
}
