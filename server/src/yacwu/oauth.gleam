//// Built-in OAuth 2.0 / OpenID Connect login (authorization code + PKCE).
////
//// An alternative to forward auth for deployments without an authenticating
//// reverse proxy: yacwu itself redirects unauthenticated browsers to an OAuth
//// provider, exchanges the returned code for tokens, and keeps the user
//// logged in with an HMAC-signed cookie — no storage layer, matching the
//// rest of the server.
////
//// Enabled when `YACWU_OAUTH_CLIENT_ID` is set together with either
//// `YACWU_OAUTH_ISSUER` (endpoints found via OIDC discovery) or explicit
//// `YACWU_OAUTH_AUTH_URL` + `YACWU_OAUTH_TOKEN_URL`. The user's identity is
//// read from the id_token claims when the provider issues one, otherwise
//// from the userinfo endpoint (`YACWU_OAUTH_USERINFO_URL`, or discovered) —
//// which also covers plain OAuth 2.0 providers like GitHub.
////
//// State that must survive the round-trip to the provider (CSRF state, PKCE
//// verifier, post-login destination) travels in a short-lived signed cookie,
//// so the flow is stateless server-side. The signing secret is
//// `YACWU_OAUTH_COOKIE_SECRET`; when unset a random secret is generated into
//// the config at load time (sessions then survive only until the next
//// restart).

import envoy
import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import yacwu/jsonx

/// Cookie carrying the signed logged-in session.
pub const session_cookie = "yacwu_session"

/// Short-lived cookie carrying the signed in-flight login (state, verifier,
/// destination).
pub const login_cookie = "yacwu_oauth"

/// How long an in-flight login (redirect to the provider and back) may take.
pub const login_ttl = 600

const secret_var = "YACWU_OAUTH_COOKIE_SECRET"

const default_scopes = "openid profile email"

const default_session_ttl = 604_800

pub type Config {
  Config(
    client_id: String,
    client_secret: String,
    issuer: Option(String),
    auth_url: Option(String),
    token_url: Option(String),
    userinfo_url: Option(String),
    scopes: String,
    user_claim: Option(String),
    allowed_users: List(String),
    redirect_url: Option(String),
    session_ttl: Int,
    secret: BitArray,
  )
}

/// The provider endpoints actually used for a login, after discovery.
pub type Endpoints {
  Endpoints(auth_url: String, token_url: String, userinfo_url: Option(String))
}

/// Read the OAuth configuration from the environment. `None` means OAuth is
/// disabled: no client id, or neither an issuer nor explicit auth+token URLs.
/// Called once, at server start (via `auth.load`).
pub fn load() -> Option(Config) {
  case env("YACWU_OAUTH_CLIENT_ID") {
    Error(_) -> None
    Ok(client_id) -> {
      let issuer = env("YACWU_OAUTH_ISSUER") |> option.from_result
      let auth_url = env("YACWU_OAUTH_AUTH_URL") |> option.from_result
      let token_url = env("YACWU_OAUTH_TOKEN_URL") |> option.from_result
      let usable = case issuer, auth_url, token_url {
        Some(_), _, _ -> True
        None, Some(_), Some(_) -> True
        None, _, _ -> False
      }
      case usable {
        False -> None
        True ->
          Some(Config(
            client_id: client_id,
            client_secret: env("YACWU_OAUTH_CLIENT_SECRET") |> result.unwrap(""),
            issuer: issuer,
            auth_url: auth_url,
            token_url: token_url,
            userinfo_url: env("YACWU_OAUTH_USERINFO_URL") |> option.from_result,
            scopes: env("YACWU_OAUTH_SCOPES") |> result.unwrap(default_scopes),
            user_claim: env("YACWU_OAUTH_USER_CLAIM") |> option.from_result,
            allowed_users: env("YACWU_OAUTH_USERS")
              |> result.unwrap("")
              |> split_users,
            redirect_url: env("YACWU_OAUTH_REDIRECT_URL") |> option.from_result,
            session_ttl: env("YACWU_OAUTH_SESSION_TTL")
              |> result.try(fn(raw) {
                int.parse(raw) |> result.replace_error(Nil)
              })
              |> result.unwrap(default_session_ttl),
            secret: cookie_secret(),
          ))
      }
    }
  }
}

fn env(name: String) -> Result(String, Nil) {
  case envoy.get(name) {
    Ok(raw) ->
      case string.trim(raw) {
        "" -> Error(Nil)
        value -> Ok(value)
      }
    Error(_) -> Error(Nil)
  }
}

fn split_users(raw: String) -> List(String) {
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(user) { user != "" })
}

// -- Cookie secret ------------------------------------------------------------

/// The cookie-signing key material: `YACWU_OAUTH_COOKIE_SECRET`, or a fresh
/// random secret when unset. Resolved into the config at load time, so every
/// request signs and verifies with the same key.
fn cookie_secret() -> BitArray {
  case env(secret_var) {
    Ok(value) -> bit_array.from_string(value)
    Error(_) -> crypto.strong_random_bytes(32)
  }
}

// -- Signed, expiring values --------------------------------------------------

/// Seal fields into a tamper-proof cookie value with an expiry timestamp.
pub fn seal(
  fields: List(#(String, Json)),
  expires_at expires_at: Int,
  secret secret: BitArray,
) -> String {
  json.object([#("exp", json.int(expires_at)), ..fields])
  |> json.to_string
  |> bit_array.from_string
  |> crypto.sign_message(secret, crypto.Sha256)
}

/// Verify and decode a sealed value, rejecting bad signatures and anything
/// past its expiry.
pub fn open(
  sealed: String,
  now now: Int,
  secret secret: BitArray,
) -> Result(Dynamic, Nil) {
  use payload <- result.try(crypto.verify_signed_message(sealed, secret))
  use fields <- result.try(
    json.parse_bits(payload, decode.dynamic) |> result.replace_error(Nil),
  )
  use expires_at <- result.try(jsonx.field_int(fields, ["exp"]))
  case expires_at > now {
    True -> Ok(fields)
    False -> Error(Nil)
  }
}

/// The logged-in user carried by a session cookie, if the cookie verifies,
/// hasn't expired, and the user is in the allowlist. The allowlist applies on
/// every request, so a cookie signed under an older allowlist doesn't outlive
/// the user's removal from it.
pub fn session_user(
  cookie: Result(String, Nil),
  allowed allowed: List(String),
  now now: Int,
  secret secret: BitArray,
) -> Result(String, Nil) {
  use sealed <- result.try(cookie)
  use fields <- result.try(open(sealed, now, secret))
  use user <- result.try(jsonx.field_string(fields, ["user"]))
  case user != "" && user_allowed(user, allowed) {
    True -> Ok(user)
    False -> Error(Nil)
  }
}

/// An empty allowlist admits any user the provider authenticates.
pub fn user_allowed(user: String, allowed: List(String)) -> Bool {
  case allowed {
    [] -> True
    _ -> list.contains(allowed, user)
  }
}

// -- Login flow building blocks -----------------------------------------------

/// A fresh PKCE code verifier (43 characters of base64url).
pub fn random_verifier() -> String {
  bit_array.base64_url_encode(crypto.strong_random_bytes(32), False)
}

/// A fresh opaque state token.
pub fn random_state() -> String {
  string.lowercase(bit_array.base16_encode(crypto.strong_random_bytes(16)))
}

/// The S256 code challenge for a PKCE verifier (RFC 7636).
pub fn pkce_challenge(verifier: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(verifier))
  |> bit_array.base64_url_encode(False)
}

/// Build the provider authorization URL, preserving any query the configured
/// endpoint already carries.
pub fn authorize_url(
  auth_url: String,
  params: List(#(String, String)),
) -> String {
  let separator = case string.contains(auth_url, "?") {
    True -> "&"
    False -> "?"
  }
  auth_url <> separator <> uri.query_to_string(params)
}

/// Only same-site absolute paths survive as post-login destinations, so the
/// `next` parameter can't become an open redirect.
pub fn sanitize_next(raw: String) -> String {
  case
    string.starts_with(raw, "/")
    && !string.starts_with(raw, "//")
    && !string.contains(raw, "\\")
  {
    True -> raw
    False -> "/"
  }
}

// -- Provider endpoints -------------------------------------------------------

/// Resolve the endpoints for a login: explicit URLs win, anything missing is
/// filled in from the issuer's OIDC discovery document. Fetched per login —
/// logins are rare and this keeps provider config edits instant.
pub fn endpoints(config: Config) -> Result(Endpoints, String) {
  case config.auth_url, config.token_url {
    Some(auth_url), Some(token_url) ->
      Ok(Endpoints(auth_url, token_url, config.userinfo_url))
    _, _ ->
      case config.issuer {
        None -> Error("no issuer or explicit endpoints configured")
        Some(issuer) -> {
          use discovered <- result.try(discover(issuer))
          Ok(Endpoints(
            auth_url: option.unwrap(config.auth_url, discovered.auth_url),
            token_url: option.unwrap(config.token_url, discovered.token_url),
            userinfo_url: option.or(
              config.userinfo_url,
              discovered.userinfo_url,
            ),
          ))
        }
      }
  }
}

fn discover(issuer: String) -> Result(Endpoints, String) {
  let base = case string.ends_with(issuer, "/") {
    True -> string.drop_end(issuer, 1)
    False -> issuer
  }
  let url = base <> "/.well-known/openid-configuration"
  use document <- result.try(get_json(url, []))
  use auth_url <- result.try(
    jsonx.field_string(document, ["authorization_endpoint"])
    |> result.replace_error("discovery document has no authorization_endpoint"),
  )
  use token_url <- result.try(
    jsonx.field_string(document, ["token_endpoint"])
    |> result.replace_error("discovery document has no token_endpoint"),
  )
  Ok(Endpoints(
    auth_url: auth_url,
    token_url: token_url,
    userinfo_url: jsonx.field_string(document, ["userinfo_endpoint"])
      |> option.from_result,
  ))
}

// -- Token exchange and identity ----------------------------------------------

/// Redeem an authorization code at the token endpoint. Returns the decoded
/// token response.
pub fn exchange_code(
  config: Config,
  endpoints: Endpoints,
  redirect_uri redirect_uri: String,
  code code: String,
  verifier verifier: String,
) -> Result(Dynamic, String) {
  let params = [
    #("grant_type", "authorization_code"),
    #("code", code),
    #("redirect_uri", redirect_uri),
    #("client_id", config.client_id),
    #("code_verifier", verifier),
  ]
  let params = case config.client_secret {
    "" -> params
    secret -> [#("client_secret", secret), ..params]
  }
  use base <- result.try(
    request.to(endpoints.token_url)
    |> result.replace_error("invalid token URL: " <> endpoints.token_url),
  )
  let req =
    base
    |> request.set_method(http.Post)
    |> request.prepend_header(
      "content-type",
      "application/x-www-form-urlencoded",
    )
    |> request.prepend_header("accept", "application/json")
    |> request.set_body(uri.query_to_string(params))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(error) {
      "token request failed: " <> string.inspect(error)
    }),
  )
  case resp.status {
    200 ->
      json.parse(resp.body, decode.dynamic)
      |> result.replace_error("token endpoint returned invalid JSON")
    status -> Error("token endpoint returned HTTP " <> int.to_string(status))
  }
}

/// Determine who logged in: the configured claim (or a sensible default
/// chain) from the id_token if the provider issued one, falling back to the
/// userinfo endpoint with the access token.
pub fn resolve_identity(
  config: Config,
  endpoints: Endpoints,
  tokens: Dynamic,
) -> Result(String, String) {
  let from_id_token =
    jsonx.field_string(tokens, ["id_token"])
    |> result.try(jwt_claims)
    |> result.try(identity_from_claims(_, config.user_claim))
  case from_id_token {
    Ok(user) -> Ok(user)
    Error(_) ->
      case
        endpoints.userinfo_url,
        jsonx.field_string(tokens, ["access_token"])
      {
        Some(url), Ok(access_token) -> {
          use claims <- result.try(
            get_json(url, [
              #("authorization", "Bearer " <> access_token),
            ]),
          )
          identity_from_claims(claims, config.user_claim)
          |> result.replace_error(
            "no usable identity claim in the userinfo response",
          )
        }
        _, _ ->
          Error("could not determine the user identity from the token response")
      }
  }
}

/// Decode a JWT's claims without verifying its signature — only ever applied
/// to id_tokens received directly from the token endpoint over TLS, where the
/// transport already authenticates the issuer.
pub fn jwt_claims(token: String) -> Result(Dynamic, Nil) {
  case string.split(token, ".") {
    [_, payload, ..] ->
      bit_array.base64_url_decode(payload)
      |> result.try(fn(bits) {
        json.parse_bits(bits, decode.dynamic) |> result.replace_error(Nil)
      })
    _ -> Error(Nil)
  }
}

/// Pick the user identity out of a claims object: the configured claim, or
/// the first non-empty of preferred_username / email / login / sub. `login`
/// covers GitHub's userinfo shape.
pub fn identity_from_claims(
  claims: Dynamic,
  user_claim: Option(String),
) -> Result(String, Nil) {
  let candidates = case user_claim {
    Some(claim) -> [claim]
    None -> ["preferred_username", "email", "login", "sub"]
  }
  list.find_map(candidates, fn(claim) {
    use value <- result.try(jsonx.field_string(claims, [claim]))
    case string.trim(value) {
      "" -> Error(Nil)
      user -> Ok(user)
    }
  })
}

// -- Shared HTTP helper -------------------------------------------------------

fn get_json(
  url: String,
  headers: List(#(String, String)),
) -> Result(Dynamic, String) {
  use base <- result.try(
    request.to(url) |> result.replace_error("invalid URL: " <> url),
  )
  let req =
    list.fold(headers, base, fn(req, header) {
      request.prepend_header(req, header.0, header.1)
    })
    |> request.prepend_header("accept", "application/json")
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(error) {
      "request to " <> url <> " failed: " <> string.inspect(error)
    }),
  )
  case resp.status {
    200 ->
      json.parse(resp.body, decode.dynamic)
      |> result.replace_error(url <> " returned invalid JSON")
    status -> Error(url <> " returned HTTP " <> int.to_string(status))
  }
}

// -- Time ---------------------------------------------------------------------

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn erl_system_time(unit: TimeUnit) -> Int

/// Current Unix time in seconds.
pub fn now() -> Int {
  erl_system_time(Second)
}
