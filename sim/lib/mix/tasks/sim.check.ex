defmodule Mix.Tasks.Sim.Check do
  @shortdoc "Renders every page of the simulator without a browser"

  @moduledoc """
  Starts the simulated board, renders every page once and reports what each
  produced, then drives the screen through a few keys and a reboot.

      MIX_TARGET=sim mix sim.check
      MIX_TARGET=sim mix sim.check --dump DIR    # also write each frame as JSON
  """

  use Mix.Task

  alias Badge.Sim.Board
  alias Badge.Sim.Check
  alias Badge.Sim.Screen

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _log} = Badge.Log.start_link(:ok)
    {:ok, _board} = Board.start_link(:ok)

    for page <- Check.pages() do
      case Check.render(page) do
        {:ok, items, frame, assets} ->
          Mix.shell().info("#{inspect(page)}: #{length(items)} items, #{length(assets)} bitmaps, #{length(frame)} commands")

        {:error, error} ->
          Mix.shell().error("#{inspect(page)}: FAILED " <> Exception.message(error))
      end
    end

    for key <- [{:nav, :diamond}, {:move, :right}, {:move, :right}, {:move, :right}] do
      Screen.key(key)
      Process.sleep(150)
    end

    Mix.shell().info("screen frame: #{length(Screen.frame())} commands")

    Board.reboot()
    Process.sleep(150)
    Mix.shell().info("after reboot: #{length(Screen.frame())} commands")

    case OptionParser.parse!(args, strict: [dump: :string]) do
      {[dump: dir], _} -> Check.dump(dir)
      _ -> :ok
    end
  end
end
