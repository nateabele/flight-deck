//! Trigram index size and build time against corpus size, and in-process query cost against a
//! brute-force scan of the same blobs:
//! `cargo run --release --example trigram_build -- <repo> <scratch-dir> <rev>... [-- <regex>...]`
//!
//! Indexes the distinct indexable blobs of the given revisions (read-only `git ls-tree` and
//! `git cat-file`) into `<scratch-dir>/t.tri`, then, for each regex, times the plan plus candidate
//! lookup plus verification of the candidates (content held in memory) against matching every
//! blob, and checks the two find the same blobs.
use flightindex::trigram::{plan, RepoIndex};
use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;
use std::time::Instant;

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let split = a.iter().position(|x| x == "--").unwrap_or(a.len());
    let (repo, out, revs) = (Path::new(&a[0]), Path::new(&a[1]), &a[2..split]);
    let patterns: Vec<&String> = a.iter().skip(split + 1).collect();
    let mut ids: BTreeSet<String> = BTreeSet::new();
    for rev in revs {
        let o = Command::new("git").arg("-C").arg(repo).args(["ls-tree", "-r", "-z", rev]).output().expect("git ls-tree");
        for entry in o.stdout.split(|&b| b == 0).filter(|e| !e.is_empty()) {
            let e = String::from_utf8_lossy(entry);
            let Some((meta, path)) = e.split_once('\t') else { continue };
            let f: Vec<&str> = meta.split(' ').collect();
            if f.len() == 3 && f[1] == "blob" && flightindex::lang::for_path(Path::new(path)).is_some() {
                ids.insert(f[2].to_string());
            }
        }
    }
    let ids: Vec<String> = ids.into_iter().collect();
    let dir = out.join("t.tri");
    let _ = std::fs::remove_dir_all(&dir);
    let idx = RepoIndex::open(&dir);
    let t = Instant::now();
    let bytes = idx.append(repo, ids.clone()).expect("index");
    let took = t.elapsed();
    let snap = idx.snapshot();
    let load = std::fs::read_to_string("/proc/loadavg").ok().or_else(|| Command::new("sysctl").args(["-n", "vm.loadavg"]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()));
    println!(
        "{} revs: {} blobs, {:.1} MB content -> {:.1} MB index ({:.1}%), {} trigram entries, {} segment(s), built in {:.2?} (load {})",
        revs.len(),
        snap.blobs(),
        bytes as f64 / 1e6,
        snap.bytes() as f64 / 1e6,
        100.0 * snap.bytes() as f64 / bytes.max(1) as f64,
        snap.trigrams(),
        snap.segments(),
        took,
        load.unwrap_or_default()
    );
    if patterns.is_empty() {
        return;
    }
    let contents = cat_file(repo, &ids);
    let docs: Vec<(u32, String)> = ids.iter().zip(contents).filter_map(|(id, c)| Some((snap.ordinal(id)?, String::from_utf8(c?).ok()?))).collect();
    for p in patterns {
        let re = regex::RegexBuilder::new(p).case_insensitive(true).build().expect("regex");
        let t = Instant::now();
        let brute: Vec<u32> = docs.iter().filter(|(_, d)| d.lines().any(|l| re.is_match(l))).map(|(o, _)| *o).collect();
        let scan = t.elapsed();
        let t = Instant::now();
        let q = plan(p).expect("plan");
        let cands = snap.candidates(&q);
        let lookup = t.elapsed();
        let indexed: Vec<u32> = docs.iter().filter(|(o, _)| cands.as_ref().is_none_or(|c| c.contains(*o))).filter(|(_, d)| d.lines().any(|l| re.is_match(l))).map(|(o, _)| *o).collect();
        let total = t.elapsed();
        println!(
            "{p:<32} candidates {:>6} of {}  lookup {:>8.3?}  indexed {:>9.3?}  scan {:>9.3?}  hits {:>5} same {}",
            cands.as_ref().map(|c| c.len().to_string()).unwrap_or_else(|| "all".into()),
            docs.len(),
            lookup,
            total,
            scan,
            brute.len(),
            brute == indexed
        );
    }
}

/// Every blob's content, by `git cat-file --batch` (read-only).
fn cat_file(repo: &Path, ids: &[String]) -> Vec<Option<Vec<u8>>> {
    use std::io::{BufRead, Read, Write};
    let mut child = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["cat-file", "--batch"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("git cat-file");
    let mut stdin = child.stdin.take().unwrap();
    let input: String = ids.iter().map(|i| format!("{i}\n")).collect();
    let writer = std::thread::spawn(move || stdin.write_all(input.as_bytes()));
    let mut r = std::io::BufReader::new(child.stdout.take().unwrap());
    let mut out = Vec::new();
    for _ in ids {
        let mut header = String::new();
        r.read_line(&mut header).unwrap();
        let parts: Vec<&str> = header.split_whitespace().collect();
        if parts.len() == 3 && parts[1] == "blob" {
            let mut buf = vec![0u8; parts[2].parse::<usize>().unwrap() + 1];
            r.read_exact(&mut buf).unwrap();
            buf.pop();
            out.push(Some(buf));
        } else {
            out.push(None);
        }
    }
    let _ = writer.join();
    let _ = child.wait();
    out
}
