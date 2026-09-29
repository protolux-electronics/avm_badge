defmodule Mix.Tasks.Atomvm.ApplicationBin do
  @moduledoc """
  Writes `priv/application.bin`, the application metadata NervesHub reads.

  A `priv` file is packed as `<app>/priv/<file>`, which is where both the
  device and NervesHub look for it. Aliased onto `atomvm.packbeam`, so a
  normal build produces one.

  ExAtomVM does not write this file and has no option to. Without it
  `:nh_flash.read_metadata/0` answers `no_application_metadata`, the agent
  refuses to start, and NervesHub cannot parse an upload.
  """

  use Mix.Task

  @shortdoc "Write priv/application.bin from the project's app spec"

  @impl Mix.Task
  def run(_args) do
    config = Mix.Project.config()
    app = Keyword.fetch!(config, :app)

    term =
      {:application, app,
       [
         {:description, String.to_charlist(config[:description] || to_string(app))},
         {:vsn, String.to_charlist(Keyword.fetch!(config, :version))},
         {:registered, []},
         {:applications, [:kernel, :stdlib]}
       ]}

    File.mkdir_p!("priv")
    File.write!("priv/application.bin", :erlang.term_to_binary(term))

    # Mix links priv into _build when it compiles. On a clean tree priv did not
    # exist then, so the packer would not see this file without the link.
    Mix.Project.build_structure()

    Mix.shell().info("priv/application.bin: #{app} #{config[:version]}")
  end
end
