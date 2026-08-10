//// Filesystem and process operations on a session's workspace, local or
//// remote.
////
//// Local sessions touch yacwu's own filesystem directly. Remote sessions go
//// through the session's codex app-server, which runs on the machine that
//// owns the files: `fs/readFile` / `fs/writeFile` carry contents as base64
//// (binary-safe), and `command/exec` runs argv vectors — used both for `git`
//// and for the tiny `sh` probes that report sizes and directory listings.
//// Every remote operation therefore rides the existing multiplexed
//// WebSocket link; no extra ssh round-trips.

import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile
import yacwu/codex.{type Codex}
import yacwu/files
import yacwu/jsonx

pub type Workspace {
  LocalWorkspace
  RemoteWorkspace(cx: Codex)
}

/// Cap for images served from a remote workspace (base64 over the link).
pub const max_image_bytes = 10_000_000

// -- command/exec -------------------------------------------------------------

/// Run an argv vector on the workspace's machine via the app-server. Returns
/// `#(exit_code, stdout, stderr)`. Remote workspaces only.
pub fn exec(
  cx: Codex,
  cwd: String,
  argv: List(String),
  timeout_ms: Int,
) -> Result(#(Int, String, String), String) {
  let params = [
    #("command", json.array(argv, json.string)),
    #(
      "sandboxPolicy",
      json.object([#("type", json.string("dangerFullAccess"))]),
    ),
    #("timeoutMs", json.int(timeout_ms)),
  ]
  let params = case cwd {
    "" -> params
    _ -> [#("cwd", json.string(cwd)), ..params]
  }
  use result <- result.try(codex.request(
    cx,
    "command/exec",
    json.object(params),
  ))
  use exit_code <- result.try(
    jsonx.field_int(result, ["exitCode"])
    |> result.replace_error("command/exec returned no exit code"),
  )
  let stdout = jsonx.field_string(result, ["stdout"]) |> result.unwrap("")
  let stderr = jsonx.field_string(result, ["stderr"]) |> result.unwrap("")
  Ok(#(exit_code, stdout, stderr))
}

/// Run `git` in `cwd` for the Git changes viewer: on success the parseable
/// stdout, on failure git's diagnostics.
pub fn exec_git(
  cx: Codex,
  cwd: String,
  arguments: List(String),
) -> Result(#(Int, String), String) {
  use #(code, stdout, stderr) <- result.try(exec(
    cx,
    cwd,
    ["git", ..arguments],
    15_000,
  ))
  case code {
    0 -> Ok(#(0, stdout))
    _ -> Ok(#(code, string.trim(stderr <> stdout)))
  }
}

// -- directory listing --------------------------------------------------------

/// One POSIX-sh pass over a directory: an `E <kind> <symlink> <name>` line
/// per entry (builtin tests only — no per-file processes), then a single
/// `wc -c` supplying `S <size> ./<name>` lines for regular files. No single
/// quotes: the script travels as an argv element.
const list_script = "
for f in ./* ./.[!.]* ./..?*; do
  if [ -e \"$f\" ] || [ -h \"$f\" ]; then
    name=\"${f#./}\"
    if [ -h \"$f\" ]; then sym=1; else sym=0; fi
    if [ -d \"$f\" ]; then kind=d; elif [ -f \"$f\" ]; then kind=f; else kind=o; fi
    printf \"E %s %s %s\\n\" \"$kind\" \"$sym\" \"$name\"
  fi
done
wc -c ./* ./.[!.]* ./..?* 2>/dev/null | sed -e \"s/^ *//\" -e \"s/^/S /\"
exit 0
"

pub fn list_directory(
  ws: Workspace,
  dir: String,
) -> Result(List(files.Entry), String) {
  case ws {
    LocalWorkspace -> files.list_directory(dir)
    RemoteWorkspace(cx) -> {
      use #(code, stdout, stderr) <- result.try(exec(
        cx,
        dir,
        ["sh", "-c", list_script],
        20_000,
      ))
      case code {
        0 -> Ok(files.sort_entries(parse_listing(stdout)))
        _ -> Error(remote_error(stderr, "could not list the remote directory"))
      }
    }
  }
}

/// Parse the listing script's output into entries.
pub fn parse_listing(output: String) -> List(files.Entry) {
  let lines = string.split(output, "\n")
  let sizes =
    list.filter_map(lines, fn(line) {
      use rest <- result.try(prefixed(line, "S "))
      use #(size, name) <- result.try(string.split_once(rest, " "))
      use size <- result.try(int.parse(size))
      case string.starts_with(name, "./") {
        True -> Ok(#(string.drop_start(name, 2), size))
        False -> Error(Nil)
      }
    })
  list.filter_map(lines, fn(line) {
    use rest <- result.try(prefixed(line, "E "))
    use #(kind, rest) <- result.try(string.split_once(rest, " "))
    use #(sym, name) <- result.try(string.split_once(rest, " "))
    case name {
      "" -> Error(Nil)
      _ -> {
        let kind = case kind {
          "d" -> "dir"
          "f" -> "file"
          _ -> "other"
        }
        let size = case kind {
          "file" -> list.key_find(sizes, name) |> result.unwrap(0)
          _ -> 0
        }
        Ok(files.Entry(name: name, kind: kind, size: size, symlink: sym == "1"))
      }
    }
  })
}

fn prefixed(line: String, prefix: String) -> Result(String, Nil) {
  case string.starts_with(line, prefix) {
    True -> Ok(string.drop_start(line, string.length(prefix)))
    False -> Error(Nil)
  }
}

// -- file reading -------------------------------------------------------------

type Probe {
  RegularFile(size: Int)
  NotRegular
  Absent
}

/// One `sh` probe classifying a path and reporting a regular file's size,
/// without transferring the content.
const probe_script = "
if [ -f \"$0\" ]; then wc -c < \"$0\"
elif [ -e \"$0\" ] || [ -h \"$0\" ]; then echo YACWU_OTHER
else echo YACWU_MISSING
fi
"

fn probe(cx: Codex, path: String) -> Result(Probe, String) {
  use #(code, stdout, stderr) <- result.try(exec(
    cx,
    "",
    ["sh", "-c", probe_script, path],
    15_000,
  ))
  let answer = string.trim(stdout)
  case code, answer {
    0, "YACWU_MISSING" -> Ok(Absent)
    0, "YACWU_OTHER" -> Ok(NotRegular)
    0, _ ->
      case int.parse(answer) {
        Ok(size) -> Ok(RegularFile(size))
        Error(_) -> Error("unexpected probe answer: " <> answer)
      }
    _, _ -> Error(remote_error(stderr, "could not inspect the remote file"))
  }
}

fn fs_read(cx: Codex, path: String) -> Result(BitArray, String) {
  use result <- result.try(codex.request(
    cx,
    "fs/readFile",
    json.object([#("path", json.string(path))]),
  ))
  use data <- result.try(
    jsonx.field_string(result, ["dataBase64"])
    |> result.replace_error("fs/readFile returned no data"),
  )
  bit_array.base64_decode(data)
  |> result.replace_error("fs/readFile returned invalid base64")
}

/// Read a file for the browser, with the same size cap and text/binary
/// classification as the local path.
pub fn read_file(
  ws: Workspace,
  path: String,
) -> Result(files.FileContent, String) {
  case ws {
    LocalWorkspace -> Ok(files.read_file(path))
    RemoteWorkspace(cx) -> {
      use probed <- result.try(probe(cx, path))
      case probed {
        Absent | NotRegular -> Ok(files.Missing)
        RegularFile(size) if size > files.max_file_bytes ->
          Ok(files.TooLarge(size))
        RegularFile(size) -> {
          use bits <- result.try(fs_read(cx, path))
          case bit_array.to_string(bits) {
            Error(_) -> Ok(files.Binary(size))
            Ok(content) ->
              case string.contains(content, "\u{0000}") {
                True -> Ok(files.Binary(size))
                False -> Ok(files.Text(size, content))
              }
          }
        }
      }
    }
  }
}

/// Read raw bytes (image serving), capped at `max_bytes`.
pub fn read_binary(
  ws: Workspace,
  path: String,
  max_bytes: Int,
) -> Result(BitArray, String) {
  case ws {
    LocalWorkspace ->
      simplifile.read_bits(path) |> result.replace_error("file not found")
    RemoteWorkspace(cx) -> {
      use probed <- result.try(probe(cx, path))
      case probed {
        Absent | NotRegular -> Error("file not found")
        RegularFile(size) if size > max_bytes ->
          Error("file exceeds the transfer limit")
        RegularFile(_) -> fs_read(cx, path)
      }
    }
  }
}

// -- writing (image uploads) --------------------------------------------------

pub fn write_file(
  ws: Workspace,
  path: String,
  data: BitArray,
) -> Result(Nil, String) {
  case ws {
    LocalWorkspace ->
      simplifile.write_bits(path, data)
      |> result.replace_error("failed to write " <> path)
    RemoteWorkspace(cx) ->
      codex.request(
        cx,
        "fs/writeFile",
        json.object([
          #("path", json.string(path)),
          #("dataBase64", json.string(bit_array.base64_encode(data, True))),
        ]),
      )
      |> result.replace(Nil)
  }
}

pub fn create_directory(ws: Workspace, path: String) -> Result(Nil, String) {
  case ws {
    LocalWorkspace ->
      simplifile.create_directory_all(path)
      |> result.replace_error("failed to create " <> path)
    RemoteWorkspace(cx) -> {
      use #(code, _, stderr) <- result.try(exec(
        cx,
        "",
        ["mkdir", "-p", path],
        15_000,
      ))
      case code {
        0 -> Ok(Nil)
        _ -> Error(remote_error(stderr, "failed to create " <> path))
      }
    }
  }
}

fn remote_error(stderr: String, fallback: String) -> String {
  case string.trim(stderr) {
    "" -> fallback
    message -> message
  }
}
