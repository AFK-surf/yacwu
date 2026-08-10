//// End-to-end exercise of the remote transport against a stub app-server:
//// WebSocket attach + initialize handshake, request/response, notification
//// broadcast, and — the point of the whole design — automatic reconnect with
//// thread re-resume after the connection drops while the server persists.

import gleam/erlang/process
import gleam/json
import gleam/string
import gleeunit/should
import simplifile
import ws_stub
import yacwu/codex
import yacwu/jsonx

const sock_path = "/tmp/yacwu-remote-link-test.sock"

fn drain_events(events: process.Subject(ws_stub.Event)) -> Nil {
  case process.receive(events, 0) {
    Ok(_) -> drain_events(events)
    Error(_) -> Nil
  }
}

/// Wait until the stub reports receiving `method` (events arrive in order).
fn await_received(
  events: process.Subject(ws_stub.Event),
  method: String,
  timeout: Int,
) -> Result(Nil, String) {
  case process.receive(events, timeout) {
    Error(_) -> Error("timed out waiting for " <> method)
    Ok(ws_stub.Received(received)) if received == method -> Ok(Nil)
    Ok(_) -> await_received(events, method, timeout)
  }
}

// Waits on real sockets and reconnect backoff timers; gleeunit scales the
// eunit timeout so the pauses fit comfortably.
pub fn remote_link_reconnect_test() -> Nil {
  let events = process.new_subject()
  let control = ws_stub.start(sock_path, events)

  let name: codex.Codex = process.new_name("codex_link_test")
  let assert Ok(_) = codex.start(name, "stub", codex.UnixSock(sock_path))

  // Subscribe to the notification stream to observe host status events.
  let stream = process.new_subject()
  codex.subscribe(name, process.self(), stream)

  // First request triggers connect + initialize, then flushes the request.
  let assert Ok(_) = codex.request(name, "test/ping", json.object([]))
  let assert Ok(Nil) = await_received(events, "initialize", 5000)
  let assert Ok(Nil) = await_received(events, "test/ping", 5000)

  // Info reflects a live connection.
  should.equal(codex.info(name).state, "connected")

  // The subscribers saw the connecting/connected transitions.
  let assert Ok(Nil) = await_stream_contains(stream, "\"connected\"", 5000)

  // Resume a thread: the manager should remember it for reconnects.
  let assert Ok(resumed) =
    codex.request(
      name,
      "thread/resume",
      json.object([#("threadId", json.string("thr_test_1"))]),
    )
  should.equal(jsonx.field_string(resumed, ["thread", "id"]), Ok("thr_test_1"))

  drain_events(events)

  // Sever the connection while the "server" stays up — the ssh drop /
  // laptop-sleep scenario. The manager must reconnect on its own (backoff)
  // and re-resume the thread without any caller involvement.
  process.send(control, ws_stub.Kill)
  let assert Ok(Nil) = await_stream_contains(stream, "\"disconnected\"", 5000)

  let assert Ok(Nil) = await_received(events, "initialize", 15_000)
  let assert Ok(Nil) = await_received(events, "thread/resume", 5000)

  // And the link is usable again for ordinary requests.
  let assert Ok(_) = codex.request(name, "test/after", json.object([]))
  should.equal(codex.info(name).state, "connected")

  process.send(control, ws_stub.Stop)
  let _ = simplifile.delete(sock_path)
  Nil
}

/// Wait for a raw notification containing `needle` (e.g. a host status).
fn await_stream_contains(
  stream: process.Subject(String),
  needle: String,
  timeout: Int,
) -> Result(Nil, String) {
  case process.receive(stream, timeout) {
    Error(_) -> Error("timed out waiting for notification " <> needle)
    Ok(line) ->
      case string.contains(line, needle) {
        True -> Ok(Nil)
        False -> await_stream_contains(stream, needle, timeout)
      }
  }
}
