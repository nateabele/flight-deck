//! `fdindex mcp`: the stdio MCP shim (spec §4.2). A thin client of the daemon: it holds no index and
//! opens no database. Every `tools/call` becomes one daemon request carrying the shim's launch
//! directory as `cwd` and a counter as `seq`. When the daemon cannot be reached or started the call
//! returns `state: UNAVAILABLE` with the reason (spec §6), never an answer from a private index.
//!
//! MCP over stdio is newline-delimited JSON-RPC 2.0. Requests are answered one at a time, in order.
//! The tool list (`mcp_tools.json`) keeps the qartez v0.11.0 tool and parameter names and schema
//! shapes, so agent habits keep working. The descriptions are fdindex's own: what each tool does and
//! which sibling to use instead, tersely (tests/mcp_descriptions.rs holds them to that).

use crate::client::{connect_only, connect_or_start, Client};
use crate::error::Result;
use crate::proto::state;
use crate::runtime::Paths;
use serde_json::{json, Map, Value};
use std::io::{BufRead, Write};
use std::time::{Duration, Instant};

const TOOLS_JSON: &str = include_str!("mcp_tools.json");
/// Newest first; an unknown request gets the newest.
const PROTOCOLS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];
/// After a failed start, further calls answer UNAVAILABLE at once for this long instead of each
/// waiting out another start attempt.
const START_RETRY: Duration = Duration::from_secs(5);
const MUTATORS: &[&str] = &[
    "qartez_replace_symbol",
    "qartez_insert_before_symbol",
    "qartez_insert_after_symbol",
    "qartez_rename",
    "qartez_move",
    "qartez_safe_delete",
    "qartez_rename_file",
];

/// Server instructions: what this is, which tool answers which question, and how to read a result.
/// The routing lines mirror the "use X instead" sentences in `mcp_tools.json`.
const INSTRUCTIONS: &str = "Flight Deck's code index: one machine-wide daemon answers every session's queries; nothing to configure.\n\
Which tool:\n\
- Where is X defined? qartez_find (exact or qualified name). Part of a name: qartez_grep (prefix). Text in function bodies: qartez_grep search_bodies=true.\n\
- Show code: qartez_read (symbols, or a file's line range). A file's symbols: qartez_outline.\n\
- Who uses symbol X? qartez_refs (every reference). Callers or callees, or a call chain: qartez_calls.\n\
- What could break if file F changes? qartez_impact. F's direct imports and importers only: qartez_deps.\n\
- New to the repo: qartez_map (files by importance); qartez_stats for counts.\n\
- Edits (rename, move, replace_symbol, insert_*, safe_delete, rename_file) preview unless apply=true.\n\
Paths: absolute, or relative to the directory this server started in; results print absolute paths.\n\
Each result starts with a `view:` line: the worktree, repository, base commit and dirty state that answered. `index: building` there means ask again shortly.\n\
`state: UNAVAILABLE` means the daemon is down: use rg and read files, and run `flightdeck index status`.";

pub struct Options {
    pub paths: Paths,
    /// The caller's working directory, sent with every call.
    pub cwd: String,
    /// Start the daemon when it is not running. Off, a call answers UNAVAILABLE instead.
    pub auto_start: bool,
    pub daemon_args: Vec<String>,
}

pub struct Shim {
    opts: Options,
    tools: Vec<Value>,
    conn: Option<Client>,
    seq: u64,
    /// When the last start attempt failed, and why.
    down: Option<(Instant, String)>,
}

impl Shim {
    pub fn new(opts: Options) -> Shim {
        let tools = serde_json::from_str(TOOLS_JSON).expect("mcp_tools.json is valid JSON");
        Shim { opts, tools, conn: None, seq: 0, down: None }
    }

    /// The reply to one JSON-RPC message, or `None` for a notification.
    pub fn handle(&mut self, msg: Value) -> Option<Value> {
        let id = msg.get("id").cloned()?;
        let method = msg["method"].as_str().unwrap_or("");
        let params = &msg["params"];
        let outcome = match method {
            "initialize" => Ok(self.initialize(params)),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({"tools": self.tools})),
            "tools/call" => self.tools_call(params),
            "resources/list" => Ok(json!({"resources": []})),
            "resources/templates/list" => Ok(json!({"resourceTemplates": []})),
            "prompts/list" => Ok(json!({"prompts": []})),
            other => Err((-32601, format!("method not found: {other}"))),
        };
        Some(match outcome {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err((code, message)) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}),
        })
    }

    fn initialize(&self, params: &Value) -> Value {
        let asked = params["protocolVersion"].as_str().unwrap_or("");
        let version = PROTOCOLS.iter().find(|p| **p == asked).unwrap_or(&PROTOCOLS[0]);
        json!({
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": false}},
            "serverInfo": {"name": "flightdeck-index", "version": env!("CARGO_PKG_VERSION")},
            "instructions": INSTRUCTIONS,
        })
    }

    fn tools_call(&mut self, params: &Value) -> std::result::Result<Value, (i32, String)> {
        let name = params["name"].as_str().unwrap_or("");
        if !self.tools.iter().any(|t| t["name"] == name) {
            return Err((-32602, format!("unknown tool: {name}")));
        }
        // Qartez schemas allow null for an unset optional; the daemon reads absent as unset.
        let args: Map<String, Value> = params["arguments"].as_object().map(|a| a.iter().filter(|(_, v)| !v.is_null()).map(|(k, v)| (k.clone(), v.clone())).collect()).unwrap_or_default();
        let (text, is_error) = match self.send(name, args) {
            Ok(r) if r.ok => (r.text.unwrap_or_default(), false),
            Ok(r) => (format!("state: {}\n{}", r.state.unwrap_or_else(|| state::ERROR.into()), r.error.unwrap_or_default()), true),
            Err(reason) => (format!("state: {}\n{reason}", state::UNAVAILABLE), true),
        };
        Ok(json!({"content": [{"type": "text", "text": text}], "isError": is_error}))
    }

    /// One daemon request. A dead connection (the daemon restarted since the last call) is replaced
    /// and the request sent again, except for an applied edit that may already have reached the
    /// daemon: that one is never replayed.
    fn send(&mut self, tool: &str, args: Map<String, Value>) -> std::result::Result<crate::proto::Response, String> {
        self.seq += 1;
        let applies = MUTATORS.contains(&tool) && args.get("apply").is_some_and(|a| a == &Value::Bool(true));
        let mut last = String::new();
        for _ in 0..2 {
            self.ensure_connected()?;
            let conn = self.conn.as_mut().expect("connected above");
            // A write to a dead socket can succeed into the kernel buffer and only the read fails,
            // which is too late to know whether the edit ran. Ask first, so a stale connection is
            // found before the edit is sent.
            if applies && conn.call("", 0, "hello", Map::new()).is_err() {
                self.conn = None;
                continue;
            }
            match conn.call(&self.opts.cwd, self.seq, tool, args.clone()) {
                Ok(r) => return Ok(r),
                Err(e) => {
                    self.conn = None;
                    last = e.to_string();
                    if applies {
                        return Err(format!("the daemon connection was lost during an applied edit ({last}); it may or may not have been written, so run the preview again to see the file's state"));
                    }
                }
            }
        }
        Err(format!("the index daemon stopped answering: {last}"))
    }

    fn ensure_connected(&mut self) -> std::result::Result<(), String> {
        if self.conn.is_some() {
            return Ok(());
        }
        if let Some((_, reason)) = self.down.as_ref().filter(|(at, _)| self.opts.auto_start && at.elapsed() < START_RETRY) {
            return Err(reason.clone());
        }
        let attempt = if self.opts.auto_start {
            connect_or_start(&self.opts.paths, &self.opts.daemon_args)
        } else {
            connect_only(&self.opts.paths).map_err(|e| crate::error::Error::Msg(format!("{e}; auto-start is disabled")))
        };
        match attempt {
            Ok(c) => {
                self.conn = Some(c);
                self.down = None;
                Ok(())
            }
            Err(e) => {
                let reason = one_line(&e.to_string());
                if self.opts.auto_start {
                    self.down = Some((Instant::now(), reason.clone()));
                }
                Err(reason)
            }
        }
    }
}

fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Serve MCP on `input`/`output` until `input` closes.
pub fn serve(shim: &mut Shim, input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(msg) => shim.handle(msg),
            Err(e) => Some(json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": format!("parse error: {e}")}})),
        };
        if let Some(reply) = reply {
            writeln!(output, "{reply}")?;
            output.flush()?;
        }
    }
    Ok(())
}

/// `fdindex mcp`: serve on stdin and stdout.
pub fn run(opts: Options) -> Result<()> {
    let mut shim = Shim::new(opts);
    serve(&mut shim, std::io::stdin().lock(), std::io::stdout().lock()).map_err(|e| crate::error::Error::Msg(format!("stdio: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shim(auto_start: bool) -> Shim {
        let paths = Paths::new("/nonexistent/fdi-store", Some("/nonexistent/fdi.sock".into()));
        Shim::new(Options { paths, cwd: "/tmp".into(), auto_start, daemon_args: vec![] })
    }

    fn rpc(s: &mut Shim, msg: Value) -> Value {
        s.handle(msg).expect("a reply")
    }

    #[test]
    fn initialize_negotiates_and_describes_the_server() {
        let mut s = shim(false);
        let r = rpc(&mut s, json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}));
        assert_eq!(r["result"]["protocolVersion"], "2024-11-05");
        assert!(r["result"]["capabilities"]["tools"].is_object());
        assert!(r["result"]["instructions"].as_str().unwrap().contains("Flight Deck"));
        let r = rpc(&mut s, json!({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "1999"}}));
        assert_eq!(r["result"]["protocolVersion"], PROTOCOLS[0]);
    }

    #[test]
    fn notifications_get_no_reply_and_ping_works() {
        let mut s = shim(false);
        assert!(s.handle(json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).is_none());
        assert_eq!(rpc(&mut s, json!({"jsonrpc": "2.0", "id": 3, "method": "ping"}))["result"], json!({}));
        assert_eq!(rpc(&mut s, json!({"jsonrpc": "2.0", "id": 4, "method": "nope"}))["error"]["code"], -32601);
    }

    #[test]
    fn the_tool_list_has_the_first_cut_names_with_required_params() {
        let mut s = shim(false);
        let r = rpc(&mut s, json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}));
        let tools = r["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        for n in [
            "map", "find", "grep", "read", "outline", "deps", "stats", "impact", "refs", "calls", "replace_symbol", "insert_before_symbol", "insert_after_symbol", "rename", "move",
            "safe_delete", "rename_file", "add_root", "workspace",
        ] {
            assert!(names.contains(&format!("qartez_{n}").as_str()), "missing {n}");
        }
        assert_eq!(names.len(), 19);
        let find = tools.iter().find(|t| t["name"] == "qartez_find").unwrap();
        assert_eq!(find["inputSchema"]["required"], json!(["name"]));
    }

    #[test]
    fn an_unreachable_daemon_is_a_tool_result_not_a_crash() {
        let mut s = shim(false);
        let r = rpc(&mut s, json!({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "qartez_find", "arguments": {"name": "x"}}}));
        assert_eq!(r["result"]["isError"], true);
        let text = r["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.starts_with("state: UNAVAILABLE\n"), "{text}");
        assert_eq!(text.lines().count(), 2, "one line of reason: {text}");
    }

    #[test]
    fn an_unknown_tool_is_a_protocol_error() {
        let mut s = shim(false);
        let r = rpc(&mut s, json!({"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "qartez_wiki"}}));
        assert_eq!(r["error"]["code"], -32602);
    }

    #[test]
    fn serve_answers_each_line_and_survives_garbage() {
        let mut s = shim(false);
        let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\nnot json\n\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n";
        let mut out = Vec::new();
        serve(&mut s, input.as_bytes(), &mut out).unwrap();
        let lines: Vec<Value> = String::from_utf8(out).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[1]["error"]["code"], -32700);
        assert_eq!(lines[2]["id"], 2);
    }
}
