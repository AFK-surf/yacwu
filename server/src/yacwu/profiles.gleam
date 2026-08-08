//// Per-session codex profile selection.
////
//// In current codex, a profile is a `$CODEX_HOME/<name>.config.toml` file
//// layered over the base config with `--profile <name>` — but that flag only
//// applies to CLI invocations, not `codex app-server`, and the app-server
//// protocol has no profile parameter. So yacwu emulates the layering
//// per-thread: the chosen profile file is parsed and passed as the generic
//// `config` override map on `thread/start` / `thread/resume`. Top-level
//// request params beat that map, so yacwu's forced `approvalPolicy: "never"`
//// (the web UI cannot answer interactive approvals) survives any profile.
////
//// Which profile a session uses is kept in memory. After a server restart
//// the selection is re-inferred: a session defaults to the profile whose
//// `model` matches the session's current model, if any.

import envoy
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Subject}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import simplifile
import tom
import yacwu/jsonx

pub type Profile {
  Profile(name: String, config: Dynamic, model: Option(String))
}

/// The directory codex reads its config (and profile files) from.
pub fn codex_home() -> String {
  case envoy.get("CODEX_HOME") {
    Ok(home) if home != "" -> home
    _ -> {
      let home = envoy.get("HOME") |> result.unwrap("/")
      home <> "/.codex"
    }
  }
}

/// The profile name encoded in a file name, e.g. "fast.config.toml" -> "fast".
/// The base "config.toml" is not a profile.
pub fn profile_file_name(file_name: String) -> Result(String, Nil) {
  case file_name, string.ends_with(file_name, ".config.toml") {
    "config.toml", _ | _, False -> Error(Nil)
    _, True -> Ok(string.drop_end(file_name, string.length(".config.toml")))
  }
}

/// Parse one profile file's contents.
pub fn parse_profile(name: String, content: String) -> Result(Profile, Nil) {
  use config <- result.try(
    tom.parse_to_dynamic(content) |> result.replace_error(Nil),
  )
  let model = jsonx.field_string(config, ["model"]) |> option.from_result
  Ok(Profile(name: name, config: config, model: model))
}

/// All profiles found in the codex home, sorted by name.
pub fn list_profiles() -> List(Profile) {
  let home = codex_home()
  case simplifile.read_directory(home) {
    Error(_) -> []
    Ok(entries) ->
      entries
      |> list.filter_map(profile_file_name)
      |> list.sort(string.compare)
      |> list.filter_map(fn(name) {
        simplifile.read(home <> "/" <> name <> ".config.toml")
        |> result.replace_error(Nil)
        |> result.try(parse_profile(name, _))
      })
  }
}

pub fn find(profiles: List(Profile), name: String) -> Result(Profile, Nil) {
  list.find(profiles, fn(profile) { profile.name == name })
}

/// The profile to assume for a session with no stored selection: the first
/// (alphabetically) whose `model` matches the session's model.
pub fn infer_for_model(
  profiles: List(Profile),
  model: String,
) -> Result(Profile, Nil) {
  case model {
    "" -> Error(Nil)
    _ -> list.find(profiles, fn(profile) { profile.model == Some(model) })
  }
}

/// The profile's config table as the JSON `config` override map for
/// `thread/start` / `thread/resume`.
pub fn config_json(profile: Profile) -> Json {
  jsonx.to_json(profile.config)
}

/// JSON shape shared by the profile endpoints.
pub fn profiles_to_json(profiles: List(Profile)) -> Json {
  json.preprocessed_array(
    list.map(profiles, fn(profile) {
      json.object([
        #("name", json.string(profile.name)),
        #("model", case profile.model {
          Some(model) -> json.string(model)
          None -> json.null()
        }),
      ])
    }),
  )
}

// -- Per-thread selection store -----------------------------------------------

pub opaque type StoreMsg {
  Get(thread_id: String, reply: Subject(Result(String, Nil)))
  Put(thread_id: String, profile: Option(String))
}

pub type Store =
  Name(StoreMsg)

pub fn supervised(
  name: Store,
) -> supervision.ChildSpecification(Subject(StoreMsg)) {
  supervision.worker(fn() {
    let initial: dict.Dict(String, String) = dict.new()
    actor.new(initial)
    |> actor.named(name)
    |> actor.on_message(fn(state, msg) {
      case msg {
        Get(thread_id, reply) -> {
          process.send(reply, dict.get(state, thread_id))
          actor.continue(state)
        }
        Put(thread_id, Some(profile)) ->
          actor.continue(dict.insert(state, thread_id, profile))
        Put(thread_id, None) -> actor.continue(dict.delete(state, thread_id))
      }
    })
    |> actor.start
  })
}

pub fn get_selection(store: Store, thread_id: String) -> Result(String, Nil) {
  process.call_forever(process.named_subject(store), Get(thread_id, _))
}

pub fn set_selection(
  store: Store,
  thread_id: String,
  profile: Option(String),
) -> Nil {
  process.send(process.named_subject(store), Put(thread_id, profile))
}
