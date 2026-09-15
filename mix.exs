defmodule Badge.MixProject do
  use Mix.Project

  def project do
    [
      app: :avm_badge,
      version: "0.1.1",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # ExAtomVM writes no application.bin, and NervesHub cannot identify
      # firmware without one. The flash task bypasses the packbeam alias.
      aliases: [
        "atomvm.packbeam": ["atomvm.application_bin", "atomvm.packbeam"],
        "atomvm.esp32.flash": ["atomvm.application_bin", "atomvm.esp32.flash"]
      ],
      atomvm: [
        start: Badge,
        flash_offset: 0x2B8000,
        chip: "esp32s3",
        port: "auto"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:exatomvm,
       github: "atomvm/ExAtomVM",
       ref: "ff7daf7e83a4e86fbf078730b6c49045a99de9f8",
       runtime: false},
      # The Erlang side of the port driver built into the VM. A rebar3
      # project, so mix is told which manager to use.
      {:atomvm_websocket_client,
       github: "nerves-hub/atomvm_websocket_client",
       ref: "011b99c30bea5253eb29558e3c6ac420a5472c0f",
       manager: :rebar3},
      # The NervesHub agent, and its Elixir face. The override stops the
      # wrapper fetching its own unpinned copy of the agent.
      {:nerves_hub_link_atomvm_esp32_ex,
       github: "nerves-hub/nerves_hub_link_atomvm_esp32_ex",
       ref: "b9f8a01868d41fcf25bfafe8dd6dc62f61498e52"},
      {:nerves_hub_link_atomvm_esp32,
       github: "nerves-hub/nerves_hub_link_atomvm_esp32",
       ref: "b5d57f945114c0687d519cbd23a7b210d48c5fdc",
       manager: :rebar3,
       override: true},
      # The packbeam escript, from Hex rather than an AtomVM checkout.
      {:atomvm_packbeam, "~> 0.8.2", runtime: false}
    ]
  end
end
