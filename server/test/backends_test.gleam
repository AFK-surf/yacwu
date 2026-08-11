import envoy
import gleam/list
import yacwu/backends.{Backend}
import yacwu/hosts

fn with_env(value: String, run: fn() -> a) -> a {
  envoy.set("YACWU_BACKENDS", value)
  let result = run()
  envoy.unset("YACWU_BACKENDS")
  result
}

// -- Parsing ------------------------------------------------------------------

pub fn parse_single_entry_test() {
  assert backends.parse("claude=claude-codex app-server")
    == [Backend("claude", ["claude-codex", "app-server"])]
}

pub fn parse_multiple_entries_test() {
  assert backends.parse(
      "claude=node /opt/claude-codex/dist/src/adapter.mjs;mini=codex-mini app-server",
    )
    == [
      Backend("claude", ["node", "/opt/claude-codex/dist/src/adapter.mjs"]),
      Backend("mini", ["codex-mini", "app-server"]),
    ]
}

pub fn parse_trims_names_and_collapses_whitespace_test() {
  assert backends.parse(" claude =  claude-codex   app-server ; ")
    == [Backend("claude", ["claude-codex", "app-server"])]
}

pub fn parse_empty_test() {
  assert backends.parse("") == []
  assert backends.parse(";;") == []
}

pub fn parse_drops_entries_without_a_command_test() {
  assert backends.parse("claude=;ok=cmd") == [Backend("ok", ["cmd"])]
  assert backends.parse("claude= \t ") == []
}

pub fn parse_drops_entries_without_an_equals_test() {
  assert backends.parse("just-a-command;ok=cmd") == [Backend("ok", ["cmd"])]
}

pub fn parse_reserves_the_local_name_test() {
  assert backends.parse("local=evil-codex app-server") == []
}

pub fn parse_drops_unsafe_names_test() {
  assert backends.parse("=cmd") == []
  assert backends.parse("has space=cmd") == []
  assert backends.parse("has/slash=cmd") == []
  assert backends.parse("-dash=cmd") == []
}

pub fn parse_first_entry_wins_on_duplicate_names_test() {
  assert backends.parse("dup=first one;dup=second")
    == [Backend("dup", ["first", "one"])]
}

pub fn parse_command_may_contain_further_equals_test() {
  // Only the first `=` separates name from command, so flags with values
  // survive intact.
  assert backends.parse("claude=adapter --mode=remote")
    == [Backend("claude", ["adapter", "--mode=remote"])]
}

// -- Environment discovery and host classification ----------------------------

pub fn discover_reads_the_environment_test() {
  use <- with_env("claude=claude-codex app-server;mini=codex-mini app-server")
  assert list.map(backends.discover(), fn(backend) { backend.name })
    == ["claude", "mini"]
  assert backends.command("claude") == Ok(["claude-codex", "app-server"])
  assert backends.command("nope") == Error(Nil)
}

pub fn backends_count_as_local_hosts_test() {
  use <- with_env("claude=claude-codex app-server")
  assert hosts.is_local("local")
  assert hosts.is_local("claude")
  assert !hosts.is_local("some-ssh-host")
}

pub fn without_configuration_only_local_is_local_test() {
  envoy.unset("YACWU_BACKENDS")
  assert backends.discover() == []
  assert hosts.is_local("local")
  assert !hosts.is_local("claude")
}
