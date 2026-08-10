//// Command-line and environment configuration.
////
//// Mirrors the original binary's interface:
////   yacwu [options] [address]
////   -H/--host, -p/--port, --unix <path>, --remote-user <users>, -h/--help
////   plus a positional `host:port` / `:port` / `host` / `port` address.
//// CLI flags override the HOST/PORT env vars.

import envoy
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string

pub const usage = "yacwu — minimalist Codex web UI

Usage: yacwu [options] [address]

Options:
  -H, --host <host>      listening host (default: 127.0.0.1, or $HOST)
  -p, --port <port>      listening port (default: 3000, or $PORT)
      --unix <path>      listen on a Unix domain socket instead of host:port
      --remote-user <u>  enable forward auth: require a Remote-User header
                         matching one of the comma-separated users
  -h, --help             show this help and exit

Address:
  A positional host:port may be given instead of -H/-p, e.g.
    yacwu 0.0.0.0:8080      yacwu :8080      yacwu 192.168.1.5

Environment:
  HOST, PORT          fallbacks for --host / --port
  YACWU_CWD           working directory for new Codex sessions
  YACWU_STATIC        directory holding the built web UI (default: ./build)
  YACWU_REMOTE_USERS  fallback for --remote-user
  YACWU_OAUTH_*       built-in OAuth/OIDC login: ISSUER (or AUTH_URL +
                      TOKEN_URL), CLIENT_ID, CLIENT_SECRET, USERINFO_URL,
                      SCOPES, USER_CLAIM, USERS, REDIRECT_URL, COOKIE_SECRET,
                      SESSION_TTL — see the README's Authentication section
"

pub type Config {
  Config(
    host: String,
    port: Int,
    unix: Option(String),
    static_dir: String,
    help: Bool,
  )
}

pub type ParseError {
  UnknownOption(flag: String)
  MissingValue(flag: String)
  InvalidPort(raw: String)
}

type Opts {
  Opts(
    host: Option(String),
    port: Option(String),
    unix: Option(String),
    remote_user: Option(String),
    help: Bool,
  )
}

/// Parse CLI arguments and the environment into a runtime config. On success
/// this also applies the `--remote-user` flag to `YACWU_REMOTE_USERS` so the
/// per-request auth check sees it.
pub fn load(args: List(String)) -> Result(Config, ParseError) {
  use opts <- result.try(parse_args(
    args,
    Opts(host: None, port: None, unix: None, remote_user: None, help: False),
  ))
  case opts.remote_user {
    Some(users) -> envoy.set("YACWU_REMOTE_USERS", users)
    None -> Nil
  }
  let host =
    opts.host
    |> option.lazy_unwrap(fn() {
      envoy.get("HOST") |> result.unwrap("127.0.0.1")
    })
  let port_raw =
    opts.port
    |> option.lazy_unwrap(fn() { envoy.get("PORT") |> result.unwrap("3000") })
  use port <- result.try(case opts.unix {
    Some(_) -> Ok(0)
    None ->
      case int.parse(port_raw) {
        Ok(port) if port >= 0 && port <= 65_535 -> Ok(port)
        _ -> Error(InvalidPort(port_raw))
      }
  })
  let static_dir = envoy.get("YACWU_STATIC") |> result.unwrap("./build")
  Ok(Config(
    host: host,
    port: port,
    unix: opts.unix,
    static_dir: static_dir,
    help: opts.help,
  ))
}

fn parse_args(args: List(String), opts: Opts) -> Result(Opts, ParseError) {
  case args {
    [] -> Ok(opts)
    [arg, ..rest] -> {
      // Support --flag=value as well as --flag value.
      let #(flag, inline, rest) = case
        string.starts_with(arg, "--"),
        string.split_once(arg, "=")
      {
        True, Ok(#(flag, value)) -> #(flag, Some(value), rest)
        _, _ -> #(arg, None, rest)
      }
      let value = fn() {
        case inline, rest {
          Some(value), _ -> Ok(#(value, rest))
          None, [value, ..rest] -> Ok(#(value, rest))
          None, [] -> Error(MissingValue(flag))
        }
      }
      case flag {
        "-h" | "--help" -> parse_args(rest, Opts(..opts, help: True))
        "-H" | "--host" -> {
          use #(host, rest) <- result.try(value())
          parse_args(rest, Opts(..opts, host: Some(host)))
        }
        "-p" | "--port" -> {
          use #(port, rest) <- result.try(value())
          parse_args(rest, Opts(..opts, port: Some(port)))
        }
        "--unix" -> {
          use #(path, rest) <- result.try(value())
          parse_args(rest, Opts(..opts, unix: Some(path)))
        }
        "--remote-user" -> {
          use #(users, rest) <- result.try(value())
          parse_args(rest, Opts(..opts, remote_user: Some(users)))
        }
        _ ->
          case string.starts_with(flag, "-") {
            True -> Error(UnknownOption(arg))
            False -> parse_args(rest, parse_address(arg, opts))
          }
      }
    }
  }
}

/// Split a "host:port" / ":port" / "host" / "port" positional token.
fn parse_address(addr: String, opts: Opts) -> Opts {
  case string.contains(addr, ":") {
    True -> {
      // Split on the *last* colon so IPv6-ish hosts keep their colons.
      let parts = string.split(addr, ":")
      let port = list.last(parts) |> result.unwrap("")
      let host =
        list.take(parts, list.length(parts) - 1)
        |> string.join(":")
      let opts = case host {
        "" -> opts
        host -> Opts(..opts, host: Some(host))
      }
      case port {
        "" -> opts
        port -> Opts(..opts, port: Some(port))
      }
    }
    False -> {
      let assert Ok(digits) = regexp.from_string("^[0-9]+$")
      case regexp.check(digits, addr) {
        True -> Opts(..opts, port: Some(addr))
        False -> Opts(..opts, host: Some(addr))
      }
    }
  }
}
