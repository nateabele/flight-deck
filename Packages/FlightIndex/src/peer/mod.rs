//! Blob facts travel (spec §7 item 3, first cut): a daemon asks a peer daemon for the facts of
//! the blobs it is missing before it parses them.
//!
//! Facts are keyed by `(blob id, language, parser version)` and say only what one file says about
//! itself, so a fact row made on one machine is valid on any machine with the same parser version
//! (`Lang::parser_version`, which is in the key). Nothing about the asker's repository, path or
//! commit travels; a blob the peer holds under any repository answers.
//!
//! **Roles.** The *asker* is `Engine::build`: after it lists the view and finds the keys its store
//! lacks, it hands them to a [`FactSource`] and stores whatever comes back; the keys that do not
//! come back are parsed as before. A peer that is down, slow to answer or broken costs the build
//! nothing but the attempt: every failure falls back to parsing. The *holder* is
//! [`serve::serve_stream`], run by the daemon on a connection that asked for it (`peer_facts`).
//!
//! **Transport.** [`wire`] is a framed byte stream, half a request and half an answer, so any
//! byte pipe carries it. Today that is the daemon's own Unix socket: the first line of the
//! connection is the JSON request `{"tool":"peer_facts","args":{"format":1}}`, the daemon answers
//! one JSON line and the connection then carries frames ([`socket::SocketPeer`]). On a paired host
//! the same bytes, upgrade line included, ride a HostKit `ChannelMux` channel unchanged: the Mac
//! opens a channel and names it in an `index.facts` control request, and the host pipes the
//! channel to its daemon's socket the way `port.open` pipes one to a TCP port. Neither end of the
//! link parses a frame (see ARCHITECTURE.md §Index Service, "Facts from a peer").
//!
//! **Why chunks are re-encoded on the way out.** A stored chunk's reference names are ids into its
//! database's `names` table, meaningless anywhere else. The holder renumbers them into a table
//! scoped to the connection (each name crosses once per connection, in the FACTS frame that first
//! uses it) and re-encodes the chunk. Shipping the raw chunk with its database's whole name table
//! was the alternative: no re-encode, but 28k tessera names (about 400 KB) on the first fetch even
//! when one blob is wanted, and a table per database the answer draws from.

pub mod serve;
pub mod socket;
pub mod wire;

use crate::chunk;
use crate::error::{Error, Result};
use crate::facts::{BlobFacts, Reference, TypeFacts};
use crate::store::ParsedBlob;
use std::io::{Read, Write};
use wire::{WireKey, KIND_DONE, KIND_ERROR, KIND_FACTS, KIND_WANT};

/// One blob the asker lacks.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FactKey {
    pub blob_id: String,
    pub language: &'static str,
    pub parser_version: u32,
}

/// What one fetch moved.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FetchStats {
    /// Blobs the peer answered (parsed or recorded as skipped).
    pub delivered: usize,
    /// Keys the peer does not hold.
    pub missing: usize,
    /// Bytes read from the peer, frames and all.
    pub bytes_in: u64,
    /// Bytes written to the peer.
    pub bytes_out: u64,
}

/// Somewhere the facts of missing blobs can come from instead of the parser.
pub trait FactSource: Send + Sync {
    /// Ask for `keys` and hand each batch that arrives to `sink`, in arrival order. A key the
    /// source does not hold is never delivered; an error means the rest were not.
    fn fetch(&self, keys: &[FactKey], sink: &mut dyn FnMut(Vec<ParsedBlob>) -> Result<()>) -> Result<FetchStats>;

    /// Where the facts come from, for logs and `status`.
    fn describe(&self) -> String;
}

struct Counting<T> {
    inner: T,
    bytes: u64,
}

impl<T: Read> Read for Counting<T> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.bytes += n as u64;
        Ok(n)
    }
}

/// The asker's half of one exchange on an open stream: send one WANT for `keys`, then turn every
/// FACTS frame into `ParsedBlob`s for `sink` until DONE.
pub fn exchange(r: &mut impl Read, w: &mut impl Write, keys: &[FactKey], sink: &mut dyn FnMut(Vec<ParsedBlob>) -> Result<()>) -> Result<FetchStats> {
    let want: Vec<WireKey> = keys.iter().map(|k| WireKey { blob_id: k.blob_id.clone(), language: k.language.to_string(), parser_version: k.parser_version }).collect();
    let payload = wire::encode_want(&want);
    wire::write_frame(w, KIND_WANT, &payload).and_then(|_| w.flush()).map_err(|e| Error::Msg(format!("peer stream: {e}")))?;
    let mut stats = FetchStats { bytes_out: payload.len() as u64 + 5, ..Default::default() };
    let mut r = Counting { inner: r, bytes: 0 };
    let mut names: Vec<String> = Vec::new();
    let mut seen = vec![false; keys.len()];
    loop {
        let Some((kind, payload)) = wire::read_frame(&mut r)? else {
            return Err(Error::Msg("the peer closed the stream before it finished answering".into()));
        };
        match kind {
            KIND_FACTS => {
                let facts = wire::decode_facts(&payload)?;
                names.extend(facts.new_names);
                let mut batch = Vec::with_capacity(facts.entries.len());
                for e in facts.entries {
                    let key = keys.get(e.key_index).ok_or_else(|| Error::Msg("peer answered a key it was not asked for".into()))?;
                    if std::mem::replace(&mut seen[e.key_index], true) {
                        continue; // answered twice: keep the first
                    }
                    batch.push(ParsedBlob { blob_id: key.blob_id.clone(), language: key.language, parser_version: key.parser_version, facts: to_blob_facts(e, &names)? });
                }
                stats.delivered += batch.len();
                if !batch.is_empty() {
                    sink(batch)?;
                }
            }
            KIND_DONE => {
                let (_, missing) = wire::decode_done(&payload)?;
                stats.missing = missing;
                stats.bytes_in = r.bytes;
                return Ok(stats);
            }
            KIND_ERROR => return Err(Error::Msg(format!("peer: {}", wire::decode_error(&payload)))),
            other => return Err(Error::Msg(format!("peer sent an unknown frame kind {other}"))),
        }
    }
}

/// A received entry in the parser's own form, names resolved through the connection's table.
fn to_blob_facts(e: wire::WireEntry, names: &[String]) -> Result<Option<BlobFacts>> {
    if !e.parsed {
        return Ok(None);
    }
    let d = chunk::decode(&e.chunk)?;
    let name = |id: u32| names.get(id as usize).cloned().ok_or_else(|| Error::Msg("peer chunk names an unknown reference name".into()));
    let mut refs = Vec::with_capacity(d.refs.len());
    for r in &d.refs {
        let qualifier = match r.qualifier() {
            Some(q) => Some(name(q.0)?),
            None => None,
        };
        refs.push(Reference { name: name(r.name.0)?, qualifier, line: r.line, enclosing: r.enclosing(), kind: r.kind });
    }
    let types = if e.types.is_empty() { TypeFacts::default() } else { TypeFacts::decode(&e.types) };
    Ok(Some(BlobFacts { module_name: e.module_name, line_count: e.line_count, symbols: d.symbols, imports: d.imports, refs, hierarchy: d.hierarchy, types }))
}
