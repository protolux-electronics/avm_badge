defmodule Mix.Tasks.Badge.Schedule do
  @shortdoc "Refreshes assets/schedule.json, the programme compiled into the firmware"

  @moduledoc """
  Downloads the site's programme over the checked-in copy, fetches each
  talk's own page for its abstract, and says how many sessions it holds.
  Commit the file and flash for the badge to carry it.

      mix badge.schedule
  """

  use Mix.Task

  # Host-only deps, absent from a badge-target compile of this file.
  @compile {:no_warn_undefined, [Req, LazyHTML]}

  @url "https://goatmire.com/schedule.json"
  @out "assets/schedule.json"
  @selector ".whitespace-pre-wrap"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)

    with {:ok, %{status: 200, body: body}} <- Req.get(@url, decode_body: false),
         programme = abstracts(body),
         {:ok, sessions} <- Badge.Schedule.parse(programme, Badge.Page.Schedule.columns()) do
      File.write!(@out, programme)
      Mix.shell().info("#{@out}: #{length(sessions)} sessions")
    else
      :error -> Mix.raise("#{@url} did not answer with a programme")
      {:ok, %{status: status}} -> Mix.raise("could not fetch #{@url}: HTTP #{status}")
      {:error, error} -> Mix.raise("could not fetch #{@url}: #{Exception.message(error)}")
    end
  end

  defp abstracts(body) do
    path = ["days", Access.all(), "spaces", Access.all(), "sessions", Access.all()]

    :erlang.iolist_to_binary(:json.encode(update_in(:json.decode(body), path, &described/1)))
  end

  defp described(%{"url" => url} = session) do
    case abstract(url) do
      "" -> session
      text -> Map.put(session, "description", text)
    end
  end

  defp described(session), do: session

  # A talk page that cannot be read, or carries no abstract, leaves the session
  # as schedule.json gave it.
  defp abstract(url) do
    case Req.get(url, retry: false) do
      {:ok, %{status: 200, body: html}} ->
        html |> LazyHTML.from_document() |> LazyHTML.query(@selector) |> LazyHTML.text()

      _other ->
        ""
    end
  rescue
    _error -> ""
  end
end
