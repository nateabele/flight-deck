//! What a stat sweep must find, against what `git status` says afterwards. Edits are made by other
//! processes, as an agent's tools make them. The snapshots use a zero racy window, so what is
//! exercised is the comparison of stats; the default window (every recent entry is read again) is
//! covered at the end.
mod common;
use common::*;
use flightindex::git::{self, Overlay, View};
use flightindex::refresh::{refresh, BaseIndex, Refreshed};
use flightindex::sweep::{Changes, Snapshot};
use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

fn overlay_of(v: &View) -> BTreeMap<String, Option<String>> {
    let in_base = |p: &str| v.base.iter().any(|f| f.path == p);
    v.overlay
        .iter()
        .filter(|o| matches!(o, Overlay::Present(_)) || in_base(o.path()))
        .map(|o| match o {
            Overlay::Present(f) => (f.path.clone(), Some(f.blob_id.clone())),
            Overlay::Deleted(p) => (p.clone(), None),
        })
        .collect()
}

fn files_of(v: &View) -> BTreeMap<String, String> {
    v.files().into_iter().map(|f| (f.path, f.blob_id)).collect()
}

fn sh(script: &str) {
    assert!(Command::new("sh").arg("-c").arg(script).status().unwrap().success(), "{script}");
}

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, ".gitignore", "dist/\n*.gen.ts\n");
    write(&r.root, "src/A.elm", ELM_A);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "web/a.ts", "export const a = 1;\n");
    write(&r.root, "web/inner/b.ts", "export const b = 2;\n");
    write(&r.root, "docs/notes.txt", "notes\n");
    write(&r.root, "README.md", "docs\n");
    commit_all(&r.root, "init");
    r
}

/// A worktree being followed: its view, the index of its base tree and a snapshot, the way the
/// service keeps them.
struct Rig {
    root: std::path::PathBuf,
    view: View,
    index: BaseIndex,
    snap: Snapshot,
    _repo: Repo,
}

fn rig() -> Rig {
    let repo = project();
    let view = git::view_for_path(&repo.root).unwrap();
    let common = repo.root.join(".git");
    let snap = Snapshot::take_with_window(&view, &common, 0.0);
    Rig { root: repo.root.clone(), index: BaseIndex::new(&view), view, snap, _repo: repo }
}

impl Rig {
    /// One request's worth of work: sweep, apply, and compare with a view from scratch.
    fn follow(&mut self) -> Changes {
        let changes = self.snap.check();
        assert!(!changes.rescan, "unexpected rescan");
        if !changes.is_empty() {
            let Refreshed::View(v) = refresh(&self.view, &self.index, &changes).unwrap() else { panic!("refresh asked for a rescan") };
            self.snap.settle(&v, &|p| self.index.contains(p), &changes);
            self.view = v;
        }
        let want = git::view_for_path(&self.root).unwrap();
        assert_eq!(overlay_of(&self.view), overlay_of(&want), "overlay");
        assert_eq!(files_of(&self.view), files_of(&want), "files");
        changes
    }

    fn edit(&mut self, script: &str) -> Changes {
        sh(&script.replace("$R", &self.root.display().to_string()));
        self.follow()
    }
}

#[test]
fn a_quiet_worktree_sweeps_empty() {
    let mut r = rig();
    assert!(r.follow().is_empty());
    assert!(r.follow().is_empty(), "and stays empty");
}

#[test]
fn an_in_place_edit_of_a_clean_tracked_file_is_found_with_nothing_flagged_before() {
    // The case an event barrier can lose: a file never touched before, edited just now.
    let mut r = rig();
    let c = r.edit("printf 'export const a = 2;\\n' >> $R/web/a.ts");
    assert!(c.paths.contains(&r.root.join("web/a.ts")));
}

#[test]
fn replace_by_rename_deletion_creation_and_directory_moves_agree_with_git_status() {
    let mut r = rig();
    r.edit("printf 'module A exposing (a)\\n\\na = 1\\n' > $R/src/A.elm.tmp && mv $R/src/A.elm.tmp $R/src/A.elm");
    r.edit("perl -pi -e 's/a = 1/a = 2/' $R/src/A.elm");
    r.edit("rm $R/src/B.elm");
    r.edit("printf 'module C exposing (c)\\n\\nc = 1\\n' > $R/src/C.elm");
    r.edit("printf 'export const n = 1;\\n' > $R/brand/new.ts 2>/dev/null || (mkdir -p $R/brand/deeper && printf 'export const n = 1;\\n' > $R/brand/deeper/new.ts)");
    r.edit("mv $R/web/inner $R/web/moved");
    r.edit("printf 'export const late = 1;\\n' > $R/web/moved/late.ts");
    r.edit("rm -r $R/web");
    r.edit("mkdir -p $R/web && printf 'export const back = 1;\\n' > $R/web/a.ts");
}

#[test]
fn a_new_file_in_a_directory_that_held_nothing_indexed_is_found() {
    // `docs/` has only a text file, so no indexed path ever named it: it is known only because the
    // walk listed it, and a file created there moves its mtime.
    let mut r = rig();
    let c = r.edit("printf 'pub fn f() {}\\n' > $R/docs/x.rs");
    assert!(c.paths.contains(&r.root.join("docs/x.rs")));
}

#[test]
fn ignored_files_and_ignored_directories_stay_out_and_are_asked_about_once() {
    let mut r = rig();
    r.edit("mkdir -p $R/dist && printf 'var x = 1;\\n' > $R/dist/bundle.js");
    let c = r.edit("printf 'export const g = 1;\\n' > $R/web/thing.gen.ts");
    assert!(c.paths.contains(&r.root.join("web/thing.gen.ts")), "git is asked, and says no");
    // Touching the directory again does not ask again about a path git already refused.
    let c = r.edit("printf 'x\\n' > $R/web/unrelated.txt");
    assert!(!c.paths.contains(&r.root.join("web/thing.gen.ts")), "{c:?}");
}

#[test]
fn a_nested_repository_is_not_this_views_business() {
    let mut r = rig();
    r.edit("git init -q $R/vendor/dep && printf 'export const x = 1;\\n' > $R/vendor/dep/x.ts");
    r.edit("printf 'export const y = 1;\\n' > $R/vendor/dep/y.ts");
}

#[test]
fn a_changed_ignore_file_asks_for_a_rescan() {
    // What is ignored may have changed, so nothing already decided can be trusted.
    let mut r = rig();
    sh(&format!("printf 'dist/\\n*.gen.ts\\nweb/\\n' > {}/.gitignore", r.root.display()));
    assert!(r.snap.check().rescan);
}

#[test]
fn a_symlink_and_an_oversized_file_are_not_indexed() {
    let mut r = rig();
    r.edit("rm $R/web/a.ts && ln -s ../src/A.elm $R/web/a.ts && head -c 1100000 /dev/zero | tr '\\0' 'x' > $R/web/big.ts");
}

#[test]
fn a_hundred_mixed_external_edits_are_each_found_by_the_next_sweep() {
    // Counted, not timed: the sweep after each edit must name the file the edit touched.
    let mut r = rig();
    let mut missed = Vec::new();
    for i in 0..100 {
        let rel = format!("gen{}.rs", i % 5);
        let abs = r.root.join(&rel);
        let script = match i % 5 {
            0 => format!("printf 'pub fn m{i}() {{}}\\n' >> $R/{rel}"),
            1 => format!("printf 'pub fn m{i}() {{}}\\n' > $R/{rel}.tmp && mv $R/{rel}.tmp $R/{rel}"),
            2 => format!("printf 'pub fn m{i}() {{}}\\n' >> $R/{rel}; perl -pi -e 's/pub fn/pub  fn/' $R/{rel}"),
            3 => format!("printf 'pub fn m{i}() {{}}\\n' >> $R/{rel}"),
            _ => format!("rm -f $R/{rel}"),
        };
        let existed = abs.exists();
        let c = r.edit(&script);
        if !c.paths.contains(&abs) && (i % 5 != 4 || existed) {
            missed.push(i);
        }
    }
    assert!(missed.is_empty(), "sweeps that did not name the edited file: {missed:?}");
}

#[test]
fn entries_changed_within_the_racy_window_are_read_again_until_they_age_out() {
    // With the real window, an entry whose ctime is recent is never trusted, so a second write
    // that leaves the stat tuple unchanged (a coarse clock) cannot hide.
    let repo = project();
    let view = git::view_for_path(&repo.root).unwrap();
    write(&repo.root, "web/a.ts", "export const a = 5;\n");
    let mut snap = Snapshot::take(&view, &repo.root.join(".git"));
    assert!(snap.check().paths.contains(&repo.root.join("web/a.ts")), "recently written: read again");
    assert!(snap.check().paths.contains(&repo.root.join("web/a.ts")), "and again, while it is still recent");
    std::thread::sleep(std::time::Duration::from_millis(2100));
    let _ = snap.check(); // observes it aged out, still reported once more
    assert!(!snap.check().paths.contains(&repo.root.join("web/a.ts")), "aged out: trusted");
}

#[test]
fn a_sweep_takes_about_a_millisecond_per_thousand_files() {
    // Not a benchmark, a tripwire: the point of the sweep is to be cheaper than `git status`.
    let r = init_repo();
    for d in 0..40 {
        for f in 0..50 {
            write(&r.root, &format!("d{d}/f{f}.ts"), "export const x = 1;\n");
        }
    }
    commit_all(&r.root, "many");
    let view = git::view_for_path(&r.root).unwrap();
    let mut snap = Snapshot::take_with_window(&view, &r.root.join(".git"), 0.0);
    let _ = snap.check();
    // Timed in CPU time, and the fastest of 20 sweeps: wall time on a loaded machine (load above
    // 80) measures the scheduler, not the sweep, and failed here while the sweep was as cheap as
    // ever. A sweep that really got slower is slower in CPU time on every run. The sweep fans out
    // over rayon, so it runs in a one-thread pool whose thread does all of its work, and that
    // thread's clock is the sweep's whole cost (other tests in this process do not count).
    let pool = rayon::ThreadPoolBuilder::new().num_threads(1).build().unwrap();
    let mut best = std::time::Duration::MAX;
    for _ in 0..20 {
        let cpu = pool.install(|| {
            let t = thread_cpu_time();
            assert!(snap.check().is_empty());
            thread_cpu_time().saturating_sub(t)
        });
        best = best.min(cpu);
    }
    assert!(best < std::time::Duration::from_millis(40), "2000 files swept in {best:?} of CPU");
    let _ = Path::new("");
}

/// CPU time this thread has used, user and system (the sweep is mostly `lstat` calls).
fn thread_cpu_time() -> std::time::Duration {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a valid out-pointer; CLOCK_THREAD_CPUTIME_ID exists on macOS and Linux.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    assert_eq!(rc, 0, "clock_gettime(CLOCK_THREAD_CPUTIME_ID)");
    std::time::Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}
