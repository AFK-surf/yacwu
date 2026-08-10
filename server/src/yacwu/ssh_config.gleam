//// Remote host discovery from the user's OpenSSH client configuration.
////
//// yacwu keeps no host registry of its own: the set of remote machines is
//// exactly the concrete `Host` aliases in `~/.ssh/config` (plus files pulled
//// in by `Include`). Authentication, jump hosts, ports and usernames all stay
//// in ssh's hands — yacwu only ever passes the alias to the `ssh` binary.
////
//// The config is re-read on demand, so edits show up without a restart and
//// nothing is cached across yacwu runs.

import envoy
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// One directive we care about from an ssh_config file.
pub type Directive {
  Hosts(List(String))
  Include(List(String))
}

/// Parse ssh_config content into Host and Include directives, in file order.
/// Handles `Keyword value`, `Keyword=value`, comments, and quoted tokens.
pub fn parse(content: String) -> List(Directive) {
  string.split(content, "\n")
  |> list.filter_map(fn(line) {
    let line = string.trim(line)
    case string.starts_with(line, "#") || line == "" {
      True -> Error(Nil)
      False -> {
        // `Keyword=value` is equivalent to `Keyword value`.
        let line = case string.split_once(line, "=") {
          Ok(#(keyword, value)) ->
            case string.contains(string.trim(keyword), " ") {
              True -> line
              False -> string.trim(keyword) <> " " <> string.trim(value)
            }
          Error(_) -> line
        }
        case string.split_once(line, " ") {
          Error(_) -> Error(Nil)
          Ok(#(keyword, rest)) ->
            case string.lowercase(keyword) {
              "host" -> Ok(Hosts(tokens(rest)))
              "include" -> Ok(Include(tokens(rest)))
              _ -> Error(Nil)
            }
        }
      }
    }
  })
}

/// Split a directive's arguments into tokens, honouring double quotes.
fn tokens(rest: String) -> List(String) {
  do_tokens(string.trim(rest), [], "")
}

fn do_tokens(rest: String, acc: List(String), current: String) -> List(String) {
  case string.pop_grapheme(rest) {
    Error(_) -> finish_token(acc, current) |> list.reverse
    Ok(#("\"", rest)) ->
      case string.split_once(rest, "\"") {
        Ok(#(quoted, rest)) -> do_tokens(rest, acc, current <> quoted)
        Error(_) -> do_tokens("", acc, current <> rest)
      }
    Ok(#(" ", rest)) | Ok(#("\t", rest)) ->
      do_tokens(string.trim_start(rest), finish_token(acc, current), "")
    Ok(#(char, rest)) -> do_tokens(rest, acc, current <> char)
  }
}

fn finish_token(acc: List(String), current: String) -> List(String) {
  case current {
    "" -> acc
    _ -> [current, ..acc]
  }
}

/// Whether an alias names a single concrete host yacwu can offer: no glob
/// patterns or negations, and safe to embed in argv and socket file names.
pub fn concrete_host(alias: String) -> Bool {
  alias != ""
  && !string.starts_with(alias, "-")
  && !string.starts_with(alias, "!")
  && string.to_graphemes(alias)
  |> list.all(fn(char) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@",
      char,
    )
  })
}

/// Minimal glob matching for Include arguments: `*` matches any run of
/// characters; other characters match literally.
pub fn glob_match(pattern: String, name: String) -> Bool {
  case string.split(pattern, "*") {
    [literal] -> literal == name
    [prefix, ..rest] ->
      case string.starts_with(name, prefix) {
        False -> False
        True ->
          match_parts(rest, string.drop_start(name, string.length(prefix)))
      }
    [] -> name == ""
  }
}

fn match_parts(parts: List(String), name: String) -> Bool {
  case parts {
    [] -> True
    // A trailing `*` matches the remainder.
    [""] -> True
    [last] -> string.ends_with(name, last)
    [part, ..rest] ->
      case part {
        "" -> match_parts(rest, name)
        _ ->
          case string.split_once(name, part) {
            Ok(#(_, after)) -> match_parts(rest, after)
            Error(_) -> False
          }
      }
  }
}

/// All concrete host aliases from an ssh_config file, following `Include`
/// directives (relative paths and globs resolve against `base_dir`, `~` is
/// expanded from `home`). `depth` bounds include recursion.
pub fn hosts_in(
  path: String,
  base_dir: String,
  home: String,
  depth: Int,
) -> List(String) {
  case depth <= 0, simplifile.read(path) {
    True, _ | _, Error(_) -> []
    False, Ok(content) ->
      parse(content)
      |> list.flat_map(fn(directive) {
        case directive {
          Hosts(aliases) -> list.filter(aliases, concrete_host)
          Include(patterns) ->
            patterns
            |> list.flat_map(resolve_include(_, base_dir, home))
            |> list.flat_map(hosts_in(_, base_dir, home, depth - 1))
        }
      })
      |> list.unique
  }
}

/// Expand one Include argument to concrete file paths.
fn resolve_include(
  pattern: String,
  base_dir: String,
  home: String,
) -> List(String) {
  let pattern = case pattern {
    "~" -> home
    _ ->
      case string.starts_with(pattern, "~/") {
        True -> home <> string.drop_start(pattern, 1)
        False ->
          case string.starts_with(pattern, "/") {
            True -> pattern
            False -> base_dir <> "/" <> pattern
          }
      }
  }
  case string.contains(pattern, "*") {
    False -> [pattern]
    True -> {
      // Glob in the final path segment only (the common ssh usage).
      let #(dir, file_pattern) = case last_slash_split(pattern) {
        Ok(#(dir, file_pattern)) -> #(dir, file_pattern)
        Error(_) -> #(base_dir, pattern)
      }
      case simplifile.read_directory(dir) {
        Error(_) -> []
        Ok(names) ->
          names
          |> list.filter(glob_match(file_pattern, _))
          |> list.sort(string.compare)
          |> list.map(fn(name) { dir <> "/" <> name })
      }
    }
  }
}

fn last_slash_split(path: String) -> Result(#(String, String), Nil) {
  case string.split(path, "/") |> list.reverse {
    [file, ..dir_parts] if dir_parts != [] ->
      Ok(#(string.join(list.reverse(dir_parts), "/"), file))
    _ -> Error(Nil)
  }
}

/// The remote hosts yacwu offers: concrete aliases from `~/.ssh/config`.
pub fn discover() -> List(String) {
  let home = envoy.get("HOME") |> result.unwrap("/")
  let ssh_dir = home <> "/.ssh"
  hosts_in(ssh_dir <> "/config", ssh_dir, home, 4)
}
