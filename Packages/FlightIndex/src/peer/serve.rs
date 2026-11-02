//! The holder's half: answer WANT frames from every repository database in a store.

use super::wire::{self, WireEntry, WireFacts, WireKey, KIND_DONE, KIND_ERROR, KIND_FACTS, KIND_WANT};
use crate::chunk;
use crate::error::{Error, Result};
use crate::facts::RefSite;
use crate::names::{NameId, NamePool};
use crate::store::{list_dbs, Reader};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// What a holder has served since the daemon started (`status`).
#[derive(Debug, Default)]
pub struct ServeCounters {
    pub connections: AtomicU64,
    pub served: AtomicU64,
    pub missing: AtomicU64,
    pub bytes_out: AtomicU64,
}

/// One repository database the holder reads, with its reference names as far as it has read them.
struct Db {
    reader: Reader,
    pool: NamePool,
}

/// Per connection: the databases opened so far and the connection's name table.
struct Holder {
    store_root: PathBuf,
    /// Opened lazily, in `list_dbs` order; `None` for a file that would not open.
    dbs: Vec<(PathBuf, Option<Db>)>,
    listed: bool,
    /// The database that answered last: a WANT's keys mostly come from one repository, so it is
    /// asked first.
    last_hit: usize,
    /// (database index, store name id) -> connection name id.
    names: HashMap<(usize, u32), u32>,
}

impl Holder {
    fn new(store_root: &Path) -> Holder {
        Holder { store_root: store_root.to_path_buf(), dbs: Vec::new(), listed: false, last_hit: 0, names: HashMap::new() }
    }

    fn list(&mut self) {
        if !self.listed {
            self.dbs = list_dbs(&self.store_root).into_iter().map(|(p, _)| (p, None)).collect();
            self.listed = true;
        }
    }

    fn db(&mut self, i: usize) -> Option<&mut Db> {
        let (path, slot) = self.dbs.get_mut(i)?;
        if slot.is_none() {
            let reader = Reader::open_file(path.clone()).ok()?;
            let mut pool = NamePool::new(reader.store_id());
            reader.load_names(&mut pool).ok()?;
            *slot = Some(Db { reader, pool });
        }
        slot.as_mut()
    }

    /// The entry for `key`, its new connection names appended to `new_names`; `None` if no
    /// database holds it.
    fn entry(&mut self, key_index: usize, key: &WireKey, new_names: &mut Vec<String>) -> Result<Option<WireEntry>> {
        self.list();
        let n = self.dbs.len();
        for step in 0..n {
            let i = (self.last_hit + step) % n;
            let Some(db) = self.db(i) else { continue };
            let Some((parsed, facts)) = db.reader.get_stored(&key.blob_id, &key.language, key.parser_version)? else { continue };
            if facts.name_bound as usize > db.pool.len() {
                db.reader.load_names(&mut db.pool)?; // names added since this connection opened the file
            }
            self.last_hit = i;
            let db = self.dbs[i].1.as_ref().expect("opened above");
            let mut conn_id = |id: NameId| -> Result<NameId> {
                if let Some(&c) = self.names.get(&(i, id.0)) {
                    return Ok(NameId(c));
                }
                if id.0 as usize >= db.pool.len() {
                    return Err(Error::Msg(format!("{}: a chunk names an id its names table lacks", db.reader.path().display())));
                }
                let c = self.names.len() as u32;
                self.names.insert((i, id.0), c);
                new_names.push(db.pool.resolve(id).to_string());
                Ok(NameId(c))
            };
            let mut refs = Vec::with_capacity(facts.refs.len());
            for r in &facts.refs {
                let qualifier = match r.qualifier() {
                    Some(q) => Some(conn_id(q)?),
                    None => None,
                };
                refs.push(RefSite::new(conn_id(r.name)?, qualifier, r.line, r.enclosing(), r.kind));
            }
            let chunk = if parsed { chunk::encode(&facts.symbols, &facts.imports, &refs, &facts.hierarchy) } else { Vec::new() };
            let types = if facts.types.is_empty() { String::new() } else { facts.types.encode() };
            return Ok(Some(WireEntry { key_index, parsed, module_name: facts.module_name, line_count: facts.line_count, chunk, types }));
        }
        Ok(None)
    }
}

/// Answer frames on one stream until the asker closes it. Every WANT gets FACTS frames (cut at
/// `wire::FACTS_FRAME_BYTES`) and one DONE. A frame that is not a WANT, or a store error, ends
/// the stream with an ERROR frame.
pub fn serve_stream(store_root: &Path, r: &mut impl Read, w: &mut impl Write, counters: &ServeCounters) -> Result<()> {
    counters.connections.fetch_add(1, Ordering::Relaxed);
    let mut holder = Holder::new(store_root);
    let io = |e: std::io::Error| Error::Msg(format!("peer stream: {e}"));
    loop {
        let Some((kind, payload)) = wire::read_frame(r)? else { return Ok(()) };
        let answered = (|| -> Result<()> {
            if kind != KIND_WANT {
                return Err(Error::Msg(format!("expected a WANT frame, got kind {kind}")));
            }
            let keys = wire::decode_want(&payload)?;
            let (mut delivered, mut missing) = (0usize, 0usize);
            let mut frame = WireFacts::default();
            let mut frame_bytes = 0usize;
            for (i, key) in keys.iter().enumerate() {
                match holder.entry(i, key, &mut frame.new_names)? {
                    Some(e) => {
                        frame_bytes += e.chunk.len() + e.types.len() + 16;
                        frame.entries.push(e);
                        delivered += 1;
                    }
                    None => missing += 1,
                }
                if frame_bytes >= wire::FACTS_FRAME_BYTES {
                    let bytes = wire::encode_facts(&std::mem::take(&mut frame));
                    wire::write_frame(w, KIND_FACTS, &bytes).map_err(io)?;
                    counters.bytes_out.fetch_add(bytes.len() as u64 + 5, Ordering::Relaxed);
                    frame_bytes = 0;
                }
            }
            if !frame.entries.is_empty() || !frame.new_names.is_empty() {
                let bytes = wire::encode_facts(&frame);
                wire::write_frame(w, KIND_FACTS, &bytes).map_err(io)?;
                counters.bytes_out.fetch_add(bytes.len() as u64 + 5, Ordering::Relaxed);
            }
            wire::write_frame(w, KIND_DONE, &wire::encode_done(delivered, missing)).and_then(|_| w.flush()).map_err(io)?;
            counters.served.fetch_add(delivered as u64, Ordering::Relaxed);
            counters.missing.fetch_add(missing as u64, Ordering::Relaxed);
            Ok(())
        })();
        if let Err(e) = answered {
            let _ = wire::write_frame(w, KIND_ERROR, &wire::encode_error(&e.to_string())).and_then(|_| w.flush());
            return Err(e);
        }
    }
}
