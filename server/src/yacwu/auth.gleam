//// Authentication configuration: read from the environment once at server
//// start into an immutable value that the router carries for the lifetime of
//// the process.
////
//// Two mechanisms, usable together:
////
//// - forward auth: `YACWU_REMOTE_USERS` (or the `--remote-user` flag, which
////   sets that variable) is a comma-separated allowlist; every request must
////   carry a `Remote-User` header — injected by an authenticating reverse
////   proxy (Authelia, Traefik forward-auth, oauth2-proxy, …) — whose value
////   is in the list.
//// - built-in OAuth login: see `yacwu/oauth`.
////
//// With neither configured the server refuses to start unless
//// `YACWU_INSECURE_SKIP_AUTH=1` explicitly opts into serving without
//// authentication.

import envoy
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import yacwu/oauth

pub type Config {
  Config(
    remote_users: List(String),
    oauth: Option(oauth.Config),
    insecure_skip_auth: Bool,
  )
}

pub type Denial {
  Denial(status: Int, message: String)
}

/// Read the authentication configuration from the environment. Called once,
/// at server start.
pub fn load() -> Config {
  Config(
    remote_users: envoy.get("YACWU_REMOTE_USERS")
      |> result.unwrap("")
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(user) { user != "" }),
    oauth: oauth.load(),
    insecure_skip_auth: envoy.get("YACWU_INSECURE_SKIP_AUTH") == Ok("1"),
  )
}

/// True when at least one authentication mechanism is configured.
pub fn configured(config: Config) -> Bool {
  config.remote_users != [] || option.is_some(config.oauth)
}

/// Returns `Error(denial)` when the request must be rejected, `Ok(Nil)` when
/// allowed. No-op when the allowlist is empty.
pub fn check_remote_user(
  header: Result(String, Nil),
  allowed allowed: List(String),
) -> Result(Nil, Denial) {
  case allowed {
    [] -> Ok(Nil)
    allowed -> {
      let user = case header {
        Ok(value) -> string.trim(value)
        Error(_) -> ""
      }
      case user {
        "" -> Error(Denial(401, "Missing Remote-User header"))
        user ->
          case list.contains(allowed, user) {
            True -> Ok(Nil)
            False -> Error(Denial(403, "Forbidden"))
          }
      }
    }
  }
}
