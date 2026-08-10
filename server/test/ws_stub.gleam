//// Test double for a persistent `codex app-server --listen unix://…`.
////
//// Listens on a Unix socket, performs the WebSocket server handshake, and
//// answers a tiny scripted subset of the app-server protocol: `initialize`
//// gets an empty result, `thread/resume` echoes the thread id back, and any
//// other request gets `{"ok": true}`. Every received request method is
//// reported to the test's subject, and the test can kill the current
//// connection to exercise the manager's reconnect path.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile
import yacwu/ws

pub type Socket

type TcpOption {
  Binary
  Active(Bool)
  Ifaddr(NetAddress)
}

type NetAddress {
  Local(String)
}

@external(erlang, "gen_tcp", "listen")
fn tcp_listen(port: Int, options: List(TcpOption)) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "accept")
fn tcp_accept(socket: Socket, timeout: Int) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "recv")
fn tcp_recv(
  socket: Socket,
  length: Int,
  timeout: Int,
) -> Result(BitArray, Dynamic)

@external(erlang, "gen_tcp", "send")
fn tcp_send(socket: Socket, data: BitArray) -> Dynamic

@external(erlang, "gen_tcp", "close")
fn tcp_close(socket: Socket) -> Dynamic

/// What the stub reports back to the test.
pub type Event {
  Attached
  Received(method: String)
}

/// Test-side control over the stub.
pub type Control {
  /// Drop the current connection (the server keeps listening).
  Kill
  /// Shut the stub down entirely.
  Stop
}

/// Start a stub server on `path`. Events flow to `events`; the returned
/// subject controls the stub. The socket file is (re)created fresh.
pub fn start(path: String, events: Subject(Event)) -> Subject(Control) {
  let ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let _ = simplifile.delete(path)
      let assert Ok(listener) =
        tcp_listen(0, [Binary, Active(False), Ifaddr(Local(path))])
      // Hand a control subject owned by *this* process to the test.
      let control = process.new_subject()
      process.send(ready, control)
      accept_loop(listener, events, control)
    })
  let assert Ok(control) = process.receive(ready, 5000)
  control
}

fn accept_loop(
  listener: Socket,
  events: Subject(Event),
  control: Subject(Control),
) -> Nil {
  case process.receive(control, 0) {
    Ok(Stop) -> {
      let _ = tcp_close(listener)
      Nil
    }
    Ok(Kill) -> accept_loop(listener, events, control)
    Error(_) ->
      case tcp_accept(listener, 250) {
        Error(_) -> accept_loop(listener, events, control)
        Ok(client) -> {
          case handshake(client) {
            Ok(leftover) -> {
              process.send(events, Attached)
              serve(client, ws.new_decoder(), leftover, events, control)
            }
            Error(_) -> {
              let _ = tcp_close(client)
              Nil
            }
          }
          accept_loop(listener, events, control)
        }
      }
  }
}

fn handshake(client: Socket) -> Result(BitArray, Nil) {
  use #(header, leftover) <- result.try(read_header(client, <<>>, 20))
  use key <- result.try(
    string.split(header, "\r\n")
    |> list.find_map(fn(line) {
      case string.split_once(line, ":") {
        Ok(#(name, value)) ->
          case string.lowercase(string.trim(name)) == "sec-websocket-key" {
            True -> Ok(string.trim(value))
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    }),
  )
  let response =
    "HTTP/1.1 101 Switching Protocols\r\n"
    <> "Upgrade: websocket\r\n"
    <> "Connection: Upgrade\r\n"
    <> "Sec-WebSocket-Accept: "
    <> ws.accept_key(key)
    <> "\r\n\r\n"
  let _ = tcp_send(client, bit_array.from_string(response))
  Ok(leftover)
}

fn read_header(
  client: Socket,
  buffer: BitArray,
  attempts: Int,
) -> Result(#(String, BitArray), Nil) {
  case ws.split_header(buffer) {
    Ok(split) -> Ok(split)
    Error(_) ->
      case attempts <= 0 {
        True -> Error(Nil)
        False ->
          case tcp_recv(client, 0, 5000) {
            Error(_) -> Error(Nil)
            Ok(data) ->
              read_header(
                client,
                bit_array.concat([buffer, data]),
                attempts - 1,
              )
          }
      }
  }
}

fn serve(
  client: Socket,
  decoder: ws.Decoder,
  data: BitArray,
  events: Subject(Event),
  control: Subject(Control),
) -> Nil {
  let #(frames, decoder) = ws.push(decoder, data)
  let closed =
    list.any(frames, fn(frame) {
      case frame {
        ws.Text(text) -> {
          handle_message(client, text, events)
          False
        }
        ws.Ping(payload) -> {
          let _ = tcp_send(client, ws.encode(ws.Pong(payload), None))
          False
        }
        ws.Close -> True
        _ -> False
      }
    })
  case closed {
    True -> {
      let _ = tcp_close(client)
      Nil
    }
    False ->
      case process.receive(control, 0) {
        Ok(Kill) -> {
          let _ = tcp_close(client)
          Nil
        }
        Ok(Stop) -> {
          let _ = tcp_close(client)
          Nil
        }
        Error(_) ->
          case tcp_recv(client, 0, 200) {
            Ok(data) -> serve(client, decoder, data, events, control)
            Error(reason) ->
              case is_timeout(reason) {
                True -> serve(client, decoder, <<>>, events, control)
                False -> {
                  let _ = tcp_close(client)
                  Nil
                }
              }
          }
      }
  }
}

fn is_timeout(reason: Dynamic) -> Bool {
  decode.run(reason, atom.decoder()) == Ok(atom.create("timeout"))
}

fn handle_message(client: Socket, text: String, events: Subject(Event)) -> Nil {
  let parsed = json.parse(text, decode.dynamic)
  let method =
    parsed
    |> result.replace_error(Nil)
    |> result.try(fn(msg) {
      decode.run(msg, decode.at(["method"], decode.string))
      |> result.replace_error(Nil)
    })
  let id =
    parsed
    |> result.replace_error(Nil)
    |> result.try(fn(msg) {
      decode.run(msg, decode.at(["id"], decode.int))
      |> result.replace_error(Nil)
    })
  case method {
    Error(_) -> Nil
    Ok(method) -> {
      process.send(events, Received(method))
      case id {
        // Notifications (initialized, …) get no reply.
        Error(_) -> Nil
        Ok(id) -> {
          let result = case method {
            "thread/resume" -> {
              let thread_id =
                parsed
                |> result.replace_error(Nil)
                |> result.try(fn(msg) {
                  decode.run(
                    msg,
                    decode.at(["params", "threadId"], decode.string),
                  )
                  |> result.replace_error(Nil)
                })
                |> result.unwrap("thr_unknown")
              json.object([
                #("thread", json.object([#("id", json.string(thread_id))])),
              ])
            }
            _ -> json.object([#("ok", json.bool(True))])
          }
          let reply = json.object([#("id", json.int(id)), #("result", result)])
          let _ =
            tcp_send(client, ws.encode(ws.Text(json.to_string(reply)), None))
          Nil
        }
      }
    }
  }
}
