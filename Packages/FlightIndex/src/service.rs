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
//! 2. The view's overlay is whatever differs from HEAD right now. `Freshness` keeps it between
//!    requests and finds what changed by `stat` (an edit made a moment ago is in the overlay,
//!    parsed on demand, and visible to this query); a worktree it cannot vouch for is read from
//!    `git status`.
//! 3. If the store lacks facts for the view, it is built, requested paths first, and the request
//!    waits for that slice up to a bound; past the bound it answers from what is stored and says
//!    so in the header.
//! 4. The tool runs on the view's graph and the result gets the view header.

use crate::cochange::CoChange;
use crate::edit;
use crate::engine::{Engine, Phase, Progress, DEFAULT_GRAPH_BUDGET};
use crate::error::{Error, Result};
use crate::git::{self, View};
use crate::proto::{state, Request, Response, PROTOCOL_VERSION};
use crate::refresh::{self, BaseIndex, Refreshed};
use crate::retention::{self, GcReport, Maintenance};
use crate::tools::{self, args::Args, Ctx, ToolError};
use crate::sweep::Snapshot;
use crate::watch::{WatchConfig, Watcher};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock};
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
    pub watch: WatchConfig,
}

impl Config {
    pub fn new(store: impl Into<PathBuf>) -> Config {
        Config { store: store.into(), build_wait: DEFAULT_BUILD_WAIT, graph_budget: DEFAULT_GRAPH_BUDGET, watch: WatchConfig::default() }
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
    is_git: bool,
    base: Option<String>,
    dirty_files: usize,
    requests: u64,
    last_used: SystemTime,
}

pub struct Service {
    pub engine: Engine,
    cfg: Config,
    freshness: Freshness,
    watcher: Option<Arc<Watcher>>,
    builds: Mutex<HashMap<PathBuf, Arc<Job>>>,
    views: Mutex<HashMap<PathBuf, ViewInfo>>,
    cochange: Mutex<HashMap<PathBuf, (String, CoChangeCell)>>,
    /// One gate per worktree: a mutation holds it for writing from planning to re-index, and every
    /// read holds it for reading while it fetches its view and graph. A query therefore sees the
    /// worktree before a mutation or after it, never between two of its file writes.
    gates: Mutex<HashMap<PathBuf, Arc<RwLock<()>>>>,
    /// Last `seq` seen per cwd. Nothing reads it: freshness does not need it, because every
    /// request looks at the file system itself.
    seqs: Mutex<HashMap<String, u64>>,
    maintenance: Arc<Maintenance>,
    started: Instant,
    requests: AtomicU64,
    errors: AtomicU64,
}

impl Drop for Service {
    fn drop(&mut self) {
        self.maintenance.stop();
    }
}

impl Service {
    pub fn open(cfg: Config) -> Result<Arc<Service>> {
        let engine = Engine::open(&cfg.store)?;
        engine.set_graph_budget(cfg.graph_budget);
        let svc = Arc::new_cyclic(|me: &std::sync::Weak<Service>| {
            // The refs callback runs on the watcher's own thread, after the service exists.
            let me = me.clone();
            let watcher = Watcher::start(&cfg.watch, move |common| {
                if let Some(s) = me.upgrade() {
                    s.on_refs(common);
                }
            });
            Service {
                freshness: Freshness::new(cfg.watch.enabled),
                watcher,
                engine,
                cfg,
                builds: Mutex::new(HashMap::new()),
                views: Mutex::new(HashMap::new()),
                cochange: Mutex::new(HashMap::new()),
                gates: Mutex::new(HashMap::new()),
                seqs: Mutex::new(HashMap::new()),
                maintenance: Arc::new(Maintenance::default()),
                started: Instant::now(),
                requests: AtomicU64::new(0),
                errors: AtomicU64::new(0),
            }
        });
        svc.watch_known_repos();
        let (weak, m) = (Arc::downgrade(&svc), svc.maintenance.clone());
        std::thread::Builder::new().name("fdindex-maintenance".into()).spawn(move || maintenance_loop(weak, m)).map_err(|e| Error::Msg(format!("could not start the maintenance thread: {e}")))?;
        Ok(svc)
    }

    // ---- maintenance ----------------------------------------------------------------------

    /// One look at the world: drop worktrees whose directory is gone, release watches nobody has
    /// used lately, and collect when a collection is due.
    pub fn maintain(&self) {
        let removed = self.sweep();
        if removed > 0 {
            // Their blobs are garbage as soon as no other tree names them.
            self.maintenance.request_gc();
        }
        for root in self.freshness.release_idle(self.cfg.watch.active_for) {
            log::info(&format!("dropped the kept view of idle worktree {}", root.display()));
        }
        if self.maintenance.gc_due(self.started.elapsed()) {
            self.run_gc();
        }
    }

    /// Forget every known worktree whose directory (or `.git`) no longer exists: its kept view,
    /// its watch, its overlay and its graph. Returns how many went. The stat per worktree is the
    /// whole cost, which is why this runs every tick instead of waiting for the watcher to say so.
    fn sweep(&self) -> usize {
        let gone: Vec<(PathBuf, PathBuf, Option<String>)> = self
            .views
            .lock()
            .unwrap()
            .iter()
            .filter(|(wt, i)| !wt.exists() || (i.is_git && !wt.join(".git").exists()))
            .map(|(wt, i)| (wt.clone(), i.repo.clone(), i.base.clone()))
            .collect();
        for (wt, repo, base) in &gone {
            self.freshness.forget(wt);
            self.gates.lock().unwrap().remove(wt);
            let in_use = {
                let mut views = self.views.lock().unwrap();
                views.remove(wt);
                base.is_some() && views.values().any(|i| i.repo == *repo && i.base == *base)
            };
            self.engine.release_worktree(repo, wt, base.as_deref(), in_use);
            log::info(&format!("worktree {} is gone: released its view, overlay and graph", wt.display()));
        }
        gone.len()
    }

    /// Drop the kept view of every worktree idle for `idle`, as the maintenance thread does for
    /// `watch.active_for`. Returns how many were released.
    pub fn release_idle_views(&self, idle: Duration) -> usize {
        self.freshness.release_idle(idle).len()
    }

    /// Collect the whole store now, one collection at a time whoever asks.
    pub fn run_gc(&self) -> GcReport {
        let _one = self.maintenance.gc_lock.lock().unwrap_or_else(|e| e.into_inner());
        let report = retention::collect(&self.engine, &|repo| {
            if let Some(w) = self.watcher.as_ref() {
                w.unwatch_repo(repo);
            }
        });
        log::info(&format!("gc: {}", report.summary()));
        self.maintenance.record(report.clone());
        report
    }

    /// A repository's refs changed (or it was just added to the ref watch). Re-read its branch
    /// heads, which garbage collection treats as roots, and prepare the new base tree of every
    /// kept worktree whose HEAD moved: its listing is derived from the old one and only blobs the
    /// store has never seen are parsed, so the question that follows a commit, checkout or rebase
    /// finds that done. Late or lost, this only costs the warm-up: a request compares HEAD itself.
    fn on_refs(self: &Arc<Self>, common: &Path) {
        if !common.join("HEAD").exists() {
            // Gone, or not a git repository at all; the retention pass drops its store.
            if let Some(w) = &self.watcher {
                w.unwatch_repo(common);
            }
            return;
        }
        if let Err(e) = self.engine.refresh_known_refs(common) {
            log::info(&format!("could not read the branch heads of {}: {e}", common.display()));
        }
        for wt in self.freshness.moved_heads(common) {
            let started = Instant::now();
            let parsed = self.engine.parse_count();
            let prepared = self.view(&wt).and_then(|view| self.ensure_built(&view, &[], false, Some(MAX_BUILD_WAIT)).map(|_| view));
            match prepared {
                Ok(view) => log::info(&format!(
                    "prepared {} for its new base {} in {:?}, {} blob(s) parsed",
                    wt.display(),
                    view.label.base_commit.as_deref().map(|c| &c[..c.len().min(7)]).unwrap_or("-"),
                    started.elapsed(),
                    self.engine.parse_count().saturating_sub(parsed)
                )),
                Err(e) => log::info(&format!("could not prepare {}: {e}", wt.display())),
            }
        }
    }

    /// Every repository the store already knows, so their refs are watched from the first moment
    /// and a commit made while no request was in flight still moves the known refs.
    fn watch_known_repos(&self) {
        let Some(w) = self.watcher.as_ref() else { return };
        for (_, repo) in crate::store::list_dbs(&self.cfg.store) {
            if let Some(repo) = repo.filter(|r| r.join("HEAD").exists()) {
                w.watch_repo(&repo);
            }
        }
    }

    /// The view of the worktree containing `path` as of now, recorded in the store (see
    /// `Engine::record_view`).
    fn view(&self, path: &Path) -> Result<View> {
        let view = self.freshness.view(&self.engine, path)?;
        self.engine.record_view(&view)?;
        // A repository is watched from the first request that names it; one the store already
        // knew was watched at startup.
        if let (Some(w), true) = (&self.watcher, view.label.is_git) {
            w.watch_repo(&view.label.repo);
        }
        Ok(view)
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
            other if tools::mutate::canonical(other).is_some() => {
                let tool = tools::mutate::canonical(other).expect("checked");
                self.run_mutator(tool, req).map(|t| Response::text(Value::Null, t))
            }
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
        check_indexable(&located, &anchor.path)?;
        let gate = self.gate(&located.root);
        let _reading = gate.read().unwrap_or_else(|e| e.into_inner());
        let view = self.view(&anchor.path)?;
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

    fn gate(&self, worktree: &Path) -> Arc<RwLock<()>> {
        self.gates.lock().unwrap().entry(worktree.to_path_buf()).or_default().clone()
    }

    /// A mutator: plan the change on the view that answers the lookup, then either show it or
    /// write it. The write gate is held from the first look at the view to the re-index, so the
    /// plan is made against what will be written over and no query sees half of it.
    fn run_mutator(self: &Arc<Self>, tool: &'static str, req: &Request) -> std::result::Result<String, ToolError> {
        use tools::mutate::{self, MutCtx};
        if req.cwd.is_empty() || !Path::new(&req.cwd).is_absolute() {
            return Err(ToolError::bad("cwd must be an absolute path"));
        }
        let args = Args::new(req.args.clone(), PathBuf::from(&req.cwd));
        let (_, token_budget) = tools::common_params(tool, &args)?;
        let apply = args.flag(&["apply"], false);
        let anchor = mutate::anchor_path(tool, &args)?;
        let priority = mutate::priority_paths(tool, &args);
        let wait = self.wait_bound(&args);
        let located = git::locate(&anchor)?;
        check_indexable(&located, &anchor)?;
        let gate = self.gate(&located.root);
        let _writing = gate.write().unwrap_or_else(|e| e.into_inner());

        let mut attempt = 0;
        let (view, plan) = loop {
            attempt += 1;
            let view = self.view(&anchor)?;
            self.touch(&view);
            // A rename that misses a file because its importers were not parsed yet would leave
            // the code broken, so a mutator never works from a partial graph.
            if let Readiness::Building { done, total } = self.ensure_built(&view, &priority, false, Some(wait))? {
                return Err(ToolError {
                    state: state::BUILDING,
                    message: format!("{} needs the complete index of {}, which is still building (index: building, {done} of {total} files); nothing was changed, retry shortly", tool, view.label.worktree.display()),
                });
            }
            let graph = self.engine.graph(&view)?;
            match mutate::plan(tool, &MutCtx { graph: &graph, args: &args }) {
                Ok(plan) => break (view, plan),
                // The index lagged an edit made a moment ago: look again.
                Err(e) if e.message.starts_with(mutate::STALE) && attempt < 3 => continue,
                Err(e) => return Err(e),
            }
        };

        // An agent that named a path in another checkout asked for that checkout, but the answer
        // must still say so: an edit landing somewhere unexpected, unlabelled, is the failure to avoid.
        let cwd_root = git::locate(Path::new(&req.cwd)).map(|l| l.root).ok();
        let elsewhere = cwd_root.as_deref().filter(|r| *r != view.label.worktree).map(|r| {
            format!("\nnote: this is not your worktree ({}): the path you named is in {}, so that is where the change lands", r.display(), view.label.worktree.display())
        });
        let mut out = tools::header(&view.label, view.overlay.len(), None);
        out.push_str(elsewhere.as_deref().unwrap_or(""));
        let lists = |out: &mut String, plan: &mutate::Plan| {
            for n in &plan.notes {
                out.push_str(&format!("\n{n}"));
            }
            for w in &plan.warnings {
                out.push_str(&format!("\nwarning: {w}"));
            }
        };
        if plan.changes.is_empty() {
            out.push_str(&format!("\nno change: {} would not alter any file", plan.summary));
            return Ok(out);
        }
        if !apply {
            out.push_str(&format!("\npreview: {} ({} file(s)); nothing written, pass apply=true to write", plan.summary, plan.changes.len()));
            lists(&mut out, &plan);
            let mut diff = String::new();
            for c in &plan.changes {
                let text = |b: &Option<Vec<u8>>| b.as_ref().map(|b| String::from_utf8_lossy(b).to_string());
                diff.push_str(&edit::unified_diff(&c.path, text(&c.before).as_deref(), text(&c.after).as_deref()));
            }
            out.push('\n');
            out.push_str(&tools::truncate(diff, token_budget));
            return Ok(out);
        }

        let parsed_before = self.engine.parse_count();
        edit::apply_changes(&view.label.worktree, &plan.changes).map_err(ToolError::failed)?;
        log::info(&format!("{tool}: wrote {} file(s) in {}", plan.changes.len(), view.label.worktree.display()));

        // Re-index before answering: the next query from this cwd must see the change, so look at
        // the worktree again now (the writes are on disk) and make its graph.
        let view = self.view(&anchor)?;
        let written: Vec<PathBuf> = plan.changes.iter().filter(|c| c.after.is_some()).map(|c| c.path.clone()).collect();
        self.ensure_built(&view, &written, false, Some(MAX_BUILD_WAIT))?;
        let graph = self.engine.graph(&view)?;
        let stale: Vec<String> = plan
            .changes
            .iter()
            .filter(|c| match &c.after {
                Some(b) => graph.file_idx(&c.path).is_none_or(|i| graph.file(i).blob_id != git::blob_id(b)) && tools::mutate::indexable(&c.path),
                None => graph.file_idx(&c.path).is_some(),
            })
            .map(|c| c.path.display().to_string())
            .collect();

        let mut out = tools::header(&view.label, view.overlay.len(), None);
        out.push_str(elsewhere.as_deref().unwrap_or(""));
        out.push_str(&format!("\napplied: {}", plan.summary));
        out.push_str(&format!("\nwrote {} file(s):", plan.changes.len()));
        for c in &plan.changes {
            out.push_str(&format!("\n  {} {}", if c.after.is_none() { "deleted" } else if c.before.is_none() { "created" } else { "modified" }, c.path.display()));
        }
        if stale.is_empty() {
            out.push_str(&format!(
                "\nview updated: {} blob(s) re-parsed and the graph recomputed; the next query from {} sees the change",
                self.engine.parse_count().saturating_sub(parsed_before),
                req.cwd
            ));
        } else {
            out.push_str(&format!("\nwarning: the index does not yet reflect {} (a concurrent edit changed it again); the next query re-reads it", stale.join(", ")));
        }
        lists(&mut out, &plan);
        Ok(out)
    }

    fn wait_bound(&self, args: &Args) -> Duration {
        let ask = args.num(&["build_wait_ms"]).map(|ms| Duration::from_millis(ms as u64));
        ask.unwrap_or(self.cfg.build_wait).min(MAX_BUILD_WAIT)
    }

    fn touch(&self, view: &View) {
        let mut views = self.views.lock().unwrap();
        let e = views.entry(view.label.worktree.clone()).or_insert_with(|| ViewInfo {
            repo: view.label.repo.clone(),
            is_git: view.label.is_git,
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
        let named = args.path(&["path", "root", "dir", "file_path"]);
        if tool == "gc" && named.is_none() {
            // No path: the whole store. `--now` waits for it; without, it is queued for the
            // maintenance thread and the answer says what the last one did.
            if args.flag(&["now"], false) {
                return Ok(format!("gc: {}", self.run_gc().summary()));
            }
            self.maintenance.request_gc();
            let last = self.maintenance.last().map(|r| r.summary()).unwrap_or_else(|| "none yet".into());
            return Ok(format!("gc requested; it runs in the background (pass --now to wait for it). Last: {last}"));
        }
        let path = named.or_else(|| (!req.cwd.is_empty()).then(|| PathBuf::from(&req.cwd))).ok_or_else(|| ToolError::bad(format!("{tool} requires a path")))?;
        let view = self.view(&path)?;
        self.touch(&view);
        if tool == "gc" {
            let stats = self.engine.gc(&view.label.repo)?;
            let freed = self.engine.vacuum(&view.label.repo)?;
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
                    let k = self.freshness.kept_info(wt);
                    let ago = |t: SystemTime| now.duration_since(t).map(|d| d.as_secs()).unwrap_or(0);
                    json!({
                        "worktree": wt, "repo": i.repo, "base": i.base, "dirty_files": i.dirty_files, "requests": i.requests,
                        "idle_seconds": ago(i.last_used),
                        // Kept between requests and swept by stat, or read from `git status` each time.
                        "kept": k.is_some(),
                        "snapshot_files": k.as_ref().map(|k| k.files), "snapshot_dirs": k.as_ref().map(|k| k.dirs),
                        "sweeps": k.as_ref().map(|k| k.sweeps),
                        "last_sweep_ms": k.as_ref().and_then(|k| k.last_sweep).map(|d| d.as_secs_f64() * 1000.0),
                        "last_change_seconds_ago": k.as_ref().and_then(|k| k.last_change).map(ago),
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
        let overview = retention::store_overview(&self.engine);
        let stores: Vec<Value> = overview
            .iter()
            .map(|(db, repo, bytes, free)| json!({"name": db.file_name().map(|n| n.to_string_lossy().to_string()), "repo": repo, "bytes": bytes, "free_pages": free}))
            .collect();
        let store_bytes: u64 = overview.iter().map(|(_, _, b, _)| b).sum();
        let free_pages: u64 = overview.iter().map(|(_, _, _, f)| f).sum();
        let ago = |t: SystemTime| now.duration_since(t).map(|d| d.as_secs()).unwrap_or(0);
        let watch = match self.watcher.as_ref() {
            None => json!({"enabled": false, "keeps_views": self.cfg.watch.enabled}),
            Some(w) => json!({
                "enabled": true, "keeps_views": true,
                "active_hours": self.cfg.watch.active_for.as_secs_f64() / 3600.0,
                "events": w.total_events(),
                "ref_repos": w.repos().into_iter().map(|r| json!({"repo": r.common, "events": r.events, "last_event_seconds_ago": r.last_event.map(ago)})).collect::<Vec<_>>(),
            }),
        };
        let gc = json!({
            "runs": self.maintenance.runs(), "reclaimed_bytes_total": self.maintenance.reclaimed_total(),
            "free_pages": free_pages, "last": self.maintenance.last().map(|r| r.to_json()),
        });
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
            "watch": watch, "gc": gc,
        });
        let mb = |b: u64| format!("{:.1} MB", b as f64 / 1_048_576.0);
        let text = format!(
            "fdindex {} (protocol {PROTOCOL_VERSION}), pid {}, up {}s\nrss {}; {} request(s), {} error(s), {} blob(s) parsed\nviews known: {}; builds running: {}\ngraphs cached: {} ({} of {} budget, {} evicted)\nstore: {} db file(s), {}, {} free page(s)\nwatch: {}\ngc: {}",
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
            free_pages,
            match (self.cfg.watch.enabled, self.watcher.as_ref()) {
                (false, _) => "off (every request reads git status)".to_string(),
                (true, None) => "views kept and swept by stat; no ref watcher on this platform".to_string(),
                (true, Some(w)) => format!("views kept and swept by stat; refs of {} repo(s) watched, {} event(s)", w.repos().len(), w.total_events()),
            },
            match self.maintenance.last() {
                None => "no collection yet".to_string(),
                Some(r) => format!("{} run(s); last {}s ago reclaimed {} bytes", self.maintenance.runs(), r.at.map(ago).unwrap_or(0), r.reclaimed()),
            },
        );
        Response { ok: true, text: Some(text), data: Some(data), ..Default::default() }
    }
}

/// Where a request's view comes from.
///
/// With `watch.enabled`, a worktree's view is *kept* between requests. A request looks at the file
/// system (`Snapshot::check`: a `stat` of every indexed file and non-ignored directory, about 2 ms
/// on tessera), applies only what changed (`refresh`), and compares HEAD, read from git's own
/// files, with the one the view was built on. No process is spawned and nothing waits on an event,
/// so an edit made a millisecond before the request is seen: the stat is of the file system as it
/// is. (Events were tried and measured unsound; see `sweep`.)
///
/// Otherwise, and whenever the kept view cannot be trusted, the view is recomputed from `git
/// status`, which is slower and always right: a worktree first seen, one whose kept view was
/// dropped for idleness, a moved HEAD, a changed ignore file, a bulk change, a directory outside
/// git. Concurrent requests for one worktree share a recomputation, but never an older one: a
/// request that arrives while a `git status` is running waits for the *next* one to start and
/// finish, so whatever it returns was computed after the request arrived. Under N simultaneous
/// clients that is two statuses per round instead of N.
#[derive(Default)]
pub struct Freshness {
    slots: Mutex<HashMap<PathBuf, Arc<Slot>>>,
    keep: bool,
    entries: Mutex<HashMap<PathBuf, Arc<Mutex<Entry>>>>,
}

/// One worktree's kept view. The mutex serialises its requests: a second request must not read
/// the view while the first is still applying the changes its sweep found.
#[derive(Default)]
struct Entry {
    cached: Option<Cached>,
    last_used: Option<Instant>,
    /// How long the last sweep took, and when one last found a change, for `status`.
    last_sweep: Option<Duration>,
    last_change: Option<SystemTime>,
    sweeps: u64,
}

struct Cached {
    view: View,
    index: BaseIndex,
    snapshot: Snapshot,
    gitdir: PathBuf,
    common: PathBuf,
}

/// What `status` shows of one worktree's kept view.
pub struct KeptInfo {
    pub files: usize,
    pub dirs: usize,
    pub last_sweep: Option<Duration>,
    pub last_change: Option<SystemTime>,
    pub sweeps: u64,
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
    pub fn new(keep: bool) -> Freshness {
        Freshness { keep, ..Default::default() }
    }

    pub fn view(&self, engine: &Engine, path: &Path) -> Result<View> {
        let located = git::locate(path)?;
        if self.keep && located.is_git {
            self.kept(engine, &located.root, path)
        } else {
            self.read_status(engine, path)
        }
    }

    fn kept(&self, engine: &Engine, root: &Path, path: &Path) -> Result<View> {
        let entry = self.entries.lock().unwrap().entry(root.to_path_buf()).or_default().clone();
        let mut e = entry.lock().unwrap_or_else(|x| x.into_inner());
        e.last_used = Some(Instant::now());
        if let Some(c) = e.cached.as_mut() {
            let started = Instant::now();
            let swept = Self::sweep(c);
            let took = started.elapsed();
            if let Some((view, changed)) = swept {
                e.last_sweep = Some(took);
                e.sweeps += 1;
                if changed {
                    e.last_change = Some(SystemTime::now());
                }
                return Ok(view);
            }
        }
        // A full read, and a snapshot of the file system right after it: whatever changes in
        // between has a ctime inside the snapshot's racy window and is looked at again.
        e.cached = None;
        let view = self.read_status(engine, path)?;
        if let Ok((gitdir, common)) = git::git_dirs(root) {
            e.cached = Some(Cached { index: BaseIndex::new(&view), snapshot: Snapshot::take(&view, &common), view: view.clone(), gitdir, common });
        }
        Ok(view)
    }

    /// The kept view brought up to date, or `None` when it needs a full read. The `bool` says
    /// whether anything had changed.
    fn sweep(c: &mut Cached) -> Option<(View, bool)> {
        if git::read_head(&c.gitdir, &c.common) != c.view.label.base_commit {
            return None;
        }
        let changes = c.snapshot.check();
        if changes.rescan {
            return None;
        }
        if changes.is_empty() {
            return Some((c.view.clone(), false));
        }
        match refresh::refresh(&c.view, &c.index, &changes) {
            Ok(Refreshed::View(v)) => {
                c.snapshot.settle(&v, &|p| c.index.contains(p), &changes);
                c.view = v.clone();
                Some((v, true))
            }
            _ => None,
        }
    }

    /// Worktrees of `common` whose kept view was built on a commit that is no longer their HEAD:
    /// what the ref watcher prepares the next question for.
    pub fn moved_heads(&self, common: &Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for (root, entry) in self.entries.lock().unwrap().iter() {
            let Ok(e) = entry.try_lock() else { continue };
            // A worktree whose directory is gone has no HEAD to compare, which would read as a move;
            // the sweep releases it, and preparing it would index whatever directory is left where it was.
            if let Some(c) = &e.cached
                && c.common == common
                && root.join(".git").exists()
                && git::read_head(&c.gitdir, &c.common) != c.view.label.base_commit
            {
                out.push(root.clone());
            }
        }
        out
    }

    /// Drop the kept view of worktrees nobody has asked about for `idle`: their next query is a
    /// full read (spec §5.4). Returns the worktrees released.
    pub fn release_idle(&self, idle: Duration) -> Vec<PathBuf> {
        let mut released = Vec::new();
        for (root, entry) in self.entries.lock().unwrap().iter() {
            // A worktree being answered right now is not idle, whatever its stamp says.
            let Ok(mut e) = entry.try_lock() else { continue };
            if e.cached.is_some() && e.last_used.is_some_and(|t| t.elapsed() >= idle) {
                e.cached = None;
                released.push(root.clone());
            }
        }
        released
    }

    /// A worktree that no longer exists.
    pub fn forget(&self, root: &Path) {
        self.entries.lock().unwrap().remove(root);
    }

    pub fn kept_info(&self, root: &Path) -> Option<KeptInfo> {
        let entry = self.entries.lock().unwrap().get(root)?.clone();
        let e = entry.try_lock().ok()?;
        let c = e.cached.as_ref()?;
        let (files, dirs) = c.snapshot.counts();
        Some(KeptInfo { files, dirs, last_sweep: e.last_sweep, last_change: e.last_change, sweeps: e.sweeps })
    }

    /// The view recomputed from git, shared between concurrent callers.
    fn read_status(&self, engine: &Engine, path: &Path) -> Result<View> {
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

/// Runs until the service is dropped. It waits on the shared `Maintenance` and holds the service
/// only while it works, so it never keeps one alive.
fn maintenance_loop(svc: std::sync::Weak<Service>, m: Arc<Maintenance>) {
    while !m.stopped() {
        m.wait();
        let Some(s) = svc.upgrade() else { return };
        if m.stopped() {
            return;
        }
        s.maintain();
    }
}

/// Refuse a path outside any repository or project: `read /etc/hosts` must not index `/etc`.
fn check_indexable(located: &git::Located, path: &Path) -> std::result::Result<(), ToolError> {
    if !located.is_git && !has_project_marker(&located.root) {
        return Err(ToolError::failed(format!(
            "{} is not inside a git repository or a recognised project (no .git, elm.json, Cargo.toml, package.json, mix.exs, Package.swift or pyproject.toml above it), so there is no index to answer from",
            path.display()
        )));
    }
    Ok(())
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
