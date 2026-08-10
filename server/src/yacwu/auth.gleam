//// Forward-auth support.
////
//// When `YACWU_REMOTE_USERS` is set to a comma-separated allowlist, every
//// request must carry a `Remote-User` header whose value is in the list. This
//// is the header reverse proxies (Authelia, Traefik forward-auth,
//// oauth2-proxy, …) inject after authenticating the user. When the variable
//// is empty/unset, auth is off.
////
//// The `--remote-user` flag sets `YACWU_REMOTE_USERS`, so the same code path
//// covers every way of running the server.

import envoy
import gleam/list
import gleam/string

pub type Denial {
  Denial(status: Int, message: String)
}

/// The configured allowlist (empty = auth disabled). Read per-request.
pub fn allowed_remote_users() -> List(String) {
  envoy.get("YACWU_REMOTE_USERS")
  |> fn(raw) {
    case raw {
      Ok(raw) -> raw
      Error(_) -> ""
    }
  }
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(user) { user != "" })
}

/// True when the operator explicitly opted into running without any
/// authentication (`YACWU_INSECURE_SKIP_AUTH=1`). With neither forward auth
/// nor OAuth configured, the server refuses to serve unless this is set —
/// failing closed rather than silently open.
pub fn insecure_skip_auth() -> Bool {
  envoy.get("YACWU_INSECURE_SKIP_AUTH") == Ok("1")
}

/// Returns `Error(denial)` when the request must be rejected, `Ok(Nil)` when
/// allowed. No-op when no allowlist is configured.
pub fn check_remote_user(header: Result(String, Nil)) -> Result(Nil, Denial) {
  case allowed_remote_users() {
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
