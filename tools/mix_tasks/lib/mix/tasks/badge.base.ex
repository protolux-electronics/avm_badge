defmodule Mix.Tasks.Badge.Base do
  @shortdoc "Downloads and flashes the AtomVM base image this firmware expects"

  @moduledoc """
  Fetches the release named in `BASE_IMAGE`, with `curl` when it is installed
  and `gh` otherwise, and writes it to the board.

      mix badge.base              # bootloader, partition table, VM at 0x10000, boot.avm at 0x1F0000
      mix badge.base --vm-only    # just the VM and boot.avm
      mix badge.base --fetch-only # download and verify into .base/, write nothing

  The application at 0x2B8000 survives either flash. `boot.avm` holds the
  standard libraries the VM starts from, so it is always written with the VM.
  `--full` is accepted and does nothing, since it is now the default.
  """

  use Mix.Task

  @repo "protolux-electronics/AtomVM"
  @cache ".base"
  @vm {"atomvm-esp32s3-badge.bin", "0x10000"}
  @boot {"boot.avm", "0x1f0000"}
  @bootloader {"bootloader.bin", "0x0"}
  @table {"partition-table.bin", "0x8000"}
  @sums "SHA256SUMS"

  @impl Mix.Task
  def run(args) do
    {options, _rest} =
      OptionParser.parse!(args, strict: [full: :boolean, vm_only: :boolean, fetch_only: :boolean])

    tag = "BASE_IMAGE" |> File.read!() |> String.trim()
    dir = Path.join(@cache, tag)
    parts = parts(options)

    fetch(tag, dir, parts)
    verify!(dir, parts)
    unless options[:fetch_only], do: flash(dir, parts)
  end

  @doc "What a flash writes: everything unless only the VM was asked for."
  @spec parts(keyword) :: [{binary, binary}]
  def parts(options) do
    if Keyword.get(options, :vm_only, false) do
      [@vm, @boot]
    else
      [@bootloader, @table, @vm, @boot]
    end
  end

  defp fetch(tag, dir, parts) do
    if cached?(dir, parts) do
      Mix.shell().info("base image #{tag} already downloaded")
    else
      tmp = dir <> ".partial"
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)
      Mix.shell().info("downloading base image #{tag}")
      download(tag, tmp, parts)
      # Only becomes the real cache dir once the download has fully landed.
      File.rm_rf!(dir)
      File.rename!(tmp, dir)
    end
  end

  defp download(tag, tmp, parts) do
    cond do
      System.find_executable("curl") ->
        for file <- [@sums | Enum.map(parts, &elem(&1, 0))] do
          url = "https://github.com/#{@repo}/releases/download/#{tag}/#{file}"
          cmd!("curl", ["-sSfL", "-m", "300", "-o", Path.join(tmp, file), url])
        end

      System.find_executable("gh") ->
        cmd!("gh", ["release", "download", tag, "--repo", @repo, "-D", tmp])

      true ->
        Mix.raise("no curl or gh on PATH")
    end
  end

  # A cache predating a newly added part is refetched rather than reported missing.
  defp cached?(dir, parts) do
    File.dir?(dir) and File.exists?(Path.join(dir, @sums)) and
      Enum.all?(parts, fn {file, _offset} -> File.exists?(Path.join(dir, file)) end)
  end

  defp verify!(dir, parts) do
    sums_path = Path.join(dir, @sums)
    unless File.exists?(sums_path), do: Mix.raise("#{sums_path} is missing")

    sums =
      sums_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [hash, name] = String.split(line, "  ", parts: 2)
        {Path.basename(name), hash}
      end)

    for {file, _offset} <- parts do
      expected = sums[file] || Mix.raise("#{@sums} does not cover #{file}")
      path = Path.join(dir, file)
      unless File.exists?(path), do: Mix.raise("#{file} is missing from #{dir}")

      actual =
        path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      if actual != expected, do: Mix.raise("#{file}: checksum mismatch, download is corrupt")
    end
  end

  defp flash(dir, parts) do
    args = Enum.flat_map(parts, fn {file, offset} -> [offset, Path.join(dir, file)] end)
    {bin, prefix} = esptool()

    cmd!(bin, prefix ++ ["--chip", "esp32s3", "--baud", "921600", "write_flash"] ++ args)
  end

  # esptool ships under both names while the .py suffix is being retired.
  defp esptool do
    cond do
      path = System.find_executable("esptool") -> {path, []}
      path = System.find_executable("esptool.py") -> {path, []}
      path = System.find_executable("python3") -> {path, ["-m", "esptool"]}
      true -> Mix.raise("no esptool on PATH")
    end
  end

  defp cmd!(bin, args) do
    case System.cmd(bin, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, code} -> Mix.raise("#{bin} exited #{code}")
    end
  end
end
