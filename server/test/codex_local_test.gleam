//// The local (stdio child) transport must survive the app-server dying at
//// any moment. A child exit is asynchronous: the port closes as soon as the
//// OS process dies, but the manager only learns of it when it dequeues the
//// `exit_status` message — and `port_command`/`port_close` on a closed port
//// raise `badarg`. Writes racing a child crash (codex aborting after e.g.
//// "failed to refresh available models") must not take the manager down
//// with it.

import gleam/erlang/process
import gleam/json
import gleeunit/should
import yacwu/codex

/// A minimal app-server stand-in: replies to every request by echoing its id,
/// ignores notifications, and exits immediately when told to die.
const stub_command = [
  "bash",
  "-c",
  "
while IFS= read -r line; do
  case \"$line\" in
    *yacwu/die*) exit 0 ;;
  esac
  id=$(printf '%s' \"$line\" | sed -n 's/.*\\\"id\\\":\\([0-9]*\\).*/\\1/p')
  if [ -n \"$id\" ]; then printf '{\"id\":%s,\"result\":{\"ok\":true}}\\n' \"$id\"; fi
done
",
]

fn retry_request(codex: codex.Codex, attempts: Int) -> Result(Nil, String) {
  case codex.request(codex, "test/after", json.object([])) {
    Ok(_) -> Ok(Nil)
    Error(message) ->
      case attempts <= 1 {
        True -> Error(message)
        False -> {
          process.sleep(100)
          retry_request(codex, attempts - 1)
        }
      }
  }
}

fn flood_notify(codex: codex.Codex, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      codex.notify(codex, "test/noise", json.object([]))
      flood_notify(codex, remaining - 1)
    }
  }
}

/// The child exits mid-conversation while the manager's mailbox is full of
/// pending writes: every write that lands on the closed port must be
/// swallowed, the in-flight work failed cleanly, and the next request must
/// respawn a fresh child.
pub fn child_exit_during_writes_test() -> Nil {
  let name: codex.Codex = process.new_name("codex_local_crash_test")
  let assert Ok(_) = codex.start(name, "local-test", codex.Local(stub_command))

  // Connect + initialize + first request round-trip.
  let assert Ok(_) = codex.request(name, "test/ping", json.object([]))

  // Tell the child to die, then keep writing. The die notification and the
  // noise all queue ahead of the port's exit_status message, so the manager
  // keeps calling port_command on a port that closes under it.
  codex.notify(name, "yacwu/die", json.object([]))
  flood_notify(name, 20_000)

  // The manager must still be alive: a follow-up request either fails with
  // the clean "app-server exited" error or respawns a fresh child. Retry
  // until the respawned child answers; a crashed manager never recovers here
  // (there is no registry to restart it) and every attempt reports
  // "codex manager is restarting".
  should.equal(retry_request(name, 10), Ok(Nil))
}

/// A child that dies without ever speaking the protocol: callers get a clean
/// error, not a hang or a manager crash.
pub fn child_exits_before_handshake_test() -> Nil {
  let name: codex.Codex = process.new_name("codex_local_dead_test")
  let assert Ok(_) = codex.start(name, "local-test", codex.Local(["true"]))

  let assert Error(_) = codex.request(name, "test/ping", json.object([]))

  // And the manager survives to serve the error again.
  let assert Error(_) = codex.request(name, "test/ping", json.object([]))
  Nil
}
