//! Talking to the daemon, and starting it when it is not running (spec §4.1: "if the daemon is not
//! running, a client starts it"). The CLI and, later, the MCP shim are both built on this.

use crate::error::{Error, Result};
use crate::proto::{Request, Response, PROTOCOL_VERSION};
use crate::runtime::Paths;
use serde_json::{json, Map, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// How long a client waits for a daemon it just started to open its socket.
const START_WAIT: Duration = Duration::from_secs(10);

pub struct Client {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
}

impl Client {
    pub fn connect(socket: &Path) -> std::io::Result<Client> {
        let writer = UnixStream::connect(socket)?;
        let reader = BufReader::new(writer.try_clone()?);
        Ok(Client { writer, reader, next_id: 1 })
    }

    /// Bound every later read and write on this connection, for callers that must not hang (hooks).
    pub fn set_timeout(&self, t: Duration) -> std::io::Result<()> {
        self.writer.set_read_timeout(Some(t))?;
        self.writer.set_write_timeout(Some(t))
    }

    pub fn call(&mut self, cwd: &str, seq: u64, tool: &str, args: Map<String, Value>) -> Result<Response> {
        let req = Request { v: Some(PROTOCOL_VERSION), id: json!(self.next_id), cwd: cwd.to_string(), seq, tool: tool.to_string(), args };
        self.next_id += 1;
        let mut line = serde_json::to_vec(&req).map_err(|e| Error::Msg(e.to_string()))?;
        line.push(b'\n');
        self.writer.write_all(&line).map_err(|e| Error::Msg(format!("daemon connection lost: {e}")))?;
        let mut reply = String::new();
        let n = self.reader.read_line(&mut reply).map_err(|e| Error::Msg(format!("daemon connection lost: {e}")))?;
        if n == 0 {
            return Err(Error::Msg("daemon closed the connection".into()));
        }
        serde_json::from_str(reply.trim()).map_err(|e| Error::Msg(format!("daemon sent an unreadable reply: {e}")))
    }

    /// Check the daemon speaks our protocol before sending it real work.
    pub fn handshake(&mut self) -> Result<()> {
        let r = self.call("", 0, "hello", Map::new())?;
        let theirs = r.data.as_ref().and_then(|d| d["protocol"].as_u64()).unwrap_or(0) as u32;
        if theirs != PROTOCOL_VERSION {
            return Err(Error::Msg(format!(
                "the running daemon speaks protocol {theirs}, this client speaks {PROTOCOL_VERSION}; stop it with `fdindex stop` and retry"
            )));
        }
        Ok(())
    }
}

/// Connect to a daemon that is already running; never starts one (`--no-start`, hooks, `status`).
pub fn connect_only(paths: &Paths) -> Result<Client> {
    let mut c = Client::connect(&paths.socket).map_err(|e| Error::Msg(unreachable_message(&paths.socket, &e)))?;
    c.handshake()?;
    Ok(c)
}

/// Why a connect failed, in words an agent can act on. `PermissionDenied` (EPERM or EACCES) on a
/// socket that exists is a sandbox, not a missing daemon.
pub fn unreachable_message(socket: &Path, e: &std::io::Error) -> String {
    if e.kind() == std::io::ErrorKind::PermissionDenied {
        format!(
            "cannot connect to {}: {e} - a sandbox is blocking Unix sockets (for Codex: -s workspace-write -c sandbox_workspace_write.network_access=true, or run outside the sandbox); fall back to rg",
            socket.display()
        )
    } else {
        format!("the index daemon is not running ({e})")
    }
}

/// Connect to the daemon for `paths`, starting it detached if nothing is listening. Starting is
/// idempotent (a second daemon exits on the lock), so concurrent clients may all try.
pub fn connect_or_start(paths: &Paths, extra_daemon_args: &[String]) -> Result<Client> {
    let first = match Client::connect(&paths.socket) {
        Ok(mut c) => {
            c.handshake()?;
            return Ok(c);
        }
        Err(e) => e,
    };
    // A sandbox that forbids the socket forbids it for a daemon spawned here too, which would exit
    // and be reported as "exited on startup": say what is actually wrong instead.
    if first.kind() == std::io::ErrorKind::PermissionDenied {
        return Err(Error::Msg(unreachable_message(&paths.socket, &first)));
    }
    paths.check_socket_len()?;
    let exe = std::env::current_exe().map_err(|e| Error::Msg(format!("cannot find my own executable to start the daemon: {e}")))?;
    let mut cmd = Command::new(exe);
    cmd.arg("daemon").arg("--store").arg(&paths.store).arg("--socket").arg(&paths.socket).args(extra_daemon_args);
    // Its own process group, no terminal: the daemon outlives this client and its shell.
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0);
    let mut child = cmd.spawn().map_err(|e| Error::Msg(format!("could not start the daemon: {e}")))?;
    let until = Instant::now() + START_WAIT;
    loop {
        match Client::connect(&paths.socket) {
            Ok(mut c) => {
                c.handshake()?;
                return Ok(c);
            }
            Err(e) => {
                // A daemon that died on startup (unwritable store, bad socket path) will never
                // open the socket; say so now instead of after the full wait.
                if let Ok(Some(status)) = child.try_wait() {
                    if !status.success() {
                        return Err(Error::Msg(format!("the daemon exited on startup ({status}); see {} or run `fdindex daemon` to see why", paths.log.display())));
                    }
                    // It found the lock held. If that daemon is still answering, the next connect
                    // succeeds; if it was on its way out (a `stop` a moment ago) nobody is left to
                    // open the socket, so try again.
                    std::thread::sleep(Duration::from_millis(50));
                    if Client::connect(&paths.socket).is_err() {
                        child = cmd.spawn().map_err(|e| Error::Msg(format!("could not start the daemon: {e}")))?;
                    }
                }
                if Instant::now() >= until {
                    return Err(Error::Msg(format!("started the daemon but it did not open {} within {START_WAIT:?}: {e} (see {})", paths.socket.display(), paths.log.display())));
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    }
}
