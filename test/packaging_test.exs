defmodule PackagingTest do
  use ExUnit.Case, async: true

  test "no dependency is resolved from a local path outside the repo" do
    root = Path.expand("..", __DIR__)

    offenders =
      for {name, opts} <- Mix.Project.config()[:deps],
          is_list(opts),
          path = Keyword.get(opts, :path),
          not String.starts_with?(Path.expand(path, root), root <> "/"),
          do: name

    assert offenders == [],
           "path deps do not exist on a collaborator's machine: #{inspect(offenders)}"
  end

  test "every git dependency is pinned to a full SHA" do
    unpinned =
      for {name, opts} <- Mix.Project.config()[:deps],
          is_list(opts),
          Keyword.has_key?(opts, :git) or Keyword.has_key?(opts, :github),
          not (is_binary(Keyword.get(opts, :ref)) and byte_size(Keyword.get(opts, :ref)) == 40),
          do: name

    assert unpinned == [],
           "a floating ref makes builds irreproducible: #{inspect(unpinned)}"
  end

  @root Path.expand("..", __DIR__)

  test "every generated font is one the firmware actually loads" do
    generated =
      Path.wildcard(Path.join(@root, "assets/fonts/*.uf"))
      |> Enum.map(&Path.basename(&1, ".uf"))
      |> Enum.sort()

    assert generated == ["dogica", "pixel_operator", "w95fa"]
  end

  test "asset sources live in the repo" do
    for path <- ["assets/src/fonts", "assets/src/icons"] do
      assert File.dir?(Path.join(@root, path)), "#{path} is missing"
    end

    assert File.exists?(Path.join(@root, "assets/src/icons/rickroll-roll.gif"))
  end

  @tag :regenerates_assets
  test "mkfonts.sh reproduces the committed fonts byte for byte" do
    before =
      for f <- Path.wildcard(Path.join(@root, "assets/fonts/*.uf")),
          into: %{},
          do: {Path.basename(f), File.read!(f)}

    {_, 0} =
      System.cmd(Path.join(@root, "tools/mkfonts.sh"), [], cd: @root, stderr_to_stdout: true)

    rebuilt =
      for f <- Path.wildcard(Path.join(@root, "assets/fonts/*.uf")),
          into: %{},
          do: {Path.basename(f), File.read!(f)}

    assert before == rebuilt
  end

  @tag :regenerates_assets
  test "mix badge.assets is deterministic and packs exactly the runtime assets" do
    run = fn ->
      {_, 0} = System.cmd("mix", ["badge.assets"], cd: @root, stderr_to_stdout: true)
      File.read!(Path.join(@root, "assets.avm"))
    end

    first = run.()
    assert first == run.(), "two runs of mix badge.assets differ"

    expected =
      Enum.map(
        0..15,
        &"assets/priv/rickroll/frame#{String.pad_leading("#{&1}", 2, "0")}@48x48.rgba"
      ) ++
        [
          "assets/priv/fonts/dogica.uf",
          "assets/priv/fonts/pixel_operator.uf",
          "assets/priv/fonts/w95fa.uf"
        ]

    for name <- expected do
      assert String.contains?(first, name), "archive is missing #{name}"
    end

    refute String.contains?(first, "tengoku"),
           "tengoku.uf was dropped in Task 4 and must not be packed"

    members =
      ~r/assets\/priv\/[a-z0-9_\/.@-]+\.(?:rgba|uf)/
      |> Regex.scan(first)
      |> List.flatten()

    assert length(members) == length(expected),
           "archive has #{length(members)} members, expected #{length(expected)}: #{inspect(members -- expected)}"

    assert Enum.sort(members) == Enum.sort(expected),
           "archive members do not match the expected set exactly"
  end

  test "font and root licences are bundled" do
    bundled =
      Path.wildcard(Path.join(@root, "LICENSES/*"))
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    expected = ["dogica-OFL-1.1.txt", "pixel_operator-CC0-1.0.txt", "w95fa-OFL-1.1.txt"]

    assert bundled == expected,
           "LICENSES directory missing or has unexpected files: #{inspect(bundled)}"

    assert File.exists?(Path.join(@root, "LICENSE")),
           "root LICENSE file is missing"
  end

  test "the expected base image tag is recorded" do
    tag = @root |> Path.join("BASE_IMAGE") |> File.read!() |> String.trim()
    assert tag =~ ~r/^badge-v\d+$/, "BASE_IMAGE must name a release tag, got: #{tag}"
  end
end
