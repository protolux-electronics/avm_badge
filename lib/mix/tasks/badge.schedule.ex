defmodule Mix.Tasks.Badge.Schedule do
  @shortdoc "Refreshes assets/schedule.json, the programme compiled into the firmware"

  @moduledoc """
  Downloads the site's programme over the checked-in copy and says how many
  sessions it holds. Commit the file and flash for the badge to carry it.

      mix badge.schedule
  """

  use Mix.Task

  @url "https://goatmire.com/schedule.json"
  @out "assets/schedule.json"

  @impl Mix.Task
  def run(_args) do
    case System.cmd("curl", ["-sSf", "-m", "30", @url], stderr_to_stdout: true) do
      {body, 0} -> keep(body)
      {output, _status} -> Mix.raise("could not fetch #{@url}: #{String.trim(output)}")
    end
  end

  defp keep(body) do
    case Badge.Schedule.parse(body, Badge.Page.Schedule.columns()) do
      {:ok, sessions} ->
        File.write!(@out, body)
        Mix.shell().info("#{@out}: #{length(sessions)} sessions")

      :error ->
        Mix.raise("#{@url} did not answer with a programme")
    end
  end
end
