defmodule Pkglog.PacmanActionsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  @fixtures Path.expand("fixtures/pacman", __DIR__)

  # Run pkglog with -P over a fixture log and return the package lines
  # printed (timestamp, boot marker and delimiters stripped).
  defp run_p(fixture) do
    config =
      ["-P", "-a", "-c", "-j", "-p", Path.join(@fixtures, fixture)]
      |> Pkglog.CLI.parse_args()
      |> Pkglog.CLI.process_options()

    capture_io(fn -> Pkglog.run(config) end)
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.starts_with?(&1, "---") or &1 =~ "LAST SYSTEM BOOT"))
    |> Enum.map(fn line -> line |> String.split(" ", parts: 3) |> List.last() end)
  end

  test "shows package named in sync command, hides pulled-in dependencies" do
    assert run_p("sync_hides_deps.log") == ["foo 2.0-1 installed"]
  end

  test "shows package named with a repo prefix" do
    assert run_p("sync_repo_prefix.log") == ["foo 2.0-1 installed"]
  end

  test "--asdeps install is shown as dependency" do
    assert run_p("sync_asdeps.log") == ["bar 1.0-1 installed as dependency"]
  end

  test "-U with archive file matches package" do
    assert run_p("upgrade_archive.log") == ["baz 1.0-1 installed"]
  end

  test "removal shows named package and hides auto-removed deps" do
    assert run_p("remove_hides_deps.log") == ["foo 1.0-1 removed"]
  end

  test "-D --asdeps marks package as dependency" do
    assert run_p("mark_asdeps.log") == ["foo marked as dependency"]
  end

  test "hook and scriptlet lines don't clear the pending command" do
    assert run_p("hooks_and_scriptlets.log") == ["foo-git 1.0.r1-1 installed"]
  end
end
