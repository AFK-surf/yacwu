import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import yacwu/profiles

pub fn profile_file_name_test() {
  assert profiles.profile_file_name("fast.config.toml") == Ok("fast")
  assert profiles.profile_file_name("deep-review.config.toml")
    == Ok("deep-review")
  // The base config is not a profile, and unrelated files are ignored.
  assert profiles.profile_file_name("config.toml") == Error(Nil)
  assert profiles.profile_file_name("auth.json") == Error(Nil)
  assert profiles.profile_file_name("notes.toml") == Error(Nil)
}

pub fn parse_profile_extracts_model_test() {
  let assert Ok(profile) =
    profiles.parse_profile(
      "fast",
      "model = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"low\"\n",
    )
  assert profile.name == "fast"
  assert profile.model == Some("gpt-5.6-luna")
}

pub fn parse_profile_without_model_test() {
  let assert Ok(profile) =
    profiles.parse_profile("quiet", "model_verbosity = \"low\"\n")
  assert profile.model == None
}

pub fn parse_profile_invalid_toml_test() {
  assert profiles.parse_profile("bad", "model = ") == Error(Nil)
}

pub fn config_json_round_trips_nested_tables_test() {
  let toml =
    "
model = \"gpt-5.6-luna\"
web_search = true
project_root_markers = [\".git\", \"package.json\"]

[sandbox_workspace_write]
network_access = true
"
  let assert Ok(profile) = profiles.parse_profile("nested", toml)
  let encoded = json.to_string(profiles.config_json(profile))
  let assert Ok(parsed) = json.parse(encoded, decode.dynamic)
  assert decode.run(parsed, decode.at(["model"], decode.string))
    == Ok("gpt-5.6-luna")
  assert decode.run(parsed, decode.at(["web_search"], decode.bool)) == Ok(True)
  assert decode.run(
      parsed,
      decode.at(["project_root_markers"], decode.list(decode.string)),
    )
    == Ok([".git", "package.json"])
  assert decode.run(
      parsed,
      decode.at(["sandbox_workspace_write", "network_access"], decode.bool),
    )
    == Ok(True)
}

pub fn infer_for_model_test() {
  let assert Ok(fast) =
    profiles.parse_profile("fast", "model = \"gpt-5.6-luna\"")
  let assert Ok(deep) =
    profiles.parse_profile("deep", "model = \"gpt-5.6-sol\"")
  let assert Ok(quiet) = profiles.parse_profile("quiet", "web_search = false")
  let available = [deep, fast, quiet]

  assert profiles.infer_for_model(available, "gpt-5.6-luna") == Ok(fast)
  assert profiles.infer_for_model(available, "gpt-5.6-sol") == Ok(deep)
  assert profiles.infer_for_model(available, "gpt-6") == Error(Nil)
  assert profiles.infer_for_model(available, "") == Error(Nil)
}

pub fn find_test() {
  let assert Ok(fast) =
    profiles.parse_profile("fast", "model = \"gpt-5.6-luna\"")
  assert profiles.find([fast], "fast") == Ok(fast)
  assert profiles.find([fast], "nope") == Error(Nil)
}
