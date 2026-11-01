//! The daemon's brain, without the socket: turn a `Request` into a `Response`.
//!
//! Keeping it socket-free means the whole request path (view resolution, auto-build, freshness,
//! the tools) is testable in-process, and the daemon is only transport.
//!
//! One request, in order:
//!
//! 1. Paths in the arguments resolve against the caller's `cwd`; the view is the one containing
//!    the *resolved path* (so `../tessera/...` named from another repo is answered from tessera), and
//!    a query that names no path uses the view containing `cwd`.
//! 2. The view is recomputed from git on every request: its overlay is whatever differs from
//!    HEAD right now. That is the freshness rule until the watcher exists (an edit made a moment
//!    ago is in the overlay, parsed on demand, and visible to this query). `Freshness` is the seam
//!    the watcher replaces.
//! 3. If the store lacks facts for the view, it is built, requested paths first, and the request
//!    waits for that slice up to a bound; past the bound it answers from what is stored and says
//!    so in the header.
//! 4. The tool runs on the view's graph and the result gets the view header.

use crate::cochange::CoChange;
use crate::engine::{Engine, Phase, Progress, DEFAULT_GRAPH_BUDGET};
use crate::error::{Error, Result};
use crate::git::{self, View};
use crate::proto::{state, Request, Response, PROTOCOL_VERSION};
use crate::tools::{self, args::Args, Ctx, ToolError};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

/// A request never waits on a build longer than this, whatever it asks for: an agent blocked on
/// the index is worse off than one told "building" (spec §6 puts the ceiling at the 30 s lock
/// deadline).
pub const MAX_BUILD_WAIT: Duration = Duration::from_secs(30);
pub const DEFAULT_BUILD_WAIT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
pub struct Config {
    pub store: PathBuf,
    pub build_wait: Duration,
    pub graph_budget: usize,
}

impl Config {
    pub fn new(store: impl Into<PathBuf>) -> Config {
        Config { store: store.into(), build_wait: DEFAULT_BUILD_WAIT, graph_budget: DEFAULT_GRAPH_BUDGET }
    }
}

/// One repository's co-change, computed once by whichever request needs it first.
type CoChangeCell = Arc<OnceLock<std::result::Result<Arc<CoChange>, String>>>;

/// What a build is doing, shared between the thread running it and the requests waiting on it.
struct Job {
    state: Mutex<JobState>,
    cv: Condvar,
    priority: Vec<PathBuf>,
    started: Instant,
}

struct JobState {
    progress: Progress,
    finished: Option<std::result::Result<(), String>>,
}

impl Job {
    /// Does this job's priority slice contain everything `wanted` names?
    fn covers(&self, wanted: &[PathBuf]) -> bool {
        wanted.iter().all(|w| self.priority.iter().any(|p| w.starts_with(p)))
    }
}

#[derive(Debug, Clone, Copy)]
enum Readiness {
    Ready,
    Building { done: usize, total: usize },
}

struct ViewInfo {
    repo: PathBuf,
    base: Option<String>,
    dirty_files: usize,
    requests: u64,
    last_used: SystemTime,
}

pub struct Service {
    pub engine: Engine,
    cfg: Config,
    freshness: Freshness,
    builds: Mutex<HashMap<PathBuf, Arc<Job>>>,
    views: Mutex<HashMap<PathBuf, ViewInfo>>,
    cochange: Mutex<HashMap<PathBuf, (String, CoChangeCell)>>,
    /// Last `seq` seen per cwd. Nothing reads it yet; the watcher step uses it to prove a
    /// caller's earlier edits were indexed before it is answered.
    seqs: Mutex<HashMap<String, u64>>,
    started: Instant,
    requests: AtomicU64,
    errors: AtomicU64,
}

impl Service {
    pub fn open(cfg: Config) -> Result<Arc<Service>> {
        let engine = Engine::open(&cfg.store)?;
        engine.set_graph_budget(cfg.graph_budget);
        Ok(Arc::new(Service {
            engine,
            cfg,
            freshness: Freshness::default(),
            builds: Mutex::new(HashMap::new()),
            views: Mutex::new(HashMap::new()),
            cochange: Mutex::new(HashMap::new()),
            seqs: Mutex::new(HashMap::new()),
            started: Instant::now(),
            requests: AtomicU64::new(0),
            errors: AtomicU64::new(0),
        }))
    }

    /// Answer one request. Never panics out: a bug in a tool costs that request, not the daemon.
    pub fn handle(self: &Arc<Self>, req: Request) -> Response {
        self.requests.fetch_add(1, Ordering::Relaxed);
        let id = req.id.clone();
        if let Some(v) = req.v
            && v != PROTOCOL_VERSION
        {
            return self.fail(Response::error(id, state::VERSION_MISMATCH, format!("client speaks protocol {v}, daemon speaks {PROTOCOL_VERSION}")));
        }
        let svc = self.clone();
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || svc.dispatch(&req)));
        match outcome {
            Ok(Ok(resp)) => resp.with_id(id),
            Ok(Err(e)) => self.fail(Response::error(id, e.state, e.message)),
            Err(_) => self.fail(Response::error(id, state::ERROR, "internal error: the request panicked (see the daemon log)")),
        }
    }

    fn fail(&self, r: Response) -> Response {
        self.errors.fetch_add(1, Ordering::Relaxed);
        r
    }

    fn dispatch(self: &Arc<Self>, req: &Request) -> std::result::Result<Response, ToolError> {
        if !req.cwd.is_empty() {
            self.seqs.lock().unwrap().insert(req.cwd.clone(), req.seq);
        }
        let name = req.tool.strip_prefix("qartez_").or_else(|| req.tool.strip_prefix("fdindex_")).unwrap_or(&req.tool);
        match name {
            "hello" => Ok(Response {
                ok: true,
                text: Some(format!("fdindex {} protocol {PROTOCOL_VERSION}", env!("CARGO_PKG_VERSION"))),
                data: Some(json!({"version": env!("CARGO_PKG_VERSION"), "protocol": PROTOCOL_VERSION, "pid": std::process::id()})),
                ..Default::default()
            }),
            "status" => Ok(self.status()),
            "gc" | "build" | "add_root" | "workspace" => self.admin(name, req).map(|t| Response::text(Value::Null, t)),
            other => {
                let tool = tools::canonical(other).ok_or_else(|| ToolError::bad(format!("unknown tool '{other}'")))?;
                self.run_tool(tool, req).map(|t| Response::text(Value::Null, t))
            }
        }
    }

    fn run_tool(self: &Arc<Self>, tool: &'static str, req: &Request) -> std::result::Result<String, ToolError> {
        if req.cwd.is_empty() || !Path::new(&req.cwd).is_absolute() {
            return Err(ToolError::bad("cwd must be an absolute path"));
        }
        let args = Args::new(req.args.clone(), PathBuf::from(&req.cwd));
        let (format, token_budget) = tools::common_params(tool, &args)?;
        let anchor = tools::anchor(tool, &args)?;
        let wait = self.wait_bound(&args);

        let located = git::locate(&anchor.path)?;
        if !located.is_git && !has_project_marker(&located.root) {
            // Without this, `read /etc/hosts` would index `/etc`.
            return Err(ToolError::failed(format!(
                "{} is not inside a git repository or a recognised project (no .git, elm.json, Cargo.toml, package.json, mix.exs, Package.swift or pyproject.toml above it), so there is no index to answer from",
                anchor.path.display()
            )));
        }
        let view = self.freshness.view(&self.engine, &anchor.path)?;
        self.touch(&view);

        let readiness = self.ensure_built(&view, &anchor.priority, anchor.slice_ok, anchor.needs_index.then_some(wait))?;
        let (graph, building) = match readiness {
            Readiness::Ready => (self.engine.graph(&view)?, None),
            Readiness::Building { done, total } => (self.engine.graph_partial(&view)?, Some((done, total))),
        };
        let cochange = || self.cochange_for(&view);
        let ctx = Ctx { graph: &graph, args: &args, format, token_budget, building, cochange: &cochange };
        let body = tools::run(tool, &ctx)?;
        Ok(format!("{}\n{body}", tools::header(&view.label, view.overlay.len(), building)))
    }

    fn wait_bound(&self, args: &Args) -> Duration {
        let ask = args.num(&["build_wait_ms"]).map(|ms| Duration::from_millis(ms as u64));
        ask.unwrap_or(self.cfg.build_wait).min(MAX_BUILD_WAIT)
    }

    fn touch(&self, view: &View) {
        let mut views = self.views.lock().unwrap();
        let e = views.entry(view.label.worktree.clone()).or_insert_with(|| ViewInfo {
            repo: view.label.repo.clone(),
            base: view.label.base_commit.clone(),
            dirty_files: 0,
            requests: 0,
            last_used: SystemTime::now(),
        });
        e.base = view.label.base_commit.clone();
        e.dirty_files = view.overlay.len();
        e.requests += 1;
        e.last_used = SystemTime::now();
    }

    // ---- building -----------------------------------------------------------------------

    /// Make sure the store holds facts for `view`, building if it does not. `slice_ok` says the
    /// caller can be answered from the priority slice alone (a file's own outline); anyone asking
    /// who imports or calls something needs the whole graph, and a partial one would answer
    /// "no importers" for a file whose importers were not parsed yet. `wait` of `None`
    /// starts a build without waiting for it (a plain file read needs no index, but it is the
    /// first sign of a repository, so the index starts warming).
    fn ensure_built(self: &Arc<Self>, view: &View, priority: &[PathBuf], slice_ok: bool, wait: Option<Duration>) -> Result<Readiness> {
        let deadline = Instant::now() + wait.unwrap_or_default();
        // A second pass covers a view whose overlay moved while the first job ran; three is more
        // than any real race needs and keeps a file that never settles from looping.
        for _ in 0..3 {
            if self.engine.is_ready(view)? {
                return Ok(Readiness::Ready);
            }
            let job = self.job_for(view, priority);
            if wait.is_none() {
                let p = job.state.lock().unwrap().progress;
                return Ok(Readiness::Building { done: p.done, total: p.total });
            }
            let mut st = job.state.lock().unwrap();
            loop {
                if let Some(done) = &st.finished {
                    match done {
                        Ok(()) => break,
                        Err(e) => return Err(Error::Msg(format!("build failed: {e}"))),
                    }
                }
                // `Done` is not "slice ready": the job is about to report finished, and answering from a
                // partial graph at that instant would skip the cache and mislabel a complete index.
                let slice_ready = slice_ok && !priority.is_empty() && matches!(st.progress.phase, Phase::PriorityDone | Phase::Rest) && job.covers(priority);
                let left = deadline.saturating_duration_since(Instant::now());
                if slice_ready || left.is_zero() {
                    return Ok(Readiness::Building { done: st.progress.done, total: st.progress.total });
                }
                st = job.cv.wait_timeout(st, left).unwrap().0;
            }
        }
        Ok(Readiness::Ready)
    }

    /// The running build of this worktree, or a new one. Concurrent requests for one view share a
    /// build; a finished job is never reused.
    fn job_for(self: &Arc<Self>, view: &View, priority: &[PathBuf]) -> Arc<Job> {
        let worktree = view.label.worktree.clone();
        let mut builds = self.builds.lock().unwrap();
        if let Some(j) = builds.get(&worktree)
            && j.state.lock().unwrap().finished.is_none()
        {
            return j.clone();
        }
        let total = view.files().len();
        let job = Arc::new(Job {
            state: Mutex::new(JobState { progress: Progress { phase: Phase::Priority, done: 0, total }, finished: None }),
            cv: Condvar::new(),
            priority: priority.to_vec(),
            started: Instant::now(),
        });
        builds.insert(worktree.clone(), job.clone());
        let (svc, job2, view, priority) = (self.clone(), job.clone(), view.clone(), priority.to_vec());
        let spawned = std::thread::Builder::new().name("fdindex-build".into()).stack_size(8 << 20).spawn(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                svc.engine.build(&view, &priority, |p| {
                    job2.state.lock().unwrap().progress = p;
                    job2.cv.notify_all();
                })
            }));
            let finished = match result {
                Ok(Ok(report)) => {
                    log::info(&format!("built {} in {:?}: {} files, {} parsed", view.label.worktree.display(), report.elapsed, report.total_files, report.parsed));
                    Ok(())
                }
                Ok(Err(e)) => {
                    log::info(&format!("build of {} failed: {e}", view.label.worktree.display()));
                    Err(e.to_string())
                }
                Err(_) => Err("the build panicked".to_string()),
            };
            {
                let mut st = job2.state.lock().unwrap();
                st.finished = Some(finished);
                if st.finished.as_ref().is_some_and(|f| f.is_ok()) {
                    st.progress.phase = Phase::Done;
                    st.progress.done = st.progress.total;
                }
            }
            job2.cv.notify_all();
            let mut builds = svc.builds.lock().unwrap();
            if builds.get(&view.label.worktree).is_some_and(|j| Arc::ptr_eq(j, &job2)) {
                builds.remove(&view.label.worktree);
            }
        });
        if let Err(e) = spawned {
            job.state.lock().unwrap().finished = Some(Err(format!("could not start a build thread: {e}")));
            builds.remove(&worktree);
        }
        job
    }

    /// Co-change of the view's repository at its commit, computed once per (repo, commit) however
    /// many requests ask at once, and replaced when HEAD moves.
    fn cochange_for(&self, view: &View) -> Result<Arc<CoChange>> {
        let commit = view.label.base_commit.clone().ok_or_else(|| Error::Msg("no commits yet".into()))?;
        let cell = {
            let mut m = self.cochange.lock().unwrap();
            let slot = m.entry(view.label.repo.clone()).or_insert_with(|| (commit.clone(), Arc::new(OnceLock::new())));
            if slot.0 != commit {
                *slot = (commit.clone(), Arc::new(OnceLock::new()));
            }
            slot.1.clone()
        };
        cell.get_or_init(|| CoChange::compute(&view.label.worktree, &commit).map(Arc::new).map_err(|e| e.to_string())).clone().map_err(Error::Msg)
    }

    // ---- admin tools ----------------------------------------------------------------------

    /// `add_root` / `workspace`: hints that start a build early. They never change what a query
    /// can see (any path resolves), so `workspace remove` has nothing to remove.
    fn admin(self: &Arc<Self>, tool: &str, req: &Request) -> std::result::Result<String, ToolError> {
        let args = Args::new(req.args.clone(), PathBuf::from(&req.cwd));
        if tool == "workspace" && args.str(&["action"]).as_deref() == Some("remove") {
            return Ok("workspace remove: nothing to do. The daemon indexes any path on demand, so there is no scope to shrink.".into());
        }
        let path = args.path(&["path", "root", "dir", "file_path"]).or_else(|| (!req.cwd.is_empty()).then(|| PathBuf::from(&req.cwd))).ok_or_else(|| ToolError::bad(format!("{tool} requires a path")))?;
        let view = self.freshness.view(&self.engine, &path)?;
        self.touch(&view);
        if tool == "gc" {
            let stats = self.engine.gc(&view.label.repo)?;
            let freed = self.engine.incremental_vacuum(&view.label.repo, 0)?;
            return Ok(format!("{}\ngc: {stats:?}; vacuumed {freed} page(s)", tools::header(&view.label, view.overlay.len(), None)));
        }
        let wait = (tool == "build").then(|| args.num(&["wait_ms"]).map(|m| Duration::from_millis(m as u64)).unwrap_or(Duration::from_secs(600)));
        let ready = self.ensure_built(&view, &[], false, wait)?;
        let building = match ready {
            Readiness::Ready => None,
            Readiness::Building { done, total } => Some((done, total)),
        };
        let header = tools::header(&view.label, view.overlay.len(), building);
        Ok(match building {
            Some(_) => format!("{header}\nbuild started in the background"),
            None => format!("{header}\nindexed"),
        })
    }

    // ---- status ---------------------------------------------------------------------------

    fn status(&self) -> Response {
        let now = SystemTime::now();
        let views: Vec<Value> = {
            let v = self.views.lock().unwrap();
            let mut rows: Vec<_> = v.iter().collect();
            rows.sort_by_key(|(_, i)| std::cmp::Reverse(i.last_used));
            rows.into_iter()
                .map(|(wt, i)| {
                    json!({
                        "worktree": wt, "repo": i.repo, "base": i.base, "dirty_files": i.dirty_files, "requests": i.requests,
                        "idle_seconds": now.duration_since(i.last_used).map(|d| d.as_secs()).unwrap_or(0),
                    })
                })
                .collect()
        };
        let builds: Vec<Value> = self
            .builds
            .lock()
            .unwrap()
            .iter()
            .map(|(wt, j)| {
                let s = j.state.lock().unwrap();
                json!({"worktree": wt, "phase": format!("{:?}", s.progress.phase), "done": s.progress.done, "total": s.progress.total, "running_seconds": j.started.elapsed().as_secs_f64()})
            })
            .collect();
        let g = self.engine.graph_cache_stats();
        let stores: Vec<Value> = std::fs::read_dir(&self.cfg.store)
            .map(|rd| {
                let mut v: Vec<(String, u64)> = rd
                    .flatten()
                    .filter(|e| e.file_name().to_string_lossy().ends_with(".db"))
                    .map(|e| (e.file_name().to_string_lossy().to_string(), e.metadata().map(|m| m.len()).unwrap_or(0)))
                    .collect();
                v.sort();
                v.into_iter().map(|(name, bytes)| json!({"name": name, "bytes": bytes})).collect()
            })
            .unwrap_or_default();
        let store_bytes: u64 = stores.iter().filter_map(|s| s["bytes"].as_u64()).sum();
        let rss = crate::runtime::rss_bytes();
        let data = json!({
            "version": env!("CARGO_PKG_VERSION"), "protocol": PROTOCOL_VERSION, "pid": std::process::id(),
            "uptime_seconds": self.started.elapsed().as_secs(),
            "rss_bytes": rss,
            "requests": self.requests.load(Ordering::Relaxed), "errors": self.errors.load(Ordering::Relaxed),
            "parses": self.engine.parse_count(),
            "views": views, "builds": builds,
            "graphs": {"count": g.graphs, "bytes": g.bytes, "facts_bytes": g.facts_bytes, "budget": g.budget, "evictions": g.evictions},
            "stores": stores,
        });
        let mb = |b: u64| format!("{:.1} MB", b as f64 / 1_048_576.0);
        let text = format!(
            "fdindex {} (protocol {PROTOCOL_VERSION}), pid {}, up {}s\nrss {}; {} request(s), {} error(s), {} blob(s) parsed\nviews known: {}; builds running: {}\ngraphs cached: {} ({} of {} budget, {} evicted)\nstore: {} db file(s), {}",
            env!("CARGO_PKG_VERSION"),
            std::process::id(),
            self.started.elapsed().as_secs(),
            mb(rss),
            self.requests.load(Ordering::Relaxed),
            self.errors.load(Ordering::Relaxed),
            self.engine.parse_count(),
            data["views"].as_array().map(|v| v.len()).unwrap_or(0),
            data["builds"].as_array().map(|v| v.len()).unwrap_or(0),
            g.graphs,
            mb(g.bytes as u64),
            mb(g.budget as u64),
            g.evictions,
            stores.len(),
            mb(store_bytes),
        );
        Response { ok: true, text: Some(text), data: Some(data), ..Default::default() }
    }
}

/// Where a request's view comes from. Today: git, recomputed per request. The watcher step
/// replaces this with a view kept current by file events and a ref watcher; callers do not change.
///
/// Concurrent requests for one worktree share a recomputation, but never an older one: a request
/// that arrives while a `git status` is running waits for the *next* one to start and finish, so
/// whatever it returns was computed after the request arrived (an edit made just before it is in
/// it). Under N simultaneous clients that is two statuses per round instead of N, which matters
/// because `git status` is 20 ms on a quiet checkout and several times that on a busy one.
#[derive(Default)]
pub struct Freshness {
    slots: Mutex<HashMap<PathBuf, Arc<Slot>>>,
}

#[derive(Default)]
struct Slot {
    state: Mutex<SlotState>,
    cv: Condvar,
}

#[derive(Default)]
struct SlotState {
    running: bool,
    /// Computations started so far; the next one to start has this number.
    started: u64,
    /// Computations finished so far, and the newest result.
    finished: u64,
    latest: Option<std::result::Result<View, String>>,
}

/// A computation in progress. If it ends without `finish` (a panic), `Drop` still clears
/// `running` and wakes the waiters, so one bad computation cannot wedge a worktree's slot.
struct Leader<'a> {
    slot: &'a Slot,
    finished: bool,
}

impl Leader<'_> {
    fn finish(mut self, result: std::result::Result<View, String>) {
        self.end(result);
        self.finished = true;
    }

    fn end(&self, result: std::result::Result<View, String>) {
        let mut st = self.slot.state.lock().unwrap_or_else(|e| e.into_inner());
        st.running = false;
        st.finished = st.started;
        st.latest = Some(result);
        drop(st);
        self.slot.cv.notify_all();
    }
}

impl Drop for Leader<'_> {
    fn drop(&mut self) {
        if !self.finished {
            self.end(Err("the view computation panicked".into()));
        }
    }
}

impl Freshness {
    pub fn view(&self, engine: &Engine, path: &Path) -> Result<View> {
        let root = git::locate(path)?.root;
        let slot = self.slots.lock().unwrap().entry(root).or_default().clone();
        let mut st = slot.state.lock().unwrap();
        // A computation that started before now may have missed an edit; only one that starts at
        // or after `want` is good enough.
        let want = st.started;
        loop {
            if st.finished > want
                && let Some(r) = &st.latest
            {
                return r.clone().map_err(Error::Msg);
            }
            if st.running {
                st = slot.cv.wait(st).unwrap();
                continue;
            }
            st.running = true;
            st.started += 1;
            drop(st);
            let leader = Leader { slot: &slot, finished: false };
            let computed = engine.view_for_path(path);
            leader.finish(computed.as_ref().map(|v| v.clone()).map_err(|e| e.to_string()));
            return computed;
        }
    }
}

fn has_project_marker(root: &Path) -> bool {
    ["elm.json", "Cargo.toml", "package.json", "mix.exs", "Package.swift", "pyproject.toml"].iter().any(|m| root.join(m).exists())
}

impl Response {
    fn with_id(mut self, id: Value) -> Response {
        self.id = id;
        self
    }
}

/// The daemon log: one line per event, appended to a file next to the store.
pub mod log {
    use std::io::Write;
    use std::sync::Mutex;

    static SINK: Mutex<Option<std::fs::File>> = Mutex::new(None);

    pub fn open(path: &std::path::Path) {
        if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            *SINK.lock().unwrap() = Some(f);
        }
    }

    pub fn info(msg: &str) {
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
        let line = format!("{secs:.3} {msg}\n");
        match SINK.lock().unwrap().as_mut() {
            Some(f) => {
                let _ = f.write_all(line.as_bytes());
            }
            None => eprint!("{line}"),
        }
    }
}
