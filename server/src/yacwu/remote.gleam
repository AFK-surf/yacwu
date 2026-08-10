//// SSH plumbing for remote codex app-servers.
////
//// A remote host runs one persistent `codex app-server --listen unix://…`
//// that outlives every connection to it — that persistence is the whole
//// point: SSH drops, yacwu restarts, and in-flight turns keep running on the
//// remote machine. This module owns the three legs that get us to it:
////
////   1. bootstrap: `ssh <host> "exec sh"` runs an idempotent script over
////      stdin that starts the app-server detached if it isn't running and
////      reports its pid, the remote home, and the remote socket path;
////   2. forward: a long-lived `ssh -N -L local.sock:remote.sock` child
////      relays a local Unix socket to the remote one (OpenSSH streamlocal
////      forwarding), so no TCP port is ever exposed;
////   3. attach: connect to the local socket and perform the WebSocket
////      handshake codex's Unix-socket transport speaks, then hand the
////      socket over to the manager actor.
////
//// All authentication is the system `ssh` binary's business (keys, agents,
//// ProxyJump — whatever ~/.ssh/config says). BatchMode keeps yacwu from
//// hanging on interactive prompts: hosts that need a password fail fast with
//// a visible error instead.

import envoy
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int

import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Pid}

import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import simplifile
import yacwu/ws

// -- Erlang FFI ---------------------------------------------------------------

pub type Socket

type SpawnSpec {
  SpawnExecutable(path: String)
}

/// Options for both `erlang:open_port/2` and `gen_tcp` calls — variants
/// compile to the atoms/tuples the respective Erlang APIs expect, and the
/// two APIs never see each other's variants.
type PortOption {
  Binary
  ExitStatus
  UseStdio
  StderrToStdout
  Hide
  Args(List(String))
  Active(Bool)
}

@external(erlang, "erlang", "open_port")
fn erl_open_port(spec: SpawnSpec, options: List(PortOption)) -> Port

@external(erlang, "erlang", "port_command")
fn erl_port_command(port: Port, data: BitArray) -> Bool

@external(erlang, "erlang", "port_close")
fn erl_port_close(port: Port) -> Bool

type NetAddress {
  Local(String)
}

@external(erlang, "gen_tcp", "connect")
fn tcp_connect(
  addr: NetAddress,
  port: Int,
  options: List(PortOption),
  timeout: Int,
) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "send")
fn tcp_send(socket: Socket, data: BitArray) -> Dynamic

@external(erlang, "gen_tcp", "recv")
fn tcp_recv(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, Dynamic)

@external(erlang, "gen_tcp", "close")
fn tcp_close(socket: Socket) -> Dynamic

@external(erlang, "gen_tcp", "controlling_process")
fn tcp_controlling_process(socket: Socket, owner: Pid) -> Dynamic

@external(erlang, "inet", "setopts")
fn inet_setopts(socket: Socket, options: List(PortOption)) -> Dynamic

fn tcp_options(active: Bool) -> List(PortOption) {
  [Binary, Active(active)]
}

// -- Bootstrap ----------------------------------------------------------------

/// The idempotent remote-side script. Runs under `sh` with the script on
/// stdin (so no quoting battles with the user's login shell), starts a
/// detached app-server when none is alive, and reports:
///
///   YACWU_PID <pid>
///   YACWU_HOME <home directory>
///   YACWU_SOCK <absolute socket path>
///   YACWU_ERR <message>          (on failure)
///
/// Deliberately restricted to double quotes only — the whole script travels
/// as data, never re-quoted. `nohup`/`setsid` detach the server from the SSH
/// session; on systemd machines with KillUserProcesses=yes the operator needs
/// `loginctl enable-linger` for the server to survive logout (the docs say
/// so).
pub const bootstrap_script = "
export PATH=\"$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"
if [ -f \"$HOME/.profile\" ]; then . \"$HOME/.profile\" >/dev/null 2>&1 || true; fi
dir=\"${XDG_CACHE_HOME:-$HOME/.cache}/yacwu\"
mkdir -p \"$dir\" && chmod 700 \"$dir\" || exit 1
sock=\"$dir/app-server.sock\"
pidfile=\"$dir/app-server.pid\"
log=\"$dir/app-server.log\"
# Liveness is judged by a running process serving this socket path, not by
# the recorded pid: npm-style codex installs launch through a wrapper whose
# pid can die while the real server lives on.
pid=\"\"
if command -v pgrep >/dev/null 2>&1; then
  pid=$(pgrep -f \"app-server --listen unix://$sock\" 2>/dev/null | head -n 1)
elif [ -f \"$pidfile\" ]; then
  pid=$(cat \"$pidfile\" 2>/dev/null)
  if [ -n \"$pid\" ] && ! kill -0 \"$pid\" 2>/dev/null; then pid=\"\"; fi
fi
if [ -n \"$pid\" ] && [ -S \"$sock\" ]; then
  echo \"YACWU_PID $pid\"
  echo \"YACWU_HOME $HOME\"
  echo \"YACWU_CODEX_HOME ${CODEX_HOME:-$HOME/.codex}\"
  echo \"YACWU_SOCK $sock\"
  exit 0
fi
if ! command -v codex >/dev/null 2>&1; then
  echo \"YACWU_ERR codex not found on the remote PATH\"
  exit 1
fi
# Half-dead leftovers (a server whose socket file is gone can accept no new
# connections) must not linger next to the fresh one.
if command -v pkill >/dev/null 2>&1; then
  pkill -f \"app-server --listen unix://$sock\" 2>/dev/null || true
  sleep 1
fi
rm -f \"$sock\"
if command -v setsid >/dev/null 2>&1; then
  setsid nohup codex app-server --listen \"unix://$sock\" </dev/null >>\"$log\" 2>&1 &
else
  nohup codex app-server --listen \"unix://$sock\" </dev/null >>\"$log\" 2>&1 &
fi
pid=$!
echo \"$pid\" >\"$pidfile\"
i=0
while [ ! -S \"$sock\" ]; do
  i=$((i+1))
  if [ \"$i\" -gt 60 ]; then
    echo \"YACWU_ERR codex app-server did not create its socket (see $log on the remote host)\"
    exit 1
  fi
  if ! kill -0 \"$pid\" 2>/dev/null; then
    echo \"YACWU_ERR codex app-server exited during startup (see $log on the remote host)\"
    exit 1
  fi
  sleep 0.5 2>/dev/null || sleep 1
done
echo \"YACWU_PID $pid\"
echo \"YACWU_HOME $HOME\"
echo \"YACWU_CODEX_HOME ${CODEX_HOME:-$HOME/.codex}\"
echo \"YACWU_SOCK $sock\"
exit 0
"

pub type Bootstrap {
  Bootstrap(pid: String, home: String, codex_home: String, socket: String)
}

/// Ensure the persistent app-server is running on `host`. Runs the bootstrap
/// script through `ssh` and parses its report. Synchronous — call from a
/// connector process, never from the manager actor itself.
pub fn bootstrap(host: String) -> Result(Bootstrap, String) {
  let port =
    erl_open_port(SpawnExecutable("/usr/bin/env"), [
      Binary,
      ExitStatus,
      UseStdio,
      StderrToStdout,
      Hide,
      Args([
        "ssh",
        "-oBatchMode=yes",
        "-oConnectTimeout=15",
        "--",
        host,
        "exec sh",
      ]),
    ])
  let _ = erl_port_command(port, bit_array.from_string(bootstrap_script))
  let output = collect_port_output(port, "", deadline_ms(60_000))
  parse_bootstrap(output, host)
}

fn deadline_ms(from_now: Int) -> Int {
  monotonic_ms() + from_now
}

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn erl_monotonic_time(unit: TimeUnit) -> Int

fn monotonic_ms() -> Int {
  erl_monotonic_time(Millisecond)
}

type PortEvent {
  Data(String)
  Exited
  Timeout
}

/// Ceiling on collected ssh output: a host streaming garbage must cost a
/// truncated report, never unbounded memory.
const max_collected_output = 1_000_000

/// Read a spawned command's combined output until it exits, the deadline
/// passes, or the size cap is hit (the port is killed on timeout/overflow).
fn collect_port_output(port: Port, acc: String, deadline: Int) -> String {
  let remaining = deadline - monotonic_ms()
  case remaining <= 0 || string.byte_size(acc) > max_collected_output {
    True -> {
      let _ = erl_port_close(port)
      acc
    }
    False -> {
      let selector =
        process.new_selector()
        |> process.select_other(fn(message) {
          case decode.run(message, decode.at([1, 1], decode.bit_array)) {
            Ok(data) -> Data(bit_array.to_string(data) |> result.unwrap(""))
            Error(_) ->
              case decode.run(message, decode.at([1, 1], decode.int)) {
                Ok(_code) -> Exited
                Error(_) -> Timeout
              }
          }
        })
      case process.selector_receive(selector, remaining) {
        Ok(Data(text)) -> collect_port_output(port, acc <> text, deadline)
        Ok(Exited) -> acc
        Ok(Timeout) -> collect_port_output(port, acc, deadline)
        Error(Nil) -> {
          let _ = erl_port_close(port)
          acc
        }
      }
    }
  }
}

/// Extract the YACWU_* report from the bootstrap output. Anything else in the
/// output (login noise, ssh warnings) is ignored, but surfaces in errors.
pub fn parse_bootstrap(
  output: String,
  host: String,
) -> Result(Bootstrap, String) {
  let field = fn(prefix: String) {
    string.split(output, "\n")
    |> list.filter_map(fn(line) {
      let line = string.trim(line)
      case string.starts_with(line, prefix <> " ") {
        True -> Ok(string.drop_start(line, string.length(prefix) + 1))
        False -> Error(Nil)
      }
    })
    |> list.last
  }
  case field("YACWU_ERR") {
    Ok(message) -> Error(host <> ": " <> message)
    Error(_) ->
      case field("YACWU_PID"), field("YACWU_HOME"), field("YACWU_SOCK") {
        Ok(pid), Ok(home), Ok(sock) -> {
          let codex_home =
            field("YACWU_CODEX_HOME") |> result.unwrap(home <> "/.codex")
          Ok(Bootstrap(pid, home, codex_home, sock))
        }
        _, _, _ ->
          Error(
            host
            <> ": could not start the remote codex app-server: "
            <> summarize(output),
          )
      }
  }
}

fn summarize(output: String) -> String {
  let trimmed = string.trim(output)
  case trimmed {
    "" -> "ssh produced no output (is the host reachable and key auth set up?)"
    _ -> string.slice(trimmed, 0, 300)
  }
}

// -- Local socket paths -------------------------------------------------------

/// Directory holding the local ends of forwarded sockets: private to the
/// user, recreated on demand, nothing in it survives meaningfully.
pub fn socket_dir() -> String {
  let base = case envoy.get("XDG_RUNTIME_DIR") {
    Ok(dir) if dir != "" -> dir
    _ ->
      case envoy.get("TMPDIR") {
        Ok(dir) if dir != "" -> dir
        _ -> "/tmp"
      }
  }
  let user = envoy.get("USER") |> result.unwrap("u")
  base <> "/yacwu-" <> user
}

pub fn local_socket_path(host: String) -> String {
  socket_dir() <> "/" <> host <> ".sock"
}

// -- Forwarder ----------------------------------------------------------------

/// Open the long-lived `ssh -N -L` child forwarding `local` to `remote_sock`
/// on `host`. The returned port belongs to the calling process (the manager
/// actor), so the forward lives exactly as long as the manager does.
pub fn open_forwarder(
  host: String,
  local: String,
  remote_sock: String,
) -> Result(Port, String) {
  let dir = socket_dir()
  case simplifile.create_directory_all(dir) {
    Error(error) ->
      Error(
        "could not create " <> dir <> ": " <> simplifile.describe_error(error),
      )
    Ok(_) -> {
      let _ = simplifile.set_permissions_octal(dir, 0o700)
      // ssh refuses to bind over an existing socket file.
      let _ = simplifile.delete(local)
      // `ssh -N` never touches stdio, so closing its Erlang port would
      // orphan the OS process. A local sh watchdog fixes the lifetime: when
      // the port closes (explicitly, or because the owning manager died),
      // stdin reaches EOF and the watchdog kills ssh.
      Ok(
        erl_open_port(SpawnExecutable("/usr/bin/env"), [
          Binary,
          ExitStatus,
          UseStdio,
          StderrToStdout,
          Hide,
          Args([
            "sh",
            "-c",
            "ssh \"$@\" & p=$!; cat >/dev/null; kill \"$p\" 2>/dev/null",
            "sh",
            "-oBatchMode=yes",
            "-oConnectTimeout=15",
            "-oExitOnForwardFailure=yes",
            "-oServerAliveInterval=15",
            "-oServerAliveCountMax=3",
            "-N",
            "-L",
            local <> ":" <> remote_sock,
            "--",
            host,
          ]),
        ]),
      )
    }
  }
}

pub fn close_forwarder(port: Port) -> Nil {
  let _ = erl_port_close(port)
  Nil
}

// -- Attach: connect + WebSocket handshake ------------------------------------

pub type Handover {
  Handover(socket: Socket, leftover: BitArray)
}

/// Connect to a local Unix socket and complete codex's WebSocket handshake,
/// retrying while the forwarded socket comes up. On success the socket is
/// handed to `owner` (the manager actor) still in passive mode; the actor
/// flips it to active delivery.
pub fn attach(
  path: String,
  owner: Pid,
  attempts: Int,
) -> Result(Handover, String) {
  case tcp_connect(Local(path), 0, tcp_options(False), 1000) {
    Error(_) ->
      case attempts <= 1 {
        True -> Error("could not connect to " <> path)
        False -> {
          process.sleep(400)
          attach(path, owner, attempts - 1)
        }
      }
    Ok(socket) ->
      case handshake(socket) {
        Ok(leftover) -> {
          let _ = tcp_controlling_process(socket, owner)
          Ok(Handover(socket, leftover))
        }
        Error(message) -> {
          let _ = tcp_close(socket)
          // A connect that succeeds locally but dies in the handshake means
          // the remote end of the forward is gone — retrying without a fresh
          // bootstrap won't help beyond a few attempts.
          case attempts <= 1 {
            True -> Error(message)
            False -> {
              process.sleep(400)
              attach(path, owner, attempts - 1)
            }
          }
        }
      }
  }
}

fn handshake(socket: Socket) -> Result(BitArray, String) {
  let key = ws.random_key()
  let _ = tcp_send(socket, bit_array.from_string(ws.handshake_request(key)))
  use #(header, leftover) <- result.try(read_header(socket, <<>>, 20))
  use _ <- result.try(ws.check_handshake(header, key))
  Ok(leftover)
}

fn read_header(
  socket: Socket,
  buffer: BitArray,
  attempts: Int,
) -> Result(#(String, BitArray), String) {
  case ws.split_header(buffer) {
    Ok(split) -> Ok(split)
    Error(_) ->
      case attempts <= 0 {
        True -> Error("websocket handshake did not complete")
        False ->
          case tcp_recv(socket, 0, 5000) {
            Error(_) -> Error("connection closed during websocket handshake")
            Ok(data) ->
              read_header(
                socket,
                bit_array.concat([buffer, data]),
                attempts - 1,
              )
          }
      }
  }
}

// -- Socket IO for the manager ------------------------------------------------

/// Switch a handed-over socket to active mode so its bytes arrive as
/// `{tcp, Socket, Data}` messages in the manager's mailbox.
pub fn activate(socket: Socket) -> Nil {
  let _ = inet_setopts(socket, tcp_options(True))
  Nil
}

/// Send one JSON-RPC message as a masked text frame.
pub fn send_text(socket: Socket, text: String) -> Nil {
  let _ = tcp_send(socket, ws.encode(ws.Text(text), Some(ws.random_mask())))
  Nil
}

pub fn send_pong(socket: Socket, payload: BitArray) -> Nil {
  let _ = tcp_send(socket, ws.encode(ws.Pong(payload), Some(ws.random_mask())))
  Nil
}

pub fn close(socket: Socket) -> Nil {
  let _ = tcp_close(socket)
  Nil
}

// -- In-use detection ---------------------------------------------------------

/// Scan the remote /proc for processes holding a rollout file open — the
/// remote equivalent of `session_lock`'s local scan. `$1` is the rollout
/// path, `$2` the app-server socket path: any holder whose ancestor chain
/// contains the app-server serving that socket is our own and is skipped.
/// Non-Linux remotes (no /proc) degrade to "no holders", like the local
/// unsupported-platform path. No single quotes: travels as data.
const holders_script = "
target=\"$1\"
sockpat=\"$2\"
[ -d /proc ] || exit 0
for fd_dir in /proc/[0-9]*/fd; do
  pid=\"${fd_dir%/fd}\"
  pid=\"${pid#/proc/}\"
  match=0
  for link in \"$fd_dir\"/*; do
    dest=$(readlink \"$link\" 2>/dev/null) || continue
    if [ \"$dest\" = \"$target\" ]; then match=1; break; fi
  done
  [ \"$match\" = 1 ] || continue
  p=\"$pid\"
  skip=0
  while [ -n \"$p\" ] && [ \"$p\" != 0 ] && [ \"$p\" != 1 ]; do
    if tr \"\\0\" \" \" < \"/proc/$p/cmdline\" 2>/dev/null | grep -q \"app-server --listen unix://$sockpat\"; then
      skip=1
      break
    fi
    p=$(sed -n \"s/^PPid:[[:space:]]*//p\" \"/proc/$p/status\" 2>/dev/null)
  done
  [ \"$skip\" = 1 ] && continue
  comm=$(cat \"/proc/$pid/comm\" 2>/dev/null)
  if [ -z \"$comm\" ]; then comm=\"pid $pid\"; fi
  echo \"YACWU_HOLDER $pid $comm\"
done
exit 0
"

/// Processes on `host` (other than its yacwu app-server) holding the given
/// rollout file open. Failures degrade to an empty list — in-use detection
/// is advisory, never blocking.
pub fn detect_holders(
  host: String,
  rollout_path: String,
  remote_sock: String,
) -> List(#(Int, String)) {
  case rollout_path {
    "" -> []
    _ -> {
      let port =
        erl_open_port(SpawnExecutable("/usr/bin/env"), [
          Binary,
          ExitStatus,
          UseStdio,
          StderrToStdout,
          Hide,
          Args([
            "ssh",
            "-oBatchMode=yes",
            "-oConnectTimeout=10",
            "--",
            host,
            "exec sh -s "
              <> shell_quote(rollout_path)
              <> " "
              <> shell_quote(remote_sock),
          ]),
        ])
      let _ = erl_port_command(port, bit_array.from_string(holders_script))
      collect_port_output(port, "", deadline_ms(20_000))
      |> parse_holders
    }
  }
}

/// Parse `YACWU_HOLDER <pid> <command>` lines.
pub fn parse_holders(output: String) -> List(#(Int, String)) {
  string.split(output, "\n")
  |> list.filter_map(fn(line) {
    use rest <- result.try(case string.starts_with(line, "YACWU_HOLDER ") {
      True -> Ok(string.drop_start(line, 13))
      False -> Error(Nil)
    })
    use #(pid, command) <- result.try(string.split_once(rest, " "))
    use pid <- result.try(int.parse(pid))
    Ok(#(pid, string.trim(command)))
  })
}

/// Single-quote a value for embedding in a remote shell command line.
fn shell_quote(value: String) -> String {
  "'" <> string.replace(value, "'", "'\\''") <> "'"
}
