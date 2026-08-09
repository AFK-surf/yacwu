import gleeunit/should
import simplifile
import yacwu/files

// -- sanitize -----------------------------------------------------------------

pub fn sanitize_accepts_simple_relative_paths_test() {
  files.sanitize("") |> should.equal(Ok(""))
  files.sanitize("src") |> should.equal(Ok("src"))
  files.sanitize("src/lib/protocol.ts")
  |> should.equal(Ok("src/lib/protocol.ts"))
}

pub fn sanitize_normalizes_dot_segments_test() {
  files.sanitize("src/./lib") |> should.equal(Ok("src/lib"))
  files.sanitize("src/lib/../routes") |> should.equal(Ok("src/routes"))
  files.sanitize("src//lib") |> should.equal(Ok("src/lib"))
}

pub fn sanitize_rejects_escapes_test() {
  files.sanitize("..") |> should.equal(Error(Nil))
  files.sanitize("../etc") |> should.equal(Error(Nil))
  files.sanitize("src/../../etc") |> should.equal(Error(Nil))
  files.sanitize("/etc/passwd") |> should.equal(Error(Nil))
  files.sanitize("src\\lib") |> should.equal(Error(Nil))
  files.sanitize("src/\u{0000}x") |> should.equal(Error(Nil))
}

// -- resolve ------------------------------------------------------------------

pub fn resolve_joins_relative_paths_onto_the_root_test() {
  files.resolve("/work", "") |> should.equal("/work")
  files.resolve("/work", "src/lib") |> should.equal("/work/src/lib")
}

// -- sort_entries -------------------------------------------------------------

pub fn sort_entries_puts_directories_first_then_names_test() {
  let entries = [
    files.Entry("zeta.ts", "file", 10, False),
    files.Entry("Alpha.ts", "file", 10, False),
    files.Entry("src", "dir", 0, False),
    files.Entry("BUILD", "dir", 0, False),
  ]
  files.sort_entries(entries)
  |> should.equal([
    files.Entry("BUILD", "dir", 0, False),
    files.Entry("src", "dir", 0, False),
    files.Entry("Alpha.ts", "file", 10, False),
    files.Entry("zeta.ts", "file", 10, False),
  ])
}

// -- list_directory / read_file (against a real temp tree) --------------------

fn with_temp_tree(run: fn(String) -> Nil) -> Nil {
  let root = "/tmp/yacwu_files_test"
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root <> "/sub")
  let assert Ok(_) = simplifile.write(root <> "/hello.txt", "hi there\n")
  let assert Ok(_) =
    simplifile.write_bits(root <> "/blob.bin", <<0, 159, 146, 150>>)
  run(root)
  let _ = simplifile.delete(root)
  Nil
}

pub fn list_directory_reports_kinds_and_sizes_test() {
  with_temp_tree(fn(root) {
    let assert Ok(entries) = files.list_directory(root)
    entries
    |> should.equal([
      files.Entry("sub", "dir", 0, False)
        |> fn(e) { files.Entry(..e, size: dir_size(root <> "/sub")) },
      files.Entry("blob.bin", "file", 4, False),
      files.Entry("hello.txt", "file", 9, False),
    ])
  })
}

fn dir_size(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path)
  info.size
}

pub fn list_directory_fails_for_missing_directories_test() {
  files.list_directory("/tmp/yacwu_files_test_missing")
  |> should.be_error
}

pub fn read_file_returns_text_content_test() {
  with_temp_tree(fn(root) {
    files.read_file(root <> "/hello.txt")
    |> should.equal(files.Text(9, "hi there\n"))
  })
}

pub fn read_file_detects_binary_content_test() {
  with_temp_tree(fn(root) {
    files.read_file(root <> "/blob.bin") |> should.equal(files.Binary(4))
  })
}

pub fn read_file_reports_missing_files_and_directories_test() {
  with_temp_tree(fn(root) {
    files.read_file(root <> "/nope.txt") |> should.equal(files.Missing)
    // Directories are not files.
    files.read_file(root <> "/sub") |> should.equal(files.Missing)
  })
}
