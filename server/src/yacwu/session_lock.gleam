//// Detect whether another codex process on this machine has a session's
//// rollout file open. codex keeps an open file descriptor on the rollout
//// `.jsonl` for as long as a thread is loaded (resumed) — even while idle —
//// so scanning open fds for that path tells us if some *other* codex instance
//// is using the session.
////
//// Linux-only (relies on /proc). On platforms without /proc this degrades to
//// "no detection" (returns an empty holder list) rather than blocking the
//// user.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

pub type SessionHolder {
  SessionHolder(pid: Int, command: String)
}

@external(erlang, "file", "read_link_all")
fn file_read_link(path: String) -> Result(Dynamic, Dynamic)

@external(erlang, "unicode", "characters_to_binary")
fn characters_to_binary(data: Dynamic) -> Dynamic

@external(erlang, "os", "getpid")
fn os_getpid() -> Dynamic

/// Convert a charlist-or-binary filename term into a string.
fn chars_to_string(chars: Dynamic) -> Result(String, Nil) {
  decode.run(characters_to_binary(chars), decode.string)
  |> result.replace_error(Nil)
}

fn read_link(path: String) -> Result(String, Nil) {
  case file_read_link(path) {
    Ok(name) -> chars_to_string(name)
    Error(_) -> Error(Nil)
  }
}

/// This BEAM node's own OS pid.
fn own_os_pid() -> Result(Int, Nil) {
  chars_to_string(os_getpid())
  |> result.try(fn(text) { int.parse(text) |> result.replace_error(Nil) })
}

/// Read a process's parent pid from /proc/<pid>/stat, or error if unavailable.
fn parent_pid(pid: Int) -> Result(Int, Nil) {
  use stat <- result.try(
    simplifile.read("/proc/" <> int.to_string(pid) <> "/stat")
    |> result.replace_error(Nil),
  )
  // Format: pid (comm) state ppid ... — comm may contain spaces/parens, so
  // parse after the last ')'.
  use rest <- result.try(case string.split(stat, ")") {
    [] | [_] -> Error(Nil)
    parts ->
      list.last(parts)
      |> result.replace_error(Nil)
  })
  case string.split(string.trim(rest), " ") {
    [_state, ppid, ..] -> int.parse(ppid) |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

/// Best-effort short command name for a pid (e.g. "codex").
fn command_of(pid: Int) -> String {
  let proc = "/proc/" <> int.to_string(pid)
  let comm = case simplifile.read(proc <> "/comm") {
    Ok(comm) -> string.trim(comm)
    Error(_) -> ""
  }
  case comm {
    "" ->
      case simplifile.read(proc <> "/cmdline") {
        Ok(cmdline) ->
          case
            string.split(cmdline, "\u{0000}")
            |> list.filter(fn(part) { part != "" })
          {
            [first, ..] -> {
              let base =
                string.split(first, "/")
                |> list.last
                |> result.unwrap(first)
              string.slice(base, 0, 40)
            }
            [] -> "pid " <> int.to_string(pid)
          }
        Error(_) -> "pid " <> int.to_string(pid)
      }
    comm -> comm
  }
}

fn proc_pids() -> List(Int) {
  case simplifile.read_directory("/proc") {
    Ok(names) -> list.filter_map(names, int.parse)
    Error(_) -> []
  }
}

/// All pids in the subtree rooted at `root` (inclusive), built from /proc.
fn process_subtree(root: Int) -> Set(Int) {
  let parents =
    proc_pids()
    |> list.filter_map(fn(pid) {
      parent_pid(pid) |> result.map(fn(ppid) { #(pid, ppid) })
    })
  // Repeatedly absorb any pid whose ancestor chain reaches root.
  absorb(set.insert(set.new(), root), parents)
}

fn absorb(subtree: Set(Int), parents: List(#(Int, Int))) -> Set(Int) {
  let next =
    list.fold(parents, subtree, fn(acc, entry) {
      case set.contains(acc, entry.1) && !set.contains(acc, entry.0) {
        True -> set.insert(acc, entry.0)
        False -> acc
      }
    })
  case set.size(next) == set.size(subtree) {
    True -> next
    False -> absorb(next, parents)
  }
}

/// Pids (any) that currently hold `target_path` open.
fn holders_of(target_path: String) -> List(Int) {
  proc_pids()
  |> list.filter(fn(pid) {
    case simplifile.read_directory("/proc/" <> int.to_string(pid) <> "/fd") {
      Error(_) -> False
      Ok(fds) ->
        list.any(fds, fn(fd) {
          read_link("/proc/" <> int.to_string(pid) <> "/fd/" <> fd)
          == Ok(target_path)
        })
    }
  })
}

/// Return processes — other than our own app-server's process tree and this
/// server process — that hold the given rollout file open.
pub fn detect_external_holders(
  rollout_path: String,
  own_app_server_pid: Result(Int, Nil),
) -> List(SessionHolder) {
  case rollout_path {
    "" -> []
    _ -> {
      let excluded = case own_app_server_pid {
        Ok(pid) -> process_subtree(pid)
        Error(_) -> set.new()
      }
      let excluded = case own_os_pid() {
        Ok(pid) -> set.insert(excluded, pid)
        Error(_) -> excluded
      }
      holders_of(rollout_path)
      |> list.filter(fn(pid) { !set.contains(excluded, pid) })
      |> list.map(fn(pid) { SessionHolder(pid, command_of(pid)) })
    }
  }
}
