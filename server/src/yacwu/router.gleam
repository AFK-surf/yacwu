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
import gleam/http/cookie
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
import gleam/uri
import mist.{type Connection, type ResponseData}
import simplifile
import yacwu/auth
import yacwu/codex.{type Codex}
import yacwu/defaults
import yacwu/files
import yacwu/jsonx
import yacwu/model_state.{type Store}
import yacwu/oauth
import yacwu/profiles
import yacwu/session_lock
import yacwu/static_files

pub type Context {
  Context(
    codex: Codex,
    store: Store,
    profile_store: profiles.Store,
    static_dir: String,
  )
}

const max_body = 104_857_600

pub fn handler(
  ctx: Context,
) -> fn(Request(Connection)) -> Response(ResponseData) {
  let debug = envoy.get("YACWU_DEBUG") == Ok("1")
  fn(req) {
    case gate(req) {
      Error(resp) -> resp
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

// -- Authentication gate and /oauth endpoints ---------------------------------

/// Decide whether a request may proceed, or answer it here. Two mechanisms,
/// usable together:
///
/// - forward auth: a `Remote-User` header from an authenticating reverse
///   proxy, checked against the `YACWU_REMOTE_USERS` allowlist;
/// - built-in OAuth login: a signed session cookie set by `/oauth/callback`.
///
/// A valid session cookie or a valid forward-auth header admits the request.
/// Otherwise, when OAuth is configured, browsers are sent through the login
/// flow (API callers get a plain 401); with forward auth alone the original
/// 401/403 denials apply; with neither configured everything is open.
fn gate(req: Request(Connection)) -> Result(Nil, Response(ResponseData)) {
  let oauth_config = oauth.load()
  case request.path_segments(req), oauth_config {
    // The login endpoints must be reachable while unauthenticated.
    ["oauth", "login"], Some(config) -> Error(oauth_login(req, config))
    ["oauth", "callback"], Some(config) -> Error(oauth_callback(req, config))
    ["oauth", "logout"], Some(_) -> Error(oauth_logout(req))
    _, _ -> {
      let session = case oauth_config {
        Some(config) ->
          oauth.session_user(
            cookie_value(req, oauth.session_cookie),
            allowed: config.allowed_users,
            now: oauth.now(),
            secret: oauth.cookie_secret(),
          )
        None -> Error(Nil)
      }
      case session {
        Ok(_user) -> Ok(Nil)
        Error(_) -> {
          let forward =
            auth.check_remote_user(request.get_header(req, "remote-user"))
          case auth.allowed_remote_users(), forward, oauth_config {
            [_, ..], Ok(Nil), _ -> Ok(Nil)
            _, _, Some(_) -> Error(login_required(req))
            [_, ..], Error(denial), None ->
              Error(text_response(denial.status, denial.message))
            [], _, None -> Ok(Nil)
          }
        }
      }
    }
  }
}

/// Unauthenticated while OAuth is configured: page loads bounce into the
/// login flow (remembering where they were headed); API calls get a 401 —
/// fetch/EventSource would only choke on a cross-origin redirect.
fn login_required(req: Request(Connection)) -> Response(ResponseData) {
  case request.path_segments(req), req.method {
    ["api", ..], _ -> json_response(401, error_body("authentication required"))
    _, Get | _, http.Head -> {
      let next = case req.query {
        Some(query) -> req.path <> "?" <> query
        None -> req.path
      }
      redirect("/oauth/login?" <> uri.query_to_string([#("next", next)]))
    }
    _, _ -> text_response(401, "authentication required")
  }
}

/// Start a login: stash state + PKCE verifier + destination in a short-lived
/// signed cookie and bounce to the provider's authorization endpoint.
fn oauth_login(
  req: Request(Connection),
  config: oauth.Config,
) -> Response(ResponseData) {
  case oauth.endpoints(config) {
    Error(message) ->
      text_response(502, "OAuth provider unavailable: " <> message)
    Ok(endpoints) -> {
      let next =
        request.get_query(req)
        |> result.unwrap([])
        |> list.key_find("next")
        |> result.unwrap("/")
        |> oauth.sanitize_next
      let state = oauth.random_state()
      let verifier = oauth.random_verifier()
      let sealed =
        oauth.seal(
          [
            #("state", json.string(state)),
            #("verifier", json.string(verifier)),
            #("next", json.string(next)),
          ],
          expires_at: oauth.now() + oauth.login_ttl,
          secret: oauth.cookie_secret(),
        )
      oauth.authorize_url(endpoints.auth_url, [
        #("response_type", "code"),
        #("client_id", config.client_id),
        #("redirect_uri", redirect_uri(req, config)),
        #("scope", config.scopes),
        #("state", state),
        #("code_challenge", oauth.pkce_challenge(verifier)),
        #("code_challenge_method", "S256"),
      ])
      |> redirect
      |> set_auth_cookie(req, oauth.login_cookie, sealed, oauth.login_ttl)
    }
  }
}

/// Finish a login: verify the state cookie, redeem the code (with the PKCE
/// verifier), resolve the user's identity, enforce the allowlist, and set the
/// session cookie.
fn oauth_callback(
  req: Request(Connection),
  config: oauth.Config,
) -> Response(ResponseData) {
  let query = request.get_query(req) |> result.unwrap([])
  let param = fn(name) { list.key_find(query, name) |> result.unwrap("") }
  case param("error") {
    "" ->
      case
        cookie_value(req, oauth.login_cookie)
        |> result.try(oauth.open(
          _,
          now: oauth.now(),
          secret: oauth.cookie_secret(),
        ))
      {
        Error(_) ->
          text_response(
            400,
            "OAuth login expired or state cookie missing — retry at /oauth/login",
          )
        Ok(login) -> {
          let stored_state =
            jsonx.field_string(login, ["state"]) |> result.unwrap("")
          let verifier =
            jsonx.field_string(login, ["verifier"]) |> result.unwrap("")
          let next =
            jsonx.field_string(login, ["next"])
            |> result.unwrap("/")
            |> oauth.sanitize_next
          case
            param("code"),
            stored_state != "" && param("state") == stored_state
          {
            "", _ -> text_response(400, "missing authorization code")
            _, False -> text_response(400, "OAuth state mismatch")
            code, True ->
              case complete_login(req, config, code, verifier) {
                Error(#(status, message)) -> text_response(status, message)
                Ok(user) ->
                  redirect(next)
                  |> set_auth_cookie(
                    req,
                    oauth.session_cookie,
                    oauth.seal(
                      [#("user", json.string(user))],
                      expires_at: oauth.now() + config.session_ttl,
                      secret: oauth.cookie_secret(),
                    ),
                    config.session_ttl,
                  )
                  |> set_auth_cookie(req, oauth.login_cookie, "", 0)
              }
          }
        }
      }
    error ->
      text_response(
        403,
        "OAuth provider returned an error: "
          <> error
          <> {
          case param("error_description") {
            "" -> ""
            description -> " (" <> description <> ")"
          }
        },
      )
  }
}

fn complete_login(
  req: Request(Connection),
  config: oauth.Config,
  code: String,
  verifier: String,
) -> Result(String, #(Int, String)) {
  use endpoints <- result.try(
    oauth.endpoints(config)
    |> result.map_error(fn(message) {
      #(502, "OAuth provider unavailable: " <> message)
    }),
  )
  use tokens <- result.try(
    oauth.exchange_code(
      config,
      endpoints,
      redirect_uri: redirect_uri(req, config),
      code: code,
      verifier: verifier,
    )
    |> result.map_error(fn(message) { #(502, message) }),
  )
  use user <- result.try(
    oauth.resolve_identity(config, endpoints, tokens)
    |> result.map_error(fn(message) { #(502, message) }),
  )
  case oauth.user_allowed(user, config.allowed_users) {
    True -> Ok(user)
    False -> Error(#(403, "Forbidden: " <> user <> " is not an allowed user"))
  }
}

fn oauth_logout(req: Request(Connection)) -> Response(ResponseData) {
  redirect("/")
  |> set_auth_cookie(req, oauth.session_cookie, "", 0)
}

fn cookie_value(req: Request(Connection), name: String) -> Result(String, Nil) {
  request.get_cookies(req) |> list.key_find(name)
}

fn redirect(location: String) -> Response(ResponseData) {
  response.new(302)
  |> response.set_header("location", location)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

/// Set (or, with an empty value and zero max-age, clear) one of our HttpOnly
/// auth cookies, marking it Secure when the client reached us over HTTPS.
fn set_auth_cookie(
  resp: Response(ResponseData),
  req: Request(Connection),
  name: String,
  value: String,
  max_age: Int,
) -> Response(ResponseData) {
  response.set_cookie(
    resp,
    name,
    value,
    cookie.Attributes(
      ..cookie.defaults(forwarded_scheme(req)),
      max_age: Some(max_age),
    ),
  )
}

/// The scheme the client used, honouring the reverse proxy's
/// `X-Forwarded-Proto` (mist itself always terminates plain HTTP).
fn forwarded_scheme(req: Request(Connection)) -> http.Scheme {
  case request.get_header(req, "x-forwarded-proto") {
    Ok("https") -> http.Https
    _ -> http.Http
  }
}

/// The absolute callback URL registered with the provider: explicit
/// configuration, or derived from the forwarding headers / Host of this
/// request.
fn redirect_uri(req: Request(Connection), config: oauth.Config) -> String {
  case config.redirect_url {
    Some(url) -> url
    None -> {
      let host =
        request.get_header(req, "x-forwarded-host")
        |> result.lazy_or(fn() { request.get_header(req, "host") })
        |> result.unwrap("127.0.0.1")
      http.scheme_to_string(forwarded_scheme(req))
      <> "://"
      <> host
      <> "/oauth/callback"
    }
  }
}

/// HEAD requests answer like GET — same status and headers, empty body —
/// mirroring the automatic HEAD handling of the original SvelteKit/Bun stack
/// (`curl -I`, reverse-proxy health checks, …).
fn route(ctx: Context, req: Request(Connection)) -> Response(ResponseData) {
  case req.method {
    http.Head -> {
      let resp = dispatch(ctx, request.set_method(req, Get), False)
      // File and SSE responses are already body-less for HEAD; strip only
      // buffered byte bodies.
      case resp.body {
        mist.Bytes(_) -> response.set_body(resp, mist.Bytes(bytes_tree.new()))
        _ -> resp
      }
    }
    _ -> dispatch(ctx, req, True)
  }
}

fn dispatch(
  ctx: Context,
  req: Request(Connection),
  include_body: Bool,
) -> Response(ResponseData) {
  case request.path_segments(req), req.method {
    ["api", "events"], Get ->
      case include_body {
        True -> sse(ctx, req)
        False ->
          // Advertise the stream without hijacking the socket.
          response.new(200)
          |> response.set_header("content-type", "text/event-stream")
          |> response.set_header("cache-control", "no-cache")
          |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    ["api", "account"], Get -> account(ctx)
    ["api", "images"], Get -> image(req, include_body)
    ["api", "profiles"], Get -> list_profiles()
    ["api", "threads", id, "profile"], Get -> get_profile(ctx, id)
    ["api", "threads", id, "profile"], Post -> post_profile(ctx, req, id)
    ["api", "threads"], Get -> list_threads(ctx)
    ["api", "threads"], Post -> create_thread(ctx, req)
    ["api", "threads", "loaded"], Get -> loaded_threads(ctx)
    ["api", "threads", id], Get -> read_thread(ctx, id)
    ["api", "threads", id, "open"], Post -> open_thread(ctx, req, id)
    ["api", "threads", id, "files"], Get -> list_files(ctx, req, id)
    ["api", "threads", id, "file"], Get -> read_file(ctx, req, id)
    ["api", "threads", id, "message"], Post -> message(ctx, req, id)
    ["api", "threads", id, "interrupt"], Post -> interrupt(ctx, req, id)
    ["api", "threads", id, "goal"], Get -> get_goal(ctx, id)
    ["api", "threads", id, "goal"], Post -> post_goal(ctx, req, id)
    ["api", "threads", id, "model"], Get -> get_model(ctx, id)
    ["api", "threads", id, "model"], Post -> post_model(ctx, req, id)
    ["api", "threads", id, "fast"], Post -> post_fast(ctx, req, id)
    ["api", "threads", id, "compact"], Post ->
      simple_rpc(ctx, "thread/compact/start", id)
    ["api", "threads", id, "review"], Post -> review(ctx, req, id)
    ["api", "threads", id, "shell"], Post -> shell(ctx, req, id)
    ["api", "threads", id, "rollback"], Post -> rollback(ctx, req, id)
    ["api", "threads", id, "fork"], Post -> fork(ctx, req, id)
    ["api", "threads", id, "archive"], Post ->
      simple_rpc(ctx, "thread/archive", id)
    ["api", "threads", id, "unsubscribe"], Post ->
      simple_rpc(ctx, "thread/unsubscribe", id)
    ["api", "threads", id, "unarchive"], Post ->
      simple_rpc(ctx, "thread/unarchive", id)
    ["api", ..], _ -> json_response(404, error_body("not found"))
    _, Get -> static_files.serve(ctx.static_dir, req.path, include_body)
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

fn image(
  req: Request(Connection),
  include_body: Bool,
) -> Response(ResponseData) {
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
              case
                case include_body {
                  True -> mist.send_file(path, offset: 0, limit: None)
                  False -> Ok(mist.Bytes(bytes_tree.new()))
                }
              {
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

// -- /api/threads/[id]/files and /api/threads/[id]/file -----------------------

/// The session's working directory, which roots all file browsing.
fn thread_root(ctx: Context, thread_id: String) -> Result(String, String) {
  case
    codex.request(
      ctx.codex,
      "thread/read",
      json.object([
        #("threadId", json.string(thread_id)),
        #("includeTurns", json.bool(False)),
      ]),
    )
  {
    Ok(read) ->
      case jsonx.field_string(read, ["thread", "cwd"]) {
        Ok(cwd) if cwd != "" -> Ok(cwd)
        _ -> Error("session working directory unavailable")
      }
    Error(message) -> Error(message)
  }
}

/// The sanitized `path` query parameter ("" is the session root).
fn query_rel_path(req: Request(Connection)) -> Result(String, Nil) {
  request.get_query(req)
  |> result.unwrap([])
  |> list.key_find("path")
  |> result.unwrap("")
  |> files.sanitize
}

fn list_files(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  case query_rel_path(req) {
    Error(_) -> json_response(400, error_body("invalid path"))
    Ok(rel) ->
      case thread_root(ctx, thread_id) {
        Error(message) -> json_response(500, error_body(message))
        Ok(root) ->
          case files.list_directory(files.resolve(root, rel)) {
            Error(message) -> json_response(404, error_body(message))
            Ok(entries) ->
              json_response(
                200,
                json.object([
                  #("root", json.string(root)),
                  #("path", json.string(rel)),
                  #("entries", files.entries_to_json(entries)),
                ]),
              )
          }
      }
  }
}

fn read_file(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  case query_rel_path(req) {
    Error(_) -> json_response(400, error_body("invalid path"))
    Ok("") -> json_response(400, error_body("file path is required"))
    Ok(rel) ->
      case thread_root(ctx, thread_id) {
        Error(message) -> json_response(500, error_body(message))
        Ok(root) -> {
          let meta = fn(size: Int) {
            [#("path", json.string(rel)), #("size", json.int(size))]
          }
          case files.read_file(files.resolve(root, rel)) {
            files.Text(size, content) ->
              json_response(
                200,
                json.object([#("content", json.string(content)), ..meta(size)]),
              )
            files.Binary(size) ->
              json_response(
                200,
                json.object([#("binary", json.bool(True)), ..meta(size)]),
              )
            files.TooLarge(size) ->
              json_response(
                200,
                json.object([#("tooLarge", json.bool(True)), ..meta(size)]),
              )
            files.Missing -> json_response(404, error_body("file not found"))
          }
        }
      }
  }
}

// -- /api/profiles and /api/threads/[id]/profile ------------------------------

/// Available codex profiles ($CODEX_HOME/<name>.config.toml files).
fn list_profiles() -> Response(ResponseData) {
  json_response(
    200,
    json.object([
      #("profiles", profiles.profiles_to_json(profiles.list_profiles())),
    ]),
  )
}

/// The profile a session is using: its stored selection if this server made
/// one, otherwise inferred as the profile whose `model` matches the session's
/// current model (so selections survive server restarts). A successful
/// inference is stored.
fn resolve_profile(
  ctx: Context,
  thread_id: String,
  available: List(profiles.Profile),
  rollout_path: Result(String, Nil),
) -> Result(profiles.Profile, Nil) {
  case profiles.get_selection(ctx.profile_store, thread_id) {
    Ok(name) -> profiles.find(available, name)
    Error(_) -> {
      use path <- result.try(rollout_path)
      use persisted <- result.try(model_state.read_latest_turn_model(path))
      use model <- result.try(option.to_result(persisted.model, Nil))
      use profile <- result.try(profiles.infer_for_model(available, model))
      profiles.set_selection(ctx.profile_store, thread_id, Some(profile.name))
      Ok(profile)
    }
  }
}

/// The session's rollout path, for profile inference (absent for threads that
/// haven't materialized yet).
fn thread_rollout_path(ctx: Context, thread_id: String) -> Result(String, Nil) {
  codex.request(
    ctx.codex,
    "thread/read",
    json.object([
      #("threadId", json.string(thread_id)),
      #("includeTurns", json.bool(False)),
    ]),
  )
  |> result.replace_error(Nil)
  |> result.try(jsonx.field_string(_, ["thread", "path"]))
}

/// The model/effort supplied by a session's profile, as a fallback layer for
/// model resolution (empty when the session has no profile).
fn profile_model_settings(
  ctx: Context,
  thread_id: String,
) -> model_state.Persisted {
  case
    resolve_profile(
      ctx,
      thread_id,
      profiles.list_profiles(),
      thread_rollout_path(ctx, thread_id),
    )
  {
    Ok(profile) ->
      model_state.Persisted(
        model: profile.model,
        effort: jsonx.field_string(profile.config, ["model_reasoning_effort"])
          |> option.from_result,
      )
    Error(_) -> model_state.Persisted(model: None, effort: None)
  }
}

fn profile_state_json(
  selected: Result(profiles.Profile, Nil),
  available: List(profiles.Profile),
) -> Json {
  json.object([
    #("profile", case selected {
      Ok(profile) -> json.string(profile.name)
      Error(_) -> json.null()
    }),
    #("profiles", profiles.profiles_to_json(available)),
  ])
}

fn get_profile(ctx: Context, thread_id: String) -> Response(ResponseData) {
  let available = profiles.list_profiles()
  let selected =
    resolve_profile(ctx, thread_id, available, {
      thread_rollout_path(ctx, thread_id)
    })
  json_response(200, profile_state_json(selected, available))
}

/// Select (or clear) a session's profile. Selecting re-resumes the thread
/// with the profile's config layered in, so it takes effect immediately;
/// clearing only affects how future opens resolve — settings already
/// persisted on the thread remain until changed.
fn post_profile(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let available = profiles.list_profiles()
  let requested =
    jsonx.field_string(body, ["profile"])
    |> result.unwrap("")
    |> string.trim
  case jsonx.field_bool(body, ["clear"]) == Ok(True) || requested == "" {
    True -> {
      profiles.set_selection(ctx.profile_store, thread_id, None)
      json_response(200, profile_state_json(Error(Nil), available))
    }
    False ->
      case profiles.find(available, requested) {
        Error(_) ->
          json_response(400, error_body("unknown profile: " <> requested))
        Ok(profile) -> {
          profiles.set_selection(
            ctx.profile_store,
            thread_id,
            Some(profile.name),
          )
          // Re-resume with the profile layered in so the full config applies
          // immediately. A brand-new thread has no rollout to resume yet —
          // the selection still holds: its model/effort ride along on
          // turn/start, and the full config layers in on the next open.
          let _ =
            codex.request(
              ctx.codex,
              "thread/resume",
              json.object([
                #("threadId", json.string(thread_id)),
                #("config", profiles.config_json(profile)),
                ..defaults.thread_defaults()
              ]),
            )
          json_response(200, profile_state_json(Ok(profile), available))
        }
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
        // Unset (or null) restricts the listing to the *current* provider,
        // hiding sessions created under profiles with custom providers. An
        // explicit empty array means "all providers" (per the generated
        // schema; the prose protocol docs say otherwise).
        #("modelProviders", json.preprocessed_array([])),
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

/// List thread ids currently loaded in codex memory. Ephemeral side chats
/// never appear in thread/list, so the UI uses this to re-attach them.
fn loaded_threads(ctx: Context) -> Response(ResponseData) {
  rpc(ctx, "thread/loaded/list", json.object([]))
}

/// Read one thread's metadata without loading it or including turns.
fn read_thread(ctx: Context, thread_id: String) -> Response(ResponseData) {
  rpc(
    ctx,
    "thread/read",
    json.object([
      #("threadId", json.string(thread_id)),
      #("includeTurns", json.bool(False)),
    ]),
  )
}

/// Create a new thread (session), optionally in a specific working directory.
fn create_thread(
  ctx: Context,
  req: Request(Connection),
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let params = defaults.thread_defaults()
  let params = case jsonx.field_string(body, ["model"]) {
    Ok(model) if model != "" -> [#("model", json.string(model)), ..params]
    _ -> params
  }

  let cwd_params = case jsonx.field_string(body, ["cwd"]) {
    Ok(cwd) if cwd != "" -> {
      let cwd = resolve_cwd(cwd)
      case directory_status(cwd) {
        DirectoryOk -> Ok([#("cwd", json.string(cwd)), ..params])
        NotADirectory -> Error("Not a directory: " <> cwd)
        DoesNotExist -> Error("Directory does not exist: " <> cwd)
      }
    }
    _ -> Ok(params)
  }

  let profile = case jsonx.field_string(body, ["profile"]) {
    Ok(name) if name != "" ->
      case profiles.find(profiles.list_profiles(), string.trim(name)) {
        Ok(profile) -> Ok(Some(profile))
        Error(_) -> Error("unknown profile: " <> string.trim(name))
      }
    _ -> Ok(None)
  }

  case cwd_params, profile {
    Error(message), _ | _, Error(message) ->
      json_response(400, error_body(message))
    Ok(params), Ok(profile) -> {
      let params = case profile {
        Some(profile) -> [#("config", profiles.config_json(profile)), ..params]
        None -> params
      }
      case codex.request(ctx.codex, "thread/start", json.object(params)) {
        Error(message) -> json_response(500, error_body(message))
        Ok(result) -> {
          // Remember the choice for opens/resumes on this server.
          case profile, jsonx.field_string(result, ["thread", "id"]) {
            Some(profile), Ok(thread_id) ->
              profiles.set_selection(
                ctx.profile_store,
                thread_id,
                Some(profile.name),
              )
            _, _ -> Nil
          }
          json_response(200, jsonx.to_json(result))
        }
      }
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
      // Layer the session's profile (chosen earlier, or inferred from the
      // session's model) into the resume. Profiles are re-read from disk on
      // every open so edits to the files take effect immediately.
      let profile =
        resolve_profile(
          ctx,
          thread_id,
          profiles.list_profiles(),
          case rollout_path {
            "" -> Error(Nil)
            path -> Ok(path)
          },
        )
      let resume_params = [
        #("threadId", json.string(thread_id)),
        ..defaults.thread_defaults()
      ]
      let resume_params = case profile {
        Ok(profile) -> [
          #("config", profiles.config_json(profile)),
          ..resume_params
        ]
        Error(_) -> resume_params
      }
      let resume =
        codex.request(ctx.codex, "thread/resume", json.object(resume_params))
      case resume {
        Error(message) ->
          case read {
            // Ephemeral side chats have no rollout to resume, but they are
            // already loaded and thread/read rebuilds their turns from the
            // live history — serve that instead of failing the open.
            Ok(read) -> json_response(200, jsonx.to_json(read))
            Error(_) -> json_response(500, error_body(message))
          }
        Ok(resume) -> {
          let service_tier = case jsonx.field(resume, ["serviceTier"]) {
            Ok(value) -> jsonx.to_json(value)
            Error(_) -> json.null()
          }
          case read {
            Ok(read) ->
              json_response(
                200,
                jsonx.object_with(read, [#("serviceTier", service_tier)]),
              )
            Error(_) ->
              json_response(
                200,
                json.object([
                  #("serviceTier", service_tier),
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
      // An explicit /model override wins; otherwise the session's selected
      // profile supplies model/effort. (turn/start has no `config` param, so
      // only these two profile keys can apply at turn level — the full
      // profile config is layered on thread start/resume.)
      let params = case model_state.get_override(ctx.store, thread_id) {
        Ok(settings) ->
          list.append(params, [
            #("model", json.string(settings.model)),
            #("effort", json.string(settings.effort)),
          ])
        Error(_) ->
          case
            profiles.get_selection(ctx.profile_store, thread_id)
            |> result.try(profiles.find(profiles.list_profiles(), _))
          {
            Error(_) -> params
            Ok(profile) -> {
              let params = case profile.model {
                Some(model) ->
                  list.append(params, [#("model", json.string(model))])
                None -> params
              }
              case
                jsonx.field_string(profile.config, ["model_reasoning_effort"])
              {
                Ok(effort) ->
                  list.append(params, [#("effort", json.string(effort))])
                Error(_) -> params
              }
            }
          }
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
  case
    model_state.get_thread_model_state(
      ctx.codex,
      ctx.store,
      thread_id,
      profile: profile_model_settings(ctx, thread_id),
    )
  {
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
          profile: profile_model_settings(ctx, thread_id),
        )
      {
        Ok(state) -> json_response(200, model_state.state_to_json(state))
        Error(message) -> json_response(400, error_body(message))
      }
  }
}

/// Toggle Codex Fast mode for subsequent turns on a loaded thread. Codex
/// exposes Fast mode as the `priority` service tier; an explicit null restores
/// standard routing and prevents a model-catalog default from re-enabling it.
fn post_fast(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  case jsonx.field_bool(body, ["enabled"]) {
    Error(_) -> json_response(400, error_body("enabled must be a boolean"))
    Ok(enabled) -> {
      let service_tier = case enabled {
        True -> json.string("priority")
        False -> json.null()
      }
      case
        codex.request(
          ctx.codex,
          "thread/settings/update",
          json.object([
            #("threadId", json.string(thread_id)),
            #("serviceTier", service_tier),
          ]),
        )
      {
        Ok(_) ->
          json_response(200, json.object([#("enabled", json.bool(enabled))]))
        Error(message) -> json_response(400, error_body(message))
      }
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

/// Fork a thread into a new thread id. Optional body fields: `ephemeral`
/// (non-persisted fork, used by /btw side conversations) and
/// `developerInstructions` (extra instructions layered onto the fork).
fn fork(
  ctx: Context,
  req: Request(Connection),
  thread_id: String,
) -> Response(ResponseData) {
  let body = read_json_body(req)
  let extra = case jsonx.field_bool(body, ["ephemeral"]) {
    Ok(True) -> [#("ephemeral", json.bool(True))]
    _ -> []
  }
  let extra = case jsonx.field_string(body, ["developerInstructions"]) {
    Ok(instructions) ->
      case string.trim(instructions) {
        "" -> extra
        instructions -> [
          #("developerInstructions", json.string(instructions)),
          ..extra
        ]
      }
    Error(_) -> extra
  }
  rpc(
    ctx,
    "thread/fork",
    json.object([#("threadId", json.string(thread_id)), ..extra]),
  )
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
