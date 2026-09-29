defmodule Badge.MixTasks.MixProject do
  use Mix.Project

  # The badge's own Mix tasks. A dependency with `runtime: false`, so the
  # packer leaves them out of main.avm.
  def project do
    [app: :badge_mix_tasks, version: "0.1.0", elixir: "~> 1.13", deps: []]
  end

  def application, do: [extra_applications: [:logger]]
end
