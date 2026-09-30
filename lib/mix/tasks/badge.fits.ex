defmodule Mix.Tasks.Badge.Fits do
  @shortdoc "Refuses a firmware that outgrows its packbeam slot"

  @moduledoc """
  Checks `avm_badge.avm`, written by `mix atomvm.packbeam`, against the
  656K packbeam slot (0xA4000 = 671_744 bytes).

      mix badge.fits
  """

  use Mix.Task

  @avm "avm_badge.avm"
  @limit 671_744

  @impl Mix.Task
  def run(_args) do
    size = File.stat!(@avm).size

    Mix.shell().info("badge.fits: #{size}B of #{@limit}B")

    if size > @limit do
      Mix.raise("badge.fits: #{size}B of #{@limit}B, does not fit the packbeam slot")
    end
  rescue
    File.Error -> Mix.raise("badge.fits: no #{@avm}; run mix atomvm.packbeam")
  end
end
