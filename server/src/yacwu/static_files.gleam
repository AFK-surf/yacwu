//// Serves the built web UI (a static SPA produced by `vite build`).
////
//// Unknown non-API GET paths fall back to `index.html` so client-side routes
//// like `/s/<id>` deep-link correctly.

import filepath
import gleam/bytes_tree
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None}
import gleam/string
import mist.{type ResponseData}
import simplifile

const immutable_prefix = "/_app/immutable/"

fn content_type(path: String) -> String {
  let ext =
    string.split(path, ".")
    |> list.last
    |> fn(r) {
      case r {
        Ok(ext) -> string.lowercase(ext)
        Error(_) -> ""
      }
    }
  case ext {
    "html" -> "text/html; charset=utf-8"
    "js" | "mjs" -> "text/javascript; charset=utf-8"
    "css" -> "text/css; charset=utf-8"
    "json" | "map" -> "application/json"
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "svg" -> "image/svg+xml"
    "ico" -> "image/x-icon"
    "txt" -> "text/plain; charset=utf-8"
    "webmanifest" -> "application/manifest+json"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    "wasm" -> "application/wasm"
    _ -> "application/octet-stream"
  }
}

/// Serve `url_path` from `root`, falling back to index.html when the path
/// doesn't name a file (SPA routing). With `include_body: False` (HEAD
/// requests) the response carries the same status and headers but no body —
/// and no file is opened.
pub fn serve(
  root: String,
  url_path: String,
  include_body include_body: Bool,
) -> Response(ResponseData) {
  let segments =
    string.split(url_path, "/")
    |> list.filter(fn(s) { s != "" })
  let safe = !list.any(segments, fn(s) { s == ".." || s == "." })
  let file_path = list.fold(segments, root, filepath.join)
  case safe && simplifile.is_file(file_path) == Ok(True) {
    True -> serve_file(file_path, url_path, include_body)
    False -> {
      let index = filepath.join(root, "index.html")
      case simplifile.is_file(index) == Ok(True) {
        True -> serve_file(index, "/index.html", include_body)
        False -> text_404("web UI build not found — run `bun run build` first")
      }
    }
  }
}

fn serve_file(
  file_path: String,
  url_path: String,
  include_body: Bool,
) -> Response(ResponseData) {
  let body = case include_body {
    True -> mist.send_file(file_path, offset: 0, limit: None)
    False -> Ok(mist.Bytes(bytes_tree.new()))
  }
  case body {
    Ok(body) -> {
      // Vite content-hashes everything under /_app/immutable/, so those may
      // be cached forever. Everything else — the index.html SPA shell,
      // version.json — must revalidate on every load: a stale shell would
      // reference hashed bundles that no longer exist after a redeploy.
      let cache = case string.starts_with(url_path, immutable_prefix) {
        True -> "public, max-age=31536000, immutable"
        False -> "no-cache"
      }
      response.new(200)
      |> response.set_header("content-type", content_type(file_path))
      |> response.set_header("cache-control", cache)
      |> response.set_body(body)
    }
    Error(_) -> text_404("not found")
  }
}

fn text_404(message: String) -> Response(ResponseData) {
  response.new(404)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(message)))
}
