defmodule Mix.Tasks.Sim.Check do
  @shortdoc "Renders every page of the simulator without a browser"

  @moduledoc """
  Starts the simulated board, renders every page through the shared UI and
  reports what each produced, then checks a simulated reboot.

      mix sim.check
      mix sim.check --dump DIR    # also write each frame as JSON
  """

  use Mix.Task

  alias Badge.Sim.Board
  alias Badge.Sim.Check
  alias Badge.Sim.Display

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _log} = Badge.Log.start_link(:ok)
    {:ok, _board} = Board.start_link(:ok)

    for page <- Check.pages() do
      case Check.render(page) do
        {:ok, items, frame, assets} ->
          Mix.shell().info(
            "#{inspect(page)}: #{length(items)} items, #{length(assets)} bitmaps, #{length(frame)} commands"
          )

        {:error, error} ->
          Mix.shell().error("#{inspect(page)}: FAILED " <> Exception.message(error))
      end
    end

    snapshot = Display.snapshot()
    Mix.shell().info("screen frame #{snapshot.sequence}: #{length(snapshot.frame)} commands")

    Board.reboot()
    rebooted = Display.snapshot()

    Mix.shell().info(
      "after reboot frame #{rebooted.sequence}: #{length(rebooted.frame)} commands"
    )

    case OptionParser.parse!(args, strict: [dump: :string]) do
      {[dump: dir], _} -> Check.dump(dir)
      _ -> :ok
    end
  end
end
