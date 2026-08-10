//// Per-thread model/reasoning-effort state.
////
//// The model catalog comes from `model/list`. A thread's effective settings
//// are resolved in this order: an explicit override set via the model API
//// (`/model` in the UI), the latest `turn_context` persisted in the thread's
//// rollout file, the configured defaults from `config/read`, and finally the
//// catalog's default model.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import simplifile
import yacwu/codex.{type Codex}
import yacwu/jsonx

pub type Settings {
  Settings(model: String, effort: String)
}

pub type ModelChoice {
  ModelChoice(
    id: String,
    display_name: String,
    default_effort: String,
    efforts: List(String),
  )
}

// -- Override store -----------------------------------------------------------
//
// Overrides set after the user explicitly runs /model, keyed by thread id.

pub opaque type StoreMsg {
  Get(thread_id: String, reply: Subject(Result(Settings, Nil)))
  Put(thread_id: String, settings: Settings)
}

pub type Store =
  Name(StoreMsg)

pub fn supervised(
  name: Store,
) -> supervision.ChildSpecification(Subject(StoreMsg)) {
  supervision.worker(fn() {
    let initial: Dict(String, Settings) = dict.new()
    actor.new(initial)
    |> actor.named(name)
    |> actor.on_message(fn(state, msg) {
      case msg {
        Get(thread_id, reply) -> {
          process.send(reply, dict.get(state, thread_id))
          actor.continue(state)
        }
        Put(thread_id, settings) ->
          actor.continue(dict.insert(state, thread_id, settings))
      }
    })
    |> actor.start
  })
}

/// Override included on turns after the user explicitly runs /model.
pub fn get_override(store: Store, thread_id: String) -> Result(Settings, Nil) {
  process.call_forever(process.named_subject(store), Get(thread_id, _))
}

// -- Model catalog ------------------------------------------------------------

pub type Catalog {
  Catalog(models: List(ModelChoice), default_model: Option(String))
}

pub fn list_model_choices(codex: Codex) -> Result(Catalog, String) {
  fetch_models(codex, None, [], None)
}

fn fetch_models(
  codex: Codex,
  cursor: Option(String),
  acc: List(ModelChoice),
  default_model: Option(String),
) -> Result(Catalog, String) {
  let params = [
    #("limit", json.int(100)),
    #("includeHidden", json.bool(False)),
  ]
  let params = case cursor {
    Some(cursor) -> list.append(params, [#("cursor", json.string(cursor))])
    None -> params
  }
  use result <- result.try(codex.request(
    codex,
    "model/list",
    json.object(params),
  ))
  let raw_models = case
    jsonx.field(result, ["data"])
    |> result.try(fn(data) {
      decode.run(data, decode.list(decode.dynamic))
      |> result.replace_error(Nil)
    })
  {
    Ok(models) -> models
    Error(_) -> []
  }
  let #(acc, default_model) =
    list.fold(raw_models, #(acc, default_model), fn(state, raw) {
      let #(models, default_model) = state
      case normalize_model(raw) {
        Ok(#(model, is_default)) -> #([model, ..models], case is_default {
          True -> Some(model.id)
          False -> default_model
        })
        Error(_) -> #(models, default_model)
      }
    })
  case jsonx.field_string(result, ["nextCursor"]) {
    Ok(cursor) if cursor != "" ->
      fetch_models(codex, Some(cursor), acc, default_model)
    _ -> {
      let models = list.reverse(acc)
      let default_model = case default_model {
        Some(model) -> Some(model)
        None ->
          list.first(models)
          |> result.map(fn(model) { model.id })
          |> option.from_result
      }
      Ok(Catalog(models: models, default_model: default_model))
    }
  }
}

fn effort_name(value: decode.Dynamic) -> Result(String, Nil) {
  case decode.run(value, decode.string) {
    Ok(name) if name != "" -> Ok(name)
    _ ->
      case jsonx.field_string(value, ["reasoningEffort"]) {
        Ok(name) if name != "" -> Ok(name)
        _ -> Error(Nil)
      }
  }
}

fn normalize_model(raw: decode.Dynamic) -> Result(#(ModelChoice, Bool), Nil) {
  use id <- result.try(case jsonx.field_string(raw, ["model"]) {
    Ok(id) if id != "" -> Ok(id)
    _ ->
      case jsonx.field_string(raw, ["id"]) {
        Ok(id) if id != "" -> Ok(id)
        _ -> Error(Nil)
      }
  })
  let efforts = case
    jsonx.field(raw, ["supportedReasoningEfforts"])
    |> result.try(fn(value) {
      decode.run(value, decode.list(decode.dynamic))
      |> result.replace_error(Nil)
    })
  {
    Ok(values) -> list.filter_map(values, effort_name)
    Error(_) -> []
  }
  let default_effort = case
    jsonx.field(raw, ["defaultReasoningEffort"]) |> result.try(effort_name)
  {
    Ok(effort) -> effort
    Error(_) -> list.first(efforts) |> result.unwrap("medium")
  }
  let display_name = case jsonx.field_string(raw, ["displayName"]) {
    Ok(name) -> name
    Error(_) -> id
  }
  let is_default = jsonx.field_bool(raw, ["isDefault"]) == Ok(True)
  Ok(#(
    ModelChoice(
      id: id,
      display_name: display_name,
      default_effort: default_effort,
      efforts: efforts,
    ),
    is_default,
  ))
}

// -- Persisted turn context ---------------------------------------------------

pub type Persisted {
  Persisted(model: Option(String), effort: Option(String))
}

/// Read the latest persisted turn context from a rollout file on this
/// machine. Returns `Error(Nil)` when the file is missing or holds no turn
/// context.
pub fn read_latest_turn_model(path: String) -> Result(Persisted, Nil) {
  case path {
    "" -> Error(Nil)
    _ -> {
      use content <- result.try(
        simplifile.read(path) |> result.replace_error(Nil),
      )
      parse_latest_turn_model(content)
    }
  }
}

/// The latest persisted turn context in rollout content, wherever the
/// content came from (remote sessions read the rollout over the link).
pub fn parse_latest_turn_model(content: String) -> Result(Persisted, Nil) {
  string.split(content, "\n")
  |> list.reverse
  |> list.find_map(parse_turn_context)
}

fn parse_turn_context(line: String) -> Result(Persisted, Nil) {
  case string.contains(line, "turn_context") {
    False -> Error(Nil)
    True -> {
      use event <- result.try(
        json.parse(line, decode.dynamic) |> result.replace_error(Nil),
      )
      case jsonx.field_string(event, ["type"]) {
        Ok("turn_context") -> {
          let model =
            jsonx.field_string(event, ["payload", "model"])
            |> option.from_result
          let effort = case jsonx.field_string(event, ["payload", "effort"]) {
            Ok(effort) -> Some(effort)
            Error(_) ->
              jsonx.field_string(event, ["payload", "reasoning_effort"])
              |> option.from_result
          }
          case model, effort {
            None, None -> Error(Nil)
            _, _ -> Ok(Persisted(model: model, effort: effort))
          }
        }
        _ -> Error(Nil)
      }
    }
  }
}

fn configured_settings(codex: Codex) -> Persisted {
  case
    codex.request(
      codex,
      "config/read",
      json.object([#("includeLayers", json.bool(False))]),
    )
  {
    Error(_) -> Persisted(None, None)
    Ok(result) -> {
      let model =
        jsonx.field_string(result, ["config", "model"]) |> option.from_result
      let effort = case
        jsonx.field_string(result, ["config", "model_reasoning_effort"])
      {
        Ok(effort) -> Some(effort)
        Error(_) ->
          jsonx.field_string(result, ["config", "modelReasoningEffort"])
          |> option.from_result
      }
      Persisted(model: model, effort: effort)
    }
  }
}

// -- Effective state ----------------------------------------------------------

pub type ModelState {
  ModelState(settings: Settings, models: List(ModelChoice))
}

/// Effective model settings for a thread. `profile` carries the session's
/// selected codex profile settings (if any), which sit between what the
/// thread itself has persisted and the base config: a profile-created session
/// must report the profile's model even before its first turn persists it.
pub fn get_thread_model_state(
  codex: Codex,
  store: Store,
  thread_id: String,
  profile profile: Persisted,
  read_rollout read_rollout: fn(String) -> Result(Persisted, Nil),
) -> Result(ModelState, String) {
  use catalog <- result.try(list_model_choices(codex))
  case get_override(store, thread_id) {
    Ok(settings) -> Ok(ModelState(settings, catalog.models))
    Error(_) -> {
      // A new thread has no rollout until its first turn, so a failing
      // thread/read just means "nothing persisted yet".
      let persisted = case
        codex.request(
          codex,
          "thread/read",
          json.object([
            #("threadId", json.string(thread_id)),
            #("includeTurns", json.bool(False)),
          ]),
        )
      {
        Ok(read) ->
          case jsonx.field_string(read, ["thread", "path"]) {
            Ok(path) ->
              read_rollout(path)
              |> result.unwrap(Persisted(None, None))
            Error(_) -> Persisted(None, None)
          }
        Error(_) -> Persisted(None, None)
      }
      let config = configured_settings(codex)
      let model = case
        option.or(persisted.model, option.or(profile.model, config.model))
      {
        Some(model) -> Ok(model)
        None ->
          option.to_result(catalog.default_model, "no models are available")
      }
      use model <- result.try(model)
      let choice = list.find(catalog.models, fn(c) { c.id == model })
      let effort = case
        option.or(persisted.effort, option.or(profile.effort, config.effort))
      {
        Some(effort) -> effort
        None ->
          choice
          |> result.map(fn(c) { c.default_effort })
          |> result.unwrap("medium")
      }
      Ok(ModelState(Settings(model: model, effort: effort), catalog.models))
    }
  }
}

pub fn set_thread_model_state(
  codex: Codex,
  store: Store,
  thread_id: String,
  requested_model: Option(String),
  requested_effort: Option(String),
  profile profile: Persisted,
  read_rollout read_rollout: fn(String) -> Result(Persisted, Nil),
) -> Result(ModelState, String) {
  use current <- result.try(get_thread_model_state(
    codex,
    store,
    thread_id,
    profile: profile,
    read_rollout: read_rollout,
  ))
  let model = option.unwrap(requested_model, current.settings.model)
  use choice <- result.try(
    list.find(current.models, fn(c) { c.id == model })
    |> result.replace_error("unknown model: " <> model),
  )
  let effort = case requested_effort {
    Some(effort) -> effort
    None ->
      case list.contains(choice.efforts, current.settings.effort) {
        True -> current.settings.effort
        False -> choice.default_effort
      }
  }
  use _ <- result.try(
    case choice.efforts != [] && !list.contains(choice.efforts, effort) {
      True ->
        Error(
          "unsupported effort for "
          <> model
          <> ": "
          <> effort
          <> " (choose "
          <> string.join(choice.efforts, ", ")
          <> ")",
        )
      False -> Ok(Nil)
    },
  )
  let settings = Settings(model: model, effort: effort)
  process.send(process.named_subject(store), Put(thread_id, settings))
  Ok(ModelState(settings, current.models))
}

/// JSON body shared by the model GET/POST endpoints:
/// `{ model, effort, models: [...] }`.
pub fn state_to_json(state: ModelState) -> json.Json {
  json.object([
    #("model", json.string(state.settings.model)),
    #("effort", json.string(state.settings.effort)),
    #(
      "models",
      json.preprocessed_array(
        list.map(state.models, fn(choice) {
          json.object([
            #("id", json.string(choice.id)),
            #("displayName", json.string(choice.display_name)),
            #("defaultEffort", json.string(choice.default_effort)),
            #(
              "efforts",
              json.preprocessed_array(list.map(choice.efforts, json.string)),
            ),
          ])
        }),
      ),
    ),
  ])
}
