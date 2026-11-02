//! The bytes of the fact exchange: length-prefixed frames on one byte stream. Pure encode and
//! decode, no I/O policy, so the same frames ride a local Unix socket today and a HostKit
//! `ChannelMux` channel later (a channel is a byte stream with EOF; frames span its 64 KiB data
//! messages freely).
//!
//! ```text
//! frame:  u32 LE length (of kind + payload) | u8 kind | payload
//! WANT  1 (asker -> holder)   varint n_langs  (str language, varint parser_version)*
//!                             varint n_keys   (varint lang_index, varint oid_tag, oid bytes)*
//!                             oid_tag = len << 1 | is_text: a lowercase hex id travels as raw
//!                             bytes (20 for SHA-1), anything else as its text
//! FACTS 2 (holder -> asker)   u8 flags | varint names_len | names | varint n_entries | entry*
//!                             names: varint n (str name)*, zstd'ed when flags & 1; appended to
//!                             the connection's name table, whose ids the chunks below use
//!                             entry: varint key_index (into the WANT) | u8 status (0 parsed,
//!                             1 skipped) | str? module | varint line_count | bytes chunk |
//!                             bytes type_facts (`TypeFacts::encode`, empty = none)
//! DONE  3 (holder -> asker)   varint delivered | varint missing      (ends one WANT's answer)
//! ERROR 4 (holder -> asker)   str message                            (ends the stream)
//! ```
//!
//! `str` is varint length + UTF-8, `str?` is varint (length + 1, 0 = none) + UTF-8, `bytes` is
//! varint length + bytes. A chunk is `chunk::encode`'s format (q17's columnar chunk) with its
//! reference names renumbered into the connection's table: store name ids mean nothing outside
//! their database file, so a chunk cannot travel with them.

use crate::error::{Error, Result};
use std::io::{Read, Write};

/// The exchange format this build speaks. A holder answering an asker of another format refuses
/// in the upgrade reply, before any frame.
pub const PEER_FORMAT: u32 = 1;

/// The largest frame either side accepts, so a corrupt length cannot become a huge allocation.
/// A FACTS frame is cut at `FACTS_FRAME_BYTES`, far below this.
pub const MAX_FRAME: u32 = 64 << 20;

/// Where the holder closes a FACTS frame and starts the next, so the asker can store one batch
/// while the next is on the wire.
pub const FACTS_FRAME_BYTES: usize = 1 << 20;

pub const KIND_WANT: u8 = 1;
pub const KIND_FACTS: u8 = 2;
pub const KIND_DONE: u8 = 3;
pub const KIND_ERROR: u8 = 4;

const FLAG_NAMES_ZSTD: u8 = 1;

/// Below this many bytes the names block is sent as it is.
const NAMES_ZSTD_MIN: usize = 512;

/// The most keys one WANT may name and the most entries or names one FACTS may carry.
const MAX_COUNT: u64 = 1 << 22;

fn corrupt(what: &str) -> Error {
    Error::Msg(format!("corrupt peer frame: {what}"))
}

// ---------------------------------------------------------------- primitives

pub fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn put_str(out: &mut Vec<u8>, s: &str) {
    put_varint(out, s.len() as u64);
    out.extend_from_slice(s.as_bytes());
}

fn put_opt_str(out: &mut Vec<u8>, s: Option<&str>) {
    match s {
        Some(s) => {
            put_varint(out, s.len() as u64 + 1);
            out.extend_from_slice(s.as_bytes());
        }
        None => put_varint(out, 0),
    }
}

fn put_bytes(out: &mut Vec<u8>, b: &[u8]) {
    put_varint(out, b.len() as u64);
    out.extend_from_slice(b);
}

pub struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    pub fn new(buf: &'a [u8]) -> Cursor<'a> {
        Cursor { buf, pos: 0 }
    }

    fn byte(&mut self) -> Result<u8> {
        let b = *self.buf.get(self.pos).ok_or_else(|| corrupt("truncated"))?;
        self.pos += 1;
        Ok(b)
    }

    pub fn varint(&mut self) -> Result<u64> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let b = self.byte()?;
            v |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
        }
        Err(corrupt("varint too long"))
    }

    fn count(&mut self) -> Result<usize> {
        let n = self.varint()?;
        if n > MAX_COUNT {
            return Err(corrupt("count out of range"));
        }
        Ok(n as usize)
    }

    fn take(&mut self, n: u64) -> Result<&'a [u8]> {
        let n = usize::try_from(n).map_err(|_| corrupt("length"))?;
        let end = self.pos.checked_add(n).filter(|e| *e <= self.buf.len()).ok_or_else(|| corrupt("truncated"))?;
        let s = &self.buf[self.pos..end];
        self.pos = end;
        Ok(s)
    }

    fn bytes(&mut self) -> Result<&'a [u8]> {
        let n = self.varint()?;
        self.take(n)
    }

    fn str(&mut self) -> Result<&'a str> {
        std::str::from_utf8(self.bytes()?).map_err(|_| corrupt("not UTF-8"))
    }

    fn opt_str(&mut self) -> Result<Option<&'a str>> {
        match self.varint()? {
            0 => Ok(None),
            n => Ok(Some(std::str::from_utf8(self.take(n - 1)?).map_err(|_| corrupt("not UTF-8"))?)),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.pos >= self.buf.len()
    }
}

// ---------------------------------------------------------------- frames on a stream

/// Write one frame.
pub fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) -> std::io::Result<()> {
    let len = u32::try_from(payload.len() + 1).map_err(|_| std::io::Error::other("frame too large"))?;
    w.write_all(&len.to_le_bytes())?;
    w.write_all(&[kind])?;
    w.write_all(payload)
}

/// Read one frame; `Ok(None)` at a clean end of stream (EOF before a frame starts).
pub fn read_frame(r: &mut impl Read) -> Result<Option<(u8, Vec<u8>)>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(Error::Msg(format!("peer stream: {e}"))),
    }
    let len = u32::from_le_bytes(len);
    if len == 0 || len > MAX_FRAME {
        return Err(corrupt("frame length out of range"));
    }
    let mut buf = vec![0u8; len as usize];
    r.read_exact(&mut buf).map_err(|e| Error::Msg(format!("peer stream: {e}")))?;
    let kind = buf[0];
    buf.remove(0);
    Ok(Some((kind, buf)))
}

// ---------------------------------------------------------------- WANT

/// One key asked for: a blob in one language at one parser version.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WireKey {
    pub blob_id: String,
    pub language: String,
    pub parser_version: u32,
}

fn hex_raw(s: &str) -> Option<Vec<u8>> {
    let b = s.as_bytes();
    if b.is_empty() || !b.len().is_multiple_of(2) {
        return None;
    }
    let nibble = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    b.chunks_exact(2).map(|p| Some(nibble(p[0])? << 4 | nibble(p[1])?)).collect()
}

fn raw_hex(b: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    b.iter().flat_map(|b| [HEX[(b >> 4) as usize] as char, HEX[(b & 15) as usize] as char]).collect()
}

pub fn encode_want(keys: &[WireKey]) -> Vec<u8> {
    let mut langs: Vec<(&str, u32)> = Vec::new();
    let mut out = Vec::with_capacity(keys.len() * 24 + 32);
    let idx: Vec<usize> = keys
        .iter()
        .map(|k| match langs.iter().position(|(l, v)| *l == k.language && *v == k.parser_version) {
            Some(i) => i,
            None => {
                langs.push((&k.language, k.parser_version));
                langs.len() - 1
            }
        })
        .collect();
    put_varint(&mut out, langs.len() as u64);
    for (l, v) in &langs {
        put_str(&mut out, l);
        put_varint(&mut out, u64::from(*v));
    }
    put_varint(&mut out, keys.len() as u64);
    for (k, i) in keys.iter().zip(idx) {
        put_varint(&mut out, i as u64);
        match hex_raw(&k.blob_id) {
            Some(raw) => {
                put_varint(&mut out, (raw.len() as u64) << 1);
                out.extend_from_slice(&raw);
            }
            None => {
                put_varint(&mut out, (k.blob_id.len() as u64) << 1 | 1);
                out.extend_from_slice(k.blob_id.as_bytes());
            }
        }
    }
    out
}

pub fn decode_want(payload: &[u8]) -> Result<Vec<WireKey>> {
    let mut c = Cursor::new(payload);
    let n_langs = c.count()?;
    let mut langs = Vec::with_capacity(n_langs.min(64));
    for _ in 0..n_langs {
        let l = c.str()?.to_string();
        let v = u32::try_from(c.varint()?).map_err(|_| corrupt("parser version"))?;
        langs.push((l, v));
    }
    let n = c.count()?;
    let mut keys = Vec::with_capacity(n.min(1 << 16));
    for _ in 0..n {
        let (language, parser_version) = langs.get(c.varint()? as usize).cloned().ok_or_else(|| corrupt("language index"))?;
        let tag = c.varint()?;
        let bytes = c.take(tag >> 1)?;
        let blob_id = if tag & 1 == 1 { std::str::from_utf8(bytes).map_err(|_| corrupt("blob id"))?.to_string() } else { raw_hex(bytes) };
        keys.push(WireKey { blob_id, language, parser_version });
    }
    if !c.is_empty() {
        return Err(corrupt("trailing bytes"));
    }
    Ok(keys)
}

// ---------------------------------------------------------------- FACTS

/// One blob's facts as they travel: the `facts` row's scalars plus the chunk, whose reference
/// ids index the connection's name table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireEntry {
    pub key_index: usize,
    /// False for a blob the holder recorded as skipped (not UTF-8): the asker records it skipped
    /// too rather than reading it again.
    pub parsed: bool,
    pub module_name: Option<String>,
    pub line_count: u32,
    pub chunk: Vec<u8>,
    /// `TypeFacts::encode`'s text; empty when the blob has none.
    pub types: String,
}

/// A FACTS frame: names new to the connection, then entries.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WireFacts {
    pub new_names: Vec<String>,
    pub entries: Vec<WireEntry>,
}

pub fn encode_facts(f: &WireFacts) -> Vec<u8> {
    let mut names = Vec::new();
    put_varint(&mut names, f.new_names.len() as u64);
    for n in &f.new_names {
        put_str(&mut names, n);
    }
    let mut flags = 0;
    if names.len() >= NAMES_ZSTD_MIN
        && let Ok(z) = zstd::bulk::compress(&names, 3)
        && z.len() + 8 < names.len()
    {
        let mut framed = Vec::with_capacity(z.len() + 8);
        put_varint(&mut framed, names.len() as u64);
        framed.extend_from_slice(&z);
        names = framed;
        flags |= FLAG_NAMES_ZSTD;
    }
    let mut out = Vec::with_capacity(names.len() + f.entries.iter().map(|e| e.chunk.len() + e.types.len() + 16).sum::<usize>() + 8);
    out.push(flags);
    put_bytes(&mut out, &names);
    put_varint(&mut out, f.entries.len() as u64);
    for e in &f.entries {
        put_varint(&mut out, e.key_index as u64);
        out.push(if e.parsed { 0 } else { 1 });
        put_opt_str(&mut out, e.module_name.as_deref());
        put_varint(&mut out, u64::from(e.line_count));
        put_bytes(&mut out, &e.chunk);
        put_bytes(&mut out, e.types.as_bytes());
    }
    out
}

pub fn decode_facts(payload: &[u8]) -> Result<WireFacts> {
    let mut c = Cursor::new(payload);
    let flags = c.byte()?;
    let names_block = c.bytes()?;
    let inflated;
    let names_bytes: &[u8] = if flags & FLAG_NAMES_ZSTD != 0 {
        let mut nc = Cursor::new(names_block);
        let len = nc.varint()?;
        if len > u64::from(MAX_FRAME) {
            return Err(corrupt("names length"));
        }
        inflated = zstd::bulk::decompress(&names_block[nc.pos..], len as usize).map_err(|_| corrupt("names zstd"))?;
        if inflated.len() as u64 != len {
            return Err(corrupt("names length"));
        }
        &inflated
    } else {
        names_block
    };
    let mut nc = Cursor::new(names_bytes);
    let n_names = nc.count()?;
    let mut new_names = Vec::with_capacity(n_names.min(1 << 16));
    for _ in 0..n_names {
        new_names.push(nc.str()?.to_string());
    }
    let n = c.count()?;
    let mut entries = Vec::with_capacity(n.min(1 << 14));
    for _ in 0..n {
        let key_index = c.varint()? as usize;
        let parsed = match c.byte()? {
            0 => true,
            1 => false,
            _ => return Err(corrupt("status")),
        };
        let module_name = c.opt_str()?.map(str::to_string);
        let line_count = u32::try_from(c.varint()?).map_err(|_| corrupt("line count"))?;
        let chunk = c.bytes()?.to_vec();
        let types = c.str()?.to_string();
        entries.push(WireEntry { key_index, parsed, module_name, line_count, chunk, types });
    }
    if !c.is_empty() {
        return Err(corrupt("trailing bytes"));
    }
    Ok(WireFacts { new_names, entries })
}

// ---------------------------------------------------------------- DONE / ERROR

pub fn encode_done(delivered: usize, missing: usize) -> Vec<u8> {
    let mut out = Vec::new();
    put_varint(&mut out, delivered as u64);
    put_varint(&mut out, missing as u64);
    out
}

pub fn decode_done(payload: &[u8]) -> Result<(usize, usize)> {
    let mut c = Cursor::new(payload);
    Ok((c.varint()? as usize, c.varint()? as usize))
}

pub fn encode_error(msg: &str) -> Vec<u8> {
    let mut out = Vec::new();
    put_str(&mut out, msg);
    out
}

pub fn decode_error(payload: &[u8]) -> String {
    Cursor::new(payload).str().map(str::to_string).unwrap_or_else(|_| "unreadable error".into())
}
