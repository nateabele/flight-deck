//! `fdindex service install|uninstall|start|stop|status|restart`: keeps the daemon running as a
//! login service (a launchd user agent on macOS, a systemd user unit on Linux). Nothing here needs
//! the Flight Deck app (requirement 4): the unit runs `fdindex daemon`, and the same daemon is
//! still started on demand by any client when no unit is installed.
//!
//! The unit restarts the daemon only after a failure. A clean exit (`fdindex stop`, or a second
//! daemon finding the lock held) is final, so stopping is not undone by the supervisor.

use crate::client::{connect_or_start, Client};
use crate::error::{Error, Result};
use crate::runtime::{wait_until_stopped, Paths};
use crate::store::default_store_root;
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub const DEFAULT_LABEL: &str = "dev.flightdeck.index";
/// What a launchd agent gets for a PATH is `/usr/bin:/bin:/usr/sbin:/sbin`; the daemon runs `git`.
const SERVICE_PATH: &str = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Manager {
    Launchd,
    Systemd,
}

impl Manager {
    pub fn native() -> Manager {
        if cfg!(target_os = "macos") { Manager::Launchd } else { Manager::Systemd }
    }
}

pub struct Service {
    pub manager: Manager,
    pub label: String,
    pub exe: PathBuf,
    pub paths: Paths,
    pub home: PathBuf,
}

impl Service {
    pub fn new(paths: Paths, label: Option<String>) -> Result<Service> {
        let exe = std::env::current_exe().and_then(|p| p.canonicalize()).map_err(|e| Error::Msg(format!("cannot find my own executable: {e}")))?;
        let home = PathBuf::from(std::env::var_os("HOME").ok_or_else(|| Error::Msg("HOME is not set".into()))?);
        let label = label.or_else(|| std::env::var("FLIGHTDECK_INDEX_LABEL").ok()).unwrap_or_else(|| DEFAULT_LABEL.to_string());
        Ok(Service { manager: Manager::native(), label, exe, paths, home })
    }

    pub fn unit_path(&self) -> PathBuf {
        match self.manager {
            Manager::Launchd => self.home.join("Library/LaunchAgents").join(format!("{}.plist", self.label)),
            Manager::Systemd => {
                let config = std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| self.home.join(".config"));
                config.join("systemd/user").join(format!("{}.service", self.label))
            }
        }
    }

    /// `fdindex daemon`, with the store and socket spelled out only when they are not the defaults,
    /// so a unit installed for the default store keeps following the defaults.
    pub fn daemon_argv(&self) -> Vec<String> {
        let default = Paths::new(default_store_root(), None);
        let mut argv = vec![self.exe.to_string_lossy().to_string(), "daemon".to_string()];
        if self.paths.store != default.store {
            argv.extend(["--store".to_string(), self.paths.store.to_string_lossy().to_string()]);
        }
        if self.paths.store != default.store || self.paths.socket != default.socket {
            argv.extend(["--socket".to_string(), self.paths.socket.to_string_lossy().to_string()]);
        }
        argv
    }

    pub fn render(&self) -> String {
        match self.manager {
            Manager::Launchd => render_plist(&self.label, &self.daemon_argv(), &self.paths.store.join("launchd.log")),
            Manager::Systemd => render_unit(&self.label, &self.daemon_argv()),
        }
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

pub fn render_plist(label: &str, argv: &[String], log: &Path) -> String {
    let args: String = argv.iter().map(|a| format!("        <string>{}</string>\n", xml_escape(a))).collect();
    let log = xml_escape(&log.to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
{args}    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{SERVICE_PATH}</string>
    </dict>
    <key>StandardOutPath</key>
    <string>{log}</string>
    <key>StandardErrorPath</key>
    <string>{log}</string>
</dict>
</plist>
"#,
        label = xml_escape(label)
    )
}

/// One `ExecStart` word, quoted the way systemd reads it (`%` is its specifier escape).
fn systemd_word(s: &str) -> String {
    let s = s.replace('\\', "\\\\").replace('"', "\\\"").replace('%', "%%");
    if s.is_empty() || s.contains(char::is_whitespace) { format!("\"{s}\"") } else { s }
}

pub fn render_unit(label: &str, argv: &[String]) -> String {
    let exec = argv.iter().map(|a| systemd_word(a)).collect::<Vec<_>>().join(" ");
    format!(
        "[Unit]\nDescription=Flight Deck code index ({label})\n\n[Service]\nExecStart={exec}\nRestart=on-failure\nRestartSec=2\n\n[Install]\nWantedBy=default.target\n"
    )
}

/// Run a supervisor command; `Ok(stdout)` on success, the command's own message otherwise.
fn run_tool(program: &str, args: &[&str]) -> std::result::Result<String, String> {
    let out = Command::new(program).args(args).output().map_err(|e| format!("{program}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if msg.is_empty() { format!("{program} {} exited {}", args.join(" "), out.status) } else { msg })
    }
}

fn uid() -> u32 {
    // SAFETY: getuid has no preconditions.
    unsafe { libc::getuid() }
}

impl Service {
    fn domain_target(&self) -> String {
        format!("gui/{}/{}", uid(), self.label)
    }

    fn installed(&self) -> bool {
        self.unit_path().exists()
    }

    fn loaded(&self) -> bool {
        match self.manager {
            Manager::Launchd => run_tool("launchctl", &["print", &self.domain_target()]).is_ok(),
            Manager::Systemd => run_tool("systemctl", &["--user", "is-enabled", &format!("{}.service", self.label)]).is_ok(),
        }
    }

    fn unit_name(&self) -> String {
        format!("{}.service", self.label)
    }

    fn load(&self) -> std::result::Result<(), String> {
        match self.manager {
            Manager::Launchd => run_tool("launchctl", &["bootstrap", &format!("gui/{}", uid()), &self.unit_path().to_string_lossy()]).map(|_| ()),
            Manager::Systemd => {
                run_tool("systemctl", &["--user", "daemon-reload"])?;
                run_tool("systemctl", &["--user", "enable", "--now", &self.unit_name()]).map(|_| ())
            }
        }
    }

    fn unload(&self) -> std::result::Result<(), String> {
        match self.manager {
            Manager::Launchd => run_tool("launchctl", &["bootout", &self.domain_target()]).map(|_| ()),
            Manager::Systemd => run_tool("systemctl", &["--user", "disable", "--now", &self.unit_name()]).map(|_| ()),
        }
    }

    pub fn install(&self) -> Result<()> {
        let unit = self.unit_path();
        let text = self.render();
        let unchanged = std::fs::read_to_string(&unit).is_ok_and(|old| old == text);
        let loaded = self.loaded();
        if unchanged && loaded {
            println!("already installed: {} ({})", self.label, unit.display());
            return Ok(());
        }
        std::fs::create_dir_all(&self.paths.store).map_err(|e| Error::io(&self.paths.store, e))?;
        let dir = unit.parent().expect("a unit path has a parent");
        std::fs::create_dir_all(dir).map_err(|e| Error::io(dir, e))?;
        let tmp = unit.with_extension("tmp");
        std::fs::write(&tmp, &text).map_err(|e| Error::io(&tmp, e))?;
        std::fs::rename(&tmp, &unit).map_err(|e| Error::io(&unit, e))?;
        if loaded {
            self.unload().map_err(Error::Msg)?;
        }
        // A daemon a client started earlier is not the supervisor's child: stop it so the unit's
        // daemon takes the lock and is the one that gets restarted after a crash. Open sessions
        // reconnect on their next call.
        stop(&self.paths)?;
        self.load().map_err(Error::Msg)?;
        println!("installed: {} ({})\nruns: {}", self.label, unit.display(), self.daemon_argv().join(" "));
        Ok(())
    }

    pub fn uninstall(&self) -> Result<()> {
        let unit = self.unit_path();
        if !self.installed() && !self.loaded() {
            println!("not installed: {}", self.label);
            return Ok(());
        }
        if self.loaded() {
            self.unload().map_err(Error::Msg)?;
        }
        match std::fs::remove_file(&unit) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(Error::io(&unit, e)),
        }
        if self.manager == Manager::Systemd {
            let _ = run_tool("systemctl", &["--user", "daemon-reload"]);
        }
        // Unloading ends a daemon the unit started; one a client started is stopped here, so
        // uninstall leaves nothing running.
        stop(&self.paths)?;
        println!("uninstalled: {} (removed {})", self.label, unit.display());
        Ok(())
    }

    pub fn start(&self) -> Result<()> {
        if Client::connect(&self.paths.socket).is_ok() {
            println!("already running");
            report(self);
            return Ok(());
        }
        if self.installed() {
            let started = if !self.loaded() {
                self.load()
            } else if self.manager == Manager::Launchd {
                run_tool("launchctl", &["kickstart", &self.domain_target()]).map(|_| ())
            } else {
                run_tool("systemctl", &["--user", "start", &self.unit_name()]).map(|_| ())
            };
            started.map_err(Error::Msg)?;
            let until = std::time::Instant::now() + Duration::from_secs(10);
            while Client::connect(&self.paths.socket).is_err() {
                if std::time::Instant::now() >= until {
                    return Err(Error::Msg(format!("started {} but the daemon did not open {} within 10s (see {})", self.label, self.paths.socket.display(), self.paths.log.display())));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        } else {
            connect_or_start(&self.paths, &[])?;
            println!("no service installed ({}): started the daemon on its own; `fdindex service install` keeps it running at login", self.label);
        }
        report(self);
        Ok(())
    }
}

/// Ask the daemon to exit and wait until it has. The daemon exits cleanly, which the unit treats as
/// final, so it stays down.
pub fn stop(paths: &Paths) -> Result<()> {
    match Client::connect(&paths.socket) {
        Ok(mut c) => {
            let _ = c.call("", 0, "shutdown", Map::new());
            if !wait_until_stopped(&paths.pidfile, Duration::from_secs(10)) {
                return Err(Error::Msg("asked the daemon to stop but it is still running after 10s".into()));
            }
            println!("stopped");
        }
        Err(_) => println!("not running"),
    }
    Ok(())
}

fn human_bytes(b: u64) -> String {
    format!("{:.1} MB", b as f64 / 1_048_576.0)
}

fn human_duration(secs: u64) -> String {
    match secs {
        0..=59 => format!("{secs}s"),
        60..=3599 => format!("{}m{:02}s", secs / 60, secs % 60),
        _ => format!("{}h{:02}m", secs / 3600, secs % 3600 / 60),
    }
}

/// Print the report of `fdindex status` and `service status` and return its exit code: 0 for a
/// running daemon, 3 for a stopped one. Never starts the daemon.
pub fn report(svc: &Service) -> i32 {
    let (data, code) = daemon_data(&svc.paths);
    print!("{}", format_status(svc, data.as_ref()));
    code
}

/// `status` data from a running daemon, or `None` with exit code 3 (the "unavailable" code).
pub fn daemon_data(paths: &Paths) -> (Option<Value>, i32) {
    let reply = Client::connect(paths.socket.as_path()).ok().and_then(|mut c| c.call("", 0, "status", Map::new()).ok());
    match reply.and_then(|r| r.data) {
        Some(d) => (Some(d), 0),
        None => (None, 3),
    }
}

pub fn format_status(svc: &Service, data: Option<&Value>) -> String {
    let unit = svc.unit_path();
    let manager = match svc.manager {
        Manager::Launchd => "launchd",
        Manager::Systemd => "systemd",
    };
    let mut out = String::new();
    if svc.installed() {
        let loaded = if svc.loaded() { "loaded" } else { "not loaded" };
        out += &format!("service:  {manager} {} (installed, {loaded})\nunit:     {}\n", svc.label, unit.display());
    } else {
        out += &format!("service:  not installed ({manager} {}); clients start the daemon on demand\n", svc.label);
    }
    out += &format!("binary:   {}\nsocket:   {}\nstore:    {}\n", svc.exe.display(), svc.paths.socket.display(), svc.paths.store.display());
    let Some(d) = data else {
        out += "daemon:   not running\n";
        return out;
    };
    let n = |v: &Value| v.as_u64().unwrap_or(0);
    out += &format!(
        "daemon:   running, pid {}, fdindex {} (protocol {}), up {}\nmemory:   {} resident{}; graphs {} cached, {} of {} budget, {} evicted\n",
        n(&d["pid"]),
        d["version"].as_str().unwrap_or("?"),
        n(&d["protocol"]),
        human_duration(n(&d["uptime_seconds"])),
        human_bytes(n(&d["rss_bytes"])),
        match n(&d["memory_target"]) {
            0 => String::new(),
            t => format!(" (target {}, heap {})", human_bytes(t), human_bytes(n(&d["heap_bytes"]))),
        },
        n(&d["graphs"]["count"]),
        human_bytes(n(&d["graphs"]["bytes"])),
        human_bytes(n(&d["graphs"]["budget"])),
        n(&d["graphs"]["evictions"]),
    );
    let stores = d["stores"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    out += &format!("size:     {} in {} repository store(s)\n", human_bytes(stores.iter().map(|s| n(&s["bytes"])).sum()), stores.len());
    out += &format!("traffic:  {} request(s), {} error(s), {} blob(s) parsed\n", n(&d["requests"]), n(&d["errors"]), n(&d["parses"]));
    if let Some(e) = d["last_error"].as_object() {
        let field = |k: &str| e.get(k).and_then(Value::as_str).unwrap_or("?");
        out += &format!("last err: {}: {} ({}, {} ago)\n", field("tool"), field("message"), field("state"), human_duration(e.get("seconds_ago").and_then(Value::as_u64).unwrap_or(0)));
    }
    let views = d["views"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    out += &format!("views:    {}\n", views.len());
    for v in views.iter().take(20) {
        let watching = match v["kept"].as_bool() {
            Some(true) => match v["last_sweep_ms"].as_f64() {
                Some(ms) => format!("swept by stat ({} files, {} dirs, last {:.1} ms)", n(&v["snapshot_files"]), n(&v["snapshot_dirs"]), ms),
                None => "swept by stat".to_string(),
            },
            Some(false) => "git status each time".to_string(),
            None => String::new(),
        };
        out += &format!(
            "  {} (repo {}, base {}, dirty {}), {} request(s), idle {}{}\n",
            v["worktree"].as_str().unwrap_or("?"),
            v["repo"].as_str().unwrap_or("?"),
            v["base"].as_str().map(|b| &b[..b.len().min(7)]).unwrap_or("?"),
            n(&v["dirty_files"]),
            n(&v["requests"]),
            human_duration(n(&v["idle_seconds"])),
            if watching.is_empty() { String::new() } else { format!(", {watching}") },
        );
    }
    if views.len() > 20 {
        out += &format!("  … {} more\n", views.len() - 20);
    }
    match (d["watch"]["keeps_views"].as_bool(), d["watch"]["enabled"].as_bool()) {
        (Some(true), Some(true)) => {
            let w = &d["watch"];
            out += &format!(
                "fresh:    views kept and swept by stat (dropped after {:.0} h idle); refs of {} repository(ies) watched, {} event(s)\n",
                w["active_hours"].as_f64().unwrap_or(0.0),
                w["ref_repos"].as_array().map_or(0, Vec::len),
                n(&w["events"]),
            );
        }
        (Some(true), _) => out += "fresh:    views kept and swept by stat; no ref watcher on this platform\n",
        (Some(false), _) => out += "fresh:    off; every request reads git status\n",
        _ => {}
    }
    if d["gc"].is_object() {
        let g = &d["gc"];
        out += &format!("gc:       {} run(s), {} reclaimed in total, {} free page(s)\n", n(&g["runs"]), human_bytes(n(&g["reclaimed_bytes_total"])), n(&g["free_pages"]));
        if let Some(l) = g["last"].as_object() {
            out += &format!(
                "  last: {} repo(s), {} dropped; {} fact(s), {} tree(s) collected; {} reclaimed in {:.1}s\n",
                l["repos"].as_u64().unwrap_or(0),
                l["repos_dropped"].as_u64().unwrap_or(0),
                l["facts_dropped"].as_u64().unwrap_or(0),
                l["trees_dropped"].as_u64().unwrap_or(0),
                human_bytes(l["bytes_reclaimed"].as_u64().unwrap_or(0)),
                l["took_seconds"].as_f64().unwrap_or(0.0),
            );
        }
    }
    let builds = d["builds"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    if builds.is_empty() {
        out += "builds:   none running\n";
    } else {
        out += &format!("builds:   {} running\n", builds.len());
        for b in builds {
            out += &format!("  {} {} {} of {}\n", b["worktree"].as_str().unwrap_or("?"), b["phase"].as_str().unwrap_or("?"), n(&b["done"]), n(&b["total"]));
        }
    }
    out
}

/// `fdindex service <sub>` and the top-level verbs that mean the same. Returns the exit code.
pub fn run(sub: &str, paths: Paths, label: Option<String>) -> Result<i32> {
    let svc = Service::new(paths, label)?;
    if sub == "status" {
        return Ok(report(&svc));
    }
    match sub {
        "install" => svc.install()?,
        "uninstall" => svc.uninstall()?,
        "start" => svc.start()?,
        "stop" => stop(&svc.paths)?,
        "restart" => {
            stop(&svc.paths)?;
            svc.start()?;
        }
        other => return Err(Error::Msg(format!("unknown service command '{other}' (install, uninstall, start, stop, status, restart)"))),
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn svc(manager: Manager) -> Service {
        Service {
            manager,
            label: "dev.test.index".into(),
            exe: "/opt/Flight Deck & Co/fdindex".into(),
            paths: Paths::new(default_store_root(), None),
            home: "/home/n".into(),
        }
    }

    #[test]
    fn the_plist_runs_the_real_binary_and_restarts_only_after_failure() {
        let s = svc(Manager::Launchd);
        let p = s.render();
        assert!(p.contains("<string>/opt/Flight Deck &amp; Co/fdindex</string>\n        <string>daemon</string>"), "{p}");
        assert!(p.contains("<key>RunAtLoad</key>\n    <true/>"));
        assert!(p.contains("<key>SuccessfulExit</key>\n        <false/>"));
        assert!(p.contains("launchd.log"));
        assert_eq!(s.unit_path(), PathBuf::from("/home/n/Library/LaunchAgents/dev.test.index.plist"));
    }

    #[test]
    fn a_non_default_store_is_spelled_out_in_the_command() {
        let mut s = svc(Manager::Launchd);
        assert_eq!(s.daemon_argv().len(), 2, "defaults are left to the daemon");
        s.paths = Paths::new("/scratch/store", Some("/tmp/fdi.sock".into()));
        assert_eq!(s.daemon_argv()[2..], ["--store", "/scratch/store", "--socket", "/tmp/fdi.sock"]);
    }

    #[test]
    fn the_systemd_unit_quotes_what_systemd_would_split() {
        let u = render_unit("dev.test.index", &["/opt/Flight Deck/fdindex".into(), "daemon".into(), "--store".into(), "/a%b".into()]);
        assert!(u.contains("ExecStart=\"/opt/Flight Deck/fdindex\" daemon --store /a%%b\n"), "{u}");
        assert!(u.contains("Restart=on-failure") && u.contains("WantedBy=default.target"));
    }

    #[test]
    fn status_reads_a_stopped_and_a_running_daemon() {
        let s = svc(Manager::Launchd);
        assert!(format_status(&s, None).contains("daemon:   not running"));
        let d = serde_json::json!({
            "version": "0.1.0", "protocol": 1, "pid": 42, "uptime_seconds": 125, "rss_bytes": 104857600u64, "memory_target": 1073741824u64, "heap_bytes": 52428800u64, "requests": 7, "errors": 1, "parses": 90,
            "last_error": {"state": "ERROR", "tool": "read", "message": "git cat-file failed", "seconds_ago": 30},
            "views": [{"worktree": "/w/app", "repo": "app", "base": "1a2b3c4d5e", "dirty_files": 3, "requests": 5, "idle_seconds": 9, "kept": true, "snapshot_files": 1500, "snapshot_dirs": 300, "last_sweep_ms": 1.4}],
            "builds": [{"worktree": "/w/app", "phase": "Parsing", "done": 4, "total": 10}],
            "graphs": {"count": 1, "bytes": 2097152, "budget": 536870912u64, "evictions": 0},
            "stores": [{"name": "app.db", "bytes": 1048576}],
            "watch": {"enabled": true, "keeps_views": true, "active_hours": 6.0, "events": 12, "ref_repos": [{"repo": "/w/app/.git"}, {"repo": "/w/b/.git"}]},
            "gc": {"runs": 2, "reclaimed_bytes_total": 2097152, "free_pages": 0, "last": {"repos": 2, "repos_dropped": 1, "facts_dropped": 40, "trees_dropped": 3, "bytes_reclaimed": 1048576, "took_seconds": 0.5}},
        });
        let t = format_status(&s, Some(&d));
        for want in ["pid 42", "fdindex 0.1.0", "up 2m05s", "100.0 MB resident (target 1024.0 MB, heap 50.0 MB)", "1.0 MB in 1 repository", "/w/app (repo app, base 1a2b3c4, dirty 3)", "Parsing 4 of 10", "views kept and swept by stat (dropped after 6 h idle); refs of 2 repository(ies) watched, 12 event(s)", "swept by stat (1500 files, 300 dirs, last 1.4 ms)", "2 run(s), 2.0 MB reclaimed in total", "1 dropped; 40 fact(s), 3 tree(s) collected; 1.0 MB reclaimed", "last err: read: git cat-file failed (ERROR, 30s ago)"] {
            assert!(t.contains(want), "{want} missing in\n{t}");
        }
    }
}
