import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import yacwu/git

pub fn parse_scope_test() {
  git.parse_scope("") |> should.equal(Ok(git.All))
  git.parse_scope("all") |> should.equal(Ok(git.All))
  git.parse_scope("staged") |> should.equal(Ok(git.Staged))
  git.parse_scope("unstaged") |> should.equal(Ok(git.Unstaged))
  git.parse_scope("wat") |> should.equal(Error(Nil))
}

pub fn parse_status_tracks_staging_and_untracked_files_test() {
  git.parse_status(" M src/app.ts\u{0000}A  new.ts\u{0000}?? notes.md\u{0000}")
  |> should.equal([
    git.Change("src/app.ts", None, "modified", False, True),
    git.Change("new.ts", None, "added", True, False),
    git.Change("notes.md", None, "added", False, True),
  ])
}

pub fn parse_status_handles_renames_and_conflicts_test() {
  git.parse_status(
    "R  new name.ts\u{0000}old name.ts\u{0000}UU conflict.ts\u{0000}",
  )
  |> should.equal([
    git.Change("new name.ts", Some("old name.ts"), "renamed", True, False),
    git.Change("conflict.ts", None, "conflicted", True, True),
  ])
}

pub fn parse_numstat_handles_regular_binary_and_rename_records_test() {
  let stats =
    git.parse_numstat(
      "12\t3\tsrc/app.ts\u{0000}-\t-\timage.png\u{0000}1\t0\t\u{0000}old name.ts\u{0000}new name.ts\u{0000}",
    )
  dict.get(stats, "src/app.ts")
  |> should.equal(Ok(git.LineStats(Some(12), Some(3))))
  dict.get(stats, "image.png")
  |> should.equal(Ok(git.LineStats(None, None)))
  dict.get(stats, "new name.ts")
  |> should.equal(Ok(git.LineStats(Some(1), Some(0))))
}

pub fn git_runner_inspects_the_project_without_a_shell_test() {
  git.changes_json("..", git.All) |> should.be_ok
  git.diff_json("..", git.All, "src/lib/git-diff.ts") |> should.be_ok
}
