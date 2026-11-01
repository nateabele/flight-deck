//! `fdindex session-start`: the SessionStart hook that replaces `qartez-setup --session-start`.
//!
//! The old hook printed nothing and did two things in the background: indexed the session's
//! project and checked GitHub for a newer qartez. The useful half is kept: make sure the daemon is
//! running and start the session directory's build, without waiting for it, so the first query
//! finds the index warm. The update check is dropped (this binary ships with Flight Deck).
//!
//! What it prints becomes context for the session, so it prints only when there is something an
//! agent should act on: the daemon cannot be reached (index tools will say `state: UNAVAILABLE`,
//! fall back to rg), or the view is still being built. A ready index, or a directory that is no
//! project, is silent. It never fails and never takes longer than `BUDGET`: the exit status is 0
//! whatever happened.

use crate::client::{connect_only, connect_or_start};
use crate::runtime::Paths;
use serde_json::{json, Map, Value};
use std::time::Duration;

/// A slow daemon start must not hold up a session.
const BUDGET: Duration = Duration::from_secs(4);

/// The text the hook prints (possibly empty). `input` is the hook's stdin, `project_dir` is
/// `$CLAUDE_PROJECT_DIR`, `process_cwd` the hook process's own directory.
pub fn run(paths: &Paths, daemon_args: &[String], auto_start: bool, input: &str, project_dir: Option<String>, process_cwd: String) -> String {
    let cwd = serde_json::from_str::<Value>(input)
        .ok()
        .and_then(|v| v["cwd"].as_str().map(str::to_string))
        .into_iter()
        .chain(project_dir)
        .chain(Some(process_cwd))
        .find(|c| std::path::Path::new(c).is_absolute());
    let Some(cwd) = cwd else { return String::new() };
    let (paths, daemon_args) = (paths.clone(), daemon_args.to_vec());
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(start_and_warm(&paths, &daemon_args, auto_start, &cwd));
    });
    rx.recv_timeout(BUDGET).unwrap_or_else(|_| "fdindex: the index daemon did not answer within 4 s. Index tools may say `state: UNAVAILABLE`; fall back to rg and reading files until `fdindex status` is healthy.\n".into())
}

fn start_and_warm(paths: &Paths, daemon_args: &[String], auto_start: bool, cwd: &str) -> String {
    let connected = if auto_start { connect_or_start(paths, daemon_args) } else { connect_only(paths) };
    let mut client = match connected {
        Ok(c) => c,
        Err(e) => return format!("fdindex: the index daemon is not running and could not be started ({e}). Index tools will say `state: UNAVAILABLE`; fall back to rg and reading files.\n"),
    };
    // `guard` with no file starts the view's build and answers at once.
    let mut args = Map::new();
    args.insert("build_wait_ms".into(), json!(0));
    let Ok(resp) = client.call(cwd, 0, "guard", args) else { return String::new() };
    let data = resp.data.unwrap_or_default();
    match data["state"].as_str() {
        Some("BUILDING") => format!(
            "fdindex: indexing {} ({} of {} files). Index tool results say `index: building` until it is done; ask again shortly.\n",
            data["worktree"].as_str().unwrap_or(cwd),
            data["done"].as_u64().unwrap_or(0),
            data["total"].as_u64().unwrap_or(0)
        ),
        _ => String::new(),
    }
}
