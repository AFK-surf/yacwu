//// Registry of codex managers, one per host.
////
//// "local" always exists and drives the classic stdio child. Remote hosts
//// come from ~/.ssh/config (see `ssh_config`) and get a manager started
//// lazily the first time something addresses them — starting a manager is
//// cheap and does not connect; the connection happens on its first request.
////
//// The registry also keeps the thread→host routing map, rebuilt at runtime
//// from thread listings and creations (yacwu stores nothing on disk), so
//// thread-scoped API calls can omit the host once a thread has been seen.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import yacwu/codex.{type Codex}
import yacwu/ssh_config

pub const local = "local"

pub opaque type Msg {
  Resolve(
    hint: Option(String),
    thread: Option(String),
    reply: Subject(Result(#(String, Codex), String)),
  )
  RecordThreads(host: String, threads: List(String))
  SubscribeAll(owner: Pid, subject: Subject(String))
  RunningManagers(reply: Subject(List(#(String, Codex))))
  Down(pid: Pid)
}

pub type Registry =
  Name(Msg)

/// Pick the manager for a request: an explicit host hint wins, then the
/// thread routing map, then local. Starts the host's manager when needed.
pub fn resolve(
  registry: Registry,
  hint: Option(String),
  thread: Option(String),
) -> Result(#(String, Codex), String) {
  process.call_forever(process.named_subject(registry), Resolve(hint, thread, _))
}

/// Remember which host a batch of thread ids lives on.
pub fn record_threads(
  registry: Registry,
  host: String,
  threads: List(String),
) -> Nil {
  process.send(process.named_subject(registry), RecordThreads(host, threads))
}

/// Subscribe to notifications from every manager, current and future (used
/// by the SSE stream). Dropped automatically when `owner` exits.
pub fn subscribe_all(
  registry: Registry,
  owner: Pid,
  subject: Subject(String),
) -> Nil {
  process.send(process.named_subject(registry), SubscribeAll(owner, subject))
}

/// The managers currently running, for cross-host aggregation.
pub fn running(registry: Registry) -> List(#(String, Codex)) {
  process.call_forever(process.named_subject(registry), RunningManagers)
}

type State {
  State(
    managers: Dict(String, #(Codex, Pid)),
    threads: Dict(String, String),
    subscribers: List(#(Pid, Subject(String))),
  )
}

pub fn supervised(
  name: Registry,
) -> supervision.ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name) })
}

fn start(name: Registry) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid: pid, ..) -> Down(pid)
          process.PortDown(..) -> Down(process.self())
        }
      })
    let state =
      State(managers: dict.new(), threads: dict.new(), subscribers: [])
    // The local manager always exists.
    let state = case start_manager(state, local) {
      Ok(#(state, _)) -> state
      Error(_) -> state
    }
    state
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Resolve(hint, thread, reply) -> {
      let host = case hint, thread {
        Some(host), _ if host != "" -> host
        _, Some(thread) ->
          dict.get(state.threads, thread) |> result.unwrap(local)
        _, _ -> local
      }
      case ensure_manager(state, host) {
        Ok(#(state, codex)) -> {
          process.send(reply, Ok(#(host, codex)))
          actor.continue(state)
        }
        Error(message) -> {
          process.send(reply, Error(message))
          actor.continue(state)
        }
      }
    }
    RecordThreads(host, threads) ->
      actor.continue(
        State(
          ..state,
          threads: list.fold(threads, state.threads, fn(acc, thread) {
            dict.insert(acc, thread, host)
          }),
        ),
      )
    SubscribeAll(owner, subject) -> {
      let _ = process.monitor(owner)
      dict.each(state.managers, fn(_, manager) {
        codex.subscribe(manager.0, owner, subject)
      })
      actor.continue(
        State(..state, subscribers: [#(owner, subject), ..state.subscribers]),
      )
    }
    RunningManagers(reply) -> {
      process.send(
        reply,
        dict.to_list(state.managers)
          |> list.map(fn(entry) { #(entry.0, entry.1.0) }),
      )
      actor.continue(state)
    }
    Down(pid) ->
      actor.continue(
        State(
          ..state,
          managers: dict.filter(state.managers, fn(_, manager) {
            manager.1 != pid
          }),
          subscribers: list.filter(state.subscribers, fn(s) { s.0 != pid }),
        ),
      )
  }
}

/// Look up a host's manager, starting it if this is the first time the host
/// is addressed. Unknown hosts (not "local", not in ~/.ssh/config) error.
fn ensure_manager(
  state: State,
  host: String,
) -> Result(#(State, Codex), String) {
  case dict.get(state.managers, host) {
    Ok(manager) -> Ok(#(state, manager.0))
    Error(_) ->
      case host == local || list.contains(ssh_config.discover(), host) {
        False -> Error("unknown host: " <> host)
        True -> start_manager(state, host)
      }
  }
}

fn start_manager(
  state: State,
  host: String,
) -> Result(#(State, Codex), String) {
  let name: Codex = process.new_name("yacwu_codex")
  let transport = case host == local {
    True -> codex.Local
    False -> codex.Ssh(host)
  }
  case codex.start(name, host, transport) {
    Error(_) -> Error("could not start the manager for " <> host)
    Ok(started) -> {
      let _ = process.monitor(started.pid)
      // Existing stream subscribers hear the new host too.
      list.each(state.subscribers, fn(subscriber) {
        codex.subscribe(name, subscriber.0, subscriber.1)
      })
      Ok(#(
        State(
          ..state,
          managers: dict.insert(state.managers, host, #(name, started.pid)),
        ),
        name,
      ))
    }
  }
}
