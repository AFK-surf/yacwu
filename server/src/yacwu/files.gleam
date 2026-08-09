//// Read-only file browsing for the web UI.
////
//// Both endpoints are scoped to a session's working directory: the router
//// resolves the thread's cwd and every requested path is a relative path
//// that must stay inside it. `sanitize` rejects absolute paths and `..`
//// traversal lexically; symlinks inside the tree follow the filesystem,
//// matching the trust model of `/api/images` (the browser user is the
//// machine user).

import filepath
import gleam/bit_array
import gleam/json.{type Json}
import gleam/list
import gleam/order
import gleam/string
import simplifile

/// Files larger than this are reported, not returned.
pub const max_file_bytes = 1_000_000

pub type Entry {
  Entry(name: String, kind: String, size: Int, symlink: Bool)
}

pub type FileContent {
  Text(size: Int, content: String)
  Binary(size: Int)
  TooLarge(size: Int)
  Missing
}

/// Normalize a user-supplied path relative to a session root. Returns the
/// cleaned relative path ("" is the root itself), or an error for absolute
/// paths, backslashes, NUL bytes, and `..` segments that would escape.
pub fn sanitize(raw: String) -> Result(String, Nil) {
  case
    string.contains(raw, "\\")
    || string.contains(raw, "\u{0000}")
    || filepath.is_absolute(raw)
  {
    True -> Error(Nil)
    False ->
      case string.trim(raw) {
        "" -> Ok("")
        trimmed -> filepath.expand(trimmed)
      }
  }
}

/// Join a sanitized relative path onto the session root.
pub fn resolve(root: String, rel: String) -> String {
  case rel {
    "" -> root
    _ -> filepath.join(root, rel)
  }
}

/// List a directory: directories first, then case-insensitive by name.
pub fn list_directory(dir: String) -> Result(List(Entry), String) {
  case simplifile.read_directory(dir) {
    Error(error) -> Error(simplifile.describe_error(error))
    Ok(names) ->
      names
      |> list.map(fn(name) { entry_of(dir, name) })
      |> sort_entries
      |> Ok
  }
}

fn entry_of(dir: String, name: String) -> Entry {
  let path = filepath.join(dir, name)
  let symlink = simplifile.is_symlink(path) == Ok(True)
  let kind = case simplifile.is_directory(path) {
    Ok(True) -> "dir"
    _ ->
      case simplifile.is_file(path) {
        Ok(True) -> "file"
        _ -> "other"
      }
  }
  let size = case simplifile.file_info(path) {
    Ok(info) -> info.size
    Error(_) -> 0
  }
  Entry(name:, kind:, size:, symlink:)
}

pub fn sort_entries(entries: List(Entry)) -> List(Entry) {
  list.sort(entries, fn(a, b) {
    case a.kind == "dir", b.kind == "dir" {
      True, False -> order.Lt
      False, True -> order.Gt
      _, _ -> string.compare(string.lowercase(a.name), string.lowercase(b.name))
    }
  })
}

pub fn entries_to_json(entries: List(Entry)) -> Json {
  json.preprocessed_array(
    list.map(entries, fn(entry) {
      json.object([
        #("name", json.string(entry.name)),
        #("kind", json.string(entry.kind)),
        #("size", json.int(entry.size)),
        #("symlink", json.bool(entry.symlink)),
      ])
    }),
  )
}

/// Read a regular file for display. UTF-8 text under the size cap comes back
/// as `Text`; NUL bytes or invalid UTF-8 mean `Binary`.
pub fn read_file(path: String) -> FileContent {
  case simplifile.file_info(path) {
    Error(_) -> Missing
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.File ->
          case info.size > max_file_bytes {
            True -> TooLarge(info.size)
            False -> read_regular_file(path, info.size)
          }
        _ -> Missing
      }
  }
}

fn read_regular_file(path: String, size: Int) -> FileContent {
  case simplifile.read_bits(path) {
    Error(_) -> Missing
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Error(_) -> Binary(size)
        Ok(content) ->
          case string.contains(content, "\u{0000}") {
            True -> Binary(size)
            False -> Text(size, content)
          }
      }
  }
}
