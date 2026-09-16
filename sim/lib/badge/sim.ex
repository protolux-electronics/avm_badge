defmodule Badge.Sim do
  @moduledoc """
  Runs the badge's pages on the host and draws them on a canvas in the browser.

      MIX_TARGET=sim iex -S mix        # then open http://localhost:3240
      MIX_TARGET=sim mix sim.check     # render every page once, no browser

  Pages are the real modules. Everything they call that lives on the badge
  (NVS, the radio, the ADC, the LED chain, the hub links) is stood in for by a
  fake process under the same name, so a page cannot tell the difference.
  Rendering mirrors AtomGL: rects, images and text in the built-in 8x16 font
  or a ufont, drawn tail to head.

  Keys: type to send characters, arrows move, Enter, Backspace and Tab edit,
  Esc goes home, F1 to F6 press the six shape buttons.
  """

  @root Path.expand("../../..", __DIR__)

  @doc "The repository root."
  def root, do: @root

  @doc "The `assets/` directory, standing in for the assets partition."
  def assets, do: Path.join(@root, "assets")

  @doc "Prints a line on the console and into `Badge.Log`, so the Log tab has it too."
  def log(line) do
    IO.puts(line)

    case Process.whereis(Badge.Log) do
      nil -> :ok
      log -> IO.puts(log, line)
    end
  end
end
