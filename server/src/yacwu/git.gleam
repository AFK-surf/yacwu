//// Read-only Git working-tree inspection for the changes viewer.
////
//// Commands are executed through `yacwu_git_port` with an argv list, never a
//// shell. Every status and diff is limited to the session's working directory.

import filepath
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import yacwu/files

pub type Scope {
  All
  Staged
  Unstaged
}

pub type Change {
  Change(
    path: String,
    old_path: Option(String),
    status: String,
    staged: Bool,
    unstaged: Bool,
  )
}

pub type LineStats {
  LineStats(additions: Option(Int), deletions: Option(Int))
}

/// How to reach the repository: an executor for `git <args>` and a reader
/// for workspace files (untracked content), plus the workdir for the one
/// place git needs an absolute path. Local sessions run git on this machine;
/// remote sessions execute through the session's app-server (`command/exec`).
pub type Repo {
  Repo(
    exec: fn(List(String)) -> Result(#(Int, String), String),
    read_file: fn(String) -> files.FileContent,
    cwd: String,
  )
}

/// A repository on yacwu's own machine.
pub fn local_repo(cwd: String) -> Repo {
  Repo(
    exec: fn(arguments) { run(cwd, arguments) },
    read_file: fn(path) { files.read_file(filepath.join(cwd, path)) },
    cwd: cwd,
  )
}

@external(erlang, "yacwu_git_port", "run")
fn run_port(
  cwd: String,
  arguments: List(String),
) -> Result(#(Int, BitArray), String)

pub fn parse_scope(value: String) -> Result(Scope, Nil) {
  case value {
    "" | "all" -> Ok(All)
    "staged" -> Ok(Staged)
    "unstaged" -> Ok(Unstaged)
    _ -> Error(Nil)
  }
}

pub fn scope_name(scope: Scope) -> String {
  case scope {
    All -> "all"
    Staged -> "staged"
    Unstaged -> "unstaged"
  }
}

pub fn comparison(scope: Scope) -> String {
  case scope {
    All -> "HEAD → working tree"
    Staged -> "HEAD → index"
    Unstaged -> "index → working tree"
  }
}

fn run(cwd: String, arguments: List(String)) -> Result(#(Int, String), String) {
  run_port(cwd, arguments)
  |> result.try(fn(output) {
    bit_array.to_string(output.1)
    |> result.replace_error("git returned a non-text path or diff")
    |> result.map(fn(text) { #(output.0, text) })
  })
}

fn git_arguments(command: List(String)) -> List(String) {
  [
    "--no-pager",
    "--literal-pathspecs",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "submodule.recurse=false",
    ..command
  ]
}

fn status(repo: Repo) -> Result(List(Change), String) {
  use output <- result.try(
    repo.exec(
      git_arguments([
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--",
        ".",
      ]),
    ),
  )
  case output.0 {
    0 -> Ok(parse_status(output.1))
    _ -> Error(string.trim(output.1))
  }
}

/// Parse `git status --porcelain=v1 -z`. In -z mode rename records contain
/// the destination path in the record followed by the source path as the next
/// NUL-delimited field.
pub fn parse_status(output: String) -> List(Change) {
  output
  |> string.split("\u{0000}")
  |> parse_status_records([])
  |> list.reverse
}

fn parse_status_records(
  records: List(String),
  changes: List(Change),
) -> List(Change) {
  case records {
    [] -> changes
    ["", ..rest] -> parse_status_records(rest, changes)
    [record, ..rest] -> {
      let x = string.slice(record, 0, 1)
      let y = string.slice(record, 1, 1)
      let path = string.drop_start(record, 3)
      let renamed = x == "R" || x == "C" || y == "R" || y == "C"
      case renamed, rest {
        True, [old_path, ..tail] ->
          parse_status_records(tail, [
            change(path, Some(old_path), x, y),
            ..changes
          ])
        _, _ ->
          parse_status_records(rest, [change(path, None, x, y), ..changes])
      }
    }
  }
}

fn change(
  path: String,
  old_path: Option(String),
  x: String,
  y: String,
) -> Change {
  let staged = x != " " && x != "?"
  let unstaged = y != " " || x == "?"
  let pair = x <> y
  let status = case pair {
    "DD" | "AU" | "UD" | "UA" | "DU" | "AA" | "UU" -> "conflicted"
    _ if x == "R" || y == "R" -> "renamed"
    _ if x == "C" || y == "C" -> "copied"
    _ if x == "A" || y == "A" || x == "?" -> "added"
    _ if x == "D" || y == "D" -> "deleted"
    _ -> "modified"
  }
  Change(path:, old_path:, status:, staged:, unstaged:)
}

fn applies(change: Change, scope: Scope) -> Bool {
  case scope {
    All -> True
    Staged -> change.staged
    Unstaged -> change.unstaged
  }
}

fn option_json(value: Option(String)) -> Json {
  case value {
    Some(value) -> json.string(value)
    None -> json.null()
  }
}

fn int_option_json(value: Option(Int)) -> Json {
  case value {
    Some(value) -> json.int(value)
    None -> json.null()
  }
}

fn text_line_count(content: String) -> Int {
  case content {
    "" -> 0
    _ ->
      list.length(string.split(content, "\n"))
      - case string.ends_with(content, "\n") {
        True -> 1
        False -> 0
      }
  }
}

fn untracked_stats(repo: Repo, change: Change) -> LineStats {
  case repo.read_file(change.path) {
    files.Text(_, content) -> LineStats(Some(text_line_count(content)), Some(0))
    _ -> LineStats(None, None)
  }
}

fn stats_for(
  repo: Repo,
  scope: Scope,
  stats: Dict(String, LineStats),
  change: Change,
) -> LineStats {
  case dict.get(stats, change.path) {
    Ok(stats) -> stats
    Error(_) if change.status == "added" && !change.staged && scope != Staged ->
      untracked_stats(repo, change)
    Error(_) -> LineStats(Some(0), Some(0))
  }
}

fn change_json(change: Change, stats: LineStats) -> Json {
  json.object([
    #("path", json.string(change.path)),
    #("oldPath", option_json(change.old_path)),
    #("status", json.string(change.status)),
    #("staged", json.bool(change.staged)),
    #("unstaged", json.bool(change.unstaged)),
    #("additions", int_option_json(stats.additions)),
    #("deletions", int_option_json(stats.deletions)),
  ])
}

fn parse_count(value: String) -> Option(Int) {
  case value {
    "-" -> None
    _ -> int.parse(value) |> result.map(Some) |> result.unwrap(None)
  }
}

/// Parse `git diff --numstat -z`. Rename records have an empty path after the
/// two counts, followed by separate old/new path fields.
pub fn parse_numstat(output: String) -> Dict(String, LineStats) {
  output
  |> string.split("\u{0000}")
  |> parse_numstat_records(dict.new())
}

fn parse_numstat_records(
  records: List(String),
  stats: Dict(String, LineStats),
) -> Dict(String, LineStats) {
  case records {
    [] | [""] -> stats
    [record, ..rest] ->
      case string.split_once(record, on: "\t") {
        Error(_) -> parse_numstat_records(rest, stats)
        Ok(#(added, remainder)) ->
          case string.split_once(remainder, on: "\t") {
            Error(_) -> parse_numstat_records(rest, stats)
            Ok(#(deleted, path)) -> {
              let line_stats =
                LineStats(parse_count(added), parse_count(deleted))
              case path, rest {
                "", [_old_path, new_path, ..tail] ->
                  parse_numstat_records(
                    tail,
                    dict.insert(stats, new_path, line_stats),
                  )
                _, _ ->
                  parse_numstat_records(
                    rest,
                    dict.insert(stats, path, line_stats),
                  )
              }
            }
          }
      }
  }
}

fn numstat(
  repo: Repo,
  scope: Scope,
) -> Result(Dict(String, LineStats), String) {
  case scope == All && !has_head(repo) {
    True -> Ok(dict.new())
    False -> {
      let arguments = case scope {
        All -> ["diff", "--numstat", "-z", "HEAD", "--", "."]
        Staged -> ["diff", "--numstat", "-z", "--cached", "--", "."]
        Unstaged -> ["diff", "--numstat", "-z", "--", "."]
      }
      use output <- result.try(repo.exec(git_arguments(arguments)))
      case output.0 {
        0 -> Ok(parse_numstat(output.1))
        _ -> Error(string.trim(output.1))
      }
    }
  }
}

fn branch(repo: Repo) -> String {
  case repo.exec(git_arguments(["symbolic-ref", "--short", "-q", "HEAD"])) {
    Ok(#(0, name)) -> string.trim(name)
    _ ->
      case repo.exec(git_arguments(["rev-parse", "--short", "HEAD"])) {
        Ok(#(0, sha)) -> string.trim(sha)
        _ -> "No commits yet"
      }
  }
}

fn is_work_tree(repo: Repo) -> Result(Bool, String) {
  repo.exec(git_arguments(["rev-parse", "--is-inside-work-tree"]))
  |> result.map(fn(output) { output.0 == 0 && string.trim(output.1) == "true" })
}

pub fn changes_json(repo: Repo, scope: Scope) -> Result(Json, String) {
  use available <- result.try(is_work_tree(repo))
  case available {
    False ->
      Ok(
        json.object([
          #("available", json.bool(False)),
          #("reason", json.string("notRepository")),
          #("scope", json.string(scope_name(scope))),
          #("files", json.preprocessed_array([])),
        ]),
      )
    True -> {
      use changes <- result.try(status(repo))
      use stats <- result.try(numstat(repo, scope))
      let visible = list.filter(changes, applies(_, scope))
      Ok(
        json.object([
          #("available", json.bool(True)),
          #("branch", json.string(branch(repo))),
          #("scope", json.string(scope_name(scope))),
          #("comparison", json.string(comparison(scope))),
          #(
            "files",
            json.preprocessed_array(
              list.map(visible, fn(change) {
                change_json(change, stats_for(repo, scope, stats, change))
              }),
            ),
          ),
        ]),
      )
    }
  }
}

fn has_head(repo: Repo) -> Bool {
  case repo.exec(git_arguments(["rev-parse", "--verify", "HEAD"])) {
    Ok(#(0, _)) -> True
    _ -> False
  }
}

fn find_change(changes: List(Change), path: String) -> Option(Change) {
  list.find(changes, fn(change) { change.path == path })
  |> result.map(Some)
  |> result.unwrap(None)
}

fn diff_arguments(scope: Scope, paths: List(String)) -> List(String) {
  let common = [
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--unified=3",
  ]
  case scope {
    All -> list.append(common, ["HEAD", "--", ..paths])
    Staged -> list.append(common, ["--cached", "--", ..paths])
    Unstaged -> list.append(common, ["--", ..paths])
  }
}

fn untracked_patch(repo: Repo, path: String) -> Result(#(Int, String), String) {
  repo.exec(
    git_arguments([
      "diff",
      "--no-index",
      "--no-color",
      "--no-ext-diff",
      "--no-textconv",
      "--unified=3",
      "--",
      "/dev/null",
      filepath.join(repo.cwd, path),
    ]),
  )
}

fn repository_path(repo: Repo, path: String) -> String {
  case repo.exec(git_arguments(["rev-parse", "--show-prefix"])) {
    Ok(#(0, prefix)) -> string.trim(prefix) <> path
    _ -> path
  }
}

fn blob_text(repo: Repo, revision: String, path: String) -> Option(String) {
  let spec = revision <> ":" <> repository_path(repo, path)
  case repo.exec(git_arguments(["show", spec])) {
    Ok(#(0, content)) -> Some(content)
    _ -> None
  }
}

fn working_text(repo: Repo, path: String, deleted: Bool) -> Option(String) {
  case deleted {
    True -> Some("")
    False ->
      case repo.read_file(path) {
        files.Text(_, content) -> Some(content)
        _ -> None
      }
  }
}

fn diff_contents(
  repo: Repo,
  scope: Scope,
  change: Option(Change),
  path: String,
) -> #(Option(String), Option(String)) {
  let old_path = case change {
    Some(Change(old_path: Some(old_path), ..)) -> old_path
    _ -> path
  }
  let added = case change {
    Some(change) -> change.status == "added"
    None -> False
  }
  let deleted = case change {
    Some(change) -> change.status == "deleted"
    None -> False
  }
  let staged = case change {
    Some(change) -> change.staged
    None -> False
  }
  let original = case scope {
    All | Staged ->
      case added || !has_head(repo) {
        True -> Some("")
        False -> blob_text(repo, "HEAD", old_path)
      }
    Unstaged ->
      case added && !staged {
        True -> Some("")
        False -> blob_text(repo, "", old_path)
      }
  }
  let modified = case scope {
    All | Unstaged -> working_text(repo, path, deleted)
    Staged ->
      case deleted {
        True -> Some("")
        False -> blob_text(repo, "", path)
      }
  }
  #(original, modified)
}

pub fn diff_json(
  repo: Repo,
  scope: Scope,
  path: String,
) -> Result(Json, String) {
  use changes <- result.try(status(repo))
  let selected = find_change(changes, path)
  let paths = case selected {
    Some(Change(old_path: Some(old_path), ..)) -> [path, old_path]
    _ -> [path]
  }
  let use_no_index = case selected {
    Some(change) ->
      change.status == "added"
      && !change.staged
      && scope != Staged
      || { !has_head(repo) && scope == All }
    None -> False
  }
  let output = case use_no_index {
    True -> untracked_patch(repo, path)
    False -> repo.exec(git_arguments(diff_arguments(scope, paths)))
  }
  use output <- result.try(output)
  // git diff --no-index uses 1 to mean "different", not failure.
  case output.0 == 0 || { use_no_index && output.0 == 1 } {
    False -> Error(string.trim(output.1))
    True -> {
      let contents = diff_contents(repo, scope, selected, path)
      let binary =
        string.contains(output.1, "Binary files ")
        || string.contains(output.1, "GIT binary patch")
      Ok(
        json.object([
          #("path", json.string(path)),
          #("scope", json.string(scope_name(scope))),
          #("comparison", json.string(comparison(scope))),
          #("binary", json.bool(binary)),
          #("patch", json.string(output.1)),
          #("original", option_json(contents.0)),
          #("modified", option_json(contents.1)),
        ]),
      )
    }
  }
}
