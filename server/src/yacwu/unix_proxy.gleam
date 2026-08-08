//// `--unix <path>` support.
////
//// mist/glisten cannot listen on Unix domain sockets, so we accept
//// connections on the socket ourselves and relay bytes to the real HTTP
//// listener bound on loopback. The relay is protocol-agnostic, so HTTP,
//// SSE streaming, and the forward-auth headers all pass through untouched.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import simplifile

pub type Socket

type LocalAddress {
  Local(String)
}

type TcpOption {
  Binary
  Active(Bool)
  Ifaddr(LocalAddress)
}

@external(erlang, "gen_tcp", "listen")
fn tcp_listen(port: Int, options: List(TcpOption)) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "accept")
fn tcp_accept(socket: Socket) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "connect")
fn tcp_connect(
  host: #(Int, Int, Int, Int),
  port: Int,
  options: List(TcpOption),
) -> Result(Socket, Dynamic)

@external(erlang, "gen_tcp", "recv")
fn tcp_recv(socket: Socket, length: Int) -> Result(BitArray, Dynamic)

@external(erlang, "gen_tcp", "send")
fn tcp_send(socket: Socket, data: BitArray) -> Dynamic

@external(erlang, "gen_tcp", "close")
fn tcp_close(socket: Socket) -> Dynamic

@external(erlang, "gen_tcp", "controlling_process")
fn tcp_controlling_process(socket: Socket, owner: process.Pid) -> Dynamic

/// Listen on `path` and relay every connection to 127.0.0.1:`port`.
pub fn start(path: String, port: Int) -> Result(Nil, String) {
  // Remove a stale socket file from a previous run; listen would fail on it.
  let _ = simplifile.delete(path)
  case tcp_listen(0, [Binary, Active(False), Ifaddr(Local(path))]) {
    Error(_) -> Error("could not listen on unix socket " <> path)
    Ok(listener) -> {
      process.spawn_unlinked(fn() { accept_loop(listener, port) })
      Ok(Nil)
    }
  }
}

fn accept_loop(listener: Socket, port: Int) -> Nil {
  case tcp_accept(listener) {
    Error(_) -> Nil
    Ok(client) -> {
      case tcp_connect(#(127, 0, 0, 1), port, [Binary, Active(False)]) {
        Error(_) -> {
          let _ = tcp_close(client)
          Nil
        }
        Ok(upstream) -> {
          let a = process.spawn_unlinked(fn() { pump(client, upstream) })
          let b = process.spawn_unlinked(fn() { pump(upstream, client) })
          let _ = tcp_controlling_process(client, a)
          let _ = tcp_controlling_process(upstream, b)
          Nil
        }
      }
      accept_loop(listener, port)
    }
  }
}

/// Copy bytes from one socket to the other until either side closes.
///
/// The pump may briefly lose the ownership race against
/// `controlling_process`; `not_owner` errors are retried.
fn pump(from: Socket, to: Socket) -> Nil {
  case tcp_recv(from, 0) {
    Ok(data) -> {
      let _ = tcp_send(to, data)
      pump(from, to)
    }
    Error(reason) ->
      case is_not_owner(reason) {
        True -> {
          process.sleep(5)
          pump(from, to)
        }
        False -> {
          let _ = tcp_close(from)
          let _ = tcp_close(to)
          Nil
        }
      }
  }
}

fn is_not_owner(reason: Dynamic) -> Bool {
  decode.run(reason, atom.decoder()) == Ok(atom.create("not_owner"))
}
