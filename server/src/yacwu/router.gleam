//// HTTP routing: the REST/SSE API over the codex app-server protocol, plus
//// static serving of the built web UI.

import envoy
import filepath
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import mist.{type Connection, type ResponseData}
import simplifile
import yacwu/auth
import yacwu/codex.{type Codex}
import yacwu/defaults
import yacwu/jsonx
import yacwu/model_state.{type Store}
import yacwu/session_lock
import yacwu/static_files

pub type Context {
  Context(codex: Codex, store: Store, static_dir: String)
}

const max_body = 104_857_600

pub fn handler(
  ctx: Context,
) -> fn(Request(Connection)) -> Response(ResponseData) {
  let debug = envoy.get("YACWU_DEBUG") == Ok("1")
  fn(req) {
    case auth.check_remote_user(request.get_header(req, "remote-user")) {
      Error(denial) -> text_response(denial.status, denial.message)
      Ok(Nil) ->
        case debug {
          False -> route(ctx, req)
          True -> {
            let started = monotonic_ms()
            let resp = route(ctx, req)
            io.println_error(
              "[req] "
              <> http.method_to_string(req.method)
              <> " "
              <> req.path
              <> " -> "
              <> int.to_string(resp.status)
              <> " in "
              <> int.to_string(monotonic_ms() - started)
              <> "ms",
            )
            resp
          }
        }
    }
  }
}

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn erl_monotonic_time(unit: TimeUnit) -> Int

fn monotonic_ms() -> Int {
  erl_monotonic_time(Millisecond)
}

fn route(ctx: Context, req: Request(Connection)) -> Response(ResponseData) {
  case request.path_segments(req), req.method {
    ["api", "events"], Get -> sse(ctx, req)
    ["api", "account"], Get -> account(ctx)
    ["api", "images"], Get -> image(req)
    ["api", "threads"], Get -> list_threads(ctx)
    ["api", "threads"], Post -> create_thread(ctx, req)
    ["api", "threads", id, "open"], Post -> open_thread(ctx, req, id)
    ["api", "threads", id, "message"], Post -> message(ctx, req, id)
    ["api", "threads", id, "interrupt"], Post -> interrupt(ctx, req, id)
    ["api", "threads", id, "goal"], Get -> get_goal(ctx, id)
    ["api", "threads", id, "goal"], Post -> post_goal(ctx, req, id)
    ["api", "threads", id, "model"], Get -> get_model(ctx, id)
    ["api", "threads", id, "model"], Post -> post_model(ctx, req, id)
    ["api", "threads", id, "compact"], Post ->
      simple_rpc(ctx, "thread/compact/start", id)
    ["api", "threads", id, "review"], Post -> review(ctx, req, id)
    ["api", "threads", id, "shell"], Post -> shell(ctx, req, id)
    ["api", "threads", id, "rollback"], Post -> rollback(ctx, req, id)
    ["api", "threads", id, "fork"], Post -> simple_rpc(ctx, "thread/fork", id)
    ["api", "threads", id, "archive"], Post ->
      simple_rpc(ctx, "thread/archive", id)
    ["api", ..], _ -> json_response(404, error_body("not found"))
    _, Get -> static_files.serve(ctx.static_dir, req.path)
    _, _ -> text_response(404, "not found")
  }
}

// -- Small helpers ------------------------------------------------------------

fn text_response(status: Int, message: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(message)))
}

fn json_response(status: Int, body: Json) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

fn error_body(message: String) -> Json {
  json.object([#("error", json.string(message))])
}

/// Read and JSON-parse the request body; parse failures yield an "empty
/// object" so field lookups simply miss (mirrors `.catch(() => ({}))`).
fn read_json_body(req: Request(Connection)) -> Dynamic {
  case mist.read_body(req, max_body) {
    Ok(req) ->
      case json.parse_bits(req.body, decode.dynamic) {
        Ok(body) -> body
        Error(_) -> dynamic.nil()
      }
    Error(_) -> dynamic.nil()
  }
}

/// Perform a codex request and pass its result JSON through, mapping errors
/// to a 500 response.
fn rpc(ctx: Context, method: String, params: Json) -> Response(ResponseData) {
  case codex.request(ctx.codex, method, params) {
    Ok(result) -> json_response(200, jsonx.to_json(result))
    Error(message) -> json_response(500, error_body(message))
  }
}

fn simple_rpc(
  ctx: Context,
  method: String,
  thread_id: String,
) -> Response(ResponseData) {
  rpc(ctx, method, json.object([#("threadId", json.string(thread_id))]))
}

// -- /api/events --------------------------------------------------------------

/// Ping messages share the notification subject; codex notifications are
/// always JSON objects, so a bare "ping" cannot collide.
const ping = "ping"

/// Server-Sent Events stream of every codex notification (all sessions).
fn sse(ctx: Context, req: Request(Connection)) -> Response(ResponseData) {
  mist.server_sent_events(
    req,
    response.new(200),
    fn(subject) {
      process.send(subject, "{\"method\":\"yacwu/connected\",\"params\":{}}")
      codex.subscribe(ctx.codex, process.self(), subject)
      let _ = process.send_after(subject, 15_000, ping)
      subject
    },
    fn(subject, message, conn) {
      case message {
        m if m == ping -> {
          let event =
            mist.event(string_tree.from_string("ping"))
            |> mist.event_name("ping")
          case mist.send_event(conn, event) {
            Ok(_) -> {
              let _ = process.send_after(subject, 15_000, ping)
              actor.continue(subject)
            }
            Error(_) -> actor.stop()
          }
        }
        notification ->
          case
            mist.send_event(
              conn,
              mist.event(string_tree.from_string(notification)),
            )
          {
            Ok(_) -> actor.continue(subject)
            Error(_) -> actor.stop()
          }
      }
    },
  )
}

// -- /api/account -------------------------------------------------------------

/// Account + rate-limit info backing the /status command.
fn account(ctx: Context) -> Response(ResponseData) {
  let account =
    codex.request(
      ctx.codex,
      "account/read",
      json.object([#("refreshToken", json.bool(False))]),
    )
  let rate =
    codex.request(ctx.codex, "account/rateLimits/read", json.object([]))
  let pick = fn(result: Result(Dynamic, String), field: String) -> Json {
    case result {
      Ok(value) ->
        case jsonx.field(value, [field]) {
          Ok(inner) -> jsonx.to_json(inner)
          Error(_) -> json.null()
        }
      Error(_) -> json.null()
    }
  }
  json_response(
    200,
    json.object([
      #("account", pick(account, "account")),
      #("rateLimits", pick(rate, "rateLimits")),
    ]),
  )
}

// -- /api/images --------------------------------------------------------------

const image_mime = [
  #(".gif", "image/gif"),
  #(".jpg", "image/jpeg"),
  #(".jpeg", "image/jpeg"),
  #(".png", "image/png"),
  #(".webp", "image/webp"),
]

fn extension_of(path: String) -> String {
  case string.split(path, "/") |> list.last {
    Ok(name) ->
      case string.split(name, ".") {
        [_only] -> ""
        parts ->
          case list.last(parts) {
            Ok(ext) -> "." <> string.lowercase(ext)
            Error(_) -> ""
          }
      }
    Error(_) -> ""
  }
}

fn image(req: Request(Connection)) -> Response(ResponseData) {
  let path =
    request.get_query(req)
    |> result.unwrap([])
    |> list.key_find("path")
    |> result.unwrap("")
  case string.starts_with(path, "/") {
    False ->
      json_response(
        400,
        json.object([#("message", json.string("absolute image path required"))]),
      )
    True ->
      case simplifile.is_file(path) {
        Ok(True) ->
          case list.key_find(image_mime, extension_of(path)) {
            Ok(mime) ->
              case mist.send_file(path, offset: 0, limit: None) {
                Ok(body) ->
                  response.new(200)
                  |> response.set_header("content-type", mime)
                  |> response.set_header("cache-control", "no-store")
                  |> response.set_body(body)
                Error(_) ->
                  json_response(
                    404,
                    json.object([#("message", json.string("image not found"))]),
                  )
              }
            Error(_) ->
              json_response(
                415,
                json.object([
                  #("message", json.string("unsupported image type")),
                ]),
              )
          }
        _ ->
          json_response(
            404,
            json.object([#("message", json.string("image not found"))]),
          )
      }
  }
}

// -- /api/threads -------------------------------------------------------------

/// List stored codex sessions (newest first), plus the default working dir.
fn list_threads(ctx: Context) -> Response(ResponseData) {
  case
    codex.request(
      ctx.codex,
      "thread/list",
      json.object([
        #("limit", json.int(100)),
        #("sortKey", json.string("updated_at")),
      ]),
    )
  {
    Ok(result) ->
      json_response(
        200,
        jsonx.object_with(result, [
          #("defaultCwd", json.string(codex.default_cwd())),
        ]),
      )
    Error(message) -> json_response(500, error_body(message))
  }
}

/// Create a new thread (session), optionally in a specific working directory.
fn create_thread(
  ctx: Context,
  req: Request(Connection),
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let params = defaults.thread_defaults()
  let cwd = case jsonx.field_string(body, ["cwd"]) {
    Ok(cwd) if cwd != "" -> Some(resolve_cwd(cwd))
    _ -> None
  }
  case cwd {
    Some(cwd) ->
      case directory_status(cwd) {
        DirectoryOk -> {
          let params = [#("cwd", json.string(cwd)), ..params]
          let params = case jsonx.field_string(body, ["model"]) {
            Ok(model) if model != "" -> [
              #("model", json.string(model)),
              ..params
            ]
            _ -> params
          }
          rpc(ctx, "thread/start", json.object(params))
        }
        NotADirectory ->
          json_response(400, error_body("Not a directory: " <> cwd))
        DoesNotExist ->
          json_response(400, error_body("Directory does not exist: " <> cwd))
      }
    None -> {
      let params = case jsonx.field_string(body, ["model"]) {
        Ok(model) if model != "" -> [#("model", json.string(model)), ..params]
        _ -> params
      }
      rpc(ctx, "thread/start", json.object(params))
    }
  }
}

type DirectoryStatus {
  DirectoryOk
  NotADirectory
  DoesNotExist
}

fn directory_status(path: String) -> DirectoryStatus {
  case simplifile.file_info(path) {
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.Directory -> DirectoryOk
        _ -> NotADirectory
      }
    Error(_) -> DoesNotExist
  }
}

/// Resolve relative paths against the default cwd and expand a leading `~`.
fn resolve_cwd(raw: String) -> String {
  let home = envoy.get("HOME") |> result.unwrap("/")
  let expanded = case raw {
    "~" -> home
    _ ->
      case string.starts_with(raw, "~/") {
        True -> home <> string.drop_start(raw, 1)
        False -> raw
      }
  }
  case string.starts_with(expanded, "/") {
    True -> expanded
    False -> filepath.join(codex.default_cwd(), expanded)
  }
}

// -- /api/threads/[id]/open ---------------------------------------------------

/// Open a session: resume it (loads it into memory + subscribes this
/// connection to its live events) and return its full prior history so the UI
/// can render it.
///
/// Before resuming, we check whether another codex instance on this machine
/// already has the session's rollout file open. If so we refuse with 409
/// unless the caller passes `{ force: true }`, so two codex processes don't
/// drive the same conversation concurrently.
fn open_thread(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let force = jsonx.field_bool(body, ["force"]) == Ok(True)

  // thread/read returns the rollout path + history WITHOUT loading the
  // thread. A brand-new thread isn't materialized until its first user
  // message, so thread/read can fail — treat that as "no history yet".
  let read =
    codex.request(
      ctx.codex,
      "thread/read",
      json.object([
        #("threadId", json.string(thread_id)),
        #("includeTurns", json.bool(True)),
      ]),
    )
  let rollout_path = case read {
    Ok(read) ->
      jsonx.field_string(read, ["thread", "path"]) |> result.unwrap("")
    Error(_) -> ""
  }

  let holders = case force {
    True -> []
    False ->
      session_lock.detect_external_holders(
        rollout_path,
        codex.os_pid(ctx.codex),
      )
  }
  case holders {
    [_, ..] -> {
      let base = [
        #("conflict", json.bool(True)),
        #(
          "holders",
          json.preprocessed_array(
            list.map(holders, fn(holder) {
              json.object([
                #("pid", json.int(holder.pid)),
                #("command", json.string(holder.command)),
              ])
            }),
          ),
        ),
      ]
      let body = case read {
        Ok(read) ->
          case jsonx.field(read, ["thread"]) {
            Ok(thread) ->
              list.append(base, [#("thread", jsonx.to_json(thread))])
            Error(_) -> base
          }
        Error(_) -> base
      }
      json_response(409, json.object(body))
    }
    [] -> {
      let resume =
        codex.request(
          ctx.codex,
          "thread/resume",
          json.object([
            #("threadId", json.string(thread_id)),
            ..defaults.thread_defaults()
          ]),
        )
      case resume {
        Error(message) -> json_response(500, error_body(message))
        Ok(_) ->
          case read {
            Ok(read) -> json_response(200, jsonx.to_json(read))
            Error(_) ->
              json_response(
                200,
                json.object([
                  #(
                    "thread",
                    json.object([
                      #("id", json.string(thread_id)),
                      #("turns", json.preprocessed_array([])),
                    ]),
                  ),
                ]),
              )
          }
      }
    }
  }
}

// -- /api/threads/[id]/message ------------------------------------------------

type Part {
  Part(
    name: String,
    filename: Option(String),
    content_type: Option(String),
    data: BitArray,
  )
}

fn parse_parts(
  data: BitArray,
  boundary: String,
  acc: List(Part),
) -> Result(List(Part), Nil) {
  // The whole body is read up front, so the streaming "more required"
  // continuations are treated as malformed input.
  case http.parse_multipart_headers(data, boundary) {
    Error(_) | Ok(http.MoreRequiredForHeaders(_)) -> Error(Nil)
    Ok(http.MultipartHeaders([], _)) -> Ok(list.reverse(acc))
    Ok(http.MultipartHeaders(headers, remaining)) -> {
      use body <- result.try(http.parse_multipart_body(remaining, boundary))
      use #(chunk, done, rest) <- result.try(case body {
        http.MultipartBody(chunk, done, rest) -> Ok(#(chunk, done, rest))
        http.MoreRequiredForBody(..) -> Error(Nil)
      })
      let disposition =
        list.key_find(headers, "content-disposition")
        |> result.try(fn(header) {
          http.parse_content_disposition(header)
          |> result.map(fn(d) { d.parameters })
        })
        |> result.unwrap([])
      let part =
        Part(
          name: list.key_find(disposition, "name") |> result.unwrap(""),
          filename: list.key_find(disposition, "filename")
            |> option.from_result,
          content_type: list.key_find(headers, "content-type")
            |> option.from_result,
          data: chunk,
        )
      let acc = [part, ..acc]
      case done {
        True -> Ok(list.reverse(acc))
        False -> parse_parts(rest, boundary, acc)
      }
    }
  }
}

fn boundary_of(content_type: String) -> Result(String, Nil) {
  string.split(content_type, ";")
  |> list.find_map(fn(param) {
    case string.split_once(string.trim(param), "=") {
      Ok(#("boundary", value)) ->
        Ok(case string.starts_with(value, "\"") {
          True ->
            value
            |> string.drop_start(1)
            |> string.drop_end(1)
          False -> value
        })
      _ -> Error(Nil)
    }
  })
}

const image_extension_by_type = [
  #("image/png", ".png"),
  #("image/jpeg", ".jpg"),
  #("image/webp", ".webp"),
  #("image/gif", ".gif"),
]

fn image_extension(filename: Option(String), content_type: String) -> String {
  case list.key_find(image_extension_by_type, content_type) {
    Ok(ext) -> ext
    Error(_) -> {
      let from_name = extension_of(option.unwrap(filename, ""))
      let valid =
        from_name != ""
        && string.length(from_name) <= 10
        && list.all(string.to_graphemes(from_name), fn(char) {
          string.contains("abcdefghijklmnopqrstuvwxyz0123456789.", char)
        })
      case valid {
        True -> from_name
        False -> ".img"
      }
    }
  }
}

fn stage_image(part: Part) -> Result(String, String) {
  let display = case part.filename {
    Some(name) if name != "" -> name
    _ -> "upload"
  }
  let content_type = part.content_type |> option.unwrap("") |> string.lowercase
  case string.starts_with(content_type, "image/") {
    False -> Error(display <> " is not an image")
    True -> {
      let tmp = envoy.get("TMPDIR") |> result.unwrap("/tmp")
      let name =
        "yacwu-"
        <> string.lowercase(
          bit_array.base16_encode(crypto.strong_random_bytes(16)),
        )
        <> image_extension(part.filename, content_type)
      let path = filepath.join(tmp, name)
      case simplifile.write_bits(path, part.data) {
        Ok(_) -> Ok(path)
        Error(_) -> Error("failed to store " <> display)
      }
    }
  }
}

/// Send user input, starting a new turn on the thread.
fn message(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let content_type =
    request.get_header(req, "content-type") |> result.unwrap("")
  let input = case string.contains(content_type, "multipart/form-data") {
    True -> {
      use boundary <- result.try(
        boundary_of(content_type) |> result.replace_error("invalid form data"),
      )
      use body <- result.try(
        mist.read_body(req, max_body)
        |> result.replace_error("failed to read form data"),
      )
      use parts <- result.try(
        parse_parts(body.body, boundary, [])
        |> result.replace_error("invalid form data"),
      )
      let text =
        list.find(parts, fn(part) { part.name == "text" })
        |> result.try(fn(part) {
          bit_array.to_string(part.data) |> result.replace_error(Nil)
        })
        |> result.unwrap("")
      let text_input = case string.trim(text) {
        "" -> []
        _ -> [
          json.object([
            #("type", json.string("text")),
            #("text", json.string(text)),
          ]),
        ]
      }
      let images =
        list.filter(parts, fn(part) {
          part.name == "images" && part.data != <<>>
        })
      list.try_fold(images, [], fn(acc, part) {
        stage_image(part)
        |> result.map(fn(path) {
          [
            json.object([
              #("type", json.string("localImage")),
              #("path", json.string(path)),
            ]),
            ..acc
          ]
        })
      })
      |> result.map(fn(image_inputs) {
        list.append(text_input, list.reverse(image_inputs))
      })
    }
    False -> {
      let body = read_json_body(req)
      let text = jsonx.field_string(body, ["text"]) |> result.unwrap("")
      case string.trim(text) {
        "" -> Ok([])
        _ ->
          Ok([
            json.object([
              #("type", json.string("text")),
              #("text", json.string(text)),
            ]),
          ])
      }
    }
  }

  case input {
    Error(message) -> json_response(400, error_body(message))
    Ok([]) -> json_response(400, error_body("empty message"))
    Ok(input) -> {
      let params = [
        #("threadId", json.string(thread_id)),
        #("input", json.preprocessed_array(input)),
      ]
      let params = case model_state.get_override(ctx.store, thread_id) {
        Ok(settings) ->
          list.append(params, [
            #("model", json.string(settings.model)),
            #("effort", json.string(settings.effort)),
          ])
        Error(_) -> params
      }
      rpc(ctx, "turn/start", json.object(params))
    }
  }
}

// -- Remaining thread endpoints ----------------------------------------------

/// Interrupt the in-flight turn on a thread.
fn interrupt(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let params = [#("threadId", json.string(thread_id))]
  let params = case jsonx.field(body, ["turnId"]) {
    Ok(turn_id) -> list.append(params, [#("turnId", jsonx.to_json(turn_id))])
    Error(_) -> params
  }
  rpc(ctx, "turn/interrupt", json.object(params))
}

/// Read a thread's current goal (null if none).
fn get_goal(ctx: Context, thread_id: String) -> Response(ResponseData) {
  case
    codex.request(
      ctx.codex,
      "thread/goal/get",
      json.object([#("threadId", json.string(thread_id))]),
    )
  {
    Ok(result) -> json_response(200, jsonx.to_json(result))
    Error(_) -> json_response(200, json.object([#("goal", json.null())]))
  }
}

/// Set or clear a thread's goal (the same state the TUI's /goal manages).
fn post_goal(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  case jsonx.field_bool(body, ["clear"]) == Ok(True) {
    True -> simple_rpc(ctx, "thread/goal/clear", thread_id)
    False -> {
      let objective =
        jsonx.field_string(body, ["objective"])
        |> result.unwrap("")
        |> string.trim
      case objective {
        "" -> json_response(400, error_body("goal objective is required"))
        _ ->
          case string.length(objective) > 4000 {
            True ->
              json_response(
                400,
                error_body("goal objective must be at most 4000 characters"),
              )
            False -> {
              let params = [
                #("threadId", json.string(thread_id)),
                #("objective", json.string(objective)),
                #("status", json.string("active")),
              ]
              case jsonx.field(body, ["tokenBudget"]) {
                Error(_) -> rpc(ctx, "thread/goal/set", json.object(params))
                Ok(raw) -> {
                  let budget = case jsonx.field_int(body, ["tokenBudget"]) {
                    Ok(budget) -> Ok(budget)
                    Error(_) ->
                      decode.run(raw, decode.string)
                      |> result.replace_error(Nil)
                      |> result.try(int.parse)
                  }
                  case budget {
                    Ok(budget) if budget >= 1 ->
                      rpc(
                        ctx,
                        "thread/goal/set",
                        json.object(
                          list.append(params, [
                            #("tokenBudget", json.int(budget)),
                          ]),
                        ),
                      )
                    _ ->
                      json_response(
                        400,
                        error_body("tokenBudget must be a positive integer"),
                      )
                  }
                }
              }
            }
          }
      }
    }
  }
}

fn get_model(ctx: Context, thread_id: String) -> Response(ResponseData) {
  case model_state.get_thread_model_state(ctx.codex, ctx.store, thread_id) {
    Ok(state) -> json_response(200, model_state.state_to_json(state))
    Error(message) -> json_response(500, error_body(message))
  }
}

fn post_model(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let model = case jsonx.field_string(body, ["model"]) {
    Ok(model) ->
      case string.trim(model) {
        "" -> None
        model -> Some(model)
      }
    Error(_) -> None
  }
  let effort = case jsonx.field_string(body, ["effort"]) {
    Ok(effort) ->
      case string.trim(effort) {
        "" -> None
        effort -> Some(string.lowercase(effort))
      }
    Error(_) -> None
  }
  case model, effort {
    None, None -> json_response(400, error_body("model or effort is required"))
    _, _ ->
      case
        model_state.set_thread_model_state(
          ctx.codex,
          ctx.store,
          thread_id,
          model,
          effort,
        )
      {
        Ok(state) -> json_response(200, model_state.state_to_json(state))
        Error(message) -> json_response(400, error_body(message))
      }
  }
}

/// Start a Codex review (the TUI's /review). With no instructions it reviews
/// the uncommitted changes; with free-form text it runs a custom review.
fn review(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let instructions =
    jsonx.field_string(body, ["instructions"])
    |> result.unwrap("")
    |> string.trim
  let target = case instructions {
    "" -> json.object([#("type", json.string("uncommittedChanges"))])
    _ ->
      json.object([
        #("type", json.string("custom")),
        #("instructions", json.string(instructions)),
      ])
  }
  rpc(
    ctx,
    "review/start",
    json.object([
      #("threadId", json.string(thread_id)),
      #("delivery", json.string("inline")),
      #("target", target),
    ]),
  )
}

/// Run a user-initiated shell command attached to the thread.
fn shell(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let command =
    jsonx.field_string(body, ["command"])
    |> result.unwrap("")
    |> string.trim
  case command {
    "" -> json_response(400, error_body("shell command is required"))
    _ ->
      rpc(
        ctx,
        "thread/shellCommand",
        json.object([
          #("threadId", json.string(thread_id)),
          #("command", json.string(command)),
        ]),
      )
  }
}

/// Roll back the last N turns and return the updated thread history.
fn rollback(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let num_turns = case jsonx.field(body, ["numTurns"]) {
    Error(_) -> Ok(1)
    Ok(_) -> jsonx.field_int(body, ["numTurns"]) |> result.replace_error(Nil)
  }
  case num_turns {
    Ok(num_turns) if num_turns >= 1 ->
      rpc(
        ctx,
        "thread/rollback",
        json.object([
          #("threadId", json.string(thread_id)),
          #("numTurns", json.int(num_turns)),
        ]),
      )
    _ -> json_response(400, error_body("numTurns must be a positive integer"))
  }
}
