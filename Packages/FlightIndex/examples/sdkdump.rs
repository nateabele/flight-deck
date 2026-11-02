//! What the Swift package views read from the active SDK: `cargo run --release --example sdkdump
//! -- <Module>... [--find Name] [--member Type.name]`. Prints each module's parse time, names and
//! re-exports, then where a name resolves in their closure.
use flightindex::pkgview_swift as sdk;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(s) = sdk::sdk() else {
        println!("no SDK");
        return;
    };
    println!("sdk {} {} at {}", s.name, s.version, s.root.display());
    let mut mods: Vec<&str> = Vec::new();
    let mut finds: Vec<&str> = Vec::new();
    let mut members: Vec<&str> = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--find" => finds.extend(it.next().map(String::as_str)),
            "--member" => members.extend(it.next().map(String::as_str)),
            m => mods.push(m),
        }
    }
    for m in &mods {
        let t = std::time::Instant::now();
        match sdk::module(&s, m) {
            Some(x) => println!("{m}: {} ms, {} top, {} types, {} names, reexports {:?}", t.elapsed().as_millis(), x.top.len(), x.types.len(), x.names(), x.reexports),
            None => println!("{m}: not in the SDK"),
        }
    }
    let t = std::time::Instant::now();
    let scope = sdk::closure(&s, &mods);
    println!("closure: {} modules in {} ms: {:?}", scope.len(), t.elapsed().as_millis(), scope.iter().map(|m| m.name.as_str()).collect::<Vec<_>>());
    for f in finds {
        for m in scope.iter() {
            if let Some(x) = m.top.get(f) {
                println!("  {f}: {} ({}) {:?}", x.display(), x.kind.as_str(), x.signature);
            }
        }
        println!("  -> {:?}", sdk::lookup_top(&scope, f).map(|x| x.display()));
    }
    for q in members {
        let (ty, name) = q.rsplit_once('.').unwrap_or(("", q));
        match sdk::lookup_member(&scope, ty, name) {
            Some(mem) => println!("  {q}: {} {:?} -> {:?}", mem.sym.display(), mem.sym.signature, mem.ty),
            None => println!("  {q}: none"),
        }
    }
    let st = sdk::stats();
    println!("stats: {} modules, {} names, missing {:?}", st.modules, st.names, st.missing);
}
