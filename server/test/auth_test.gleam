import envoy
import yacwu/auth

fn with_allowlist(value: String, run: fn() -> a) -> a {
  envoy.set("YACWU_REMOTE_USERS", value)
  let result = run()
  envoy.unset("YACWU_REMOTE_USERS")
  result
}

pub fn auth_disabled_when_no_allowlist_test() {
  envoy.unset("YACWU_REMOTE_USERS")
  assert auth.check_remote_user(Error(Nil)) == Ok(Nil)
  assert auth.check_remote_user(Ok("anyone")) == Ok(Nil)
}

pub fn missing_header_rejected_with_401_test() {
  use <- with_allowlist("alice,bob")
  assert auth.check_remote_user(Error(Nil))
    == Error(auth.Denial(401, "Missing Remote-User header"))
}

pub fn unknown_user_rejected_with_403_test() {
  use <- with_allowlist("alice,bob")
  assert auth.check_remote_user(Ok("carol"))
    == Error(auth.Denial(403, "Forbidden"))
}

pub fn listed_user_allowed_and_allowlist_trimmed_test() {
  use <- with_allowlist(" alice , bob ")
  assert auth.check_remote_user(Ok("bob")) == Ok(Nil)
}

pub fn incoming_value_trimmed_before_matching_test() {
  use <- with_allowlist("alice")
  assert auth.check_remote_user(Ok("  alice  ")) == Ok(Nil)
}

pub fn empty_header_value_is_missing_test() {
  use <- with_allowlist("alice")
  assert auth.check_remote_user(Ok("   "))
    == Error(auth.Denial(401, "Missing Remote-User header"))
}

pub fn insecure_skip_auth_requires_exactly_1_test() {
  envoy.unset("YACWU_INSECURE_SKIP_AUTH")
  assert !auth.insecure_skip_auth()
  envoy.set("YACWU_INSECURE_SKIP_AUTH", "true")
  assert !auth.insecure_skip_auth()
  envoy.set("YACWU_INSECURE_SKIP_AUTH", "1")
  assert auth.insecure_skip_auth()
  envoy.unset("YACWU_INSECURE_SKIP_AUTH")
}
