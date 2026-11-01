//! The wire protocol between clients (CLI, MCP shim) and the daemon: one JSON object per line over
//! a Unix socket, answered in order on the same connection. A client wanting two requests in
//! flight opens two connections.
//!
//! ```text
//! -> {"v":1,"id":7,"cwd":"/work/app","seq":12,"tool":"find","args":{"name":"update"}}
//! <- {"id":7,"ok":true,"text":"view: /work/app (repo app, base 1a2b3c4, clean)\nFound 2 match(es)…"}
//! <- {"id":7,"ok":false,"error":"file is not indexed yet","state":"BUILDING"}
//! ```
//!
//! `v` is the protocol version the client speaks. A daemon that does not speak it answers
//! `VERSION_MISMATCH` instead of guessing, so an old shim never gets a differently-shaped result
//! from a new daemon (or the reverse). `hello` returns the daemon's own version for clients that
//! want to check before sending anything.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// Bump on any change to the request or response shape that an older peer would misread.
pub const PROTOCOL_VERSION: u32 = 1;

/// A request line larger than this is refused: the daemon reads a line into memory before it
/// parses it, so an unbounded line is an unbounded allocation.
pub const MAX_LINE_BYTES: u64 = 4 << 20;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    /// The protocol version the client speaks; absent means "whatever you speak".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub v: Option<u32>,
    /// Echoed in the response so a client can match answers to requests.
    #[serde(default)]
    pub id: Value,
    /// The caller's working directory: relative paths resolve against it and a pathless symbol
    /// query searches the view found from it.
    #[serde(default)]
    pub cwd: String,
    /// The caller's request counter. Recorded per cwd; the watcher step uses it to prove a
    /// caller's earlier edits are indexed before it is answered.
    #[serde(default)]
    pub seq: u64,
    pub tool: String,
    #[serde(default)]
    pub args: Map<String, Value>,
}

/// Why a request failed, as a stable word a client can branch on.
pub mod state {
    /// The daemon cannot be reached or started. Produced by clients, never by the daemon.
    pub const UNAVAILABLE: &str = "UNAVAILABLE";
    /// The answer needs part of the index that is still being built.
    pub const BUILDING: &str = "BUILDING";
    pub const BAD_REQUEST: &str = "BAD_REQUEST";
    pub const VERSION_MISMATCH: &str = "VERSION_MISMATCH";
    /// The request was understood and failed (a path that does not exist, a git error, …).
    pub const ERROR: &str = "ERROR";
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Response {
    #[serde(default)]
    pub id: Value,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    /// Machine-readable payload of `hello` and `status`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl Response {
    pub fn text(id: Value, text: String) -> Response {
        Response { id, ok: true, text: Some(text), ..Default::default() }
    }

    pub fn error(id: Value, state: &str, error: impl Into<String>) -> Response {
        Response { id, ok: false, error: Some(error.into()), state: Some(state.to_string()), ..Default::default() }
    }
}
