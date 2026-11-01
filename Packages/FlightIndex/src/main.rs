//! `fdindex`: the CLI/daemon binary. Step 1 ships only developer verbs that drive the engine
//! directly; the daemon, MCP shim and query CLI arrive in steps 2-4.
//!
//! ```text
//! fdindex build <path> [--store DIR] [--priority FILE]...   index the view containing <path>
//! fdindex find  <path> <name> [--store DIR]                 find a definition by exact name
//! fdindex refs  <path> <name> [--store DIR]                 references to a definition
//! fdindex gc    <path> [--store DIR]                        garbage-collect and vacuum its repo
//! ```

use flightindex::engine::{Engine, Phase};
use flightindex::query::NameMatch;
use flightindex::store::default_store_root;
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    if let Err(e) = run() {
        eprintln!("fdindex: {e}");
        std::process::exit(1);
    }
}

fn run() -> flightindex::error::Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut store = default_store_root();
    let mut priority: Vec<PathBuf> = Vec::new();
    let mut positional = Vec::new();
    while !args.is_empty() {
        let a = args.remove(0);
        match a.as_str() {
            "--store" if !args.is_empty() => store = PathBuf::from(args.remove(0)),
            "--priority" if !args.is_empty() => priority.push(PathBuf::from(args.remove(0))),
            _ => positional.push(a),
        }
    }
    let (verb, path) = match positional.as_slice() {
        [v, p, ..] => (v.as_str(), PathBuf::from(p)),
        _ => {
            eprintln!("usage: fdindex <build|find|refs|gc> <path> [name] [--store DIR] [--priority FILE]");
            std::process::exit(2);
        }
    };
    let path = path.canonicalize().unwrap_or(path);
    let engine = Engine::open(store)?;
    let view = engine.view_for_path(&path)?;
    match verb {
        "build" => {
            let t = Instant::now();
            let report = engine.build(&view, &priority, |p| {
                if matches!(p.phase, Phase::PriorityDone) {
                    eprintln!("priority slice ready: {} of {} files", p.done, p.total);
                }
            })?;
            let built = t.elapsed();
            let g = engine.graph(&view)?;
            let graph_time = t.elapsed() - built;
            println!("view: {:?}", g.label);
            println!("build: {report:?}");
            println!("graph: {} ms", graph_time.as_millis());
            let stats = g.stats().data;
            for (lang, s) in &stats.by_language {
                println!("{lang}: {} files, {} lines, {} symbols", s.files, s.lines, s.symbols);
            }
            let (exact, fallback, none) = g.resolution_counts();
            println!("refs: {exact} exact, {fallback} fallback, {none} unresolved");
            let st = engine.reader(&view.label.repo)?.stats()?;
            println!("store: {} facts rows, {} symbols, {} bytes", st.facts, st.symbols, (st.page_count - st.free_pages) * st.page_size);
        }
        "find" => {
            let name = positional.get(2).cloned().unwrap_or_default();
            let g = engine.graph(&view)?;
            for h in g.find_symbols(&NameMatch::Exact(name), None, 20).data {
                println!("{} {} {}:{}-{}  {}", h.kind.as_str(), h.name, h.path.display(), h.start_line, h.end_line, h.signature.unwrap_or_default());
            }
        }
        "refs" => {
            let name = positional.get(2).cloned().unwrap_or_default();
            let g = engine.graph(&view)?;
            for def in g.find_symbols(&NameMatch::Exact(name), None, 5).data {
                println!("{} {}:{}", def.name, def.path.display(), def.start_line);
                for r in g.references(def.id).data {
                    println!("  {}:{} {:?} in {} ({:?})", r.path.display(), r.line, r.kind, r.enclosing.unwrap_or_default(), r.confidence);
                }
            }
        }
        "gc" => {
            let stats = engine.gc(&view.label.repo)?;
            let freed = engine.incremental_vacuum(&view.label.repo, 0)?;
            println!("gc: {stats:?}; vacuumed {freed} pages");
        }
        other => {
            eprintln!("unknown verb {other}");
            std::process::exit(2);
        }
    }
    Ok(())
}
