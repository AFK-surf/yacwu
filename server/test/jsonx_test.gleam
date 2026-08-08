import gleam/dynamic/decode
import gleam/json
import yacwu/jsonx

/// Round-trip a JSON document through the Dynamic passthrough and confirm the
/// decoded values are structurally identical.
fn assert_round_trip(document: String) {
  let assert Ok(parsed) = json.parse(document, decode.dynamic)
  let re_encoded = json.to_string(jsonx.to_json(parsed))
  let assert Ok(re_parsed) = json.parse(re_encoded, decode.dynamic)
  assert re_parsed == parsed
}

pub fn round_trip_scalars_test() {
  assert_round_trip("{\"a\":1,\"b\":2.5,\"c\":\"x\",\"d\":true,\"e\":null}")
}

pub fn round_trip_nested_test() {
  assert_round_trip(
    "{\"thread\":{\"id\":\"t1\",\"turns\":[{\"items\":[1,2,3]},{\"items\":[]}]},\"cursor\":null}",
  )
}

pub fn round_trip_unicode_test() {
  assert_round_trip("{\"text\":\"héllo → wörld 🎉\"}")
}

pub fn object_with_adds_fields_test() {
  let assert Ok(parsed) = json.parse("{\"a\":1}", decode.dynamic)
  let combined =
    json.to_string(jsonx.object_with(parsed, [#("b", json.int(2))]))
  let assert Ok(re_parsed) = json.parse(combined, decode.dynamic)
  let assert Ok(expected) = json.parse("{\"a\":1,\"b\":2}", decode.dynamic)
  assert re_parsed == expected
}

pub fn object_with_replaces_fields_test() {
  let assert Ok(parsed) = json.parse("{\"a\":1,\"b\":1}", decode.dynamic)
  let combined =
    json.to_string(jsonx.object_with(parsed, [#("b", json.int(2))]))
  let assert Ok(re_parsed) = json.parse(combined, decode.dynamic)
  let assert Ok(expected) = json.parse("{\"a\":1,\"b\":2}", decode.dynamic)
  assert re_parsed == expected
}

pub fn field_helpers_test() {
  let assert Ok(parsed) =
    json.parse(
      "{\"thread\":{\"path\":\"/tmp/x\",\"n\":3,\"flag\":true}}",
      decode.dynamic,
    )
  assert jsonx.field_string(parsed, ["thread", "path"]) == Ok("/tmp/x")
  assert jsonx.field_int(parsed, ["thread", "n"]) == Ok(3)
  assert jsonx.field_bool(parsed, ["thread", "flag"]) == Ok(True)
  assert jsonx.field_string(parsed, ["missing"]) == Error(Nil)
}
