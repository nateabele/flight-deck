//! What a Rust package view holds: load std (or a registry crate by `name@version` through a
//! one-package lock) and print what each path names, with load times.
//! `cargo run --release --example crate_probe -- std collections::HashMap prelude::rust_2021::Default::default`
use flightindex::facts::RefKind;
use flightindex::pkgview::cargo;
use std::time::Instant;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let t = Instant::now();
    let krate = match a[1].split_once('@') {
        None => cargo::sysroot_crate(&a[1]),
        Some((name, version)) => {
            let manifest = "[package]\nname = \"probe\"\nversion = \"0.0.0\"\n";
            let lock = format!("[[package]]\nname = \"probe\"\nversion = \"0.0.0\"\ndependencies = [\"{name}\"]\n\n[[package]]\nname = \"{name}\"\nversion = \"{version}\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n");
            cargo::RustDeps::new(manifest, Some(&lock), None).krate(&name.replace('-', "_"))
        }
    };
    let Some(krate) = krate else {
        eprintln!("not loaded: {:?}", cargo::stats().missing);
        return;
    };
    let st = cargo::stats();
    let mb = |b: usize| b as f64 / 1048576.0;
    println!(
        "loaded in {:?}: {} crate(s), {} names, {} files of {}; heap live {:.1} MB, peak {:.1} MB",
        t.elapsed(),
        st.crates,
        st.names,
        krate.files,
        krate.package,
        mb(flightindex::alloc::live_bytes()),
        mb(flightindex::alloc::peak_bytes())
    );
    for path in &a[2..] {
        let t = Instant::now();
        let mut cur = Some(krate.root());
        for seg in path.split("::") {
            cur = cur.and_then(|c| c.child(seg));
        }
        match cur {
            None => println!("{path}: nothing ({:?})", t.elapsed()),
            Some(found) => {
                let t0 = t;
                let t = found;
                let items: Vec<String> = t.items.iter().map(|s| format!("{} ({})", s.display(), s.kind.as_str())).collect();
                let pick = [RefKind::Call, RefKind::Type, RefKind::Macro].map(|k| t.pick(k).map(|s| s.kind.as_str()).unwrap_or("-"));
                println!("{path}: module={} items=[{}] pick call/type/macro={pick:?} ({:?})", t.module.is_some(), items.join(", "), t0.elapsed());
            }
        }
    }
}
