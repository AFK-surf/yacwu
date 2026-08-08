//// yacwu server entry point: parses CLI/env config, starts the codex manager
//// and model-override store under a supervisor, and serves the HTTP API +
//// static web UI with mist.

import argv
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import mist
import yacwu/codex
import yacwu/config
import yacwu/model_state
import yacwu/router
import yacwu/unix_proxy

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

pub fn main() -> Nil {
  let conf = case config.load(argv.load().arguments) {
    Ok(conf) -> conf
    Error(config.UnknownOption(flag)) -> {
      io.println_error("yacwu: unknown option '" <> flag <> "'\n")
      io.println_error(config.usage)
      halt(1)
      panic as "unreachable"
    }
    Error(config.MissingValue(flag)) -> {
      io.println_error("yacwu: missing value for '" <> flag <> "'\n")
      io.println_error(config.usage)
      halt(1)
      panic as "unreachable"
    }
    Error(config.InvalidPort(raw)) -> {
      io.println_error("yacwu: invalid port '" <> raw <> "'")
      halt(1)
      panic as "unreachable"
    }
  }
  case conf.help {
    True -> {
      io.print(config.usage)
      halt(0)
    }
    False -> serve(conf)
  }
}

fn serve(conf: config.Config) -> Nil {
  let codex_name = process.new_name("yacwu_codex")
  let store_name = process.new_name("yacwu_models")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(codex.supervised(codex_name))
    |> supervisor.add(model_state.supervised(store_name))
    |> supervisor.start

  let ctx =
    router.Context(
      codex: codex_name,
      store: store_name,
      static_dir: conf.static_dir,
    )

  let listen = case conf.unix {
    Some(path) -> {
      // mist can't bind Unix sockets, so bind loopback on an ephemeral port
      // and relay the socket's bytes to it.
      let bound = process.new_subject()
      let assert Ok(_) =
        mist.new(router.handler(ctx))
        |> mist.bind("127.0.0.1")
        |> mist.port(0)
        |> mist.after_start(fn(port, _scheme, _ip) { process.send(bound, port) })
        |> mist.start
      let assert Ok(port) = process.receive(bound, 10_000)
      case unix_proxy.start(path, port) {
        Ok(Nil) -> Nil
        Error(message) -> {
          io.println_error("yacwu: " <> message)
          halt(1)
        }
      }
      "unix:" <> path
    }
    None -> {
      let assert Ok(_) =
        mist.new(router.handler(ctx))
        |> mist.bind(conf.host)
        |> mist.port(conf.port)
        |> mist.start
      "http://" <> conf.host <> ":" <> int.to_string(conf.port)
    }
  }

  io.println("yacwu listening on " <> listen)
  let cwd_note =
    envoy.get("YACWU_CWD")
    |> result.unwrap("(home)")
  io.println("  working directory for new sessions: " <> cwd_note)
  process.sleep_forever()
}
