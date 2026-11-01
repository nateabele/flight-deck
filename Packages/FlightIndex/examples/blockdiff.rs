//! How many per-file resolved blocks are identical across the graphs of several worktrees:
//! `cargo run --release --example blockdiff -- <store> <worktree>...`.
//!
//! A block is one file's resolution (its imports, its references' targets and confidence, its
//! file edges). Its "stable" hash names targets by path, which is what a block holds when file
//! indices are the same in every graph of a repository; its "dense" hash names them by the graph's
//! own index (0..n by path before blocks were shared, the repository's numbering since), so the two
//! agree when the numbering works. "file-only" drops the target symbol and keeps its file: the
//! sharing there would be if adding a symbol to a file did not renumber its later symbols. Prints,
//! per worktree, how many of its blocks (and references) an earlier graph already had, then the
//! totals, the live heap and the cache's own accounting.
use flightindex::engine::Engine;
use flightindex::graph::ViewGraph;
use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::path::Path;
use std::time::Instant;

/// Live heap, as the library's counting allocator sees it (requested bytes, before rounding).
fn live_mb() -> f64 {
    flightindex::alloc::live_bytes() as f64 / 1_048_576.0
}

struct Block {
    path: String,
    stable: u64,
    dense: u64,
    fileonly: u64,
    bytes: usize,
    refs: usize,
}

fn blocks(g: &ViewGraph) -> Vec<Block> {
    let mut out = Vec::new();
    for i in 0..g.files_len() as u32 {
        let f = g.file(i);
        if !f.alive {
            continue;
        }
        let r = g.resolution(i);
        let mut s = DefaultHasher::new();
        let mut d = DefaultHasher::new();
        let mut fo = DefaultHasher::new();
        f.path.hash(&mut fo);
        format!("{:?}", r.imports).hash(&mut fo);
        f.path.hash(&mut s);
        f.path.hash(&mut d);
        format!("{:?}", r.imports).hash(&mut s);
        format!("{:?}", r.imports).hash(&mut d);
        for rr in &r.refs {
            rr.target.map(|t| (g.file(t.file).path.clone(), t.local)).hash(&mut s);
            rr.target.map(|t| (t.file, t.local)).hash(&mut d);
            rr.target.map(|t| g.file(t.file).path.clone()).hash(&mut fo);
            let x = (rr.confidence as u8, format!("{:?}", rr.external));
            x.hash(&mut s);
            x.hash(&mut d);
        }
        for e in &r.edges {
            g.file(*e).path.hash(&mut s);
            e.hash(&mut d);
            g.file(*e).path.hash(&mut fo);
        }
        let bytes = r.refs.capacity() * std::mem::size_of::<flightindex::graph::RefRes>() + r.imports.capacity() * std::mem::size_of::<flightindex::resolve::Resolved>() + r.edges.capacity() * 4 + 72;
        out.push(Block { path: f.path.clone(), stable: s.finish(), dense: d.finish(), fileonly: fo.finish(), bytes, refs: r.refs.len() });
    }
    out
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let e = Engine::open(&a[1]).unwrap();
    e.set_graph_budget(usize::MAX);
    let mut seen_stable: HashSet<u64> = HashSet::new();
    let mut seen_dense: HashSet<u64> = HashSet::new();
    let mut seen_fo: HashSet<u64> = HashSet::new();
    let (mut fo_b, mut res_bytes_all, mut res_bytes_distinct) = (0usize, 0usize, 0usize);
    let mut keep = Vec::new();
    let mut prev: Option<HashMap<String, u64>> = None;
    let (mut tot_b, mut tot_r, mut dist_sb, mut dist_sr, mut dist_db, mut dist_dr) = (0usize, 0usize, 0usize, 0usize, 0usize, 0usize);
    println!("worktree\tcommit\tfiles\trefs\tbuild_ms\tnew_stable_blocks\tnew_stable_refs\tnew_dense_blocks\tnew_dense_refs\tsame_as_prev_blocks");
    for wt in &a[2..] {
        let v = e.view_for_path(Path::new(wt)).unwrap();
        e.build(&v, &[], |_| {}).unwrap();
        let before = live_mb();
        let t = Instant::now();
        let g = e.graph(&v).unwrap();
        let after = live_mb();
        let ms = t.elapsed().as_secs_f64() * 1000.0;
        let bs = blocks(&g);
        let (mut nsb, mut nsr, mut ndb, mut ndr, mut refs) = (0, 0, 0, 0, 0);
        for b in &bs {
            refs += b.refs;
            if seen_stable.insert(b.stable) {
                res_bytes_distinct += b.bytes;
                nsb += 1;
                nsr += b.refs;
            }
            res_bytes_all += b.bytes;
            if seen_fo.insert(b.fileonly) {
                fo_b += 1;
            }
            if seen_dense.insert(b.dense) {
                ndb += 1;
                ndr += b.refs;
            }
        }
        let same_prev = prev.as_ref().map(|p| bs.iter().filter(|b| p.get(&b.path) == Some(&b.stable)).count()).unwrap_or(0);
        prev = Some(bs.iter().map(|b| (b.path.clone(), b.stable)).collect());
        tot_b += bs.len();
        tot_r += refs;
        dist_sb += nsb;
        dist_sr += nsr;
        dist_db += ndb;
        dist_dr += ndr;
        let commit = v.label.base_commit.clone().unwrap_or_default();
        let own: usize = bs.iter().map(|b| b.bytes).sum();
        eprintln!("heap {:.1} MB (+{:.1} MB for this graph, of which res ~{:.1} MB)", after, after - before, own as f64 / 1_048_576.0);
        keep.push(g);
        println!("{wt}\t{}\t{}\t{refs}\t{ms:.0}\t{nsb}\t{nsr}\t{ndb}\t{ndr}\t{same_prev}", &commit[..commit.len().min(9)], bs.len());
    }
    let st = e.graph_cache_stats();
    println!("cache: {} graphs, charged {:.1} MB, facts {:.1} MB, {} blocks {:.1} MB, own (graphs) {:.1} MB", st.graphs, st.bytes as f64 / 1048576.0, st.facts_bytes as f64 / 1048576.0, st.blocks, st.block_bytes as f64 / 1048576.0, keep.iter().map(|g| g.own_bytes()).sum::<usize>() as f64 / 1048576.0);
    println!("file-only distinct {fo_b} ({:.1}%); res bytes all {:.1} MB distinct {:.1} MB; live heap {:.1} MB with {} graphs", 100.0 * fo_b as f64 / tot_b as f64, res_bytes_all as f64 / 1_048_576.0, res_bytes_distinct as f64 / 1_048_576.0, live_mb(), keep.len());
    println!(
        "TOTAL block refs {tot_b} (refs {tot_r}); distinct stable {dist_sb} ({:.1}%) refs {dist_sr} ({:.1}%); distinct dense {dist_db} ({:.1}%) refs {dist_dr} ({:.1}%)",
        100.0 * dist_sb as f64 / tot_b as f64,
        100.0 * dist_sr as f64 / tot_r.max(1) as f64,
        100.0 * dist_db as f64 / tot_b as f64,
        100.0 * dist_dr as f64 / tot_r.max(1) as f64
    );
}
