//// Manager for a single `codex app-server` process.
////
//// Multiplexes many threads (sessions) over one stdio JSON-RPC connection.
//// Every codex notification carries `params.threadId`, so the frontend can
//// route events to the right session. There is no database here: codex
//// persists its own sessions on disk and we read them back via `thread/list`
//// and `thread/read`.
////
//// The app-server process is spawned lazily on the first request and
//// respawned on the next request after it exits, mirroring the behaviour of
//// the original TypeScript implementation.

import envoy
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
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import yacwu/jsonx

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

pub type Reply =
  Result(Dynamic, String)

pub opaque type Msg {
  Request(method: String, params: Json, reply: Subject(Reply))
  Notify(method: String, params: Json)
  Subscribe(owner: Pid, subject: Subject(String))
  GetOsPid(reply: Subject(Result(Int, Nil)))
  PortData(BitArray)
  PortExit(Int)
  SubscriberDown(pid: Pid)
  Ignore
}

/// A handle used by HTTP handlers to talk to the manager.
pub type Codex =
  Name(Msg)

/// The working directory codex runs in (`YACWU_CWD`, defaulting to `$HOME`).
pub fn default_cwd() -> String {
  case envoy.get("YACWU_CWD") {
    Ok(cwd) if cwd != "" -> cwd
    _ -> envoy.get("HOME") |> result.unwrap("/")
  }
}

/// Send a JSON-RPC request to codex and wait for its response.
pub fn request(codex: Codex, method: String, params: Json) -> Reply {
  process.call_forever(process.named_subject(codex), Request(method, params, _))
}

/// Send a JSON-RPC notification (no response expected).
pub fn notify(codex: Codex, method: String, params: Json) -> Nil {
  process.send(process.named_subject(codex), Notify(method, params))
}

/// Subscribe `subject` to every codex notification, formatted as raw JSON
/// strings. The subscription is removed automatically when `owner` exits.
pub fn subscribe(codex: Codex, owner: Pid, subject: Subject(String)) -> Nil {
  process.send(process.named_subject(codex), Subscribe(owner, subject))
}

/// OS pid of the managed `codex app-server` process, if it is running.
pub fn os_pid(codex: Codex) -> Result(Int, Nil) {
  process.call_forever(process.named_subject(codex), GetOsPid)
}

/// Child spec for running the manager under a supervisor.
pub fn supervised(name: Codex) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name) })
}

fn start(name: Codex) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid: pid, ..) -> SubscriberDown(pid)
          process.PortDown(..) -> Ignore
        }
      })
      |> process.select_other(classify_other)
    initial_state()
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

type Status {
  NotRunning
  Initializing(port: Port, init_id: Int, queued: List(Queued))
  Running(port: Port)
}

type State {
  State(
    status: Status,
    next_id: Int,
    pending: Dict(Int, Subject(Reply)),
    subscribers: List(#(Pid, Subject(String))),
    buffer: BitArray,
  )
}

fn initial_state() -> State {
  State(
    status: NotRunning,
    next_id: 1,
    pending: dict.new(),
    subscribers: [],
    buffer: <<>>,
  )
}

/// Raw port messages arrive as `{Port, {data, Bin}}` or
/// `{Port, {exit_status, Code}}` tuples rather than typed subject messages.
fn classify_other(message: Dynamic) -> Msg {
  case decode.run(message, decode.at([1, 1], decode.bit_array)) {
    Ok(data) -> PortData(data)
    Error(_) ->
      case decode.run(message, decode.at([1, 1], decode.int)) {
        Ok(code) -> PortExit(code)
        Error(_) -> Ignore
      }
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Request(method, params, reply) -> on_request(state, method, params, reply)
    Notify(method, params) -> {
      case state.status {
        Running(port) | Initializing(port, _, _) ->
          write_notification(port, method, params)
        NotRunning -> Nil
      }
      actor.continue(state)
    }
    Subscribe(owner, subject) -> {
      let _ = process.monitor(owner)
      actor.continue(
        State(..state, subscribers: [#(owner, subject), ..state.subscribers]),
      )
    }
    SubscriberDown(pid) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.filter(state.subscribers, fn(s) { s.0 != pid }),
        ),
      )
    GetOsPid(reply) -> {
      let pid = case state.status {
        Running(port) | Initializing(port, _, _) ->
          decode.run(
            erl_port_info(port, atom.create("os_pid")),
            decode.at([1], decode.int),
          )
          |> result.replace_error(Nil)
        NotRunning -> Error(Nil)
      }
      process.send(reply, pid)
      actor.continue(state)
    }
    PortData(data) -> on_port_data(state, data)
    PortExit(code) -> on_port_exit(state, code)
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
    NotRunning -> {
      let port = spawn_codex()
      let init_id = state.next_id
      write_request(
        port,
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
          #(
            "capabilities",
            json.object([#("experimentalApi", json.bool(True))]),
          ),
        ]),
      )
      actor.continue(
        State(
          ..state,
          status: Initializing(port, init_id, [#(method, params, reply)]),
          next_id: init_id + 1,
        ),
      )
    }
    Initializing(port, init_id, queued) ->
      actor.continue(
        State(
          ..state,
          status: Initializing(port, init_id, [
            #(method, params, reply),
            ..queued
          ]),
        ),
      )
    Running(port) -> {
      let id = state.next_id
      write_request(port, id, method, params)
      actor.continue(
        State(
          ..state,
          next_id: id + 1,
          pending: dict.insert(state.pending, id, reply),
        ),
      )
    }
  }
}

fn spawn_codex() -> Port {
  erl_open_port(SpawnExecutable("/usr/bin/env"), [
    Binary,
    ExitStatus,
    UseStdio,
    Hide,
    Args(["codex", "app-server"]),
    Cd(default_cwd()),
  ])
}

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
    Initializing(port, init_id, queued) if id == init_id ->
      case reply {
        Ok(_) -> {
          write_notification(port, "initialized", json.object([]))
          // Flush requests queued while the handshake was in flight.
          list.fold(
            list.reverse(queued),
            State(..state, status: Running(port)),
            fn(state, queued_request) {
              let #(method, params, reply) = queued_request
              let id = state.next_id
              write_request(port, id, method, params)
              State(
                ..state,
                next_id: id + 1,
                pending: dict.insert(state.pending, id, reply),
              )
            },
          )
        }
        Error(message) -> {
          io.println_error("[codex] initialize failed: " <> message)
          list.each(queued, fn(q) { process.send(q.2, Error(message)) })
          let _ = erl_port_close(port)
          State(..state, status: NotRunning, buffer: <<>>)
        }
      }
    _ ->
      case dict.get(state.pending, id) {
        Ok(subject) -> {
          process.send(subject, reply)
          State(..state, pending: dict.delete(state.pending, id))
        }
        Error(_) -> state
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
    Running(port) | Initializing(port, _, _) ->
      write_line(
        port,
        json.object([#("id", jsonx.to_json(id)), #("result", result)]),
      )
    NotRunning -> Nil
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

fn on_port_exit(state: State, code: Int) -> actor.Next(State, Msg) {
  io.println_error(
    "[codex] app-server exited with code " <> int.to_string(code),
  )
  let failure = Error("codex app-server exited")
  dict.each(state.pending, fn(_, subject) { process.send(subject, failure) })
  case state.status {
    Initializing(_, _, queued) ->
      list.each(queued, fn(q) { process.send(q.2, failure) })
    _ -> Nil
  }
  actor.continue(
    State(..state, status: NotRunning, pending: dict.new(), buffer: <<>>),
  )
}

fn write_request(port: Port, id: Int, method: String, params: Json) -> Nil {
  write_line(
    port,
    json.object([
      #("method", json.string(method)),
      #("id", json.int(id)),
      #("params", params),
    ]),
  )
}

fn write_notification(port: Port, method: String, params: Json) -> Nil {
  write_line(
    port,
    json.object([#("method", json.string(method)), #("params", params)]),
  )
}

fn write_line(port: Port, message: Json) -> Nil {
  let data = bit_array.from_string(json.to_string(message) <> "\n")
  let _ = erl_port_command(port, data)
  Nil
}
