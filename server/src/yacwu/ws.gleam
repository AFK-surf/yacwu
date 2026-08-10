//// Minimal RFC 6455 WebSocket client codec.
////
//// Codex's Unix-socket transport speaks WebSocket over the socket (one
//// JSON-RPC message per text frame, standard HTTP Upgrade handshake), and no
//// Gleam/Erlang WebSocket *client* works over a Unix socket, so the framing
//// lives here. Pure functions only — the socket IO happens in `remote` and
//// the `codex` manager.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Frame {
  Text(String)
  Binary(BitArray)
  Ping(BitArray)
  Pong(BitArray)
  Close
}

/// Incremental frame decoder: raw TCP chunks in, complete frames out.
/// `fragments` accumulates a fragmented message (initial opcode + payload).
pub opaque type Decoder {
  Decoder(buffer: BitArray, fragments: Option(#(Int, BitArray)))
}

pub fn new_decoder() -> Decoder {
  Decoder(buffer: <<>>, fragments: None)
}

/// Feed bytes into the decoder, returning every frame completed so far.
pub fn push(decoder: Decoder, data: BitArray) -> #(List(Frame), Decoder) {
  decode_loop(
    Decoder(..decoder, buffer: bit_array.concat([decoder.buffer, data])),
    [],
  )
}

fn decode_loop(decoder: Decoder, acc: List(Frame)) -> #(List(Frame), Decoder) {
  case parse_frame(decoder.buffer) {
    Error(Nil) -> #(list.reverse(acc), decoder)
    Ok(#(fin, opcode, payload, rest)) -> {
      let #(frame, fragments) =
        assemble(decoder.fragments, fin, opcode, payload)
      let decoder = Decoder(buffer: rest, fragments: fragments)
      case frame {
        Some(frame) -> decode_loop(decoder, [frame, ..acc])
        None -> decode_loop(decoder, acc)
      }
    }
  }
}

/// Parse one complete frame off the buffer: `#(fin, opcode, payload, rest)`.
/// Errors mean "incomplete" — the caller waits for more bytes.
fn parse_frame(
  buffer: BitArray,
) -> Result(#(Int, Int, BitArray, BitArray), Nil) {
  case buffer {
    <<
      fin:size(1),
      _rsv:size(3),
      opcode:size(4),
      mask:size(1),
      len:size(7),
      rest:bits,
    >> -> {
      use #(len, rest) <- result.try(case len {
        126 ->
          case rest {
            <<len:size(16), rest:bits>> -> Ok(#(len, rest))
            _ -> Error(Nil)
          }
        127 ->
          case rest {
            <<len:size(64), rest:bits>> -> Ok(#(len, rest))
            _ -> Error(Nil)
          }
        _ -> Ok(#(len, rest))
      })
      use #(key, rest) <- result.try(case mask, rest {
        1, <<key:bytes-size(4), rest:bits>> -> Ok(#(Some(key), rest))
        1, _ -> Error(Nil)
        _, _ -> Ok(#(None, rest))
      })
      case bit_array.byte_size(rest) >= len {
        False -> Error(Nil)
        True -> {
          use payload <- result.try(
            bit_array.slice(rest, 0, len) |> result.replace_error(Nil),
          )
          use remaining <- result.try(
            bit_array.slice(rest, len, bit_array.byte_size(rest) - len)
            |> result.replace_error(Nil),
          )
          let payload = case key {
            Some(key) -> mask_payload(payload, key)
            None -> payload
          }
          Ok(#(fin, opcode, payload, remaining))
        }
      }
    }
    _ -> Error(Nil)
  }
}

/// Turn a parsed frame into an emitted `Frame`, folding continuation frames
/// into the pending fragmented message. Control frames (ping/pong/close) may
/// interleave with fragments and never touch fragment state.
fn assemble(
  fragments: Option(#(Int, BitArray)),
  fin: Int,
  opcode: Int,
  payload: BitArray,
) -> #(Option(Frame), Option(#(Int, BitArray))) {
  case opcode, fin, fragments {
    8, _, _ -> #(Some(Close), fragments)
    9, _, _ -> #(Some(Ping(payload)), fragments)
    10, _, _ -> #(Some(Pong(payload)), fragments)
    // Continuation of a fragmented message.
    0, 1, Some(#(first, acc)) -> #(
      Some(data_frame(first, bit_array.concat([acc, payload]))),
      None,
    )
    0, _, Some(#(first, acc)) -> #(
      None,
      Some(#(first, bit_array.concat([acc, payload]))),
    )
    // Continuation with nothing pending: drop it.
    0, _, None -> #(None, None)
    // Unfragmented data frame.
    _, 1, _ -> #(Some(data_frame(opcode, payload)), fragments)
    // First frame of a fragmented message.
    _, _, _ -> #(None, Some(#(opcode, payload)))
  }
}

fn data_frame(opcode: Int, payload: BitArray) -> Frame {
  case opcode {
    1 ->
      case bit_array.to_string(payload) {
        Ok(text) -> Text(text)
        Error(_) -> Binary(payload)
      }
    _ -> Binary(payload)
  }
}

/// Encode a frame. Client-to-server frames must carry a 4-byte mask key.
pub fn encode(frame: Frame, mask_key: Option(BitArray)) -> BitArray {
  let #(opcode, payload) = case frame {
    Text(text) -> #(1, bit_array.from_string(text))
    Binary(data) -> #(2, data)
    Ping(data) -> #(9, data)
    Pong(data) -> #(10, data)
    Close -> #(8, <<>>)
  }
  let len = bit_array.byte_size(payload)
  let mask_bit = case mask_key {
    Some(_) -> 1
    None -> 0
  }
  let length_part = case len {
    len if len <= 125 -> <<mask_bit:size(1), len:size(7)>>
    len if len <= 65_535 -> <<mask_bit:size(1), 126:size(7), len:size(16)>>
    len -> <<mask_bit:size(1), 127:size(7), len:size(64)>>
  }
  let body = case mask_key {
    Some(key) -> bit_array.concat([key, mask_payload(payload, key)])
    None -> payload
  }
  bit_array.concat([<<1:size(1), 0:size(3), opcode:size(4)>>, length_part, body])
}

/// XOR a payload with a repeating 4-byte mask key (RFC 6455 §5.3). The
/// operation is symmetric: masking and unmasking are the same function.
pub fn mask_payload(payload: BitArray, key: BitArray) -> BitArray {
  do_mask(payload, key, [])
}

fn do_mask(payload: BitArray, key: BitArray, acc: List(BitArray)) -> BitArray {
  case payload, key {
    <<word:size(32), rest:bits>>, <<k:size(32), _:bits>> ->
      do_mask(rest, key, [<<int.bitwise_exclusive_or(word, k):size(32)>>, ..acc])
    <<word:size(24)>>, <<k:size(24), _:bits>> ->
      finish_mask(<<int.bitwise_exclusive_or(word, k):size(24)>>, acc)
    <<word:size(16)>>, <<k:size(16), _:bits>> ->
      finish_mask(<<int.bitwise_exclusive_or(word, k):size(16)>>, acc)
    <<word:size(8)>>, <<k:size(8), _:bits>> ->
      finish_mask(<<int.bitwise_exclusive_or(word, k):size(8)>>, acc)
    _, _ -> finish_mask(<<>>, acc)
  }
}

fn finish_mask(last: BitArray, acc: List(BitArray)) -> BitArray {
  bit_array.concat(list.reverse([last, ..acc]))
}

// -- Handshake ----------------------------------------------------------------

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

pub fn random_key() -> String {
  bit_array.base64_encode(crypto.strong_random_bytes(16), True)
}

pub fn random_mask() -> BitArray {
  crypto.strong_random_bytes(4)
}

/// The HTTP Upgrade request opening a WebSocket connection.
pub fn handshake_request(key: String) -> String {
  "GET / HTTP/1.1\r\n"
  <> "Host: yacwu\r\n"
  <> "Upgrade: websocket\r\n"
  <> "Connection: Upgrade\r\n"
  <> "Sec-WebSocket-Key: "
  <> key
  <> "\r\n"
  <> "Sec-WebSocket-Version: 13\r\n\r\n"
}

/// The Sec-WebSocket-Accept value a server must echo for `key`.
pub fn accept_key(key: String) -> String {
  crypto.hash(crypto.Sha1, bit_array.from_string(key <> websocket_guid))
  |> bit_array.base64_encode(True)
}

/// Split an HTTP response buffer at the header terminator, returning the
/// header text and any bytes already received past it (the first frames).
pub fn split_header(buffer: BitArray) -> Result(#(String, BitArray), Nil) {
  use index <- result.try(find_terminator(buffer, 0))
  use header <- result.try(
    bit_array.slice(buffer, 0, index) |> result.replace_error(Nil),
  )
  use rest <- result.try(
    bit_array.slice(buffer, index + 4, bit_array.byte_size(buffer) - index - 4)
    |> result.replace_error(Nil),
  )
  use header <- result.try(
    bit_array.to_string(header) |> result.replace_error(Nil),
  )
  Ok(#(header, rest))
}

fn find_terminator(buffer: BitArray, index: Int) -> Result(Int, Nil) {
  case bit_array.slice(buffer, index, 4) {
    Ok(<<"\r\n\r\n":utf8>>) -> Ok(index)
    Ok(_) -> find_terminator(buffer, index + 1)
    Error(_) -> Error(Nil)
  }
}

/// Validate a handshake response header: 101 status and the accept key
/// matching the request's `key`.
pub fn check_handshake(header: String, key: String) -> Result(Nil, String) {
  let lines = string.split(header, "\r\n")
  use status <- result.try(case lines {
    [status, ..] -> Ok(status)
    [] -> Error("empty handshake response")
  })
  case string.contains(status, " 101 ") || string.ends_with(status, " 101") {
    False -> Error("unexpected handshake status: " <> status)
    True -> {
      let expected = string.lowercase(accept_key(key))
      let accepted =
        list.any(lines, fn(line) {
          case string.split_once(line, ":") {
            Ok(#(name, value)) ->
              string.lowercase(string.trim(name)) == "sec-websocket-accept"
              && string.lowercase(string.trim(value)) == expected
            Error(_) -> False
          }
        })
      case accepted {
        True -> Ok(Nil)
        False -> Error("handshake accept key mismatch")
      }
    }
  }
}
