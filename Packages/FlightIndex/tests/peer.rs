//! Blob facts travel (spec §7 item 3): a second store fetches the facts it lacks from a peer
//! instead of parsing them, and ends up with the same facts and the same answers.
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::error::Result;
use flightindex::git::FileRef;
use flightindex::lang;
use flightindex::peer::serve::{serve_stream, ServeCounters};
use flightindex::peer::socket::SocketPeer;
use flightindex::peer::wire::{self, WireEntry, WireFacts, WireKey};
use flightindex::peer::{exchange, FactKey, FactSource, FetchStats};
use flightindex::store::ParsedBlob;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

/// A peer served from another store in this process, over a socket pair: the same frames the
/// daemon's socket carries, without a daemon.
struct StorePeer {
    store: PathBuf,
}

impl FactSource for StorePeer {
    fn fetch(&self, keys: &[FactKey], sink: &mut dyn FnMut(Vec<ParsedBlob>) -> Result<()>) -> Result<FetchStats> {
        let (mut ours, theirs) = UnixStream::pair().unwrap();
        let store = self.store.clone();
        let holder = std::thread::spawn(move || {
            let (mut r, mut w) = (theirs.try_clone().unwrap(), theirs);
            let _ = serve_stream(&store, &mut r, &mut w, &ServeCounters::default());
        });
        let mut r = ours.try_clone().unwrap();
        let out = exchange(&mut r, &mut ours, keys, sink);
        drop(ours);
        drop(r);
        holder.join().unwrap();
        out
    }

    fn describe(&self) -> String {
        "test store".into()
    }
}

fn seed(r: &Repo) {
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/A.elm", ELM_A);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "web/app.ts", "import { f } from './util';\nexport const g = () => f();\nclass K extends Base { run() { return f(); } }\n");
    write(&r.root, "web/util.ts", "export function f() { return 1 }\n");
    write(&r.root, "lib.rs", "pub fn x() { y() }\nfn y() {}\n");
    write(&r.root, "Sources/T.swift", "struct T { let n: Int\n func go() -> Int { n } }\nfunc use(t: T) -> Int { t.go() }\n");
    commit_all(&r.root, "init");
}

fn version(f: &FileRef) -> u32 {
    lang::by_id(f.language).map(|l| l.parser_version()).unwrap()
}

/// Every file's facts, with names as text, as one store holds them.
fn all_facts(e: &Engine, root: &Path) -> Vec<(String, Option<(bool, String)>)> {
    let v = e.view_for_path(root).unwrap();
    let reader = e.reader(&v.label.repo).unwrap();
    let mut out: Vec<_> = v
        .files()
        .iter()
        .map(|f| {
            let stored = reader.get_stored(&f.blob_id, f.language, version(f)).unwrap().map(|(parsed, _)| parsed);
            let text = reader.get_facts(&f.blob_id, f.language, version(f)).unwrap();
            (f.path.clone(), stored.map(|p| (p, format!("{text:?}"))))
        })
        .collect();
    out.sort();
    out
}

fn two_engines() -> (tempfile::TempDir, Engine, Engine) {
    let d = tempfile::tempdir().unwrap();
    let a = Engine::open(d.path().join("a")).unwrap();
    let b = Engine::open(d.path().join("b")).unwrap();
    (d, a, b)
}

#[test]
fn a_build_with_a_peer_fetches_every_blob_the_peer_holds_and_parses_none() {
    let (_d, a, b) = two_engines();
    let r = init_repo();
    seed(&r);
    let va = a.view_for_path(&r.root).unwrap();
    assert_eq!(a.build(&va, &[], |_| {}).unwrap().parsed, 6);

    b.set_peer(Some(Arc::new(StorePeer { store: a.store_root().to_path_buf() })));
    let vb = b.view_for_path(&r.root).unwrap();
    let rep = b.build(&vb, &[], |_| {}).unwrap();
    assert_eq!(rep.parsed, 0, "every blob came from the peer");
    assert_eq!(rep.fetched, 6);
    assert!(rep.fetched_bytes > 0);
    assert_eq!(b.parse_count(), 0);
    assert_eq!(all_facts(&b, &r.root), all_facts(&a, &r.root), "the same facts, names and all");

    // and the same answers
    let (ga, gb) = (a.graph(&va).unwrap(), b.graph(&vb).unwrap());
    let q = flightindex::query::NameMatch::Exact("f".into());
    assert_eq!(format!("{:?}", gb.find_symbols(&q, None, 10).data), format!("{:?}", ga.find_symbols(&q, None, 10).data));
    assert_eq!(format!("{:?}", gb.stats().data), format!("{:?}", ga.stats().data));
}

#[test]
fn keys_the_peer_lacks_are_parsed() {
    let (_d, a, b) = two_engines();
    let r = init_repo();
    seed(&r);
    a.build(&a.view_for_path(&r.root).unwrap(), &[], |_| {}).unwrap();
    write(&r.root, "src/B.elm", "module B exposing (b)\n\nb : Int\nb =\n    99\n");
    write(&r.root, "src/D.elm", "module D exposing (d)\n\nd =\n    1\n");
    commit_all(&r.root, "two");

    b.set_peer(Some(Arc::new(StorePeer { store: a.store_root().to_path_buf() })));
    let rep = b.build(&b.view_for_path(&r.root).unwrap(), &[], |_| {}).unwrap();
    assert_eq!((rep.fetched, rep.parsed), (5, 2), "the peer had the five unchanged blobs");
}

#[test]
fn a_skipped_blob_travels_as_skipped() {
    let (_d, a, b) = two_engines();
    let r = init_repo();
    seed(&r);
    std::fs::write(r.root.join("web/bin.ts"), [0xffu8, 0xfe, 0x00, 0x41]).unwrap();
    commit_all(&r.root, "binary");
    let rep = a.build(&a.view_for_path(&r.root).unwrap(), &[], |_| {}).unwrap();
    assert_eq!(rep.skipped, 1);

    b.set_peer(Some(Arc::new(StorePeer { store: a.store_root().to_path_buf() })));
    let rep = b.build(&b.view_for_path(&r.root).unwrap(), &[], |_| {}).unwrap();
    assert_eq!((rep.fetched, rep.parsed, rep.skipped), (7, 0, 0));
    let facts = all_facts(&b, &r.root);
    let bin = facts.iter().find(|(p, _)| p == "web/bin.ts").unwrap();
    assert_eq!(bin.1.as_ref().map(|(parsed, _)| *parsed), Some(false), "recorded skipped, not as an empty parse");
    assert_eq!(facts, all_facts(&a, &r.root));
}

#[test]
fn a_dead_peer_costs_nothing_but_the_attempt() {
    let (d, _a, b) = two_engines();
    let r = init_repo();
    seed(&r);
    b.set_peer(Some(Arc::new(SocketPeer::new(d.path().join("nobody.sock")))));
    let rep = b.build(&b.view_for_path(&r.root).unwrap(), &[], |_| {}).unwrap();
    assert_eq!((rep.fetched, rep.parsed), (0, 6));
    assert_eq!(b.peer_stats().failures, 1);
}

#[test]
fn want_frames_round_trip_hex_and_text_ids() {
    let keys = vec![
        WireKey { blob_id: "0123456789abcdef0123456789abcdef01234567".into(), language: "rust".into(), parser_version: 3 },
        WireKey { blob_id: "not-hex:path/x".into(), language: "elm".into(), parser_version: 1 },
        WireKey { blob_id: "89abcdef0123456789abcdef0123456789abcdef".into(), language: "rust".into(), parser_version: 3 },
    ];
    let bytes = wire::encode_want(&keys);
    assert!(bytes.len() < 20 * 2 + 14 + 40, "hex ids travel as raw bytes: {} bytes", bytes.len());
    assert_eq!(wire::decode_want(&bytes).unwrap(), keys);
}

#[test]
fn facts_frames_round_trip_and_reject_garbage() {
    let f = WireFacts {
        new_names: (0..300).map(|i| format!("name_{i}")).collect(),
        entries: vec![
            WireEntry { key_index: 4, parsed: true, module_name: Some("A".into()), line_count: 12, chunk: vec![1, 0, 0, 0, 0, 0, 0], types: String::new() },
            WireEntry { key_index: 0, parsed: false, module_name: None, line_count: 0, chunk: Vec::new(), types: "x".into() },
        ],
    };
    let bytes = wire::encode_facts(&f);
    assert_eq!(wire::decode_facts(&bytes).unwrap(), f);
    for cut in [0, 1, 5, bytes.len() / 2, bytes.len() - 1] {
        assert!(wire::decode_facts(&bytes[..cut]).is_err(), "a frame cut at {cut} is an error, not a panic");
    }
    let mut stream = Vec::new();
    wire::write_frame(&mut stream, wire::KIND_FACTS, &bytes).unwrap();
    let (kind, payload) = wire::read_frame(&mut stream.as_slice()).unwrap().unwrap();
    assert_eq!((kind, payload), (wire::KIND_FACTS, bytes));
    let huge = (wire::MAX_FRAME + 1).to_le_bytes();
    assert!(wire::read_frame(&mut huge.as_slice()).is_err(), "an oversized length is refused before allocating");
}

// ---------------------------------------------------------------- two daemons

const BIN: &str = env!("CARGO_BIN_EXE_fdindex");

struct Daemon {
    store: PathBuf,
    socket: PathBuf,
    child: std::process::Child,
}

impl Daemon {
    fn start(dir: &Path, name: &str, extra: &[&str]) -> Daemon {
        let (store, socket) = (dir.join(format!("store-{name}")), dir.join(format!("{name}.sock")));
        let child = Command::new(BIN)
            .args(["--store", store.to_str().unwrap(), "--socket", socket.to_str().unwrap(), "daemon", "--no-watch"])
            .args(extra)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let d = Daemon { store, socket, child };
        let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !d.socket.exists() {
            assert!(std::time::Instant::now() < until, "daemon {name} did not open its socket");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        d
    }

    fn run(&self, cwd: &Path, args: &[&str]) -> String {
        let o = Command::new(BIN).args(["--store", self.store.to_str().unwrap(), "--socket", self.socket.to_str().unwrap(), "--no-start"]).args(args).current_dir(cwd).output().unwrap();
        assert!(o.status.success(), "{args:?}: {}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).to_string()
    }

    fn status(&self, cwd: &Path) -> serde_json::Value {
        serde_json::from_str(&self.run(cwd, &["status", "--json"])).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = Command::new(BIN).args(["--store", self.store.to_str().unwrap(), "--socket", self.socket.to_str().unwrap(), "stop"]).output();
        let _ = self.child.wait();
    }
}

#[test]
fn a_daemon_with_a_peer_socket_indexes_from_the_peer_and_answers_the_same() {
    let dir = tempfile::tempdir().unwrap();
    let dir = dir.path().canonicalize().unwrap();
    let r = init_repo();
    seed(&r);
    let a = Daemon::start(&dir, "a", &[]);
    let b = Daemon::start(&dir, "b", &["--peer-socket", a.socket.to_str().unwrap()]);
    a.run(&r.root, &["build", "."]);
    b.run(&r.root, &["build", "."]);

    let sb = b.status(&r.root);
    assert_eq!(sb["data"]["parses"], 0, "{sb}");
    assert_eq!(sb["data"]["peer"]["fetched"], 6, "{sb}");
    assert!(sb["data"]["peer"]["bytes_in"].as_u64().unwrap() > 0);
    let sa = a.status(&r.root);
    assert_eq!(sa["data"]["peer_served"]["served"], 6, "{sa}");

    for q in [&["find", "f"][..], &["refs", "f"], &["outline", "web/app.ts"], &["map"], &["impact", "web/util.ts"]] {
        assert_eq!(b.run(&r.root, q), a.run(&r.root, q), "{q:?} answers the same from fetched facts");
    }
}
