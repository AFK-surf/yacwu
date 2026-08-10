import gleam/list
import gleeunit/should
import simplifile
import yacwu/ssh_config.{Hosts, Include}

pub fn parse_basic_test() {
  let content =
    "# comment
Host devbox
  HostName dev.example.com
  User me

host gpu01 gpu02
Host *
  ForwardAgent yes
"
  ssh_config.parse(content)
  |> should.equal([Hosts(["devbox"]), Hosts(["gpu01", "gpu02"]), Hosts(["*"])])
}

pub fn parse_equals_and_quotes_test() {
  ssh_config.parse("Host=devbox\nInclude \"conf d/extra\" other.conf\n")
  |> should.equal([Hosts(["devbox"]), Include(["conf d/extra", "other.conf"])])
}

pub fn concrete_host_test() {
  should.be_true(ssh_config.concrete_host("devbox"))
  should.be_true(ssh_config.concrete_host("user@host.example-1.com"))
  should.be_false(ssh_config.concrete_host("*"))
  should.be_false(ssh_config.concrete_host("web-*"))
  should.be_false(ssh_config.concrete_host("!prod"))
  should.be_false(ssh_config.concrete_host("host?"))
  should.be_false(ssh_config.concrete_host("-oProxyCommand=evil"))
  should.be_false(ssh_config.concrete_host(""))
  should.be_false(ssh_config.concrete_host("a b"))
}

pub fn glob_match_test() {
  should.be_true(ssh_config.glob_match("*.conf", "work.conf"))
  should.be_true(ssh_config.glob_match("config_*", "config_home"))
  should.be_true(ssh_config.glob_match("*", "anything"))
  should.be_true(ssh_config.glob_match("a*b*c", "aXbYc"))
  should.be_false(ssh_config.glob_match("*.conf", "conf.bak"))
  should.be_false(ssh_config.glob_match("exact", "other"))
  should.be_true(ssh_config.glob_match("exact", "exact"))
}

pub fn hosts_in_with_includes_test() {
  let dir = "/tmp/yacwu-ssh-config-test"
  let _ = simplifile.delete(dir)
  let assert Ok(_) = simplifile.create_directory_all(dir <> "/conf.d")
  let assert Ok(_) =
    simplifile.write(
      dir <> "/config",
      "Host devbox\nInclude conf.d/*.conf\nHost *.internal\nHost devbox\n",
    )
  let assert Ok(_) =
    simplifile.write(dir <> "/conf.d/a.conf", "Host alpha beta\n")
  let assert Ok(_) =
    simplifile.write(dir <> "/conf.d/b.conf", "Include ../config\nHost gamma\n")
  let assert Ok(_) = simplifile.write(dir <> "/conf.d/skip.txt", "Host nope\n")

  let hosts = ssh_config.hosts_in(dir <> "/config", dir, "/nonexistent-home", 4)
  // devbox deduped; the include cycle is cut by the depth bound; the pattern
  // alias and the non-matching skip.txt are excluded.
  should.equal(hosts, ["devbox", "alpha", "beta", "gamma"])
  should.be_false(list.contains(hosts, "nope"))

  let _ = simplifile.delete(dir)
}

pub fn hosts_in_missing_file_test() {
  ssh_config.hosts_in("/nonexistent/config", "/nonexistent", "/", 4)
  |> should.equal([])
}
