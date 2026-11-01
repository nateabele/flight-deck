//! Graph build time through the engine, with only API that predates proposal #10, so the same file
//! runs against the baseline and the change:
//! `buildtime <store> <runs> <near-worktree> <worktree> <edit-file-rel-to-near>`
//! A: cold commit graph of <worktree> (fresh engine). B: commit graph of <worktree> right after
//! <near-worktree>'s in the same engine (a new commit with a cached neighbour). C: overlay graph
//! of <near-worktree> after an edit to one file, base already cached (the per-edit path).
//! Reports p50 wall and p50 process CPU (user+sys) per scenario.
use flightindex::engine::Engine;
use std::path::Path;
use std::time::Instant;

fn cpu_ms() -> f64 {
    let mut u: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) };
    let t = |v: libc::timeval| v.tv_sec as f64 * 1000.0 + v.tv_usec as f64 / 1000.0;
    t(u.ru_utime) + t(u.ru_stime)
}

fn timed<T>(f: impl FnOnce() -> T) -> (T, f64, f64) {
    let (w, c) = (Instant::now(), cpu_ms());
    let r = f();
    (r, w.elapsed().as_secs_f64() * 1000.0, cpu_ms() - c)
}

fn med(mut v: Vec<f64>) -> f64 {
    v.sort_by(|x, y| x.partial_cmp(y).unwrap());
    v[v.len() / 2]
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (store, runs) = (&a[1], a[2].parse::<usize>().unwrap());
    let (near, path, edit) = (Path::new(&a[3]), Path::new(&a[4]), Path::new(&a[3]).join(&a[5]));
    let original = std::fs::read_to_string(&edit).unwrap();
    {
        let e = Engine::open(store).unwrap();
        for p in [near, path] {
            let v = e.view_for_path(p).unwrap();
            e.build(&v, &[], |_| {}).unwrap();
        }
    }
    let mut s: Vec<Vec<f64>> = vec![Vec::new(); 6];
    for run in 0..runs {
        let e = Engine::open(store).unwrap();
        let v = e.view_for_path(path).unwrap();
        let (_, w, c) = timed(|| e.graph(&v).unwrap());
        s[0].push(w);
        s[1].push(c);

        let e = Engine::open(store).unwrap();
        let vn = e.view_for_path(near).unwrap();
        e.graph(&vn).unwrap();
        let v = e.view_for_path(path).unwrap();
        let (_, w, c) = timed(|| e.graph(&v).unwrap());
        s[2].push(w);
        s[3].push(c);

        // C: base of <near> is cached in `e`; an edit makes an overlay graph.
        std::fs::write(&edit, format!("{original}\n\nqTenProbe{run} : Int\nqTenProbe{run} =\n    {run}\n")).unwrap();
        let vd = e.view_for_path(near).unwrap();
        e.build(&vd, &[], |_| {}).unwrap();
        let (_, w, c) = timed(|| e.graph(&vd).unwrap());
        s[4].push(w);
        s[5].push(c);
        std::fs::write(&edit, &original).unwrap();
    }
    for (i, name) in ["A cold commit graph", "B new commit, neighbour cached", "C overlay after one edit"].iter().enumerate() {
        println!("{name:<32} wall p50 {:>8.1} ms   cpu p50 {:>8.1} ms", med(s[2 * i].clone()), med(s[2 * i + 1].clone()));
    }
}
