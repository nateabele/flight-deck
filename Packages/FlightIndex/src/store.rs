//! The persistent store: one SQLite file per repository.
//!
//! What is persisted is exactly the derived-but-expensive layers: **blob facts** (keyed by blob
//! id, language and parser version, shared by every worktree of the repository), **trees**
//! (commit -> path/blob/language, which also serve as garbage-collection roots) and the
//! **repo/worktree/overlay records**. The resolved graph is never stored; `graph` recomputes it
//! from facts in milliseconds.
//!
//! A blob's facts are one `facts` row (key, status, module name, line count) plus one columnar
//! byte chunk in `chunks` (see `chunk`): nothing ever reads a single symbol or reference from the
//! store, only a whole blob, so a row per fact paid SQLite's per-row overhead 4M times on tessera
//! for nothing.
//!
//! One file per repository makes dropping a repo `rm`, and confines damage from a corrupt file to
//! one repository. Facts are derived data, so on any schema-version mismatch the writer deletes
//! the file and starts over rather than migrating.
//!
//! The API enforces single-writer by type: `Writer` is the only handle that can mutate, and
//! `Reader` opens the file `SQLITE_OPEN_READ_ONLY`. The daemon owns one `Writer` per repository
//! and any number of `Reader`s; WAL lets those read while the writer commits.

use crate::chunk;
use crate::error::{Error, Result};
use crate::facts::*;
use crate::git::{FileRef, Overlay};
use crate::lang;
use crate::names::{NameId, NamePool};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use sha1::{Digest, Sha1};
use std::ops::Deref;
use std::path::{Path, PathBuf};

/// Bump when the table layout changes. A mismatch rebuilds the file.
///
/// 2: reference names and qualifiers are ids into a `names` table (see `names`), and `facts`
/// records each blob's reference count.
/// 3: symbols, imports, references and relations are one columnar chunk per blob (`chunks`,
/// format `chunk::FORMAT`) instead of a row each; `facts` records the symbol count.
pub const SCHEMA_VERSION: i64 = 3;

/// Where the index lives by default: `~/Library/Application Support/FlightDeck/index` on macOS,
/// `$XDG_DATA_HOME/flightdeck/index` (else `~/.local/share/flightdeck/index`) elsewhere.
/// `FLIGHTDECK_INDEX_DIR` overrides both.
pub fn default_store_root() -> PathBuf {
    if let Some(dir) = std::env::var_os("FLIGHTDECK_INDEX_DIR") {
        return PathBuf::from(dir);
    }
    let home = || PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    if cfg!(target_os = "macos") {
        home().join("Library/Application Support/FlightDeck/index")
    } else {
        match std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
            Some(x) => PathBuf::from(x).join("flightdeck/index"),
            None => home().join(".local/share/flightdeck/index"),
        }
    }
}

/// `<root>/<repo-name>-<8 hex of sha1(repo key)>.db`. The name is only for humans browsing the
/// directory; the hash is what keeps two repos called `app` apart.
pub fn db_path(store_root: &Path, repo: &Path) -> PathBuf {
    let base = if repo.file_name().is_some_and(|n| n == ".git") { repo.parent().unwrap_or(repo) } else { repo };
    let name: String = base
        .file_name()
        .map(|n| n.to_string_lossy().chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' }).collect())
        .unwrap_or_else(|| "repo".into());
    let digest = Sha1::digest(repo.to_string_lossy().as_bytes());
    let hash: String = digest.iter().take(4).map(|b| format!("{b:02x}")).collect();
    store_root.join(format!("{name}-{hash}.db"))
}

/// Every repository database under `store_root`, with the repository each records (`None` for a
/// file that cannot be read). The retention pass uses it to find repositories whose common dir is
/// gone, which no request will ever name again.
pub fn list_dbs(store_root: &Path) -> Vec<(PathBuf, Option<PathBuf>)> {
    let Ok(rd) = std::fs::read_dir(store_root) else { return Vec::new() };
    let mut out: Vec<(PathBuf, Option<PathBuf>)> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "db"))
        .map(|p| {
            let repo = Connection::open_with_flags(&p, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
                .ok()
                .and_then(|c| c.query_row("SELECT value FROM meta WHERE key = 'repo'", [], |r| r.get::<_, String>(0)).ok())
                .map(PathBuf::from);
            (p, repo)
        })
        .collect();
    out.sort();
    out
}

/// Delete a repository's database and its WAL files.
pub fn remove_repo_db(store_root: &Path, repo: &Path) {
    remove_db_files(&db_path(store_root, repo));
}

/// Bytes a repository's database occupies on disk: main file plus WAL.
pub fn db_bytes(db: &Path) -> u64 {
    ["", "-wal"]
        .iter()
        .map(|suffix| {
            let mut p = db.as_os_str().to_owned();
            p.push(suffix);
            std::fs::metadata(PathBuf::from(p)).map(|m| m.len()).unwrap_or(0)
        })
        .sum()
}

const SCHEMA: &str = "
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE facts (
    id INTEGER PRIMARY KEY,
    blob_id TEXT NOT NULL,
    language TEXT NOT NULL,
    parser_version INTEGER NOT NULL,
    -- 0 = parsed, 1 = skipped (not UTF-8). A skipped row is still recorded so a binary-ish blob
    -- is not re-read on every build.
    status INTEGER NOT NULL DEFAULT 0,
    module_name TEXT,
    line_count INTEGER NOT NULL,
    -- Symbols in this blob's chunk, so `stats` can count symbols without decoding every chunk.
    symbol_count INTEGER NOT NULL DEFAULT 0,
    UNIQUE (blob_id, language, parser_version)
);
-- Every reference name and qualifier the repository has stored, once. Append-only: ids are
-- what chunks and every in-memory pool hold, so a row is never deleted or renumbered (GC leaves
-- names of dead blobs behind; 28.0k -> 28.4k ids across seven tessera commits). Ids are assigned
-- densely from 0 by the writer.
CREATE TABLE names (id INTEGER PRIMARY KEY, s TEXT NOT NULL UNIQUE);
-- One blob's symbols, imports, references and relations, encoded by `chunk`. A skipped blob has
-- no chunk. Kept out of `facts` so the garbage collector's scans over `facts` stay a few pages.
CREATE TABLE chunks (
    facts_id INTEGER PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE,
    data BLOB NOT NULL
);
CREATE TABLE trees (commit_id TEXT PRIMARY KEY, indexed_at INTEGER NOT NULL);
CREATE TABLE tree_entries (
    commit_id TEXT NOT NULL REFERENCES trees(commit_id) ON DELETE CASCADE,
    path TEXT NOT NULL, blob_id TEXT NOT NULL, language TEXT NOT NULL,
    PRIMARY KEY (commit_id, path)
) WITHOUT ROWID;
CREATE TABLE worktrees (path TEXT PRIMARY KEY, head_commit TEXT, last_seen INTEGER NOT NULL);
CREATE TABLE overlays (
    worktree TEXT NOT NULL REFERENCES worktrees(path) ON DELETE CASCADE,
    path TEXT NOT NULL, blob_id TEXT, language TEXT,
    PRIMARY KEY (worktree, path)
) WITHOUT ROWID;
CREATE TABLE known_refs (name TEXT PRIMARY KEY, commit_id TEXT NOT NULL);
CREATE INDEX tree_entries_blob ON tree_entries(blob_id);
";

/// What the parse step hands the writer. `facts` is `None` when the blob was skipped (not UTF-8).
pub struct ParsedBlob {
    pub blob_id: String,
    pub language: &'static str,
    pub parser_version: u32,
    pub facts: Option<BlobFacts>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GcStats {
    pub worktrees_dropped: usize,
    pub trees_dropped: usize,
    pub facts_dropped: usize,
}

#[derive(Debug, Clone, Default)]
pub struct StoreStats {
    pub facts: u64,
    pub symbols: u64,
    pub trees: u64,
    pub worktrees: u64,
    pub page_count: u64,
    pub free_pages: u64,
    pub page_size: u64,
}

/// Read-only access. Cheap to open; open as many as you like.
pub struct Reader {
    conn: Connection,
    path: PathBuf,
    store_id: u64,
}

/// The single writer for one repository's database. Dereferences to `Reader` for queries.
pub struct Writer {
    reader: Reader,
    /// The `names` table as this writer has seen it, read on the first `put_facts`. Another
    /// process may have added names since; a miss goes to the table, which stays the authority.
    names: Option<NamePool>,
}

impl Deref for Writer {
    type Target = Reader;
    fn deref(&self) -> &Reader {
        &self.reader
    }
}

/// `Ok(None)` means "no recognisable schema" (empty file, no meta table); any other failure
/// (busy, I/O) is an error, so a transient problem can never be mistaken for a stale schema.
fn read_version(conn: &Connection) -> Result<Option<i64>> {
    match conn.query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |r| r.get::<_, String>(0)) {
        Ok(v) => Ok(v.parse().ok()),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(rusqlite::Error::SqliteFailure(_, Some(msg))) if msg.contains("no such table") => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// The `store_id` meta value: which file assigned this store's name ids (`names`).
fn read_store_id(conn: &Connection) -> Result<u64> {
    let v: Option<String> =
        conn.query_row("SELECT value FROM meta WHERE key = 'store_id'", [], |r| r.get(0)).optional()?;
    Ok(v.and_then(|v| v.parse().ok()).unwrap_or(0))
}

/// A fresh identity for a new database file. Only has to differ from the file it replaces, so
/// the clock and pid are enough; no randomness dependency for it.
fn new_store_id() -> u64 {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mut h = Sha1::new();
    h.update(nanos.to_le_bytes());
    h.update(std::process::id().to_le_bytes());
    let d = h.finalize();
    // Positive i64 range, so it survives SQLite and JSON unchanged.
    u64::from_le_bytes(d[..8].try_into().unwrap()) >> 1
}

fn remove_db_files(path: &Path) {
    for suffix in ["", "-wal", "-shm"] {
        let mut p = path.as_os_str().to_owned();
        p.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(p));
    }
}

fn is_rebuildable(e: &Error) -> bool {
    use rusqlite::ErrorCode::{DatabaseCorrupt, NotADatabase};
    match e {
        Error::Msg(_) => true, // schema version mismatch
        Error::Store(rusqlite::Error::SqliteFailure(f, _)) => matches!(f.code, NotADatabase | DatabaseCorrupt),
        _ => false,
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl Writer {
    /// Open (creating if needed) the database for `repo`. A file with a different schema version,
    /// or one SQLite cannot read at all, is deleted and recreated: facts are derived data.
    pub fn open(store_root: &Path, repo: &Path) -> Result<Writer> {
        std::fs::create_dir_all(store_root).map_err(|e| Error::io(store_root, e))?;
        let path = db_path(store_root, repo);
        for attempt in 0..2 {
            match Self::try_open(&path, repo) {
                Ok(w) => return Ok(w),
                // Only a stale or unreadable *file* is rebuilt; a busy or permission error must
                // not delete a healthy database.
                Err(e) if attempt == 0 && is_rebuildable(&e) => remove_db_files(&path),
                Err(e) => return Err(e),
            }
        }
        unreachable!()
    }

    fn try_open(path: &Path, repo: &Path) -> Result<Writer> {
        let existed = path.exists();
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        if existed {
            match read_version(&conn)? {
                Some(SCHEMA_VERSION) => {}
                other => {
                    return Err(Error::Msg(format!("schema version {other:?}, want {SCHEMA_VERSION}; rebuilding")));
                }
            }
        } else {
            // auto_vacuum only takes effect before the first table exists. INCREMENTAL lets
            // `incremental_vacuum` return freed pages on a schedule instead of the file only ever
            // growing (the qartez failure: 28 GB of free pages in one index.db).
            conn.pragma_update(None, "auto_vacuum", "INCREMENTAL")?;
        }
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        if !existed {
            conn.execute_batch(SCHEMA)?;
            conn.execute("INSERT INTO meta VALUES ('schema_version', ?1)", params![SCHEMA_VERSION.to_string()])?;
            conn.execute("INSERT INTO meta VALUES ('repo', ?1)", params![repo.to_string_lossy()])?;
            conn.execute("INSERT INTO meta VALUES ('store_id', ?1)", params![new_store_id().to_string()])?;
        }
        let store_id = read_store_id(&conn)?;
        Ok(Writer { reader: Reader { conn, path: path.to_path_buf(), store_id }, names: None })
    }

    /// Insert a batch of parse results in one transaction. Re-inserting a key is a no-op, so two
    /// builds racing on the same blob cannot conflict.
    pub fn put_facts(&mut self, batch: &[ParsedBlob]) -> Result<()> {
        if self.names.is_none() {
            let mut pool = NamePool::new(self.reader.store_id);
            self.reader.load_names(&mut pool)?;
            self.names = Some(pool);
        }
        // Ids learned inside the transaction go into a copy, adopted only on commit: a rolled-back
        // insert must not leave the writer believing a name has an id the table never got.
        let mut names = self.names.clone().unwrap_or_default();
        let tx = self.reader.conn.transaction()?;
        {
            let mut ins_facts = tx.prepare_cached(
                "INSERT OR IGNORE INTO facts (blob_id, language, parser_version, status, module_name, line_count, symbol_count)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            )?;
            // Dense ids from 0, assigned here rather than by rowid so they start where an
            // in-memory pool's indices do. `OR IGNORE` because another writer process may have
            // added the name since this one last looked; the SELECT then reads its id.
            let mut ins_name = tx.prepare_cached(
                "INSERT OR IGNORE INTO names (id, s) SELECT coalesce(max(id) + 1, 0), ?1 FROM names",
            )?;
            let mut sel_name = tx.prepare_cached("SELECT id FROM names WHERE s = ?1")?;
            let mut intern = |s: &str| -> Result<NameId> {
                if let Some(id) = names.get(s) {
                    return Ok(id);
                }
                ins_name.execute(params![s])?;
                let id: i64 = sel_name.query_row(params![s], |r| r.get(0))?;
                names.set(NameId(id as u32), s);
                Ok(NameId(id as u32))
            };
            let mut ins_chunk = tx.prepare_cached("INSERT INTO chunks (facts_id, data) VALUES (?1, ?2)")?;
            for p in batch {
                let (status, module, lines, nsyms) = match &p.facts {
                    Some(f) => (0, f.module_name.as_deref(), f.line_count, f.symbols.len()),
                    None => (1, None, 0, 0),
                };
                let inserted =
                    ins_facts.execute(params![p.blob_id, p.language, p.parser_version, status, module, lines, nsyms as i64])?;
                let Some(f) = &p.facts else { continue };
                if inserted == 0 {
                    continue;
                }
                let id = tx.last_insert_rowid();
                let mut sites = Vec::with_capacity(f.refs.len());
                for r in &f.refs {
                    let qual = match &r.qualifier {
                        Some(q) => Some(intern(q)?),
                        None => None,
                    };
                    sites.push(RefSite::new(intern(&r.name)?, qual, r.line, r.enclosing, r.kind));
                }
                ins_chunk.execute(params![id, chunk::encode(&f.symbols, &f.imports, &sites, &f.hierarchy)])?;
            }
        }
        tx.commit()?;
        self.names = Some(names);
        Ok(())
    }

    /// Record a commit's indexable files. Replaces any earlier record of the same commit.
    pub fn put_tree(&mut self, commit: &str, files: &[FileRef]) -> Result<()> {
        let tx = self.reader.conn.transaction()?;
        tx.execute("DELETE FROM trees WHERE commit_id = ?1", params![commit])?;
        tx.execute("INSERT INTO trees VALUES (?1, ?2)", params![commit, now()])?;
        {
            let mut ins = tx.prepare_cached("INSERT INTO tree_entries VALUES (?1, ?2, ?3, ?4)")?;
            for f in files {
                ins.execute(params![commit, f.path, f.blob_id, f.language])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Record a worktree and replace its overlay. The overlay's blobs are GC roots.
    pub fn set_worktree(&mut self, worktree: &Path, head: Option<&str>, overlay: &[Overlay]) -> Result<()> {
        let key = worktree.to_string_lossy();
        let tx = self.reader.conn.transaction()?;
        tx.execute(
            "INSERT INTO worktrees VALUES (?1, ?2, ?3)
             ON CONFLICT(path) DO UPDATE SET head_commit = excluded.head_commit, last_seen = excluded.last_seen",
            params![key, head, now()],
        )?;
        tx.execute("DELETE FROM overlays WHERE worktree = ?1", params![key])?;
        {
            let mut ins = tx.prepare_cached("INSERT OR REPLACE INTO overlays VALUES (?1, ?2, ?3, ?4)")?;
            for o in overlay {
                match o {
                    Overlay::Present(f) => ins.execute(params![key, f.path, f.blob_id, f.language])?,
                    Overlay::Deleted(p) => ins.execute(params![key, p, Option::<String>::None, Option::<String>::None])?,
                };
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn remove_worktree(&mut self, worktree: &Path) -> Result<()> {
        self.reader.conn.execute("DELETE FROM worktrees WHERE path = ?1", params![worktree.to_string_lossy()])?;
        Ok(())
    }

    /// Replace the set of known refs (branch/tag heads). Their trees survive garbage collection.
    pub fn set_known_refs(&mut self, refs: &[(String, String)]) -> Result<()> {
        let tx = self.reader.conn.transaction()?;
        tx.execute("DELETE FROM known_refs", [])?;
        {
            let mut ins = tx.prepare_cached("INSERT INTO known_refs VALUES (?1, ?2)")?;
            for (n, c) in refs {
                ins.execute(params![n, c])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Drop what nothing references: worktrees whose directory is gone, trees no live worktree
    /// HEAD or known ref names, and facts no remaining tree or overlay names (or whose parser
    /// version is stale). Without this the store grows as worktrees come and go.
    ///
    /// One call does all of it, which holds the writer for as long as the deletes take. The daemon
    /// uses `gc_roots` and `gc_facts` instead, so it can let go of the writer between chunks.
    pub fn gc(&mut self) -> Result<GcStats> {
        let (mut stats, _) = self.gc_roots()?;
        loop {
            match self.gc_facts(usize::MAX)? {
                0 => break,
                n => stats.facts_dropped += n,
            }
        }
        Ok(stats)
    }

    /// First half of `gc`: the roots. Returns what was dropped and the commits whose trees went,
    /// so the caller can stop treating them as fully indexed.
    pub fn gc_roots(&mut self) -> Result<(GcStats, Vec<String>)> {
        let tx = self.reader.conn.transaction()?;
        let mut stats = GcStats::default();

        let gone: Vec<String> = {
            let mut st = tx.prepare("SELECT path FROM worktrees")?;
            let rows = st.query_map([], |r| r.get::<_, String>(0))?;
            rows.filter_map(|r| r.ok()).filter(|p| !Path::new(p).exists()).collect()
        };
        for p in &gone {
            tx.execute("DELETE FROM worktrees WHERE path = ?1", params![p])?;
        }
        stats.worktrees_dropped = gone.len();

        let dead: Vec<String> = {
            let mut st = tx.prepare(
                "SELECT commit_id FROM trees WHERE commit_id NOT IN (SELECT head_commit FROM worktrees WHERE head_commit IS NOT NULL)
                   AND commit_id NOT IN (SELECT commit_id FROM known_refs)",
            )?;
            let rows = st.query_map([], |r| r.get::<_, String>(0))?;
            rows.collect::<std::result::Result<_, _>>()?
        };
        for c in &dead {
            tx.execute("DELETE FROM trees WHERE commit_id = ?1", params![c])?;
        }
        stats.trees_dropped = dead.len();
        tx.commit()?;
        Ok((stats, dead))
    }

    /// Second half of `gc`: delete up to `limit` facts that no tree or overlay names, and every
    /// fact of a stale parser version. Returns how many went; call until it returns 0. Each call is
    /// its own transaction, so a collection of a large store never holds the writer for more than
    /// one batch.
    pub fn gc_facts(&mut self, limit: usize) -> Result<usize> {
        let limit = limit.min(i64::MAX as usize) as i64;
        let mut n = self.reader.conn.execute(
            "DELETE FROM facts WHERE id IN (
               SELECT id FROM facts WHERE
                 blob_id NOT IN (SELECT blob_id FROM tree_entries)
                 AND blob_id NOT IN (SELECT blob_id FROM overlays WHERE blob_id IS NOT NULL)
               LIMIT ?1)",
            params![limit],
        )?;
        for l in lang::all() {
            if n as i64 >= limit {
                break;
            }
            n += self.reader.conn.execute(
                "DELETE FROM facts WHERE id IN (SELECT id FROM facts WHERE language = ?1 AND parser_version != ?2 LIMIT ?3)",
                params![l.id(), l.parser_version(), limit - n as i64],
            )?;
        }
        Ok(n)
    }

    /// Return up to `pages` free pages to the filesystem (0 = all). Returns the pages freed.
    pub fn incremental_vacuum(&mut self, pages: u32) -> Result<u64> {
        let before = self.stats()?.free_pages;
        let sql = if pages == 0 { "PRAGMA incremental_vacuum".to_string() } else { format!("PRAGMA incremental_vacuum({pages})") };
        let mut st = self.reader.conn.prepare(&sql)?;
        let mut rows = st.query([])?;
        while rows.next()?.is_some() {}
        drop(rows);
        drop(st);
        Ok(before - self.stats()?.free_pages)
    }

    /// Fold the WAL back into the main file and truncate it. A reader that is mid-query makes
    /// SQLite wait, and the writer is held meanwhile, so the wait is short: a checkpoint that
    /// cannot finish now is simply not done, and the next one will.
    pub fn checkpoint(&mut self) -> Result<()> {
        self.reader.conn.busy_timeout(std::time::Duration::from_millis(100))?;
        let done = self.reader.conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
        self.reader.conn.busy_timeout(std::time::Duration::from_secs(5))?;
        done?;
        Ok(())
    }
}

impl Reader {
    /// Open an existing database read-only. Fails if it is absent or has another schema version
    /// (only the writer may rebuild).
    pub fn open(store_root: &Path, repo: &Path) -> Result<Reader> {
        let path = db_path(store_root, repo);
        let conn = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        match read_version(&conn)? {
            Some(SCHEMA_VERSION) => {
                let store_id = read_store_id(&conn)?;
                Ok(Reader { conn, path, store_id })
            }
            other => Err(Error::Msg(format!("{}: schema version {other:?}, want {SCHEMA_VERSION}", path.display()))),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Identifies the file that assigned this store's name ids; a rebuilt file gets a new one.
    pub fn store_id(&self) -> u64 {
        self.store_id
    }

    /// Add to `pool` every name the store has past `pool.len()`. 28k names read in about 2 ms,
    /// so a fresh pool loads the whole table and a warm one reads only what is new.
    pub fn load_names(&self, pool: &mut NamePool) -> Result<()> {
        let mut st = self.conn.prepare_cached("SELECT id, s FROM names WHERE id >= ?1 ORDER BY id")?;
        let mut rows = st.query(params![pool.len() as i64])?;
        while let Some(r) = rows.next()? {
            let id: i64 = r.get(0)?;
            let s = r.get_ref(1)?.as_str().map_err(rusqlite::Error::from)?;
            pool.set(NameId(id as u32), s);
        }
        Ok(())
    }

    pub fn has_facts(&self, blob_id: &str, language: &str, parser_version: u32) -> Result<bool> {
        let mut st = self
            .conn
            .prepare_cached("SELECT 1 FROM facts WHERE blob_id = ?1 AND language = ?2 AND parser_version = ?3")?;
        Ok(st.exists(params![blob_id, language, parser_version])?)
    }

    /// Facts for one blob with names as text, as the parser produced them; `Ok(None)` if absent.
    /// A skipped blob yields empty facts. The graph loads `get_interned` instead; this resolves
    /// each distinct name id with one indexed lookup, which is fine off the hot path.
    pub fn get_facts(&self, blob_id: &str, language: &str, parser_version: u32) -> Result<Option<BlobFacts>> {
        let Some(f) = self.get_interned(blob_id, language, parser_version)? else { return Ok(None) };
        let mut st = self.conn.prepare_cached("SELECT s FROM names WHERE id = ?1")?;
        let mut text: std::collections::HashMap<NameId, String> = std::collections::HashMap::new();
        let mut resolve = |id: NameId| -> Result<String> {
            if let Some(s) = text.get(&id) {
                return Ok(s.clone());
            }
            let s: String = st.query_row(params![id.0 as i64], |r| r.get(0))?;
            text.insert(id, s.clone());
            Ok(s)
        };
        let mut refs = Vec::with_capacity(f.refs.len());
        for r in &f.refs {
            let qualifier = match r.qualifier() {
                Some(q) => Some(resolve(q)?),
                None => None,
            };
            refs.push(Reference { name: resolve(r.name)?, qualifier, line: r.line, enclosing: r.enclosing(), kind: r.kind });
        }
        Ok(Some(BlobFacts {
            module_name: f.module_name,
            line_count: f.line_count,
            symbols: f.symbols,
            imports: f.imports,
            refs,
            hierarchy: f.hierarchy,
        }))
    }

    /// Facts for one blob with references as store name ids (resolve them through a pool filled
    /// by `load_names` from this store); `Ok(None)` if absent. One row and one chunk, whose
    /// vectors come out of the decoder exactly sized.
    pub fn get_interned(&self, blob_id: &str, language: &str, parser_version: u32) -> Result<Option<InternedFacts>> {
        let row = self
            .conn
            .prepare_cached(
                "SELECT f.status, f.module_name, f.line_count, c.data FROM facts f LEFT JOIN chunks c ON c.facts_id = f.id
                 WHERE f.blob_id = ?1 AND f.language = ?2 AND f.parser_version = ?3",
            )?
            .query_row(params![blob_id, language, parser_version], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, u32>(2)?, r.get::<_, Option<Vec<u8>>>(3)?))
            })
            .optional()?;
        let Some((status, module_name, line_count, data)) = row else { return Ok(None) };
        let mut facts = InternedFacts { module_name, line_count, ..Default::default() };
        if status != 0 {
            return Ok(Some(facts));
        }
        // A parsed blob without a chunk cannot happen (both are written in one transaction); read
        // it as empty rather than failing every graph of the repository.
        let Some(data) = data else { return Ok(Some(facts)) };
        let d = chunk::decode(&data)?;
        facts.name_bound = d.refs.iter().map(|r| r.name.0.max(r.qualifier().map_or(0, |q| q.0)) + 1).max().unwrap_or(0);
        facts.symbols = d.symbols;
        facts.imports = d.imports;
        facts.refs = d.refs;
        facts.hierarchy = d.hierarchy;
        Ok(Some(facts))
    }

    pub fn has_tree(&self, commit: &str) -> Result<bool> {
        let mut st = self.conn.prepare_cached("SELECT 1 FROM trees WHERE commit_id = ?1")?;
        Ok(st.exists(params![commit])?)
    }

    pub fn get_tree(&self, commit: &str) -> Result<Option<Vec<FileRef>>> {
        if !self.has_tree(commit)? {
            return Ok(None);
        }
        let mut st = self
            .conn
            .prepare_cached("SELECT path, blob_id, language FROM tree_entries WHERE commit_id = ?1 ORDER BY path")?;
        let rows = st.query_map(params![commit], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))?;
        let mut out = Vec::new();
        for r in rows {
            let (path, blob_id, language) = r?;
            if let Some(l) = lang::by_id(&language) {
                out.push(FileRef { path, blob_id, language: l.id() });
            }
        }
        Ok(Some(out))
    }

    /// The overlay recorded for a worktree, or empty.
    pub fn get_overlay(&self, worktree: &Path) -> Result<Vec<Overlay>> {
        let mut st = self.conn.prepare_cached("SELECT path, blob_id, language FROM overlays WHERE worktree = ?1 ORDER BY path")?;
        let rows = st.query_map(params![worktree.to_string_lossy()], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Option<String>>(2)?))
        })?;
        let mut out = Vec::new();
        for r in rows {
            let (path, blob, language) = r?;
            out.push(match (blob, language.as_deref().and_then(lang::by_id)) {
                (Some(blob_id), Some(l)) => Overlay::Present(FileRef { path, blob_id, language: l.id() }),
                _ => Overlay::Deleted(path),
            });
        }
        Ok(out)
    }

    /// Branch heads recorded by `set_known_refs`.
    pub fn known_refs(&self) -> Result<Vec<(String, String)>> {
        let mut st = self.conn.prepare_cached("SELECT name, commit_id FROM known_refs ORDER BY name")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn worktrees(&self) -> Result<Vec<(PathBuf, Option<String>)>> {
        let mut st = self.conn.prepare_cached("SELECT path, head_commit FROM worktrees ORDER BY path")?;
        let rows = st.query_map([], |r| Ok((PathBuf::from(r.get::<_, String>(0)?), r.get::<_, Option<String>>(1)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn stats(&self) -> Result<StoreStats> {
        let count = |sql: &str| -> Result<u64> { Ok(self.conn.query_row(sql, [], |r| r.get::<_, i64>(0))? as u64) };
        Ok(StoreStats {
            facts: count("SELECT count(*) FROM facts")?,
            symbols: count("SELECT coalesce(sum(symbol_count), 0) FROM facts")?,
            trees: count("SELECT count(*) FROM trees")?,
            worktrees: count("SELECT count(*) FROM worktrees")?,
            page_count: count("PRAGMA page_count")?,
            free_pages: count("PRAGMA freelist_count")?,
            page_size: count("PRAGMA page_size")?,
        })
    }
}
