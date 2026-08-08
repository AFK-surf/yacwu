//// Detect whether another codex process on this machine has a session's
//// rollout file open. codex keeps an open file descriptor on the rollout
//// `.jsonl` for as long as a thread is loaded (resumed) — even while idle —
//// so scanning open files for that path tells us if some *other* codex
//// instance is using the session.
////
//// Platform support:
////   - Linux: scan `/proc/*/fd` symlinks; parent pids come from
////     `/proc/<pid>/stat`.
////   - OpenBSD: no /proc — scan with `fstat(1)`, which reports every process
////     holding the file; parent pids come from `ps`.
////   - Anything else degrades to "no detection" (an empty holder list)
////     rather than blocking the user.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
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

@external(erlang, "os", "type")
fn os_type() -> #(atom.Atom, atom.Atom)

@external(erlang, "os", "cmd")
fn os_cmd(command: Charlist) -> Charlist

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

fn run(command: String) -> String {
  os_cmd(charlist.from_string(command))
  |> charlist.to_string
}

fn shell_quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}

// -- Platform dispatch --------------------------------------------------------

type Platform {
  Linux
  OpenBsd
  Unsupported
}

fn platform() -> Platform {
  let #(family, os) = os_type()
  case atom.to_string(family), atom.to_string(os) {
    "unix", "linux" -> Linux
    "unix", "openbsd" -> OpenBsd
    _, _ -> Unsupported
  }
}

/// One platform's scan results: which pids hold the file, every process's
/// parent pid (to exclude our own app-server's subtree), and a way to name a
/// holding process.
type Scan {
  Scan(
    holders: List(Int),
    parents: List(#(Int, Int)),
    command: fn(Int) -> String,
  )
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
      let scan = case platform() {
        Linux -> linux_scan(rollout_path)
        OpenBsd -> openbsd_scan(rollout_path)
        Unsupported -> Scan([], [], fn(pid) { "pid " <> int.to_string(pid) })
      }
      let excluded = case own_app_server_pid {
        Ok(pid) -> subtree(pid, scan.parents)
        Error(_) -> set.new()
      }
      let excluded = case own_os_pid() {
        Ok(pid) -> set.insert(excluded, pid)
        Error(_) -> excluded
      }
      scan.holders
      |> list.filter(fn(pid) { !set.contains(excluded, pid) })
      |> list.map(fn(pid) { SessionHolder(pid, scan.command(pid)) })
    }
  }
}

/// All pids in the subtree rooted at `root` (inclusive), given a
/// `#(pid, parent_pid)` relation. Repeatedly absorbs any pid whose ancestor
/// chain reaches the root.
fn subtree(root: Int, parents: List(#(Int, Int))) -> Set(Int) {
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

// -- Linux: /proc -------------------------------------------------------------

fn linux_scan(rollout_path: String) -> Scan {
  Scan(
    holders: proc_holders(rollout_path),
    parents: proc_parents(),
    command: proc_command,
  )
}

fn proc_pids() -> List(Int) {
  case simplifile.read_directory("/proc") {
    Ok(names) -> list.filter_map(names, int.parse)
    Error(_) -> []
  }
}

/// Pids (any) that currently hold `target_path` open.
fn proc_holders(target_path: String) -> List(Int) {
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

fn proc_parents() -> List(#(Int, Int)) {
  proc_pids()
  |> list.filter_map(fn(pid) {
    proc_parent_pid(pid) |> result.map(fn(ppid) { #(pid, ppid) })
  })
}

/// Read a process's parent pid from /proc/<pid>/stat, or error if unavailable.
fn proc_parent_pid(pid: Int) -> Result(Int, Nil) {
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
fn proc_command(pid: Int) -> String {
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

// -- OpenBSD: fstat(1) --------------------------------------------------------

fn openbsd_scan(rollout_path: String) -> Scan {
  let holders =
    parse_fstat_output(run(
      "fstat " <> shell_quote(rollout_path) <> " 2>/dev/null",
    ))
  Scan(
    holders: list.map(holders, fn(holder) { holder.0 }),
    parents: parse_ps_parents(run("ps -ax -o pid= -o ppid= 2>/dev/null")),
    command: fn(pid) {
      case list.key_find(holders, pid) {
        Ok(command) -> command
        Error(_) -> "pid " <> int.to_string(pid)
      }
    },
  )
}

/// Parse `fstat <file>` output into `#(pid, command)` pairs, one per process.
///
/// Lines look like:
///   USER     CMD          PID    FD MOUNT      INUM  MODE       R/W  SZ|DV NAME
///   heyang   codex      50655   18 /home    3529945 -rw-r--r--    r   2048 /path
///
/// The command name may itself contain spaces, so the pid is located as the
/// first integer field after it (whose next field looks like the FD column)
/// and the command is everything in between.
pub fn parse_fstat_output(output: String) -> List(#(Int, String)) {
  string.split(output, "\n")
  |> list.filter_map(fn(line) {
    let fields =
      string.split(line, " ")
      |> list.filter(fn(field) { field != "" })
    case fields {
      [_user, first_command_word, ..rest] ->
        find_pid(rest, [first_command_word])
      _ -> Error(Nil)
    }
  })
  |> unique_by_pid([])
}

/// Walk fields until one parses as an integer (the PID column); the fields
/// before it form the command name. The field after the PID must be the FD
/// column (a number or one of fstat's special fd names), which guards against
/// numeric words inside a command name.
fn find_pid(
  fields: List(String),
  command_acc: List(String),
) -> Result(#(Int, String), Nil) {
  case fields {
    [field, next, ..rest] ->
      case int.parse(field) {
        Ok(pid) -> {
          let fd_like =
            result.is_ok(int.parse(next))
            || list.contains(["text", "wd", "root", "tr"], next)
          case fd_like {
            True -> Ok(#(pid, string.join(list.reverse(command_acc), " ")))
            False -> find_pid([next, ..rest], [field, ..command_acc])
          }
        }
        Error(_) -> find_pid([next, ..rest], [field, ..command_acc])
      }
    _ -> Error(Nil)
  }
}

/// A process holding the file on several descriptors appears once per fd;
/// report it only once.
fn unique_by_pid(
  holders: List(#(Int, String)),
  seen: List(Int),
) -> List(#(Int, String)) {
  case holders {
    [] -> []
    [holder, ..rest] ->
      case list.contains(seen, holder.0) {
        True -> unique_by_pid(rest, seen)
        False -> [holder, ..unique_by_pid(rest, [holder.0, ..seen])]
      }
  }
}

/// Parse `ps -ax -o pid= -o ppid=` output into `#(pid, parent_pid)` pairs.
pub fn parse_ps_parents(output: String) -> List(#(Int, Int)) {
  string.split(output, "\n")
  |> list.filter_map(fn(line) {
    case
      string.split(line, " ")
      |> list.filter(fn(field) { field != "" })
    {
      [pid, ppid] ->
        case int.parse(pid), int.parse(ppid) {
          Ok(pid), Ok(ppid) -> Ok(#(pid, ppid))
          _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}
