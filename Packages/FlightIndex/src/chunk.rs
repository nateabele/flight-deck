//! One blob's facts as a single columnar byte chunk (`store`'s `chunks.data`).
//!
//! Row-per-fact storage cost tessera (85 worktrees, 9,488 blobs) 122 MB of a 181 MB store even
//! with reference names interned: 3.75M `refs` rows at 22.9 B each, most of it SQLite's record
//! header, key (`facts_id`, `idx`) and B-tree cell around five small integers, plus 26 MB of
//! `symbols` and 9 MB of `imports` rows. The graph never reads one fact on its own, only a whole
//! blob at a time, so nothing needs a row. As chunks the same facts are 17.7 MB.
//!
//! **Layout** (format 2, little-endian, varints are LEB128):
//!
//! ```text
//! u8 format | u8 flags | [varint body length, if FLAG_ZSTD] body (raw, or one zstd frame)
//! body: varint n_sym n_imp n_import_names n_ref n_hier [n_binding n_member n_return, if FLAG_TYPES]
//!       integer columns, in a fixed order (see `encode`), each `u8 scheme` + payload
//!       string-lengths column (len+1, 0 = None) | varint string bytes | string bytes
//! ```
//!
//! Format 2 added the Swift type facts (`TypeFacts`: bindings, member types, return types),
//! which format 1 kept as tab-separated text in a `type_facts` table beside the chunk. In the
//! chunk their lines are packed columns and their strings join the shared, zstd-compressed
//! string section; a blob without any (every non-Swift blob) leaves `FLAG_TYPES` clear and costs
//! nothing.
//!
//! Each integer column is encoded by **trying every scheme on it and keeping the smallest**
//! (BtrBlocks' selection, SIGMOD 2023). BtrBlocks samples because its columns hold 64k values;
//! a blob's columns hold tens to a few thousand (the largest tessera blob has 5,607 references),
//! so trying each scheme on the whole column is cheap: encoding all 9,488 tessera chunks takes
//! about 1.2 s of CPU against minutes of parsing. Schemes: frame-of-reference bit-packing
//! (`PACKED`, which at width 0 also covers a constant column), zigzag deltas then packing
//! (`DELTA`: lines, which the parsers emit in source order), run-length (`RLE`: kinds,
//! qualifiers), and dictionary (`DICT`: a name column with a few hot ids far apart). Cascades go
//! one level deep: run values, run lengths and dictionary codes are packed, never re-selected.
//!
//! Strings (symbol names, signatures, import specifiers and names, hierarchy targets) are
//! concatenated into one section. Interning them like reference names was not done: the graph
//! holds symbols with `String` names, so ids would only add a pool lookup per symbol at load.
//!
//! **zstd is the last pass, over the whole body.** BtrBlocks found zstd still beats lightweight
//! encodings on strings, and on tessera it also finds what bit-packing leaves in the integers
//! (repeated id patterns across columns): the bodies are 31.2 MB, 17.7 MB after zstd level 3.
//! Compressing only the string section and leaving the integers packed came to 20.0 MB. Level 19
//! would save another 0.8 MB (4%); level 1 loses 0.4 MB. A per-language dictionary trained on a
//! quarter of the bodies shrank the other three quarters by a further 19% (13.3 -> 10.7 MB, plus
//! 0.38 MB of dictionaries), about 3 MB of an 81 MB store. Not done yet: a dictionary has to exist
//! before the chunks that use it, so a fresh store would need a second pass over its chunks, and
//! every reader would have to load and keep the dictionaries. Worth revisiting once tree maps
//! (now 70% of the store) shrink and facts are the bulk again.
//!
//! Every code below (`SYMBOL_KINDS`, the scheme bytes, the column order) is part of the on-disk
//! format: append, never reorder. A change that cannot be appended bumps `FORMAT` and the store's
//! `SCHEMA_VERSION`, which rebuilds the file.

use crate::error::{Error, Result};
use crate::facts::*;
use crate::names::NameId;

/// The chunk format this build writes and reads.
pub const FORMAT: u8 = 2;

/// The body (everything after the two header bytes) is one zstd frame, preceded by its
/// uncompressed length.
const FLAG_ZSTD: u8 = 1;

/// The body carries Swift type facts: their three counts follow the other five.
const FLAG_TYPES: u8 = 2;

/// The largest uncompressed body a chunk may claim, so a corrupt length cannot become a huge
/// allocation.
const MAX_BODY: u64 = 1 << 28;

/// zstd level for the body (see the module docs for the other levels measured).
const ZSTD_LEVEL: i32 = 3;

/// Below this many body bytes zstd's frame header eats the gain, so don't try.
const ZSTD_MIN: usize = 64;

/// The most values one column of one blob may claim. A width-0 column costs no bytes however long
/// it is, so without a bound a corrupt count would be a multi-gigabyte allocation; the largest
/// blob on tessera has 5,607 references.
const MAX_COUNT: u64 = 1 << 24;

/// Symbol kinds by code. Append only.
const SYMBOL_KINDS: [SymbolKind; 17] = [
    SymbolKind::Function,
    SymbolKind::Method,
    SymbolKind::Struct,
    SymbolKind::Enum,
    SymbolKind::Trait,
    SymbolKind::Interface,
    SymbolKind::Class,
    SymbolKind::TypeAlias,
    SymbolKind::Const,
    SymbolKind::Module,
    SymbolKind::Field,
    SymbolKind::Constructor,
    SymbolKind::Impl,
    SymbolKind::Port,
    SymbolKind::Macro,
    SymbolKind::Extension,
    SymbolKind::Variable,
];

fn symbol_kind_code(k: SymbolKind) -> u64 {
    SYMBOL_KINDS.iter().position(|x| *x == k).unwrap_or(0) as u64
}

fn import_kind_code(k: ImportKind) -> u64 {
    match k {
        ImportKind::Import => 0,
        ImportKind::ModDecl => 1,
        ImportKind::Reexport => 2,
    }
}

fn import_kind(c: u64) -> ImportKind {
    match c {
        1 => ImportKind::ModDecl,
        2 => ImportKind::Reexport,
        _ => ImportKind::Import,
    }
}

fn hierarchy_kind_code(k: HierarchyKind) -> u64 {
    match k {
        HierarchyKind::Extends => 0,
        HierarchyKind::Implements => 1,
    }
}

/// What a chunk holds: everything of `InternedFacts` except the two scalars the `facts` row keeps
/// (module name, line count).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Decoded {
    pub symbols: Vec<Symbol>,
    pub imports: Vec<Import>,
    pub refs: Vec<RefSite>,
    pub hierarchy: Vec<TypeRelation>,
    pub types: TypeFacts,
}

fn corrupt() -> Error {
    Error::Msg("corrupt fact chunk".into())
}

// ---------------------------------------------------------------- varints and bit packing

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn byte(&mut self) -> Result<u8> {
        let b = *self.buf.get(self.pos).ok_or_else(corrupt)?;
        self.pos += 1;
        Ok(b)
    }

    fn varint(&mut self) -> Result<u64> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let b = self.byte()?;
            v |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
        }
        Err(corrupt())
    }

    /// A count read from the chunk, bounded by `MAX_COUNT`.
    fn count(&mut self) -> Result<usize> {
        let n = self.varint()?;
        if n > MAX_COUNT {
            return Err(corrupt());
        }
        Ok(n as usize)
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.pos.checked_add(n).filter(|e| *e <= self.buf.len()).ok_or_else(corrupt)?;
        let s = &self.buf[self.pos..end];
        self.pos = end;
        Ok(s)
    }

    fn rest(&mut self) -> &'a [u8] {
        let s = &self.buf[self.pos..];
        self.pos = self.buf.len();
        s
    }
}

fn width(v: u64) -> u8 {
    (64 - v.leading_zeros()) as u8
}

fn pack(out: &mut Vec<u8>, vals: impl Iterator<Item = u64>, w: u8) {
    if w == 0 {
        return;
    }
    let (mut acc, mut nbits) = (0u128, 0u32);
    for v in vals {
        acc |= u128::from(v) << nbits;
        nbits += u32::from(w);
        while nbits >= 8 {
            out.push(acc as u8);
            acc >>= 8;
            nbits -= 8;
        }
    }
    if nbits > 0 {
        out.push(acc as u8);
    }
}

fn unpack(cur: &mut Cursor, n: usize, w: u8) -> Result<Vec<u64>> {
    if w > 64 {
        return Err(corrupt());
    }
    if w == 0 {
        return Ok(vec![0; n]);
    }
    let bytes = cur.take((n * usize::from(w)).div_ceil(8))?;
    let mask = if w == 64 { u64::MAX } else { (1u64 << w) - 1 };
    let mut out = Vec::with_capacity(n);
    let (mut acc, mut nbits, mut i) = (0u128, 0u32, 0usize);
    for _ in 0..n {
        while nbits < u32::from(w) {
            acc |= u128::from(bytes[i]) << nbits;
            i += 1;
            nbits += 8;
        }
        out.push((acc as u64) & mask);
        acc >>= w;
        nbits -= u32::from(w);
    }
    Ok(out)
}

// ---------------------------------------------------------------- integer column schemes

const PACKED: u8 = 0;
const DELTA: u8 = 1;
const RLE: u8 = 2;
const DICT: u8 = 3;

/// Frame of reference: `min`, a bit width, then every `v - min` in that width.
fn enc_packed(out: &mut Vec<u8>, vals: &[u64]) {
    let min = vals.iter().copied().min().unwrap_or(0);
    let w = width(vals.iter().map(|v| v - min).max().unwrap_or(0));
    put_varint(out, min);
    out.push(w);
    pack(out, vals.iter().map(|v| v - min), w);
}

fn dec_packed(cur: &mut Cursor, n: usize) -> Result<Vec<u64>> {
    let min = cur.varint()?;
    let w = cur.byte()?;
    let mut v = unpack(cur, n, w)?;
    for x in &mut v {
        *x = x.checked_add(min).ok_or_else(corrupt)?;
    }
    Ok(v)
}

fn zigzag(d: i64) -> u64 {
    ((d << 1) ^ (d >> 63)) as u64
}

fn unzigzag(z: u64) -> i64 {
    ((z >> 1) as i64) ^ -((z & 1) as i64)
}

/// The first value, then the zigzagged differences packed. Values are at most `u32::MAX + 1`, so
/// a difference always fits an `i64`.
fn enc_delta(out: &mut Vec<u8>, vals: &[u64]) {
    put_varint(out, vals[0]);
    let d: Vec<u64> = vals.windows(2).map(|w| zigzag(w[1] as i64 - w[0] as i64)).collect();
    enc_packed(out, &d);
}

fn dec_delta(cur: &mut Cursor, n: usize) -> Result<Vec<u64>> {
    let first = cur.varint()?;
    let d = dec_packed(cur, n - 1)?;
    let mut out = Vec::with_capacity(n);
    let mut v = first as i64;
    out.push(first);
    for z in d {
        v = v.checked_add(unzigzag(z)).filter(|x| *x >= 0).ok_or_else(corrupt)?;
        out.push(v as u64);
    }
    Ok(out)
}

fn enc_rle(out: &mut Vec<u8>, vals: &[u64]) {
    let (mut values, mut lens) = (Vec::new(), Vec::new());
    for &v in vals {
        match values.last() {
            Some(&last) if last == v => *lens.last_mut().unwrap() += 1,
            _ => {
                values.push(v);
                lens.push(0u64); // run length - 1
            }
        }
    }
    put_varint(out, values.len() as u64);
    enc_packed(out, &values);
    enc_packed(out, &lens);
}

fn dec_rle(cur: &mut Cursor, n: usize) -> Result<Vec<u64>> {
    let runs = cur.count()?;
    if runs > n {
        return Err(corrupt());
    }
    let values = dec_packed(cur, runs)?;
    let lens = dec_packed(cur, runs)?;
    let mut out = Vec::with_capacity(n);
    for (v, l) in values.into_iter().zip(lens) {
        let l = usize::try_from(l).ok().filter(|l| out.len() + l < n).ok_or_else(corrupt)?;
        out.extend(std::iter::repeat_n(v, l + 1));
    }
    if out.len() != n {
        return Err(corrupt());
    }
    Ok(out)
}

/// The distinct values sorted and delta-coded, then each value's index into them packed.
fn enc_dict(out: &mut Vec<u8>, vals: &[u64]) {
    let mut dict: Vec<u64> = vals.to_vec();
    dict.sort_unstable();
    dict.dedup();
    put_varint(out, dict.len() as u64);
    enc_delta(out, &dict);
    let w = width(dict.len() as u64 - 1);
    out.push(w);
    pack(out, vals.iter().map(|v| dict.binary_search(v).unwrap() as u64), w);
}

fn dec_dict(cur: &mut Cursor, n: usize) -> Result<Vec<u64>> {
    let k = cur.count()?;
    if k == 0 || k > n {
        return Err(corrupt());
    }
    let dict = dec_delta(cur, k)?;
    let w = cur.byte()?;
    unpack(cur, n, w)?.into_iter().map(|c| dict.get(c as usize).copied().ok_or_else(corrupt)).collect()
}

type Encoder = fn(&mut Vec<u8>, &[u64]);

/// Write `vals` with whichever scheme is smallest for them. An empty column writes nothing: its
/// length is always known from the header.
fn put_column(out: &mut Vec<u8>, vals: &[u64]) {
    if vals.is_empty() {
        return;
    }
    let mut best: Option<(u8, Vec<u8>)> = None;
    let encoders: [(u8, Encoder); 4] = [(PACKED, enc_packed), (DELTA, enc_delta), (RLE, enc_rle), (DICT, enc_dict)];
    for (scheme, enc) in encoders {
        let mut buf = Vec::new();
        enc(&mut buf, vals);
        if best.as_ref().is_none_or(|(_, b)| buf.len() < b.len()) {
            best = Some((scheme, buf));
        }
    }
    let (scheme, buf) = best.unwrap();
    out.push(scheme);
    out.extend_from_slice(&buf);
}

fn get_column(cur: &mut Cursor, n: usize) -> Result<Vec<u64>> {
    if n == 0 {
        return Ok(Vec::new());
    }
    match cur.byte()? {
        PACKED => dec_packed(cur, n),
        DELTA => dec_delta(cur, n),
        RLE => dec_rle(cur, n),
        DICT => dec_dict(cur, n),
        _ => Err(corrupt()),
    }
}

/// `None` as 0, `Some(v)` as `v + 1`.
fn opt(v: Option<u32>) -> u64 {
    v.map_or(0, |v| u64::from(v) + 1)
}

fn unopt(v: u64) -> Result<Option<u32>> {
    match v {
        0 => Ok(None),
        v => u32::try_from(v - 1).map(Some).map_err(|_| corrupt()),
    }
}

fn u32_of(v: u64) -> Result<u32> {
    u32::try_from(v).map_err(|_| corrupt())
}

// ---------------------------------------------------------------- strings

#[derive(Default)]
struct Strings {
    lens: Vec<u64>,
    bytes: Vec<u8>,
}

impl Strings {
    fn put(&mut self, s: Option<&str>) {
        match s {
            Some(s) => {
                self.lens.push(s.len() as u64 + 1);
                self.bytes.extend_from_slice(s.as_bytes());
            }
            None => self.lens.push(0),
        }
    }
}

struct StringReader<'a> {
    lens: std::vec::IntoIter<u64>,
    bytes: &'a str,
    pos: usize,
}

impl StringReader<'_> {
    fn opt(&mut self) -> Result<Option<String>> {
        match self.lens.next().ok_or_else(corrupt)? {
            0 => Ok(None),
            l => {
                let end = usize::try_from(l - 1).ok().and_then(|l| self.pos.checked_add(l)).ok_or_else(corrupt)?;
                let s = self.bytes.get(self.pos..end).ok_or_else(corrupt)?;
                self.pos = end;
                Ok(Some(s.to_string()))
            }
        }
    }

    fn req(&mut self) -> Result<String> {
        self.opt()?.ok_or_else(corrupt)
    }
}

// ---------------------------------------------------------------- the chunk

/// A binding's type source by code: 0 none, then `Named`, `Expr`, `Each`. Append only.
fn type_source_code(t: &Option<TypeSource>) -> u64 {
    match t {
        None => 0,
        Some(TypeSource::Named(_)) => 1,
        Some(TypeSource::Expr(_)) => 2,
        Some(TypeSource::Each(_)) => 3,
    }
}

/// Encode one blob's facts. `refs` carry the store's name ids (see `names`).
pub fn encode(symbols: &[Symbol], imports: &[Import], refs: &[RefSite], hierarchy: &[TypeRelation], types: &TypeFacts) -> Vec<u8> {
    let n_names: usize = imports.iter().map(|i| i.names.len()).sum();
    let (binds, members, returns) = (&types.bindings, &types.members, &types.returns);
    let mut out = Vec::new();
    for n in [symbols.len(), imports.len(), n_names, refs.len(), hierarchy.len()] {
        put_varint(&mut out, n as u64);
    }
    let typed = !types.is_empty();
    if typed {
        for n in [binds.len(), members.len(), returns.len()] {
            put_varint(&mut out, n as u64);
        }
    }
    let flag_types = if typed { FLAG_TYPES } else { 0 };
    let col = |out: &mut Vec<u8>, it: &mut dyn Iterator<Item = u64>| put_column(out, &it.collect::<Vec<_>>());

    // Symbols. `local_id` is the position by construction (`BlobFacts::push_symbol`), which the
    // delta scheme stores in two bytes; it is kept rather than assumed so a parser that ever
    // breaks that rule round-trips instead of silently renumbering.
    col(&mut out, &mut symbols.iter().map(|s| u64::from(s.local_id)));
    col(&mut out, &mut symbols.iter().map(|s| symbol_kind_code(s.kind)));
    col(&mut out, &mut symbols.iter().map(|s| u64::from(s.start_line)));
    col(&mut out, &mut symbols.iter().map(|s| u64::from(s.start_col)));
    // Span length rather than end line: small and similar across a blob. Zigzag because nothing
    // in the type forbids an end before the start.
    col(&mut out, &mut symbols.iter().map(|s| zigzag(i64::from(s.end_line) - i64::from(s.start_line))));
    col(&mut out, &mut symbols.iter().map(|s| u64::from(s.end_col)));
    col(&mut out, &mut symbols.iter().map(|s| opt(s.parent)));
    col(&mut out, &mut symbols.iter().map(|s| u64::from(s.exported)));

    col(&mut out, &mut imports.iter().map(|i| u64::from(i.line)));
    col(&mut out, &mut imports.iter().map(|i| import_kind_code(i.kind)));
    col(&mut out, &mut imports.iter().map(|i| i.names.len() as u64));
    col(&mut out, &mut imports.iter().flat_map(|i| &i.names).map(|n| u64::from(n.subs)));

    col(&mut out, &mut refs.iter().map(|r| u64::from(r.name.0)));
    col(&mut out, &mut refs.iter().map(|r| opt(r.qualifier().map(|q| q.0))));
    col(&mut out, &mut refs.iter().map(|r| u64::from(r.line)));
    col(&mut out, &mut refs.iter().map(|r| opt(r.enclosing())));
    col(&mut out, &mut refs.iter().map(|r| u64::from(r.kind.code())));

    col(&mut out, &mut hierarchy.iter().map(|h| u64::from(h.symbol)));
    col(&mut out, &mut hierarchy.iter().map(|h| hierarchy_kind_code(h.kind)));

    // Bindings: the scope as offsets (start from the declaration, end from the start), small and
    // alike across a blob; zigzag because a closure parameter's scope can start before its line.
    col(&mut out, &mut binds.iter().map(|b| type_source_code(&b.ty)));
    col(&mut out, &mut binds.iter().map(|b| u64::from(b.decl_line)));
    col(&mut out, &mut binds.iter().map(|b| zigzag(i64::from(b.scope_start) - i64::from(b.decl_line))));
    col(&mut out, &mut binds.iter().map(|b| zigzag(i64::from(b.scope_end) - i64::from(b.scope_start))));
    col(&mut out, &mut binds.iter().map(|b| opt(b.enclosing)));

    let mut st = Strings::default();
    for s in symbols {
        st.put(Some(&s.name));
        st.put(s.signature.as_deref());
    }
    for i in imports {
        st.put(Some(&i.specifier));
        st.put(i.alias.as_deref());
        for n in &i.names {
            st.put(Some(&n.name));
            st.put(n.alias.as_deref());
        }
    }
    for h in hierarchy {
        st.put(Some(&h.target));
    }
    for b in binds {
        st.put(Some(&b.name));
        st.put(match &b.ty {
            None => None,
            Some(TypeSource::Named(t) | TypeSource::Expr(t) | TypeSource::Each(t)) => Some(t),
        });
    }
    for m in members {
        st.put(Some(&m.owner));
        st.put(Some(&m.member));
        st.put(Some(&m.ty));
    }
    for r in returns {
        st.put(Some(&r.owner));
        st.put(Some(&r.name));
        st.put(r.ty.as_deref());
    }
    put_column(&mut out, &st.lens);
    put_varint(&mut out, st.bytes.len() as u64);
    out.extend_from_slice(&st.bytes);

    let body = out;
    if body.len() >= ZSTD_MIN
        && let Ok(z) = zstd::bulk::compress(&body, ZSTD_LEVEL)
        && z.len() < body.len()
    {
        let mut out = vec![FORMAT, FLAG_ZSTD | flag_types];
        put_varint(&mut out, body.len() as u64);
        out.extend_from_slice(&z);
        return out;
    }
    let mut out = Vec::with_capacity(body.len() + 2);
    out.extend_from_slice(&[FORMAT, flag_types]);
    out.extend_from_slice(&body);
    out
}

/// Decode a chunk written by `encode`. Any inconsistency is an error, never a panic: the bytes
/// come from a file on disk.
pub fn decode(bytes: &[u8]) -> Result<Decoded> {
    let mut head = Cursor { buf: bytes, pos: 0 };
    if head.byte()? != FORMAT {
        return Err(Error::Msg("fact chunk of an unknown format".into()));
    }
    let flags = head.byte()?;
    let inflated: Vec<u8>;
    let body: &[u8] = if flags & FLAG_ZSTD != 0 {
        let len = head.varint()?;
        if len > MAX_BODY {
            return Err(corrupt());
        }
        inflated = zstd::bulk::decompress(head.rest(), len as usize).map_err(|_| corrupt())?;
        if inflated.len() as u64 != len {
            return Err(corrupt());
        }
        &inflated
    } else {
        head.rest()
    };
    let mut cur = Cursor { buf: body, pos: 0 };
    let (n_sym, n_imp, n_names, n_ref, n_hier) = (cur.count()?, cur.count()?, cur.count()?, cur.count()?, cur.count()?);
    let (n_bind, n_mem, n_ret) = if flags & FLAG_TYPES != 0 { (cur.count()?, cur.count()?, cur.count()?) } else { (0, 0, 0) };

    let local = get_column(&mut cur, n_sym)?;
    let kind = get_column(&mut cur, n_sym)?;
    let start_line = get_column(&mut cur, n_sym)?;
    let start_col = get_column(&mut cur, n_sym)?;
    let span = get_column(&mut cur, n_sym)?;
    let end_col = get_column(&mut cur, n_sym)?;
    let parent = get_column(&mut cur, n_sym)?;
    let exported = get_column(&mut cur, n_sym)?;

    let imp_line = get_column(&mut cur, n_imp)?;
    let imp_kind = get_column(&mut cur, n_imp)?;
    let imp_count = get_column(&mut cur, n_imp)?;
    let subs = get_column(&mut cur, n_names)?;

    let r_name = get_column(&mut cur, n_ref)?;
    let r_qual = get_column(&mut cur, n_ref)?;
    let r_line = get_column(&mut cur, n_ref)?;
    let r_encl = get_column(&mut cur, n_ref)?;
    let r_kind = get_column(&mut cur, n_ref)?;

    let h_sym = get_column(&mut cur, n_hier)?;
    let h_kind = get_column(&mut cur, n_hier)?;

    let b_kind = get_column(&mut cur, n_bind)?;
    let b_decl = get_column(&mut cur, n_bind)?;
    let b_start = get_column(&mut cur, n_bind)?;
    let b_end = get_column(&mut cur, n_bind)?;
    let b_encl = get_column(&mut cur, n_bind)?;

    let n_strings = 2 * n_sym + 2 * n_imp + 2 * n_names + n_hier + 2 * n_bind + 3 * n_mem + 3 * n_ret;
    let lens = get_column(&mut cur, n_strings)?;
    let raw_len = usize::try_from(cur.varint()?).map_err(|_| corrupt())?;
    let raw = cur.take(raw_len)?;
    if !cur.rest().is_empty() {
        return Err(corrupt());
    }
    let text = std::str::from_utf8(raw).map_err(|_| corrupt())?;
    let mut st = StringReader { lens: lens.into_iter(), bytes: text, pos: 0 };

    let mut symbols = Vec::with_capacity(n_sym);
    for i in 0..n_sym {
        let start = u32_of(start_line[i])?;
        let end = i64::from(start) + unzigzag(span[i]);
        symbols.push(Symbol {
            local_id: u32_of(local[i])?,
            name: st.req()?,
            kind: *SYMBOL_KINDS.get(kind[i] as usize).ok_or_else(corrupt)?,
            start_line: start,
            start_col: u32_of(start_col[i])?,
            end_line: u32::try_from(end).map_err(|_| corrupt())?,
            end_col: u32_of(end_col[i])?,
            signature: st.opt()?,
            parent: unopt(parent[i])?,
            exported: exported[i] != 0,
        });
    }
    let mut imports = Vec::with_capacity(n_imp);
    let mut name_i = 0usize;
    for i in 0..n_imp {
        let specifier = st.req()?;
        let alias = st.opt()?;
        let k = usize::try_from(imp_count[i]).ok().filter(|k| name_i + k <= n_names).ok_or_else(corrupt)?;
        let mut names = Vec::with_capacity(k);
        for _ in 0..k {
            names.push(ImportName { name: st.req()?, alias: st.opt()?, subs: subs[name_i] != 0 });
            name_i += 1;
        }
        imports.push(Import { specifier, alias, names, line: u32_of(imp_line[i])?, kind: import_kind(imp_kind[i]) });
    }
    if name_i != n_names {
        return Err(corrupt());
    }
    let mut refs = Vec::with_capacity(n_ref);
    for i in 0..n_ref {
        refs.push(RefSite::new(
            NameId(u32_of(r_name[i])?),
            unopt(r_qual[i])?.map(NameId),
            u32_of(r_line[i])?,
            unopt(r_encl[i])?,
            RefKind::from_code(r_kind[i] as i64),
        ));
    }
    let mut hierarchy = Vec::with_capacity(n_hier);
    for i in 0..n_hier {
        hierarchy.push(TypeRelation {
            symbol: u32_of(h_sym[i])?,
            target: st.req()?,
            kind: if h_kind[i] == 1 { HierarchyKind::Implements } else { HierarchyKind::Extends },
        });
    }
    let mut types = TypeFacts::default();
    types.bindings.reserve_exact(n_bind);
    let offset = |base: i64, z: u64| u32::try_from(base + unzigzag(z)).map_err(|_| corrupt());
    for i in 0..n_bind {
        let name = st.req()?;
        let t = st.opt()?;
        let ty = match (b_kind[i], t) {
            (0, None) => None,
            (1, Some(t)) => Some(TypeSource::Named(t)),
            (2, Some(t)) => Some(TypeSource::Expr(t)),
            (3, Some(t)) => Some(TypeSource::Each(t)),
            _ => return Err(corrupt()),
        };
        let decl_line = u32_of(b_decl[i])?;
        let scope_start = offset(i64::from(decl_line), b_start[i])?;
        let scope_end = offset(i64::from(scope_start), b_end[i])?;
        types.bindings.push(Binding { name, ty, decl_line, scope_start, scope_end, enclosing: unopt(b_encl[i])? });
    }
    types.members.reserve_exact(n_mem);
    for _ in 0..n_mem {
        types.members.push(MemberType { owner: st.req()?, member: st.req()?, ty: st.req()? });
    }
    types.returns.reserve_exact(n_ret);
    for _ in 0..n_ret {
        types.returns.push(ReturnType { owner: st.req()?, name: st.req()?, ty: st.opt()? });
    }
    Ok(Decoded { symbols, imports, refs, hierarchy, types })
}
