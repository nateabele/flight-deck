//! The local transport: a peer daemon's own Unix socket, upgraded to the frame stream by its
//! first request line. A HostKit bridge carries these exact bytes, upgrade line and all, between a
//! `ChannelMux` channel and the host daemon's socket, so the daemon has one way in for both.

use super::{exchange, FactKey, FactSource, FetchStats};
use crate::error::{Error, Result};
use crate::proto::{Request, Response, PROTOCOL_VERSION};
use crate::store::ParsedBlob;
use serde_json::{json, Map, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

/// The request tool that turns a daemon connection into a fact stream.
pub const UPGRADE_TOOL: &str = "peer_facts";

/// How long the asker waits on one read or write before it gives up on the peer and parses.
/// Generous: a holder answering thousands of keys writes its first frame only after reading them.
pub const IO_TIMEOUT: Duration = Duration::from_secs(30);

/// The upgrade request, as one line.
pub fn upgrade_line() -> Vec<u8> {
    let mut args = Map::new();
    args.insert("format".into(), json!(super::wire::PEER_FORMAT));
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: String::new(), seq: 0, tool: UPGRADE_TOOL.into(), args };
    let mut line = serde_json::to_vec(&req).unwrap_or_default();
    line.push(b'\n');
    line
}

/// The daemon's reply to an upgrade request: accepted, or why not. `format` is what the asker
/// speaks; a holder refuses any other.
pub fn upgrade_reply(id: Value, format: Option<u64>) -> Response {
    let ours = u64::from(super::wire::PEER_FORMAT);
    if format != Some(ours) {
        return Response::error(id, crate::proto::state::VERSION_MISMATCH, format!("this daemon exchanges facts in format {ours}, not {format:?}"));
    }
    Response { id, ok: true, text: Some("peer facts stream".into()), data: Some(json!({"format": ours, "chunk_format": crate::chunk::FORMAT})), ..Default::default() }
}

/// A peer daemon reached through its Unix socket. Never starts one: a peer that is not running
/// is a peer that has nothing to give.
pub struct SocketPeer {
    pub socket: PathBuf,
}

impl SocketPeer {
    pub fn new(socket: impl Into<PathBuf>) -> SocketPeer {
        SocketPeer { socket: socket.into() }
    }
}

impl FactSource for SocketPeer {
    fn fetch(&self, keys: &[FactKey], sink: &mut dyn FnMut(Vec<ParsedBlob>) -> Result<()>) -> Result<FetchStats> {
        let io = |e: std::io::Error| Error::Msg(format!("peer {}: {e}", self.socket.display()));
        let mut w = UnixStream::connect(&self.socket).map_err(io)?;
        w.set_read_timeout(Some(IO_TIMEOUT)).map_err(io)?;
        w.set_write_timeout(Some(IO_TIMEOUT)).map_err(io)?;
        let mut r = BufReader::with_capacity(1 << 16, w.try_clone().map_err(io)?);
        w.write_all(&upgrade_line()).map_err(io)?;
        let mut reply = String::new();
        r.read_line(&mut reply).map_err(io)?;
        let resp: Response = serde_json::from_str(reply.trim()).map_err(|e| Error::Msg(format!("peer {}: unreadable upgrade reply: {e}", self.socket.display())))?;
        if !resp.ok {
            return Err(Error::Msg(format!("peer {} refused: {}", self.socket.display(), resp.error.unwrap_or_default())));
        }
        let mut stats = exchange(&mut r, &mut w, keys, sink)?;
        stats.bytes_out += upgrade_line().len() as u64;
        stats.bytes_in += reply.len() as u64;
        Ok(stats)
    }

    fn describe(&self) -> String {
        format!("socket {}", self.socket.display())
    }
}
