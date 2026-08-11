//// Alternative local app-server backends, declared via `YACWU_BACKENDS`.
////
//// Anything that speaks the codex app-server protocol over stdio can stand
//// in for `codex app-server` — for example claude-codex, which serves the
//// protocol backed by Claude Code. Each backend is a named command; the name
//// appears in the host picker alongside "local" and its manager runs the
//// command as a child process on this machine, with the same working
//// directory, file browser, Git viewer and in-use detection as the default
//// local codex.
////
//// Format: semicolon-separated `name=command` entries, e.g.
////
////   YACWU_BACKENDS="claude=node /opt/claude-codex/dist/src/adapter.mjs"
////
//// The command is split on whitespace into argv (no quoting) and launched
//// via /usr/bin/env, so bare program names resolve on $PATH and absolute
//// paths work as-is. Entries with an invalid name (empty, "local", unsafe
//// characters), an empty command, or a name an earlier entry already used
//// are dropped. A backend name shadows an identical ~/.ssh/config alias.
////
//// Like ssh_config discovery, the environment is re-read on demand so a
//// changed variable shows up without dropping state — though under a normal
//// launch it is fixed at yacwu's start.

import envoy
import gleam/list
import gleam/result
import gleam/string
import yacwu/ssh_config

/// One configured backend: the host name it is addressed by, and the argv of
/// its app-server command.
pub type Backend {
  Backend(name: String, command: List(String))
}

/// The backends configured right now (`YACWU_BACKENDS`, re-read on demand).
pub fn discover() -> List(Backend) {
  envoy.get("YACWU_BACKENDS")
  |> result.unwrap("")
  |> parse
}

/// Parse a `YACWU_BACKENDS` value, dropping invalid entries.
pub fn parse(raw: String) -> List(Backend) {
  string.split(raw, ";")
  |> list.filter_map(fn(entry) {
    case string.split_once(entry, "=") {
      Error(_) -> Error(Nil)
      Ok(#(name, command)) -> {
        let name = string.trim(name)
        let command =
          string.split(command, " ")
          |> list.map(string.trim)
          |> list.filter(fn(token) { token != "" })
        case valid_name(name), command {
          True, [_, ..] -> Ok(Backend(name, command))
          _, _ -> Error(Nil)
        }
      }
    }
  })
  |> list.fold([], fn(acc, backend) {
    case list.any(acc, fn(seen: Backend) { seen.name == backend.name }) {
      True -> acc
      False -> [backend, ..acc]
    }
  })
  |> list.reverse
}

/// The app-server argv for `name`, when it names a configured backend.
pub fn command(name: String) -> Result(List(String), Nil) {
  discover()
  |> list.find(fn(backend) { backend.name == name })
  |> result.map(fn(backend) { backend.command })
}

/// Backend names must not collide with the built-in local host and must be
/// safe in URLs and process labels — same character set as ssh aliases.
fn valid_name(name: String) -> Bool {
  name != "local" && ssh_config.concrete_host(name)
}
