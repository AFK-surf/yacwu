import gleeunit/should
import yacwu/files
import yacwu/remote
import yacwu/workspace

pub fn parse_listing_test() {
  let output =
    "E d 0 src\n"
    <> "E f 0 README.md\n"
    <> "E f 1 link.txt\n"
    <> "E o 0 pipe\n"
    <> "E f 0 name with spaces\n"
    <> "S 120 ./README.md\n"
    <> "S 64 ./link.txt\n"
    <> "S 9 ./name with spaces\n"
    <> "S 193 total\n"
  workspace.parse_listing(output)
  |> should.equal([
    files.Entry("src", "dir", 0, False),
    files.Entry("README.md", "file", 120, False),
    files.Entry("link.txt", "file", 64, True),
    files.Entry("pipe", "other", 0, False),
    files.Entry("name with spaces", "file", 9, False),
  ])
}

pub fn parse_listing_ignores_noise_test() {
  workspace.parse_listing("garbage\nS notanumber ./x\nE f\n")
  |> should.equal([])
}

pub fn parse_holders_test() {
  remote.parse_holders(
    "noise\nYACWU_HOLDER 1234 codex\nYACWU_HOLDER 77 some command\nYACWU_HOLDER x y\n",
  )
  |> should.equal([#(1234, "codex"), #(77, "some command")])
}

pub fn parse_bootstrap_reports_codex_home_test() {
  let assert Ok(boot) =
    remote.parse_bootstrap(
      "motd noise\nYACWU_PID 42\nYACWU_HOME /home/u\nYACWU_CODEX_HOME /home/u/.codex-alt\nYACWU_SOCK /home/u/.cache/yacwu/app-server.sock\n",
      "devbox",
    )
  should.equal(boot.codex_home, "/home/u/.codex-alt")
  should.equal(boot.home, "/home/u")

  // Older report without the codex home falls back beside the home dir.
  let assert Ok(boot) =
    remote.parse_bootstrap(
      "YACWU_PID 42\nYACWU_HOME /home/u\nYACWU_SOCK /tmp/s.sock\n",
      "devbox",
    )
  should.equal(boot.codex_home, "/home/u/.codex")
}
