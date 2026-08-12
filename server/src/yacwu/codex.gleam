//// Manager for one `codex app-server`, local or remote.
////
//// Multiplexes many threads (sessions) over one JSON-RPC connection. Every
//// codex notification carries `params.threadId`, so the frontend can route
//// events to the right session. There is no database here: codex persists
//// its own sessions on disk and we read them back via `thread/list` and
//// `thread/read`.
////
//// Transports:
////
//// - `Local`: a child app-server speaking newline-delimited JSON over
////   stdio — `codex app-server`, or an alternative backend command (see
////   `backends`). Spawned lazily on the first request and respawned on the
////   next request after it exits — the original behaviour.
//// - `UnixSock`: an already-running app-server listening on a Unix socket
////   (codex's WebSocket transport). The server outlives this manager.
//// - `Ssh`: a persistent app-server on a remote machine, reached through an
////   `ssh -N -L` Unix-socket forward and bootstrapped over ssh on demand
////   (see `remote`). The remote server outlives yacwu and every SSH drop:
////   on disconnect the manager reconnects with backoff, re-initializes (the
////   handshake is per-connection by design), and re-resumes the threads it
////   had open so notifications flow again. In-flight turns keep running on
////   the remote machine while we are away.

import envoy
import exception
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import yacwu/jsonx
import yacwu/remote
import yacwu/ws

const version = "0.1.0"

// -- Erlang port FFI ---------------------------------------------------------
//
// These custom types compile to exactly the Erlang terms `erlang:open_port/2`
// expects: variants without fields become atoms (`binary`, `exit_status`, …)
// and variants with fields become tagged tuples (`{args, [...]}`, `{cd, Dir}`).

type SpawnSpec {
  SpawnExecutable(path: String)
}

type PortOption {
  Binary
  ExitStatus
  UseStdio
  Hide
  Args(List(String))
  Cd(String)
}

@external(erlang, "erlang", "open_port")
fn erl_open_port(spec: SpawnSpec, options: List(PortOption)) -> Port

@external(erlang, "erlang", "port_command")
fn erl_port_command(port: Port, data: BitArray) -> Bool

@external(erlang, "erlang", "port_close")
fn erl_port_close(port: Port) -> Bool

@external(erlang, "erlang", "port_info")
fn erl_port_info(port: Port, item: atom.Atom) -> Dynamic

@external(erlang, "erlang", "is_port")
fn erl_is_port(value: a) -> Bool

@external(erlang, "erlang", "=:=")
fn erl_same_term(a: a, b: b) -> Bool

type SplitOption {
  Global
}

@external(erlang, "binary", "split")
fn binary_split(
  subject: BitArray,
  pattern: BitArray,
  options: List(SplitOption),
) -> List(BitArray)

// -- Public API ---------------------------------------------------------------

/// The default local app-server command.
pub const default_command = ["codex", "app-server"]

/// How to reach the app-server this manager drives.
pub type Transport {
  /// Child process over stdio (the classic local setup): `default_command`,
  /// or an alternative backend's argv.
  Local(command: List(String))
  /// Persistent server on a local Unix socket (WebSocket framing).
  UnixSock(path: String)
  /// Persistent server on `host` from ~/.ssh/config, over a forwarded
  /// Unix socket.
  Ssh(host: String)
}

pub type Reply =
  Result(Dynamic, String)

/// Host connection details for /api/hosts, remote workspace operations,
/// and the UI. `codex_home` and `socket` are only known for SSH transports
/// once a bootstrap has run ("" until then, and always "" for local).
pub type HostInfo {
  HostInfo(
    state: String,
    home: String,
    codex_home: String,
    socket: String,
    error: String,
  )
}

pub opaque type Msg {
  Request(method: String, params: Json, reply: Subject(Reply))
  Notify(method: String, params: Json)
  Subscribe(owner: Pid, subject: Subject(String))
  GetOsPid(reply: Subject(Result(Int, Nil)))
  GetInfo(reply: Subject(HostInfo))
  OpenForwarder(
    local: String,
    remote_sock: String,
    reply: Subject(Result(Nil, String)),
  )
  ConnResult(
    Result(#(remote.Socket, BitArray, Option(remote.Bootstrap)), String),
  )
  TryReconnect
  PortData(BitArray)
  PortExit(Int)
  TcpData(BitArray)
  TcpClosed
  SubscriberDown(pid: Pid)
  LinkedExit(exit: process.ExitMessage)
  Ignore
}

/// A handle used by HTTP handlers to talk to the manager.
pub type Codex =
  Name(Msg)

/// The working directory codex runs in (`YACWU_CWD`, defaulting to `$HOME`).
pub fn default_cwd() -> String {
  case envoy.get("YACWU_CWD") {
    Ok(cwd) if cwd != "" -> cwd
    _ -> local_home()
  }
}

fn local_home() -> String {
  envoy.get("HOME") |> result.unwrap("/")
}

/// Send a JSON-RPC request to codex and wait for its response.
pub fn request(codex: Codex, method: String, params: Json) -> Reply {
  case
    exception.rescue(fn() {
      process.call_forever(process.named_subject(codex), Request(
        method,
        params,
        _,
      ))
    })
  {
    Ok(reply) -> reply
    Error(_) -> Error("codex manager is restarting; retry shortly")
  }
}

/// Send a JSON-RPC notification (no response expected).
pub fn notify(codex: Codex, method: String, params: Json) -> Nil {
  let _ =
    exception.rescue(fn() {
      process.send(process.named_subject(codex), Notify(method, params))
    })
  Nil
}

/// Subscribe `subject` to every codex notification, formatted as raw JSON
/// strings. The subscription is removed automatically when `owner` exits.
pub fn subscribe(codex: Codex, owner: Pid, subject: Subject(String)) -> Nil {
  let _ =
    exception.rescue(fn() {
      process.send(process.named_subject(codex), Subscribe(owner, subject))
    })
  Nil
}

/// OS pid of the managed `codex app-server` process, if it is a local child.
pub fn os_pid(codex: Codex) -> Result(Int, Nil) {
  case
    exception.rescue(fn() {
      process.call_forever(process.named_subject(codex), GetOsPid)
    })
  {
    Ok(pid) -> pid
    Error(_) -> Error(Nil)
  }
}

/// Connection state, home directory and last error for this host.
pub fn info(codex: Codex) -> HostInfo {
  case
    exception.rescue(fn() {
      process.call_forever(process.named_subject(codex), GetInfo)
    })
  {
    Ok(info) -> info
    Error(_) -> HostInfo("disconnected", "", "", "", "manager is restarting")
  }
}

/// Start a manager registered under `name`. `label` is the host name used in
/// `yacwu/host/status` notifications ("local" for the local transport).
pub fn start(
  name: Codex,
  label: String,
  transport: Transport,
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(subject) {
    // The child's port is linked to this actor, and a port can die
    // abnormally out from under us — most notably with `epipe` when the
    // app-server exits (say, after an internal error like a model-refresh
    // timeout) while writes are still in flight. Untrapped, that exit
    // signal kills the manager along with every pending request and the
    // resumed-thread list; trapped, it is just a disconnect.
    process.trap_exits(True)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_trapped_exits(LinkedExit)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid: pid, ..) -> SubscriberDown(pid)
          process.PortDown(..) -> Ignore
        }
      })
      |> process.select_other(classify_other)
    initial_state(name, label, transport)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

// -- Internal state -----------------------------------------------------------

type Queued =
  #(String, Json, Subject(Reply))

/// Whoever waits on a pending request: an HTTP caller, or nobody (requests
/// the manager sends on its own behalf, like post-reconnect re-resumes).
type ReplyTo {
  Caller(Subject(Reply))
  Discard
}

type Pending {
  Pending(method: String, thread: Option(String), reply_to: ReplyTo)
}

type Conn {
  PortConn(port: Port)
  SockConn(socket: remote.Socket)
}

type Status {
  NotRunning
  /// A connector process is establishing the remote connection.
  Connecting(queued: List(Queued))
  Initializing(conn: Conn, init_id: Int, queued: List(Queued))
  Running(conn: Conn)
}

type State {
  State(
    self: Codex,
    label: String,
    transport: Transport,
    status: Status,
    next_id: Int,
    pending: Dict(Int, Pending),
    subscribers: List(#(Pid, Subject(String))),
    buffer: BitArray,
    decoder: ws.Decoder,
    forwarder: Option(Port),
    /// The unlinked connection-setup process, monitored while `Connecting`.
    connector: Option(Pid),
    /// Threads resumed/started over this manager — re-resumed after a
    /// reconnect so their notifications keep flowing.
    resumed: List(String),
    home: String,
    codex_home: String,
    remote_sock: String,
    backoff: Int,
    last_error: String,
  )
}

fn initial_state(self: Codex, label: String, transport: Transport) -> State {
  State(
    self: self,
    label: label,
    transport: transport,
    status: NotRunning,
    next_id: 1,
    pending: dict.new(),
    subscribers: [],
    buffer: <<>>,
    decoder: ws.new_decoder(),
    forwarder: None,
    connector: None,
    resumed: [],
    home: case transport {
      Ssh(_) -> ""
      _ -> local_home()
    },
    codex_home: "",
    remote_sock: "",
    backoff: 0,
    last_error: "",
  )
}

/// Raw port and socket messages arrive as bare tuples rather than typed
/// subject messages: `{Port, {data, Bin}}`, `{Port, {exit_status, Code}}`,
/// `{tcp, Sock, Data}`, `{tcp_closed, Sock}`, `{tcp_error, Sock, Reason}`.
fn classify_other(message: Dynamic) -> Msg {
  let tag =
    decode.run(message, decode.at([0], atom.decoder()))
    |> result.map(atom.to_string)
  case tag {
    Ok("tcp") ->
      case decode.run(message, decode.at([2], decode.bit_array)) {
        Ok(data) -> TcpData(data)
        Error(_) -> Ignore
      }
    Ok("tcp_closed") | Ok("tcp_error") -> TcpClosed
    _ ->
      case decode.run(message, decode.at([1, 1], decode.bit_array)) {
        Ok(data) -> PortData(data)
        Error(_) ->
          case decode.run(message, decode.at([1, 1], decode.int)) {
            Ok(code) -> PortExit(code)
            Error(_) -> Ignore
          }
      }
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Request(method, params, reply) -> on_request(state, method, params, reply)
    Notify(method, params) -> {
      case state.status {
        Running(conn) | Initializing(conn, _, _) ->
          write_notification(conn, method, params)
        _ -> Nil
      }
      actor.continue(state)
    }
    Subscribe(owner, subject) -> {
      // Idempotent per owner: subscribers re-subscribe to self-heal after
      // registry restarts, and monitors must not accumulate.
      case list.any(state.subscribers, fn(s) { s.0 == owner }) {
        True ->
          actor.continue(
            State(..state, subscribers: [
              #(owner, subject),
              ..list.filter(state.subscribers, fn(s) { s.0 != owner })
            ]),
          )
        False -> {
          let _ = process.monitor(owner)
          actor.continue(
            State(..state, subscribers: [#(owner, subject), ..state.subscribers]),
          )
        }
      }
    }
    SubscriberDown(pid) ->
      case state.connector == Some(pid), state.status {
        // The connection-setup process died without reporting (its 15s call
        // into this actor timed out, or it crashed): fall into the normal
        // connect-failed path instead of stranding `Connecting` forever.
        True, Connecting(_) ->
          on_conn_result(
            State(..state, connector: None),
            Error("connection setup did not complete"),
          )
        True, _ -> actor.continue(State(..state, connector: None))
        False, _ ->
          actor.continue(
            State(
              ..state,
              subscribers: list.filter(state.subscribers, fn(s) { s.0 != pid }),
            ),
          )
      }
    GetOsPid(reply) -> {
      let pid = case state.status {
        Running(PortConn(port)) | Initializing(PortConn(port), _, _) ->
          decode.run(
            erl_port_info(port, atom.create("os_pid")),
            decode.at([1], decode.int),
          )
          |> result.replace_error(Nil)
        _ -> Error(Nil)
      }
      process.send(reply, pid)
      actor.continue(state)
    }
    GetInfo(reply) -> {
      let connection_state = case state.status {
        NotRunning -> "disconnected"
        Connecting(_) | Initializing(_, _, _) -> "connecting"
        Running(_) -> "connected"
      }
      process.send(
        reply,
        HostInfo(
          connection_state,
          state.home,
          state.codex_home,
          state.remote_sock,
          state.last_error,
        ),
      )
      actor.continue(state)
    }
    OpenForwarder(local, remote_sock, reply) ->
      on_open_forwarder(state, local, remote_sock, reply)
    ConnResult(result) -> on_conn_result(state, result)
    TryReconnect ->
      case state.status, state.transport {
        NotRunning, UnixSock(_) | NotRunning, Ssh(_) ->
          case state.resumed {
            [] -> actor.continue(state)
            _ -> begin_connect(state, [])
          }
        _, _ -> actor.continue(state)
      }
    PortData(data) ->
      case state.status {
        Running(PortConn(_)) | Initializing(PortConn(_), _, _) ->
          on_port_data(state, data)
        // Any other port output (the ssh forwarder's stderr) is noise.
        _ -> actor.continue(state)
      }
    PortExit(code) ->
      case state.status {
        Running(PortConn(_)) | Initializing(PortConn(_), _, _) ->
          on_child_exit(state, code)
        // The ssh forwarder exited: the socket (if any) dies with it and
        // that arrives separately as TcpClosed.
        _ -> actor.continue(State(..state, forwarder: None))
      }
    LinkedExit(exit) -> on_linked_exit(state, exit)
    TcpData(data) -> on_tcp_data(state, data)
    TcpClosed ->
      case state.status {
        Running(SockConn(_)) | Initializing(SockConn(_), _, _) ->
          on_disconnect(state, "connection to codex app-server lost")
        _ -> actor.continue(state)
      }
    Ignore -> actor.continue(state)
  }
}

fn on_request(
  state: State,
  method: String,
  params: Json,
  reply: Subject(Reply),
) -> actor.Next(State, Msg) {
  case state.status {
    NotRunning -> begin_connect(state, [#(method, params, reply)])
    Connecting(queued) ->
      actor.continue(
        State(..state, status: Connecting([#(method, params, reply), ..queued])),
      )
    Initializing(conn, init_id, queued) ->
      actor.continue(
        State(
          ..state,
          status: Initializing(conn, init_id, [
            #(method, params, reply),
            ..queued
          ]),
        ),
      )
    Running(conn) ->
      actor.continue(send_request(state, conn, method, params, Caller(reply)))
  }
}

/// Send one request over the wire and track its pending reply.
fn send_request(
  state: State,
  conn: Conn,
  method: String,
  params: Json,
  reply_to: ReplyTo,
) -> State {
  let id = state.next_id
  write_request(conn, id, method, params)
  State(
    ..state,
    next_id: id + 1,
    pending: dict.insert(
      state.pending,
      id,
      Pending(method, request_thread_id(method, params), reply_to),
    ),
  )
}

/// The threadId a request operates on, captured for the handful of methods
/// whose *response* doesn't echo it (needed to maintain `resumed`).
fn request_thread_id(method: String, params: Json) -> Option(String) {
  case method {
    "thread/unsubscribe" | "thread/archive" | "thread/resume" ->
      json.parse(json.to_string(params), decode.at(["threadId"], decode.string))
      |> option.from_result
    _ -> None
  }
}

// -- Connection establishment -------------------------------------------------

fn begin_connect(state: State, queued: List(Queued)) -> actor.Next(State, Msg) {
  case state.transport {
    Local(command) -> {
      let port = spawn_codex(command)
      actor.continue(begin_initialize(state, PortConn(port), queued))
    }
    UnixSock(_) | Ssh(_) -> {
      let connector = spawn_connector(state)
      let state = broadcast_status(state, "connecting", "")
      actor.continue(
        State(..state, status: Connecting(queued), connector: Some(connector)),
      )
    }
  }
}

/// Send the `initialize` handshake on a fresh connection and queue everything
/// else until it completes.
fn begin_initialize(state: State, conn: Conn, queued: List(Queued)) -> State {
  let init_id = state.next_id
  write_request(
    conn,
    init_id,
    "initialize",
    json.object([
      #(
        "clientInfo",
        json.object([
          #("name", json.string("yacwu")),
          #("title", json.string("yacwu")),
          #("version", json.string(version)),
        ]),
      ),
      #("capabilities", json.object([#("experimentalApi", json.bool(True))])),
    ]),
  )
  State(
    ..state,
    status: Initializing(conn, init_id, queued),
    next_id: init_id + 1,
  )
}

fn spawn_codex(command: List(String)) -> Port {
  erl_open_port(SpawnExecutable("/usr/bin/env"), [
    Binary,
    ExitStatus,
    UseStdio,
    Hide,
    Args(command),
    Cd(default_cwd()),
  ])
}

/// Establish a remote connection off the actor: bootstrap over ssh, ask the
/// actor to open the socket forward (ports must belong to the long-lived
/// actor), attach, then hand the socket back via `ConnResult`.
fn spawn_connector(state: State) -> Pid {
  let subject = process.named_subject(state.self)
  let owner = process.self()
  let transport = state.transport
  let pid =
    process.spawn_unlinked(fn() {
      let result = case transport {
        UnixSock(path) ->
          remote.attach(path, owner, 10)
          |> result.map(fn(handover) {
            #(handover.socket, handover.leftover, None)
          })
        Ssh(host) -> {
          use boot <- result.try(remote.bootstrap(host))
          let local = remote.local_socket_path(host)
          use _ <- result.try(
            process.call(subject, 15_000, OpenForwarder(local, boot.socket, _)),
          )
          use handover <- result.try(remote.attach(local, owner, 40))
          Ok(#(handover.socket, handover.leftover, Some(boot)))
        }
        Local(_) -> Error("local transport needs no connector")
      }
      process.send(subject, ConnResult(result))
    })
  let _ = process.monitor(pid)
  pid
}

fn on_open_forwarder(
  state: State,
  local: String,
  remote_sock: String,
  reply: Subject(Result(Nil, String)),
) -> actor.Next(State, Msg) {
  case state.forwarder {
    Some(old) -> remote.close_forwarder(old)
    None -> Nil
  }
  case state.transport {
    Ssh(host) ->
      case remote.open_forwarder(host, local, remote_sock) {
        Ok(port) -> {
          process.send(reply, Ok(Nil))
          actor.continue(State(..state, forwarder: Some(port)))
        }
        Error(message) -> {
          process.send(reply, Error(message))
          actor.continue(State(..state, forwarder: None))
        }
      }
    _ -> {
      process.send(reply, Error("not an ssh transport"))
      actor.continue(State(..state, forwarder: None))
    }
  }
}

fn on_conn_result(
  state: State,
  result: Result(#(remote.Socket, BitArray, Option(remote.Bootstrap)), String),
) -> actor.Next(State, Msg) {
  let state = State(..state, connector: None)
  case state.status, result {
    Connecting(queued), Ok(#(socket, leftover, boot)) -> {
      remote.activate(socket)
      let state = case boot {
        Some(boot) ->
          State(
            ..state,
            home: boot.home,
            codex_home: boot.codex_home,
            remote_sock: boot.socket,
          )
        None -> state
      }
      let state = State(..state, decoder: ws.new_decoder(), last_error: "")
      let state = begin_initialize(state, SockConn(socket), queued)
      // Bytes that arrived while the handshake was read belong to the
      // stream; run them through the normal frame path.
      case leftover {
        <<>> -> actor.continue(state)
        _ -> on_tcp_data(state, leftover)
      }
    }
    Connecting(queued), Error(message) -> {
      io.println_error("[codex " <> state.label <> "] connect: " <> message)
      list.each(queued, fn(q) { process.send(q.2, Error(message)) })
      let state =
        State(
          ..state,
          status: NotRunning,
          last_error: message,
          backoff: state.backoff + 1,
        )
      let state = broadcast_status(state, "disconnected", message)
      schedule_reconnect(state)
      actor.continue(state)
    }
    // A stray result after the connection already moved on: close it.
    _, Ok(#(socket, _, _)) -> {
      remote.close(socket)
      actor.continue(state)
    }
    _, Error(_) -> actor.continue(state)
  }
}

fn schedule_reconnect(state: State) -> Nil {
  case state.transport, state.resumed {
    Local(_), _ | _, [] -> Nil
    _, _ -> {
      // First retry after 1s, doubling to a 30s ceiling.
      let delay =
        int.min(30_000, 1000 * pow2(int.min(int.max(state.backoff - 1, 0), 5)))
      let _ =
        process.send_after(
          process.named_subject(state.self),
          delay,
          TryReconnect,
        )
      Nil
    }
  }
}

fn pow2(exponent: Int) -> Int {
  case exponent <= 0 {
    True -> 1
    False -> 2 * pow2(exponent - 1)
  }
}

// -- Incoming data ------------------------------------------------------------

fn on_port_data(state: State, data: BitArray) -> actor.Next(State, Msg) {
  let combined = bit_array.concat([state.buffer, data])
  let parts = binary_split(combined, <<"\n">>, [Global])
  // All parts but the last are complete lines; the last is the new buffer.
  let #(lines, buffer) = case list.reverse(parts) {
    [last, ..complete] -> #(list.reverse(complete), last)
    [] -> #([], <<>>)
  }
  let state = State(..state, buffer: buffer)
  let state = list.fold(lines, state, process_line)
  actor.continue(state)
}

fn on_tcp_data(state: State, data: BitArray) -> actor.Next(State, Msg) {
  let #(frames, decoder) = ws.push(state.decoder, data)
  handle_frames(State(..state, decoder: decoder), frames)
}

fn handle_frames(
  state: State,
  frames: List(ws.Frame),
) -> actor.Next(State, Msg) {
  case frames {
    [] -> actor.continue(state)
    [frame, ..rest] ->
      case frame {
        ws.Text(text) ->
          handle_frames(process_line(state, bit_array.from_string(text)), rest)
        ws.Ping(payload) -> {
          case state.status {
            Running(SockConn(socket)) | Initializing(SockConn(socket), _, _) ->
              remote.send_pong(socket, payload)
            _ -> Nil
          }
          handle_frames(state, rest)
        }
        // A close frame ends the connection; drop whatever followed it.
        ws.Close ->
          on_disconnect(state, "codex app-server closed the connection")
        // Protocol violations (oversized/hostile frames) must cost this
        // manager one disconnect+backoff, never unbounded memory: a bad
        // remote is never allowed to take the tree down.
        ws.Invalid(reason) ->
          on_disconnect(state, "dropping connection: " <> reason)
        ws.Pong(_) | ws.Binary(_) -> handle_frames(state, rest)
      }
  }
}

fn process_line(state: State, line: BitArray) -> State {
  case json.parse_bits(line, decode.dynamic) {
    Error(_) -> state
    Ok(msg) -> {
      let id = decode.run(msg, decode.at(["id"], decode.int))
      let method = decode.run(msg, decode.at(["method"], decode.string))
      let has_result =
        result.is_ok(decode.run(msg, decode.at(["result"], decode.dynamic)))
      let error = decode.run(msg, decode.at(["error"], decode.dynamic))
      let is_response = has_result || result.is_ok(error)
      case id, method {
        // Response to one of our requests.
        Ok(id), _ if is_response -> on_response(state, id, msg, error)
        // Server-initiated request (has both id and method) — e.g. approvals.
        Ok(_), Ok(request_method) ->
          on_server_request(state, line, msg, request_method)
        // Notification.
        _, Ok(_) -> broadcast(state, line)
        _, _ -> state
      }
    }
  }
}

fn on_response(
  state: State,
  id: Int,
  msg: Dynamic,
  error: Result(Dynamic, a),
) -> State {
  let reply = case error {
    Ok(err) ->
      Error(
        decode.run(err, decode.at(["message"], decode.string))
        |> result.unwrap("codex error"),
      )
    Error(_) ->
      Ok(
        decode.run(msg, decode.at(["result"], decode.dynamic))
        |> result.unwrap(dynamic.nil()),
      )
  }
  case state.status {
    Initializing(conn, init_id, queued) if id == init_id ->
      case reply {
        Ok(_) -> {
          write_notification(conn, "initialized", json.object([]))
          let state =
            State(..state, status: Running(conn), backoff: 0, last_error: "")
          let state = broadcast_status(state, "connected", "")
          // Flush requests queued while the handshake was in flight.
          let state =
            list.fold(list.reverse(queued), state, fn(state, queued_request) {
              let #(method, params, reply) = queued_request
              send_request(state, conn, method, params, Caller(reply))
            })
          // Re-open the threads this manager had loaded before the
          // disconnect, so their notifications flow on this connection too.
          list.fold(state.resumed, state, fn(state, thread_id) {
            send_request(
              state,
              conn,
              "thread/resume",
              json.object([#("threadId", json.string(thread_id))]),
              Discard,
            )
          })
        }
        Error(message) -> {
          io.println_error(
            "[codex " <> state.label <> "] initialize failed: " <> message,
          )
          list.each(queued, fn(q) { process.send(q.2, Error(message)) })
          close_conn(conn)
          let state =
            State(
              ..state,
              status: NotRunning,
              buffer: <<>>,
              decoder: ws.new_decoder(),
              last_error: message,
              backoff: state.backoff + 1,
            )
          let state = broadcast_status(state, "disconnected", message)
          schedule_reconnect(state)
          state
        }
      }
    _ ->
      case dict.get(state.pending, id) {
        Ok(Pending(method, thread, reply_to)) -> {
          case reply_to {
            Caller(subject) -> process.send(subject, reply)
            Discard -> Nil
          }
          let state = State(..state, pending: dict.delete(state.pending, id))
          track_resumed(state, method, thread, reply_to, reply)
        }
        Error(_) -> state
      }
  }
}

/// Maintain the set of threads to re-resume after a reconnect.
fn track_resumed(
  state: State,
  method: String,
  thread: Option(String),
  reply_to: ReplyTo,
  reply: Reply,
) -> State {
  case reply {
    Ok(result) ->
      case method {
        "thread/start" | "thread/resume" | "thread/fork" ->
          case jsonx.field_string(result, ["thread", "id"]) {
            Ok(id) if id != "" ->
              case list.contains(state.resumed, id) {
                True -> state
                False -> State(..state, resumed: [id, ..state.resumed])
              }
            _ -> state
          }
        "thread/unsubscribe" | "thread/archive" ->
          case thread {
            Some(id) ->
              State(
                ..state,
                resumed: list.filter(state.resumed, fn(t) { t != id }),
              )
            None -> state
          }
        _ -> state
      }
    Error(_) ->
      // An automatic re-resume that fails (thread deleted, archived
      // elsewhere) must not retry forever.
      case method, reply_to, thread {
        "thread/resume", Discard, Some(id) ->
          State(..state, resumed: list.filter(state.resumed, fn(t) { t != id }))
        _, _, _ -> state
      }
  }
}

/// We run codex with approvalPolicy "never", so approvals shouldn't normally
/// be requested. If anything does come through, auto-accept so turns never
/// hang. The request is also broadcast so the UI can show what happened.
fn on_server_request(
  state: State,
  line: BitArray,
  msg: Dynamic,
  method: String,
) -> State {
  let result = case string.contains(method, "requestApproval") {
    True -> json.object([#("decision", json.string("accept"))])
    False -> json.object([])
  }
  let id =
    decode.run(msg, decode.at(["id"], decode.dynamic))
    |> result.unwrap(dynamic.nil())
  case state.status {
    Running(conn) | Initializing(conn, _, _) ->
      write_line(
        conn,
        json.object([#("id", jsonx.to_json(id)), #("result", result)]),
      )
    _ -> Nil
  }
  broadcast(state, line)
}

fn broadcast(state: State, line: BitArray) -> State {
  case bit_array.to_string(line) {
    Ok(text) -> {
      list.each(state.subscribers, fn(s) { process.send(s.1, text) })
      state
    }
    Error(_) -> state
  }
}

/// Tell subscribers (the SSE stream) about remote connection transitions as a
/// synthetic notification. Local child restarts stay silent, as before.
fn broadcast_status(state: State, connection: String, error: String) -> State {
  case state.transport {
    Local(_) -> state
    _ ->
      broadcast(
        state,
        bit_array.from_string(
          json.to_string(
            json.object([
              #("method", json.string("yacwu/host/status")),
              #(
                "params",
                json.object([
                  #("host", json.string(state.label)),
                  #("state", json.string(connection)),
                  #("error", case error {
                    "" -> json.null()
                    _ -> json.string(error)
                  }),
                ]),
              ),
            ]),
          ),
        ),
      )
  }
}

// -- Disconnection ------------------------------------------------------------

/// The local child process exited.
fn on_child_exit(state: State, code: Int) -> actor.Next(State, Msg) {
  io.println_error(
    "[codex "
    <> state.label
    <> "] app-server exited with code "
    <> int.to_string(code),
  )
  actor.continue(fail_all(state, "codex app-server exited"))
}

/// A trapped exit signal from something linked to this manager.
///
/// The child's port dying abnormally (`epipe` after the app-server exited
/// under a write) is a recoverable disconnect: fail in-flight work and let
/// the next request respawn. Other ports' exits are lifecycle noise handled
/// through their own messages. A linked *process* exiting abnormally — the
/// registry going down — keeps its pre-trapping meaning: this manager dies
/// with it, and the link tears the child port down too.
fn on_linked_exit(
  state: State,
  exit: process.ExitMessage,
) -> actor.Next(State, Msg) {
  let current_conn_port = case state.status {
    Running(PortConn(port)) | Initializing(PortConn(port), _, _) ->
      erl_same_term(exit.pid, port)
    _ -> False
  }
  case current_conn_port, exit.reason {
    True, _ -> {
      io.println_error(
        "[codex "
        <> state.label
        <> "] app-server connection failed: "
        <> exit_reason_text(exit.reason),
      )
      actor.continue(fail_all(state, "codex app-server exited"))
    }
    False, process.Normal -> actor.continue(state)
    False, _ ->
      case erl_is_port(exit.pid) {
        True -> actor.continue(state)
        False -> actor.stop_abnormal(exit_reason_text(exit.reason))
      }
  }
}

fn exit_reason_text(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(reason) -> string.inspect(reason)
  }
}

/// The remote connection dropped: fail in-flight work, then reconnect with
/// backoff. The remote server keeps running — and keeps executing any
/// in-flight turns — so reconnecting re-attaches to live state.
fn on_disconnect(state: State, message: String) -> actor.Next(State, Msg) {
  io.println_error("[codex " <> state.label <> "] " <> message)
  case state.status {
    Running(SockConn(socket)) | Initializing(SockConn(socket), _, _) ->
      remote.close(socket)
    _ -> Nil
  }
  let state = fail_all(state, message)
  let state = State(..state, last_error: message, backoff: state.backoff + 1)
  let state = broadcast_status(state, "disconnected", message)
  schedule_reconnect(state)
  actor.continue(state)
}

fn fail_all(state: State, message: String) -> State {
  let failure = Error(message)
  dict.each(state.pending, fn(_, pending) {
    case pending.reply_to {
      Caller(subject) -> process.send(subject, failure)
      Discard -> Nil
    }
  })
  case state.status {
    Initializing(_, _, queued) | Connecting(queued) ->
      list.each(queued, fn(q) { process.send(q.2, failure) })
    _ -> Nil
  }
  State(
    ..state,
    status: NotRunning,
    pending: dict.new(),
    buffer: <<>>,
    decoder: ws.new_decoder(),
  )
}

fn close_conn(conn: Conn) -> Nil {
  case conn {
    PortConn(port) -> {
      // The port may already be gone (`port_close` on a closed port raises
      // `badarg`); closing a dead connection is a no-op, not a crash.
      let _ = exception.rescue(fn() { erl_port_close(port) })
      Nil
    }
    SockConn(socket) -> remote.close(socket)
  }
}

// -- Wire writing -------------------------------------------------------------

fn write_request(conn: Conn, id: Int, method: String, params: Json) -> Nil {
  write_line(
    conn,
    json.object([
      #("method", json.string(method)),
      #("id", json.int(id)),
      #("params", params),
    ]),
  )
}

fn write_notification(conn: Conn, method: String, params: Json) -> Nil {
  write_line(
    conn,
    json.object([#("method", json.string(method)), #("params", params)]),
  )
}

fn write_line(conn: Conn, message: Json) -> Nil {
  let text = json.to_string(message)
  case conn {
    PortConn(port) -> {
      // The child can exit at any moment, and `port_command` on a closed
      // port raises `badarg`. When that happens the port's exit is already
      // in our mailbox, so the write is safely dropped here and the pending
      // request fails cleanly when that message is processed.
      let _ =
        exception.rescue(fn() {
          erl_port_command(port, bit_array.from_string(text <> "\n"))
        })
      Nil
    }
    SockConn(socket) -> remote.send_text(socket, text)
  }
}
