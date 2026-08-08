import gleam/option.{None, Some}
import yacwu/config

pub fn defaults_test() {
  let assert Ok(conf) = config.load([])
  assert conf.host == "127.0.0.1"
  assert conf.port == 3000
  assert conf.unix == None
  assert conf.help == False
}

pub fn positional_host_port_test() {
  let assert Ok(conf) = config.load(["0.0.0.0:8080"])
  assert conf.host == "0.0.0.0"
  assert conf.port == 8080
}

pub fn positional_port_only_test() {
  let assert Ok(conf) = config.load([":8080"])
  assert conf.host == "127.0.0.1"
  assert conf.port == 8080

  let assert Ok(conf) = config.load(["9999"])
  assert conf.port == 9999
}

pub fn positional_host_only_test() {
  let assert Ok(conf) = config.load(["192.168.1.5"])
  assert conf.host == "192.168.1.5"
  assert conf.port == 3000
}

pub fn flags_test() {
  let assert Ok(conf) = config.load(["-H", "0.0.0.0", "-p", "8080"])
  assert conf.host == "0.0.0.0"
  assert conf.port == 8080
}

pub fn equals_flag_values_test() {
  let assert Ok(conf) = config.load(["--host=10.0.0.1", "--port=81"])
  assert conf.host == "10.0.0.1"
  assert conf.port == 81
}

pub fn unix_flag_test() {
  let assert Ok(conf) = config.load(["--unix", "/run/yacwu.sock"])
  assert conf.unix == Some("/run/yacwu.sock")
}

pub fn help_flag_test() {
  let assert Ok(conf) = config.load(["--help"])
  assert conf.help == True
}

pub fn unknown_option_test() {
  assert config.load(["--bogus"]) == Error(config.UnknownOption("--bogus"))
}

pub fn invalid_port_test() {
  assert config.load(["--port", "hello"]) == Error(config.InvalidPort("hello"))
  assert config.load(["--port", "70000"]) == Error(config.InvalidPort("70000"))
}

pub fn missing_value_test() {
  assert config.load(["--port"]) == Error(config.MissingValue("--port"))
}
