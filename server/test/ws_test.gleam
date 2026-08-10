import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import yacwu/ws

// RFC 6455 §1.3 handshake vector.
pub fn accept_key_test() {
  ws.accept_key("dGhlIHNhbXBsZSBub25jZQ==")
  |> should.equal("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

pub fn handshake_request_test() {
  let request = ws.handshake_request("abc==")
  should.be_true(string.starts_with(request, "GET / HTTP/1.1\r\n"))
  should.be_true(string.contains(request, "Sec-WebSocket-Key: abc==\r\n"))
  should.be_true(string.ends_with(request, "\r\n\r\n"))
}

pub fn split_header_test() {
  let buffer =
    bit_array.concat([
      bit_array.from_string("HTTP/1.1 101 Switching Protocols\r\nA: b\r\n\r\n"),
      <<1, 2, 3>>,
    ])
  let assert Ok(#(header, rest)) = ws.split_header(buffer)
  should.equal(header, "HTTP/1.1 101 Switching Protocols\r\nA: b")
  should.equal(rest, <<1, 2, 3>>)

  ws.split_header(bit_array.from_string("HTTP/1.1 101\r\npartial"))
  |> should.equal(Error(Nil))
}

pub fn check_handshake_test() {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let good =
    "HTTP/1.1 101 Switching Protocols\r\n"
    <> "Upgrade: websocket\r\n"
    <> "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
  ws.check_handshake(good, key) |> should.equal(Ok(Nil))

  let bad_status = "HTTP/1.1 400 Bad Request\r\nX: y"
  should.be_true(ws.check_handshake(bad_status, key) != Ok(Nil))

  let bad_key =
    "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: nope="
  should.be_true(ws.check_handshake(bad_key, key) != Ok(Nil))
}

pub fn mask_roundtrip_test() {
  let key = <<1, 2, 3, 4>>
  let payload = bit_array.from_string("hello codex app-server!")
  let masked = ws.mask_payload(payload, key)
  should.be_true(masked != payload)
  ws.mask_payload(masked, key) |> should.equal(payload)
}

pub fn encode_decode_unmasked_test() {
  let frame = ws.Text("{\"id\":1,\"result\":{}}")
  let #(frames, _) = ws.push(ws.new_decoder(), ws.encode(frame, None))
  should.equal(frames, [frame])
}

pub fn encode_decode_masked_test() {
  let frame = ws.Text("{\"method\":\"initialize\",\"id\":1}")
  let encoded = ws.encode(frame, Some(ws.random_mask()))
  let #(frames, _) = ws.push(ws.new_decoder(), encoded)
  should.equal(frames, [frame])
}

pub fn decode_split_across_chunks_test() {
  let frame = ws.Text("streamed in pieces")
  let encoded = ws.encode(frame, None)
  let size = bit_array.byte_size(encoded)
  let assert Ok(first) = bit_array.slice(encoded, 0, 3)
  let assert Ok(second) = bit_array.slice(encoded, 3, size - 3)
  let #(frames, decoder) = ws.push(ws.new_decoder(), first)
  should.equal(frames, [])
  let #(frames, _) = ws.push(decoder, second)
  should.equal(frames, [frame])
}

pub fn decode_multiple_frames_in_one_chunk_test() {
  let a = ws.Text("first")
  let b = ws.Text("second")
  let chunk = bit_array.concat([ws.encode(a, None), ws.encode(b, None)])
  let #(frames, _) = ws.push(ws.new_decoder(), chunk)
  should.equal(frames, [a, b])
}

pub fn decode_medium_length_test() {
  // > 125 bytes exercises the 16-bit length form.
  let text = string.repeat("x", 300)
  let #(frames, _) =
    ws.push(ws.new_decoder(), ws.encode(ws.Text(text), Some(<<9, 8, 7, 6>>)))
  should.equal(frames, [ws.Text(text)])
}

pub fn decode_large_length_test() {
  // > 65535 bytes exercises the 64-bit length form.
  let text = string.repeat("y", 70_000)
  let #(frames, _) = ws.push(ws.new_decoder(), ws.encode(ws.Text(text), None))
  should.equal(frames, [ws.Text(text)])
}

pub fn control_frames_test() {
  let chunk =
    bit_array.concat([
      ws.encode(ws.Ping(<<1, 2>>), None),
      ws.encode(ws.Pong(<<>>), None),
      ws.encode(ws.Close, None),
    ])
  let #(frames, _) = ws.push(ws.new_decoder(), chunk)
  should.equal(frames, [ws.Ping(<<1, 2>>), ws.Pong(<<>>), ws.Close])
}

pub fn fragmented_message_test() {
  // Hand-build "hel" (text, fin=0) + "lo" (continuation, fin=1), with a ping
  // interleaved between the fragments.
  let first = <<
    0:size(1),
    0:size(3),
    1:size(4),
    0:size(1),
    3:size(7),
    "hel":utf8,
  >>
  let ping = ws.encode(ws.Ping(<<>>), None)
  let last = <<
    1:size(1),
    0:size(3),
    0:size(4),
    0:size(1),
    2:size(7),
    "lo":utf8,
  >>
  let #(frames, _) =
    ws.push(ws.new_decoder(), bit_array.concat([first, ping, last]))
  should.equal(frames, [ws.Ping(<<>>), ws.Text("hello")])
}

pub fn random_key_is_base64_test() {
  let key = ws.random_key()
  should.equal(string.length(key), 24)
  should.be_true(list.all(string.to_graphemes(key), fn(_) { True }))
}
