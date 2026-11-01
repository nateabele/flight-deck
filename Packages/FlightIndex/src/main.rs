//! `fdindex`: the machine-wide code index. One binary, three roles.
//!
//! ```text
//! fdindex daemon [--foreground] [--graph-budget-mb N] [--build-wait-ms N]   run the index daemon
//! fdindex status [--json] | stop                                            ask it, or stop it
//! fdindex mcp [--no-start]                                                  stdio MCP server (a client of the daemon)
//! fdindex service install|uninstall|start|stop|status|restart [--label L]   keep it running at login
//! (install, uninstall, start, restart are also top-level verbs; started as `qartez` this is the qartez alias)
//! fdindex <tool> [first-arg] [--flag value]...                              query it
//!
//! tools: map find grep read outline deps stats impact refs calls
//!        build <path> | gc <path> | add_root <path>          (admin: index a view now, collect, hint)
//! global flags: --store DIR  --socket PATH  --cwd DIR  --json
//! ```
//!
//! A query verb connects to the daemon, starting it detached if it is not running, and sends the
//! tool with the caller's cwd. Flags become tool arguments as they are written (`--file-path x` is
//! `file_path`), so there is no per-tool flag table to keep in step with the tools themselves;
//! the first positional argument fills the tool's required parameter.

use flightindex::alias;
use flightindex::client::{connect_or_start, Client};
use flightindex::daemon;
use flightindex::mcp;
use flightindex::error::{Error, Result};
use flightindex::proto::state;
use flightindex::runtime::Paths;
use flightindex::service::Config;
use flightindex::service_install;
use flightindex::store::default_store_root;
use serde_json::{json, Map, Value};
use std::path::PathBuf;
use std::time::Duration;

/// Flags that never take a value, so `find --regex foo` reads `foo` as the name, not as regex's value.
const BOOLEAN_FLAGS: &[&str] = &[
    "regex", "transitive", "include_tests", "all_files", "search_bodies", "apply", "with_health", "json", "foreground", "allow_collision", "force", "no_start",
];

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("fdindex: {e}");
            std::process::exit(1);
        }
    }
}

struct Cli {
    store: PathBuf,
    socket: Option<PathBuf>,
    cwd: Option<String>,
    json: bool,
    foreground: bool,
    graph_budget_mb: Option<usize>,
    build_wait_ms: Option<u64>,
    verb: String,
    positional: Vec<String>,
    args: Map<String, Value>,
}

fn parse(argv: Vec<String>) -> std::result::Result<Cli, String> {
    let mut cli = Cli {
        store: default_store_root(),
        socket: None,
        cwd: None,
        json: false,
        foreground: false,
        graph_budget_mb: None,
        build_wait_ms: None,
        verb: String::new(),
        positional: Vec::new(),
        args: Map::new(),
    };
    let mut it = argv.into_iter().peekable();
    while let Some(a) = it.next() {
        let Some(flag) = a.strip_prefix("--") else {
            if cli.verb.is_empty() {
                cli.verb = a;
            } else {
                cli.positional.push(a);
            }
            continue;
        };
        let (key, inline) = match flag.split_once('=') {
            Some((k, v)) => (k.replace('-', "_"), Some(v.to_string())),
            None => (flag.replace('-', "_"), None),
        };
        let boolean = BOOLEAN_FLAGS.contains(&key.as_str());
        let value = match inline {
            Some(v) => Some(v),
            None if boolean => it.next_if(|n| matches!(n.as_str(), "true" | "false")),
            None => it.next_if(|n| !n.starts_with("--")),
        };
        match (key.as_str(), value) {
            ("store", Some(v)) => cli.store = PathBuf::from(v),
            ("socket", Some(v)) => cli.socket = Some(PathBuf::from(v)),
            ("cwd", Some(v)) => cli.cwd = Some(v),
            ("root", Some(v)) => cli.cwd = Some(v),
            ("json", _) => cli.json = true,
            ("foreground", _) => cli.foreground = true,
            ("graph_budget_mb", Some(v)) => cli.graph_budget_mb = Some(v.parse().map_err(|_| "--graph-budget-mb takes a number")?),
            ("build_wait_ms", Some(v)) if cli.verb == "daemon" => cli.build_wait_ms = Some(v.parse().map_err(|_| "--build-wait-ms takes a number")?),
            (k, None) => {
                cli.args.insert(k.to_string(), Value::Bool(true));
            }
            (k, Some(v)) => {
                // A repeated flag becomes a list (`--boost-files a --boost-files b`).
                match cli.args.get_mut(k) {
                    Some(Value::Array(list)) => list.push(Value::String(v)),
                    Some(old) => *old = json!([old.clone(), v]),
                    None => {
                        cli.args.insert(k.to_string(), Value::String(v));
                    }
                }
            }
        }
    }
    Ok(cli)
}

/// The parameter the first positional argument fills.
fn positional_param(tool: &str, first: &str) -> Option<&'static str> {
    Some(match tool {
        "find" | "calls" => "name",
        "refs" => "symbol",
        "grep" => "query",
        "outline" | "deps" | "impact" | "stats" | "build" | "gc" | "add_root" | "workspace" => "file_path",
        // `read src/x.rs` reads a file; `read parse_config` reads a symbol.
        "read" if first.contains('/') || std::path::Path::new(first).is_file() => "file_path",
        "read" => "symbol_name",
        _ => return None,
    })
}

fn run() -> Result<i32> {
    let argv0 = std::env::args().next().unwrap_or_default();
    let cli = parse(alias::normalize(&argv0, std::env::args().skip(1).collect())).map_err(Error::Msg)?;
    if cli.verb.is_empty() {
        eprintln!("usage: fdindex <daemon|mcp|service|status|start|stop|restart|install|uninstall|map|find|grep|read|outline|deps|stats|impact|refs|calls|build|gc|add_root> [args] [--flags]");
        return Ok(2);
    }
    let paths = Paths::new(&cli.store, cli.socket.clone());

    if cli.verb == "daemon" {
        let mut config = Config::new(&cli.store);
        if let Some(mb) = cli.graph_budget_mb {
            config.graph_budget = mb << 20;
        }
        if let Some(ms) = cli.build_wait_ms {
            config.build_wait = Duration::from_millis(ms);
        }
        let _ = cli.foreground; // the daemon always logs to its file; there is no terminal mode to enter
        daemon::run(daemon::Options { paths, config })?;
        return Ok(0);
    }

    // Verbs that manage or front the daemon rather than query it. None of them starts it by itself.
    let label = cli.args.get("label").and_then(Value::as_str).map(str::to_string);
    match cli.verb.as_str() {
        "stop" => {
            service_install::stop(&paths)?;
            return Ok(0);
        }
        "service" => return service_install::run(cli.positional.first().map_or("status", String::as_str), paths, label),
        "install" | "uninstall" | "start" | "restart" => return service_install::run(&cli.verb, paths, label),
        "status" if !cli.json => return service_install::run("status", paths, label),
        "mcp" => {
            let cwd = absolute_cwd(&cli)?;
            let auto_start = !cli.args.contains_key("no_start") && std::env::var_os("FLIGHTDECK_INDEX_NO_START").is_none();
            mcp::run(mcp::Options { paths, cwd, auto_start, daemon_args: daemon_args(&cli) })?;
            return Ok(0);
        }
        _ => {}
    }

    let mut args = cli.args.clone();
    if let Some(first) = cli.positional.first() {
        match positional_param(&cli.verb, first) {
            Some(param) => {
                args.entry(param.to_string()).or_insert_with(|| Value::String(first.clone()));
            }
            None => return Err(Error::Msg(format!("{} takes no positional argument (got '{first}')", cli.verb))),
        }
    }
    let cwd = absolute_cwd(&cli)?;

    let connected = if cli.verb == "status" {
        // Asking is not a reason to start it.
        Client::connect(&paths.socket).map_err(|e| Error::Msg(format!("the index daemon is not running ({e})")))
    } else {
        connect_or_start(&paths, &daemon_args(&cli))
    };
    let mut client = match connected {
        Ok(c) => c,
        Err(e) => {
            // The state a shim reports when it cannot reach the daemon: agents fall back to rg.
            eprintln!("state: {}\n{e}", state::UNAVAILABLE);
            return Ok(3);
        }
    };
    let resp = client.call(&cwd, 0, &cli.verb, args)?;
    if cli.json || (cli.verb == "status" && resp.text.is_none()) {
        println!("{}", serde_json::to_string_pretty(&resp).unwrap_or_default());
        return Ok(if resp.ok { 0 } else { 1 });
    }
    if cli.verb == "status" && !resp.ok {
        eprintln!("{}", resp.error.unwrap_or_default());
        return Ok(1);
    }
    match (resp.ok, resp.text, resp.error) {
        (true, Some(t), _) => {
            println!("{t}");
            Ok(0)
        }
        (_, _, e) => {
            eprintln!("state: {}\n{}", resp.state.unwrap_or_default(), e.unwrap_or_default());
            Ok(1)
        }
    }
}

/// Daemon tuning a client forwards when it is the one starting the daemon.
fn daemon_args(cli: &Cli) -> Vec<String> {
    let mut a = Vec::new();
    if let Some(mb) = cli.graph_budget_mb {
        a.extend(["--graph-budget-mb".to_string(), mb.to_string()]);
    }
    a
}

/// The caller's directory: `--cwd` (or qartez's `--root`) made absolute, else the process's own.
fn absolute_cwd(cli: &Cli) -> Result<String> {
    let here = std::env::current_dir().map_err(|e| Error::Msg(format!("cannot read the current directory: {e}")))?;
    Ok(match &cli.cwd {
        Some(c) => here.join(c).to_string_lossy().to_string(),
        None => here.to_string_lossy().to_string(),
    })
}
