defmodule Badge.Page.Cluster do
  @moduledoc """
  Joins the badge to an Erlang cluster over wifi.

  S brings the node up and S again takes it down. Enter edits the cookie,
  which a host has to match; clearing it puts the compiled default back.
  Everything else drawn comes from `Badge.Cluster.Link.status/0`.

  The node stays up when the page is left, since a badge that only clustered
  while this screen was showing could not be driven from anywhere else.

  The `seen` list is hosts that have called `Badge.Cluster.Remote.hello/1`,
  not the live connection list: AtomVM has no `:erlang.nodes/0`, so a badge
  only knows who has bothered to say so.
  """

  use Badge.Page

  alias Badge.Cluster.Link
  alias Badge.Field
  alias Badge.Nav
  alias Badge.Readout
  alias Badge.Theme

  @row_x 8
  @help_y 216

  # How much of a node name or reason fits beside its label.
  @columns 24

  # How many connected peers the panel has room to name.
  @shown 4

  # A cookie longer than the row is one nobody can read off the panel.
  @capacity 24

  @state_y Theme.content_top()
  @node_y @state_y + Readout.pitch()
  @cookie_y @node_y + Readout.pitch()
  @peers_y @cookie_y + Readout.pitch() + 8
  @first_peer_y @peers_y + Readout.pitch()

  @impl true
  def title, do: "Cluster"

  @impl true
  def icon, do: :link

  @impl true
  def init, do: %{status: nil, field: nil}

  @impl true
  def tick(state), do: %{state | status: Link.status()}

  @impl true
  def refresh(_state), do: 250

  # Typing owns every key, so an S in a cookie is not a command.
  @impl true
  def handle_key(event, %{field: field} = state) when field != nil, do: typing(event, state)

  def handle_key({:char, char}, %{status: %{state: :off}} = state)
      when char == ?s or char == ?S do
    Link.open()

    {:ok, state}
  end

  def handle_key({:char, char}, %{status: status} = state)
      when (char == ?s or char == ?S) and status != nil do
    Link.close()

    {:ok, state}
  end

  def handle_key({:edit, :newline}, %{status: status} = state) when status != nil do
    {:ok, %{state | field: fill(status.cookie)}}
  end

  def handle_key(_event, _state), do: :ignore

  defp typing({:edit, :newline}, state) do
    Link.set_cookie(Field.value(state.field))

    {:ok, %{state | field: nil}}
  end

  defp typing({:nav, :home}, state), do: {:ok, %{state | field: nil}}

  defp typing({:char, char}, state) do
    {:ok, %{state | field: Field.insert(state.field, char)}}
  end

  defp typing({:edit, :backspace}, state) do
    {:ok, %{state | field: Field.backspace(state.field)}}
  end

  defp typing({:move, :left}, state), do: {:ok, %{state | field: Field.left(state.field)}}
  defp typing({:move, :right}, state), do: {:ok, %{state | field: Field.right(state.field)}}

  # Everything else is swallowed rather than ignored, so no arrow walks off a
  # cookie that is half typed.
  defp typing(_event, state), do: {:ok, state}

  defp fill(value) do
    :lists.foldl(&Field.insert(&2, &1), Field.new(@capacity), :erlang.binary_to_list(value))
  end

  @impl true
  def render(%{status: nil} = state), do: render(%{state | status: unknown()})

  def render(state) do
    state_row(state.status) ++
      node_row(state.status) ++
      cookie_row(state) ++ peer_rows(state.status) ++ help(state)
  end

  defp unknown do
    %{state: :off, node: nil, cookie: Link.default_cookie(), ip: nil, peers: [], reason: nil}
  end

  defp state_row(status) do
    Readout.right_row("node", state_text(status), @state_y, state_colour(status))
  end

  defp state_text(%{state: :off}), do: "down"
  defp state_text(%{state: :waiting, reason: nil}), do: "waiting for wifi"
  defp state_text(%{state: :waiting, reason: reason}), do: clip(reason)
  defp state_text(%{state: :failed, reason: nil}), do: "failed"
  defp state_text(%{state: :failed, reason: reason}), do: clip(reason)
  defp state_text(_status), do: "up"

  defp state_colour(%{state: :off}), do: Theme.dim()
  defp state_colour(%{state: :waiting}), do: Theme.warn()
  defp state_colour(%{state: :failed}), do: Theme.alert()
  defp state_colour(_status), do: Theme.ok()

  defp node_row(%{node: nil}), do: []

  defp node_row(%{node: node}) do
    Readout.right_row("name", clip(node), @node_y, Theme.fg())
  end

  defp cookie_row(%{field: field}) when field != nil do
    Readout.right_row("cookie", Field.value(field) <> "_", @cookie_y, Theme.select())
  end

  defp cookie_row(%{status: %{cookie: cookie}}) do
    Readout.right_row("cookie", clip(cookie), @cookie_y, Theme.dim())
  end

  defp peer_rows(%{state: :off}), do: []

  defp peer_rows(%{peers: []}) do
    Readout.right_row("seen", "nobody yet", @peers_y, Theme.dim())
  end

  defp peer_rows(%{peers: peers}) do
    Readout.right_row("seen", count(peers), @peers_y, Theme.select()) ++
      named(:lists.sublist(peers, @shown), @first_peer_y, [])
  end

  defp named([], _y, acc), do: :lists.reverse(acc)

  defp named([peer | rest], y, acc) do
    item = {:text, @row_x, y, :default16px, Theme.fg(), Theme.bg(), clip(peer)}

    named(rest, y + Readout.pitch(), [item | acc])
  end

  defp count(peers), do: :erlang.integer_to_binary(length(peers))

  defp help(%{field: field}) when field != nil do
    Nav.hint([{"Enter", "save"}, {"Esc", "cancel"}, {"empty", "resets"}], @help_y, Theme.accent())
  end

  defp help(%{status: %{state: :off}}) do
    Nav.hint([{"S", "start"}, {"Enter", "cookie"}], @help_y, Theme.dim())
  end

  defp help(_state) do
    Nav.hint([{"S", "stop"}, {"Enter", "cookie"}], @help_y, Theme.dim())
  end

  # A node name or a reason can outrun the panel; the row has to stay on it.
  defp clip(text) when byte_size(text) <= @columns, do: text
  defp clip(<<head::binary-@columns, _rest::binary>>), do: head
end
