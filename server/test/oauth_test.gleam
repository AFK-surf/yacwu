import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import yacwu/jsonx
import yacwu/oauth

const oauth_vars = [
  "YACWU_OAUTH_CLIENT_ID", "YACWU_OAUTH_CLIENT_SECRET", "YACWU_OAUTH_ISSUER",
  "YACWU_OAUTH_AUTH_URL", "YACWU_OAUTH_TOKEN_URL", "YACWU_OAUTH_USERINFO_URL",
  "YACWU_OAUTH_SCOPES", "YACWU_OAUTH_USER_CLAIM", "YACWU_OAUTH_USERS",
  "YACWU_OAUTH_REDIRECT_URL", "YACWU_OAUTH_SESSION_TTL",
]

fn with_env(vars: List(#(String, String)), run: fn() -> a) -> a {
  list.each(oauth_vars, envoy.unset)
  list.each(vars, fn(pair) { envoy.set(pair.0, pair.1) })
  let result = run()
  list.each(oauth_vars, envoy.unset)
  result
}

fn claims(json_text: String) -> decode.Dynamic {
  let assert Ok(value) = json.parse(json_text, decode.dynamic)
  value
}

// -- Configuration loading ----------------------------------------------------

pub fn oauth_disabled_without_client_id_test() {
  use <- with_env([#("YACWU_OAUTH_ISSUER", "https://idp.example.com")])
  assert oauth.load() == None
}

pub fn oauth_disabled_without_issuer_or_endpoints_test() {
  use <- with_env([#("YACWU_OAUTH_CLIENT_ID", "yacwu")])
  assert oauth.load() == None
}

pub fn oauth_disabled_with_only_one_explicit_endpoint_test() {
  use <- with_env([
    #("YACWU_OAUTH_CLIENT_ID", "yacwu"),
    #("YACWU_OAUTH_AUTH_URL", "https://idp.example.com/authorize"),
  ])
  assert oauth.load() == None
}

pub fn oauth_enabled_by_issuer_with_defaults_test() {
  use <- with_env([
    #("YACWU_OAUTH_CLIENT_ID", "yacwu"),
    #("YACWU_OAUTH_ISSUER", "https://idp.example.com"),
  ])
  let assert Some(config) = oauth.load()
  assert config.client_id == "yacwu"
  assert config.issuer == Some("https://idp.example.com")
  assert config.scopes == "openid profile email"
  assert config.user_claim == None
  assert config.allowed_users == []
  assert config.session_ttl == 604_800
}

pub fn oauth_enabled_by_explicit_endpoints_test() {
  use <- with_env([
    #("YACWU_OAUTH_CLIENT_ID", "yacwu"),
    #("YACWU_OAUTH_AUTH_URL", "https://idp.example.com/authorize"),
    #("YACWU_OAUTH_TOKEN_URL", "https://idp.example.com/token"),
    #("YACWU_OAUTH_USERS", " alice , bob "),
    #("YACWU_OAUTH_SESSION_TTL", "3600"),
  ])
  let assert Some(config) = oauth.load()
  assert config.auth_url == Some("https://idp.example.com/authorize")
  assert config.token_url == Some("https://idp.example.com/token")
  assert config.allowed_users == ["alice", "bob"]
  assert config.session_ttl == 3600
}

pub fn explicit_endpoints_skip_discovery_test() {
  use <- with_env([
    #("YACWU_OAUTH_CLIENT_ID", "yacwu"),
    #("YACWU_OAUTH_AUTH_URL", "https://idp.example.com/authorize"),
    #("YACWU_OAUTH_TOKEN_URL", "https://idp.example.com/token"),
    #("YACWU_OAUTH_USERINFO_URL", "https://idp.example.com/userinfo"),
  ])
  let assert Some(config) = oauth.load()
  // No issuer configured, so this must resolve without any network call.
  assert oauth.endpoints(config)
    == Ok(oauth.Endpoints(
      auth_url: "https://idp.example.com/authorize",
      token_url: "https://idp.example.com/token",
      userinfo_url: Some("https://idp.example.com/userinfo"),
    ))
}

// -- Sealed cookie values -----------------------------------------------------

pub fn seal_open_roundtrip_test() {
  let secret = <<"test-secret":utf8>>
  let sealed =
    oauth.seal(
      [#("user", json.string("alice"))],
      expires_at: 1000,
      secret: secret,
    )
  let assert Ok(fields) = oauth.open(sealed, now: 999, secret: secret)
  assert jsonx.field_string(fields, ["user"]) == Ok("alice")
}

pub fn open_rejects_expired_test() {
  let secret = <<"test-secret":utf8>>
  let sealed =
    oauth.seal(
      [#("user", json.string("alice"))],
      expires_at: 1000,
      secret: secret,
    )
  assert oauth.open(sealed, now: 1000, secret: secret) == Error(Nil)
}

pub fn open_rejects_wrong_secret_test() {
  let sealed =
    oauth.seal([#("user", json.string("alice"))], expires_at: 1000, secret: <<
      "secret-a":utf8,
    >>)
  assert oauth.open(sealed, now: 1, secret: <<"secret-b":utf8>>) == Error(Nil)
}

pub fn open_rejects_tampered_value_test() {
  let secret = <<"test-secret":utf8>>
  let sealed =
    oauth.seal(
      [#("user", json.string("alice"))],
      expires_at: 1000,
      secret: secret,
    )
  assert oauth.open(sealed <> "x", now: 1, secret: secret) == Error(Nil)
  assert oauth.open("garbage", now: 1, secret: secret) == Error(Nil)
}

// -- Sessions -----------------------------------------------------------------

pub fn session_user_accepts_valid_cookie_test() {
  let secret = <<"test-secret":utf8>>
  let sealed =
    oauth.seal(
      [#("user", json.string("alice"))],
      expires_at: 1000,
      secret: secret,
    )
  assert oauth.session_user(Ok(sealed), allowed: [], now: 1, secret: secret)
    == Ok("alice")
}

pub fn session_user_enforces_current_allowlist_test() {
  let secret = <<"test-secret":utf8>>
  let sealed =
    oauth.seal(
      [#("user", json.string("carol"))],
      expires_at: 1000,
      secret: secret,
    )
  assert oauth.session_user(
      Ok(sealed),
      allowed: ["alice", "carol"],
      now: 1,
      secret: secret,
    )
    == Ok("carol")
  assert oauth.session_user(
      Ok(sealed),
      allowed: ["alice"],
      now: 1,
      secret: secret,
    )
    == Error(Nil)
}

pub fn session_user_rejects_missing_cookie_test() {
  assert oauth.session_user(Error(Nil), allowed: [], now: 1, secret: <<
      "s":utf8,
    >>)
    == Error(Nil)
}

pub fn user_allowed_test() {
  assert oauth.user_allowed("anyone", [])
  assert oauth.user_allowed("alice", ["alice", "bob"])
  assert !oauth.user_allowed("carol", ["alice", "bob"])
}

// -- PKCE and URLs ------------------------------------------------------------

pub fn pkce_challenge_matches_rfc7636_vector_test() {
  assert oauth.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
}

pub fn random_verifier_is_valid_pkce_length_test() {
  // RFC 7636 requires 43–128 characters.
  assert bit_array.byte_size(bit_array.from_string(oauth.random_verifier()))
    == 43
}

pub fn authorize_url_encodes_params_test() {
  assert oauth.authorize_url("https://idp.example.com/authorize", [
      #("client_id", "yacwu"),
      #("scope", "openid profile"),
      #("redirect_uri", "http://localhost:3000/oauth/callback"),
    ])
    == "https://idp.example.com/authorize?client_id=yacwu"
    <> "&scope=openid%20profile"
    <> "&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Foauth%2Fcallback"
}

pub fn authorize_url_appends_to_existing_query_test() {
  assert oauth.authorize_url("https://idp.example.com/authorize?tenant=x", [
      #("client_id", "yacwu"),
    ])
    == "https://idp.example.com/authorize?tenant=x&client_id=yacwu"
}

pub fn sanitize_next_keeps_local_paths_test() {
  assert oauth.sanitize_next("/") == "/"
  assert oauth.sanitize_next("/threads/abc?x=1") == "/threads/abc?x=1"
}

pub fn sanitize_next_rejects_external_destinations_test() {
  assert oauth.sanitize_next("") == "/"
  assert oauth.sanitize_next("https://evil.example.com") == "/"
  assert oauth.sanitize_next("//evil.example.com") == "/"
  assert oauth.sanitize_next("/\\evil.example.com") == "/"
}

// -- Identity extraction ------------------------------------------------------

pub fn identity_prefers_configured_claim_test() {
  let value =
    claims("{\"sub\":\"u-1\",\"email\":\"a@example.com\",\"nick\":\"al\"}")
  assert oauth.identity_from_claims(value, Some("nick")) == Ok("al")
  // A configured claim that's absent must not fall back to another field.
  assert oauth.identity_from_claims(value, Some("missing")) == Error(Nil)
}

pub fn identity_default_chain_test() {
  assert oauth.identity_from_claims(
      claims("{\"preferred_username\":\"alice\",\"email\":\"a@example.com\"}"),
      None,
    )
    == Ok("alice")
  assert oauth.identity_from_claims(
      claims("{\"email\":\"a@example.com\",\"sub\":\"u-1\"}"),
      None,
    )
    == Ok("a@example.com")
  // GitHub's userinfo shape.
  assert oauth.identity_from_claims(claims("{\"login\":\"octocat\"}"), None)
    == Ok("octocat")
  assert oauth.identity_from_claims(claims("{\"sub\":\"u-1\"}"), None)
    == Ok("u-1")
  assert oauth.identity_from_claims(claims("{\"aud\":\"yacwu\"}"), None)
    == Error(Nil)
}

pub fn identity_skips_empty_values_test() {
  assert oauth.identity_from_claims(
      claims("{\"preferred_username\":\" \",\"sub\":\"u-1\"}"),
      None,
    )
    == Ok("u-1")
}

// -- JWT claims ---------------------------------------------------------------

fn fake_jwt(payload: String) -> String {
  let encode = fn(part: String) {
    bit_array.base64_url_encode(bit_array.from_string(part), False)
  }
  encode("{\"alg\":\"RS256\"}") <> "." <> encode(payload) <> ".signature"
}

pub fn jwt_claims_decodes_payload_test() {
  let assert Ok(fields) =
    oauth.jwt_claims(fake_jwt("{\"sub\":\"u-1\",\"email\":\"a@example.com\"}"))
  assert jsonx.field_string(fields, ["sub"]) == Ok("u-1")
  assert jsonx.field_string(fields, ["email"]) == Ok("a@example.com")
}

pub fn jwt_claims_rejects_malformed_tokens_test() {
  assert oauth.jwt_claims("not-a-jwt") == Error(Nil)
  assert oauth.jwt_claims("a.!!notbase64!!.c") == Error(Nil)
}
