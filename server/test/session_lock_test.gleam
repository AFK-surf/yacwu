import yacwu/session_lock

// Verbatim `fstat | head` output from a real OpenBSD system (hexdump-decoded),
// including the header line, special fd names (text/wd), a pipe line with a
// trailing space, and repeated pids across descriptors.
const fstat_sample = "USER     CMD          PID   FD MOUNT        INUM  MODE          R/W    SZ|DV
user     ksh        87464 text /           25940  -r-xr-xr-x      r   810120
user     ksh        87464   wd /home      758390  drwxr-xr-x      r     1024
user     ksh        87464    0 pipe 0x0 state:
user     ksh        87464    1 /           52353  crw--w----     rw    ttyp4
user     ksh        87464    2 /           52353  crw--w----     rw    ttyp4
user     ksh        87464   10 /           53019  crw-rw-rw-   rwep      tty
user     ksh        87464   11 /           52353  crw--w----    rwe    ttyp4
user     ksh        28618 text /           25940  -r-xr-xr-x      r   810120
user     ksh        28618   wd /home      758390  drwxr-xr-x      r     1024
"

pub fn parse_fstat_dedupes_pids_test() {
  assert session_lock.parse_fstat_output(fstat_sample)
    == [#(87_464, "ksh"), #(28_618, "ksh")]
}

pub fn parse_fstat_skips_header_test() {
  assert session_lock.parse_fstat_output(
      "USER     CMD          PID   FD MOUNT        INUM  MODE          R/W    SZ|DV\n",
    )
    == []
}

pub fn parse_fstat_file_scan_line_test() {
  // `fstat <file>` lines carry the filename in a trailing NAME column.
  let output =
    "user     codex      50655   18 /home    3529945 -rw-r--r--    r    185342 /home/user/.codex/sessions/rollout.jsonl\n"
  assert session_lock.parse_fstat_output(output) == [#(50_655, "codex")]
}

pub fn parse_fstat_command_with_spaces_test() {
  let output =
    "user     beam.smp -sname x  1234    5 /home     99999 -rw-r--r--    r      2048\n"
  assert session_lock.parse_fstat_output(output)
    == [#(1234, "beam.smp -sname x")]
}

pub fn parse_fstat_garbage_test() {
  assert session_lock.parse_fstat_output("") == []
  assert session_lock.parse_fstat_output(
      "fstat: /nope: No such file or directory\n",
    )
    == []
}

pub fn parse_ps_parents_test() {
  let output = "    1     0\n87464  3921\n28618 87464\n  bad line\n"
  assert session_lock.parse_ps_parents(output)
    == [#(1, 0), #(87_464, 3921), #(28_618, 87_464)]
}
