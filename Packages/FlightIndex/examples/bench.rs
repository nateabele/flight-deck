//! Request latency against a running daemon, without a process spawn in the number:
//! `cargo run --release --example bench -- <socket> <cwd> <runs> 'tool {json args}'...`
//! Prints min / p50 / p95 / max in milliseconds per request spec, plus how many answered ok.
use flightindex::client::Client;
use std::time::Instant;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (socket, cwd, runs) = (&a[1], &a[2], a[3].parse::<usize>().unwrap());
    let mut c = Client::connect(std::path::Path::new(socket)).expect("connect");
    for spec in &a[4..] {
        let (tool, args) = spec.split_once(' ').unwrap_or((spec, "{}"));
        let args: serde_json::Map<String, serde_json::Value> = serde_json::from_str(args).expect("args json");
        let mut ms = Vec::new();
        let mut ok = 0;
        for _ in 0..runs {
            let t = Instant::now();
            let r = c.call(cwd, 0, tool, args.clone()).expect("call");
            ms.push(t.elapsed().as_secs_f64() * 1000.0);
            ok += r.ok as usize;
        }
        ms.sort_by(|x, y| x.partial_cmp(y).unwrap());
        let p = |q: f64| ms[((ms.len() - 1) as f64 * q) as usize];
        println!("{tool:<8} {:<48} min {:>7.1}  p50 {:>7.1}  p95 {:>7.1}  max {:>7.1} ms  ok {ok}/{runs}", serde_json::to_string(&args).unwrap().chars().take(48).collect::<String>(), ms[0], p(0.5), p(0.95), ms[ms.len() - 1]);
    }
}
