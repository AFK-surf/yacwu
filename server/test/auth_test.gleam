import envoy
import gleam/list
import gleam/option.{None, Some}
import yacwu/auth

const auth_vars = [
  "YACWU_REMOTE_USERS", "YACWU_INSECURE_SKIP_AUTH", "YACWU_OAUTH_CLIENT_ID",
  "YACWU_OAUTH_ISSUER",
]

fn with_env(vars: List(#(String, String)), run: fn() -> a) -> a {
  list.each(auth_vars, envoy.unset)
  list.each(vars, fn(pair) { envoy.set(pair.0, pair.1) })
  let result = run()
  list.each(auth_vars, envoy.unset)
  result
}

// -- Loading the immutable configuration --------------------------------------

pub fn load_defaults_to_nothing_configured_test() {
  use <- with_env([])
  let config = auth.load()
  assert config.remote_users == []
  assert config.oauth == None
  assert !config.insecure_skip_auth
  assert !auth.configured(config)
}

pub fn load_parses_and_trims_the_allowlist_test() {
  use <- with_env([#("YACWU_REMOTE_USERS", " alice , bob ,, ")])
  let config = auth.load()
  assert config.remote_users == ["alice", "bob"]
  assert auth.configured(config)
}

pub fn load_picks_up_oauth_test() {
  use <- with_env([
    #("YACWU_OAUTH_CLIENT_ID", "yacwu"),
    #("YACWU_OAUTH_ISSUER", "https://idp.example.com"),
  ])
  let config = auth.load()
  let assert Some(_) = config.oauth
  assert auth.configured(config)
}

pub fn insecure_skip_auth_requires_exactly_1_test() {
  use <- with_env([#("YACWU_INSECURE_SKIP_AUTH", "true")])
  assert !auth.load().insecure_skip_auth
  envoy.set("YACWU_INSECURE_SKIP_AUTH", "1")
  assert auth.load().insecure_skip_auth
}

// -- Forward-auth header checks ------------------------------------------------

pub fn empty_allowlist_admits_everything_test() {
  assert auth.check_remote_user(Error(Nil), allowed: []) == Ok(Nil)
  assert auth.check_remote_user(Ok("anyone"), allowed: []) == Ok(Nil)
}

pub fn missing_header_rejected_with_401_test() {
  assert auth.check_remote_user(Error(Nil), allowed: ["alice", "bob"])
    == Error(auth.Denial(401, "Missing Remote-User header"))
}

pub fn unknown_user_rejected_with_403_test() {
  assert auth.check_remote_user(Ok("carol"), allowed: ["alice", "bob"])
    == Error(auth.Denial(403, "Forbidden"))
}

pub fn listed_user_allowed_test() {
  assert auth.check_remote_user(Ok("bob"), allowed: ["alice", "bob"]) == Ok(Nil)
}

pub fn incoming_value_trimmed_before_matching_test() {
  assert auth.check_remote_user(Ok("  alice  "), allowed: ["alice"]) == Ok(Nil)
}

pub fn empty_header_value_is_missing_test() {
  assert auth.check_remote_user(Ok("   "), allowed: ["alice"])
    == Error(auth.Denial(401, "Missing Remote-User header"))
}
