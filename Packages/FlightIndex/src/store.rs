//! The persistent store: one SQLite file per repository.
//!
//! What is persisted is exactly the derived-but-expensive layers: **blob facts** (keyed by blob
//! id, language and parser version, shared by every worktree of the repository), **trees**
//! (commit -> path/blob/language, which also serve as garbage-collection roots) and the
//! **repo/worktree/overlay records**. The resolved graph is never stored; `graph` recomputes it
//! from facts in milliseconds.
//!
//! One file per repository makes dropping a repo `rm`, and confines damage from a corrupt file to
//! one repository. Facts are derived data, so on any schema-version mismatch the writer deletes
//! the file and starts over rather than migrating.
//!
//! The API enforces single-writer by type: `Writer` is the only handle that can mutate, and
//! `Reader` opens the file `SQLITE_OPEN_READ_ONLY`. The daemon owns one `Writer` per repository
//! and any number of `Reader`s; WAL lets those read while the writer commits.

use crate::error::{Error, Result};
use crate::facts::*;
use crate::git::{FileRef, Overlay};
use crate::lang;
use rusqlite::types::Value;
use rusqlite::{params, CachedStatement, Connection, OpenFlags, OptionalExtension, Transaction};
use sha1::{Digest, Sha1};
use std::ops::Deref;
use std::path::{Path, PathBuf};

/// Bump when the table layout changes. A mismatch rebuilds the file.
pub const SCHEMA_VERSION: i64 = 2;

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
    UNIQUE (blob_id, language, parser_version)
);
CREATE TABLE symbols (
    facts_id INTEGER NOT NULL REFERENCES facts(id) ON DELETE CASCADE,
    local_id INTEGER NOT NULL,
    name TEXT NOT NULL, kind TEXT NOT NULL,
    start_line INTEGER NOT NULL, start_col INTEGER NOT NULL,
    end_line INTEGER NOT NULL, end_col INTEGER NOT NULL,
    signature TEXT, parent INTEGER, exported INTEGER NOT NULL,
    PRIMARY KEY (facts_id, local_id)
) WITHOUT ROWID;
CREATE TABLE imports (
    facts_id INTEGER NOT NULL REFERENCES facts(id) ON DELETE CASCADE,
    idx INTEGER NOT NULL,
    specifier TEXT NOT NULL, alias TEXT, names TEXT NOT NULL, line INTEGER NOT NULL, kind TEXT NOT NULL,
    PRIMARY KEY (facts_id, idx)
) WITHOUT ROWID;
CREATE TABLE refs (
    facts_id INTEGER NOT NULL REFERENCES facts(id) ON DELETE CASCADE,
    idx INTEGER NOT NULL,
    name TEXT NOT NULL, qualifier TEXT, line INTEGER NOT NULL, enclosing INTEGER, kind TEXT NOT NULL,
    PRIMARY KEY (facts_id, idx)
) WITHOUT ROWID;
CREATE TABLE hierarchy (
    facts_id INTEGER NOT NULL REFERENCES facts(id) ON DELETE CASCADE,
    idx INTEGER NOT NULL,
    symbol INTEGER NOT NULL, target TEXT NOT NULL, kind TEXT NOT NULL,
    PRIMARY KEY (facts_id, idx)
) WITHOUT ROWID;
-- Tree maps. Every commit repeats most of its neighbours' paths and blobs, so a row holds only
-- integers: the path, blob id and language are interned once per store. `blobs.oid` holds a hex
-- git object id as its raw bytes (20 for SHA-1, 32 for SHA-256; no length is assumed) and
-- anything else as text. Orphan paths and blobs are deleted by `gc_roots`.
CREATE TABLE paths (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE);
CREATE TABLE blobs (id INTEGER PRIMARY KEY, oid BLOB NOT NULL UNIQUE);
CREATE TABLE languages (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE trees (id INTEGER PRIMARY KEY, commit_id TEXT NOT NULL UNIQUE, indexed_at INTEGER NOT NULL);
CREATE TABLE tree_entries (
    tree INTEGER NOT NULL REFERENCES trees(id) ON DELETE CASCADE,
    path INTEGER NOT NULL, blob INTEGER NOT NULL, language INTEGER NOT NULL,
    PRIMARY KEY (tree, path)
) WITHOUT ROWID;
CREATE TABLE worktrees (path TEXT PRIMARY KEY, head_commit TEXT, last_seen INTEGER NOT NULL);
CREATE TABLE overlays (
    worktree TEXT NOT NULL REFERENCES worktrees(path) ON DELETE CASCADE,
    path TEXT NOT NULL, blob_id TEXT, language TEXT,
    PRIMARY KEY (worktree, path)
) WITHOUT ROWID;
CREATE TABLE known_refs (name TEXT PRIMARY KEY, commit_id TEXT NOT NULL);
CREATE INDEX facts_blob ON facts(blob_id);
CREATE INDEX tree_entries_blob ON tree_entries(blob);
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
}

/// The single writer for one repository's database. Dereferences to `Reader` for queries.
pub struct Writer {
    reader: Reader,
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

/// A blob id as stored in `blobs.oid`: lowercase hex of even length (a git object id) as its raw
/// bytes, anything else as text, so `oid_string` gives back exactly what came in.
fn oid_value(blob_id: &str) -> Value {
    let b = blob_id.as_bytes();
    let nibble = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    if b.is_empty() || !b.len().is_multiple_of(2) {
        return Value::Text(blob_id.to_string());
    }
    let mut out = Vec::with_capacity(b.len() / 2);
    for pair in b.chunks_exact(2) {
        match (nibble(pair[0]), nibble(pair[1])) {
            (Some(h), Some(l)) => out.push(h << 4 | l),
            _ => return Value::Text(blob_id.to_string()),
        }
    }
    Value::Blob(out)
}

fn oid_string(v: Value) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    match v {
        Value::Blob(bytes) => bytes.iter().flat_map(|b| [HEX[(b >> 4) as usize] as char, HEX[(b & 15) as usize] as char]).collect(),
        Value::Text(s) => s,
        other => format!("{other:?}"),
    }
}

/// Look up a value's id in an intern table, inserting it on first sight.
struct Interner<'t> {
    select: CachedStatement<'t>,
    insert: CachedStatement<'t>,
}

impl<'t> Interner<'t> {
    fn new(tx: &'t Transaction, select: &str, insert: &str) -> Result<Self> {
        Ok(Interner { select: tx.prepare_cached(select)?, insert: tx.prepare_cached(insert)? })
    }

    fn id(&mut self, tx: &Transaction, v: Value) -> Result<i64> {
        if let Some(id) = self.select.query_row(params![v], |r| r.get(0)).optional()? {
            return Ok(id);
        }
        self.insert.execute(params![v])?;
        Ok(tx.last_insert_rowid())
    }
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
        }
        Ok(Writer { reader: Reader { conn, path: path.to_path_buf() } })
    }

    /// Insert a batch of parse results in one transaction. Re-inserting a key is a no-op, so two
    /// builds racing on the same blob cannot conflict.
    pub fn put_facts(&mut self, batch: &[ParsedBlob]) -> Result<()> {
        let tx = self.reader.conn.transaction()?;
        {
            let mut ins_facts = tx.prepare_cached(
                "INSERT OR IGNORE INTO facts (blob_id, language, parser_version, status, module_name, line_count)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )?;
            let mut ins_sym = tx.prepare_cached(
                "INSERT INTO symbols VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            )?;
            let mut ins_imp = tx.prepare_cached("INSERT INTO imports VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")?;
            let mut ins_ref = tx.prepare_cached("INSERT INTO refs VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")?;
            let mut ins_h = tx.prepare_cached("INSERT INTO hierarchy VALUES (?1, ?2, ?3, ?4, ?5)")?;
            for p in batch {
                let (status, module, lines) = match &p.facts {
                    Some(f) => (0, f.module_name.as_deref(), f.line_count),
                    None => (1, None, 0),
                };
                let inserted =
                    ins_facts.execute(params![p.blob_id, p.language, p.parser_version, status, module, lines])?;
                let Some(f) = &p.facts else { continue };
                if inserted == 0 {
                    continue;
                }
                let id = tx.last_insert_rowid();
                for s in &f.symbols {
                    ins_sym.execute(params![
                        id, s.local_id, s.name, s.kind.as_str(), s.start_line, s.start_col, s.end_line, s.end_col,
                        s.signature, s.parent, s.exported
                    ])?;
                }
                for (i, imp) in f.imports.iter().enumerate() {
                    ins_imp.execute(params![
                        id,
                        i as i64,
                        imp.specifier,
                        imp.alias,
                        serde_json::to_string(&imp.names).unwrap_or_else(|_| "[]".into()),
                        imp.line,
                        imp.kind.as_str()
                    ])?;
                }
                for (i, r) in f.refs.iter().enumerate() {
                    ins_ref.execute(params![id, i as i64, r.name, r.qualifier, r.line, r.enclosing, r.kind.as_str()])?;
                }
                for (i, h) in f.hierarchy.iter().enumerate() {
                    ins_h.execute(params![id, i as i64, h.symbol, h.target, h.kind.as_str()])?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Record a commit's indexable files. Replaces any earlier record of the same commit.
    pub fn put_tree(&mut self, commit: &str, files: &[FileRef]) -> Result<()> {
        let tx = self.reader.conn.transaction()?;
        tx.execute("DELETE FROM trees WHERE commit_id = ?1", params![commit])?;
        let tree: i64 = tx.query_row(
            "INSERT INTO trees (commit_id, indexed_at) VALUES (?1, ?2) RETURNING id",
            params![commit, now()],
            |r| r.get(0),
        )?;
        {
            let mut paths = Interner::new(&tx, "SELECT id FROM paths WHERE path = ?1", "INSERT INTO paths (path) VALUES (?1)")?;
            let mut blobs = Interner::new(&tx, "SELECT id FROM blobs WHERE oid = ?1", "INSERT INTO blobs (oid) VALUES (?1)")?;
            let mut langs =
                Interner::new(&tx, "SELECT id FROM languages WHERE name = ?1", "INSERT INTO languages (name) VALUES (?1)")?;
            let mut lang_ids: Vec<(&str, i64)> = Vec::new();
            let mut ins = tx.prepare_cached("INSERT INTO tree_entries VALUES (?1, ?2, ?3, ?4)")?;
            for f in files {
                let path = paths.id(&tx, Value::Text(f.path.clone()))?;
                let blob = blobs.id(&tx, oid_value(&f.blob_id))?;
                let language = match lang_ids.iter().find(|(n, _)| *n == f.language) {
                    Some(&(_, id)) => id,
                    None => {
                        let id = langs.id(&tx, Value::Text(f.language.to_string()))?;
                        lang_ids.push((f.language, id));
                        id
                    }
                };
                ins.execute(params![tree, path, blob, language])?;
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
        // Interned values never shrink on their own. The sweep scans every tree row (about 10 ms
        // on a 190k-row store), so it runs only when a tree went. A value orphaned by `put_tree`
        // replacing a commit (the engine never does) waits for the next such pass; until then an
        // extra row in `blobs` only keeps facts alive longer, never drops a rooted one.
        if !dead.is_empty() {
            tx.execute("DELETE FROM paths WHERE id NOT IN (SELECT path FROM tree_entries)", [])?;
            tx.execute("DELETE FROM blobs WHERE id NOT IN (SELECT blob FROM tree_entries)", [])?;
        }
        tx.commit()?;
        Ok((stats, dead))
    }

    /// Second half of `gc`: delete up to `limit` facts that no tree or overlay names, and every
    /// fact of a stale parser version. Returns how many went; call until it returns 0. Each call is
    /// its own transaction, so a collection of a large store never holds the writer for more than
    /// one chunk (the cascade over symbols, refs and imports is what makes a delete slow).
    pub fn gc_facts(&mut self, limit: usize) -> Result<usize> {
        let limit = limit.min(i64::MAX as usize) as i64;
        let mut n = self.reader.conn.execute(
            "DELETE FROM facts WHERE id IN (
               SELECT id FROM facts WHERE
                 -- `blobs` is every blob a tree named as of the last orphan sweep in `gc_roots`:
                 -- a superset of the live trees' blobs, so a rooted fact is never dropped.
                 blob_id NOT IN (SELECT CASE typeof(oid) WHEN 'blob' THEN lower(hex(oid)) ELSE oid END FROM blobs)
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
            Some(SCHEMA_VERSION) => Ok(Reader { conn, path }),
            other => Err(Error::Msg(format!("{}: schema version {other:?}, want {SCHEMA_VERSION}", path.display()))),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn has_facts(&self, blob_id: &str, language: &str, parser_version: u32) -> Result<bool> {
        let mut st = self
            .conn
            .prepare_cached("SELECT 1 FROM facts WHERE blob_id = ?1 AND language = ?2 AND parser_version = ?3")?;
        Ok(st.exists(params![blob_id, language, parser_version])?)
    }

    /// Facts for one blob; `Ok(None)` if absent. A skipped blob yields empty facts.
    pub fn get_facts(&self, blob_id: &str, language: &str, parser_version: u32) -> Result<Option<BlobFacts>> {
        let row = self
            .conn
            .prepare_cached(
                "SELECT id, status, module_name, line_count FROM facts
                 WHERE blob_id = ?1 AND language = ?2 AND parser_version = ?3",
            )?
            .query_row(params![blob_id, language, parser_version], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, u32>(3)?))
            })
            .optional()?;
        let Some((id, status, module_name, line_count)) = row else { return Ok(None) };
        let mut facts = BlobFacts { module_name, line_count, ..Default::default() };
        if status != 0 {
            return Ok(Some(facts));
        }
        let mut st = self.conn.prepare_cached(
            "SELECT local_id, name, kind, start_line, start_col, end_line, end_col, signature, parent, exported
             FROM symbols WHERE facts_id = ?1 ORDER BY local_id",
        )?;
        facts.symbols = st
            .query_map(params![id], |r| {
                Ok(Symbol {
                    local_id: r.get(0)?,
                    name: r.get(1)?,
                    kind: SymbolKind::parse(&r.get::<_, String>(2)?).unwrap_or(SymbolKind::Function),
                    start_line: r.get(3)?,
                    start_col: r.get(4)?,
                    end_line: r.get(5)?,
                    end_col: r.get(6)?,
                    signature: r.get(7)?,
                    parent: r.get(8)?,
                    exported: r.get(9)?,
                })
            })?
            .collect::<std::result::Result<_, _>>()?;
        let mut st = self.conn.prepare_cached(
            "SELECT specifier, alias, names, line, kind FROM imports WHERE facts_id = ?1 ORDER BY idx",
        )?;
        facts.imports = st
            .query_map(params![id], |r| {
                Ok(Import {
                    specifier: r.get(0)?,
                    alias: r.get(1)?,
                    names: serde_json::from_str(&r.get::<_, String>(2)?).unwrap_or_default(),
                    line: r.get(3)?,
                    kind: ImportKind::parse(&r.get::<_, String>(4)?),
                })
            })?
            .collect::<std::result::Result<_, _>>()?;
        let mut st = self.conn.prepare_cached(
            "SELECT name, qualifier, line, enclosing, kind FROM refs WHERE facts_id = ?1 ORDER BY idx",
        )?;
        facts.refs = st
            .query_map(params![id], |r| {
                Ok(Reference {
                    name: r.get(0)?,
                    qualifier: r.get(1)?,
                    line: r.get(2)?,
                    enclosing: r.get(3)?,
                    kind: RefKind::parse(&r.get::<_, String>(4)?),
                })
            })?
            .collect::<std::result::Result<_, _>>()?;
        let mut st = self
            .conn
            .prepare_cached("SELECT symbol, target, kind FROM hierarchy WHERE facts_id = ?1 ORDER BY idx")?;
        facts.hierarchy = st
            .query_map(params![id], |r| {
                Ok(TypeRelation {
                    symbol: r.get(0)?,
                    target: r.get(1)?,
                    kind: HierarchyKind::parse(&r.get::<_, String>(2)?),
                })
            })?
            .collect::<std::result::Result<_, _>>()?;
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
        let mut st = self.conn.prepare_cached(
            "SELECT p.path, b.oid, l.name FROM trees t
               JOIN tree_entries e ON e.tree = t.id
               JOIN paths p ON p.id = e.path
               JOIN blobs b ON b.id = e.blob
               JOIN languages l ON l.id = e.language
             WHERE t.commit_id = ?1 ORDER BY p.path",
        )?;
        let rows = st.query_map(params![commit], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Value>(1)?, r.get::<_, String>(2)?)))?;
        let mut out = Vec::new();
        for r in rows {
            let (path, oid, language) = r?;
            if let Some(l) = lang::by_id(&language) {
                out.push(FileRef { path, blob_id: oid_string(oid), language: l.id() });
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
            symbols: count("SELECT count(*) FROM symbols")?,
            trees: count("SELECT count(*) FROM trees")?,
            worktrees: count("SELECT count(*) FROM worktrees")?,
            page_count: count("PRAGMA page_count")?,
            free_pages: count("PRAGMA freelist_count")?,
            page_size: count("PRAGMA page_size")?,
        })
    }
}
