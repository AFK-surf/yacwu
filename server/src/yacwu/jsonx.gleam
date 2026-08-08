//// Helpers for passing arbitrary JSON values through the server.
////
//// Codex responses are decoded to `Dynamic` and re-encoded verbatim (sometimes
//// augmented with extra fields), so the HTTP layer never needs a full schema
//// for every RPC result.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/string

/// Re-encode a dynamically typed JSON value (as produced by `json.parse`).
pub fn to_json(value: Dynamic) -> Json {
  case dynamic.classify(value) {
    "String" ->
      case decode.run(value, decode.string) {
        Ok(s) -> json.string(s)
        Error(_) -> json.null()
      }
    "Int" ->
      case decode.run(value, decode.int) {
        Ok(i) -> json.int(i)
        Error(_) -> json.null()
      }
    "Float" ->
      case decode.run(value, decode.float) {
        Ok(f) -> json.float(f)
        Error(_) -> json.null()
      }
    "Bool" ->
      case decode.run(value, decode.bool) {
        Ok(b) -> json.bool(b)
        Error(_) -> json.null()
      }
    "List" ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> json.preprocessed_array(list.map(items, to_json))
        Error(_) -> json.null()
      }
    "Dict" ->
      case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
        Ok(entries) ->
          json.object(
            dict.to_list(entries)
            |> list.map(fn(entry) { #(entry.0, to_json(entry.1)) }),
          )
        Error(_) -> json.null()
      }
    // JSON null decodes to an atom; anything else non-JSON has no sensible
    // representation, so render it as its inspected form.
    "Nil" | "Atom" -> json.null()
    _ -> json.string(string.inspect(value))
  }
}

/// Decode an object into its fields so extra fields can be merged in before
/// re-encoding. Non-objects yield an empty field list.
pub fn object_fields(value: Dynamic) -> List(#(String, Dynamic)) {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(entries) -> dict.to_list(entries)
    Error(_) -> []
  }
}

/// Re-encode an object, replacing/adding the given extra fields.
pub fn object_with(value: Dynamic, extra: List(#(String, Json))) -> Json {
  let extra_keys = list.map(extra, fn(e) { e.0 })
  let kept =
    object_fields(value)
    |> list.filter(fn(entry) { !list.contains(extra_keys, entry.0) })
    |> list.map(fn(entry) { #(entry.0, to_json(entry.1)) })
  json.object(list.append(kept, extra))
}

/// Read a string field of a decoded JSON object.
pub fn field_string(value: Dynamic, path: List(String)) -> Result(String, Nil) {
  decode.run(value, decode.at(path, decode.string))
  |> result_nil
}

/// Read an int field of a decoded JSON object.
pub fn field_int(value: Dynamic, path: List(String)) -> Result(Int, Nil) {
  decode.run(value, decode.at(path, decode.int))
  |> result_nil
}

/// Read a bool field of a decoded JSON object.
pub fn field_bool(value: Dynamic, path: List(String)) -> Result(Bool, Nil) {
  decode.run(value, decode.at(path, decode.bool))
  |> result_nil
}

/// Read an arbitrary field of a decoded JSON object.
pub fn field(value: Dynamic, path: List(String)) -> Result(Dynamic, Nil) {
  decode.run(value, decode.at(path, decode.dynamic))
  |> result_nil
}

fn result_nil(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}
