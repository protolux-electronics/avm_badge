defmodule Badge.UI.Guard do
  @moduledoc """
  Runs a page callback so that a crash lands on the home grid instead of
  taking `Badge.UI` down.

  A raise, throw or exit is logged with the page, the callback and the reason.
  An installed app that crashes is disabled until the next boot.
  """

  alias Badge.Store.Installed

  @doc "`{:ok, result}` of `apply(page, fun, args)`, or `:crashed`."
  @spec call(module, atom, list) :: {:ok, term} | :crashed
  def call(page, fun, args) do
    {:ok, apply(page, fun, args)}
  catch
    kind, reason ->
      :io.format(~c"UI: page ~p crashed in ~p: ~p ~p~n", [page, fun, kind, reason])
      disable(Installed.entry_for(page))
      :crashed
  end

  defp disable(nil), do: :ok
  defp disable(entry), do: Installed.disable(entry.id)
end
