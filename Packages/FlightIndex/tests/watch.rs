mod common;
use common::*;
use flightindex::watch::{WatchConfig, Watcher};
use std::process::Command;
use std::time::Instant;

fn start() -> std::sync::Arc<Watcher> {
    Watcher::start(&WatchConfig::default(), |_| {}).expect("a watcher on this platform")
}

#[test]
fn every_external_write_is_reported_by_the_next_sync() {
    // The barrier is the whole read-your-writes rule: a sync that returns before the stream has
    // delivered an edit made just before it lets a query answer from stale facts.
    let r = init_repo();
    write(&r.root, "a.rs", "fn a() {}\n");
    commit_all(&r.root, "init");
    let w = start();
    let gitdir = r.root.join(".git");
    assert!(w.watch_worktree(&r.root, &gitdir, &gitdir));
    w.sync(&r.root).unwrap();
    let mut missed = 0;
    let mut times = Vec::new();
    for i in 0..100 {
        let file = r.root.join(format!("f{}.rs", i % 7));
        // A different process each time, as an agent's `sed -i` or a patch tool would be.
        let script = match i % 4 {
            0 => format!("printf 'fn x{i}() {{}}\\n' >> {}", file.display()),
            1 => format!("printf 'fn y{i}() {{}}\\n' > {}.tmp && mv {}.tmp {}", file.display(), file.display(), file.display()),
            2 => format!("printf 'fn z{i}() {{}}\\n' >> {}; sed -i '' 's/fn/fn/' {}", file.display(), file.display()),
            _ => format!("rm -f {}", file.display()),
        };
        let existed = file.exists();
        assert!(Command::new("sh").arg("-c").arg(&script).status().unwrap().success());
        let t = Instant::now();
        let p = w.sync(&r.root).unwrap();
        times.push(t.elapsed());
        // `rm -f` of a file that was never there changes nothing, so reports nothing.
        if !p.paths.contains(&file) && (i % 4 != 3 || existed) {
            missed += 1;
        }
    }
    times.sort();
    eprintln!("sync p50 {:?} p95 {:?} max {:?}", times[50], times[95], times[99]);
    assert_eq!(missed, 0, "syncs that did not report the preceding write");
}
