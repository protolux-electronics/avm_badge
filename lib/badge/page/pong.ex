defmodule Badge.Page.Pong do
  @moduledoc """
  Pong against the badge whose top edge faces this one, over the IR beam.

  Hold the two badges top to top. Keys on the left of the keyboard move the
  paddle left and keys on the right move it right, for as long as they are
  held. `Badge.Pong.Match` is the game; this page feeds it the clock, the
  held keys and the beam, and draws what it says.
  """

  use Badge.Page

  alias Badge.Identity
  alias Badge.Ir
  alias Badge.Keyboard
  alias Badge.Pixels
  alias Badge.Profile
  alias Badge.Pong.Coin
  alias Badge.Pong.Match
  alias Badge.Pong.Physics
  alias Badge.Pong.Wire
  alias Badge.Text
  alias Badge.Theme

  @left [~c"Q", ~c"W", ~c"E", ~c"A", ~c"S", ~c"D", ~c"Z", ~c"X", ~c"C"]
  @right [~c"I", ~c"O", ~c"P", ~c"J", ~c"K", ~c"L", ~c"B", ~c"N", ~c"M"]

  @frame_ms 50
  @count_ms 500

  @top Theme.content_top()
  @char_w 8
  @score_y @top + 4
  @coin_y 100
  @status_y 118
  @note_y 142
  @alert_y 166

  @won_hue 120
  @lost_hue 0
  @them_hue 45
  @count_hue 200

  @impl true
  def title, do: "Pong"

  @impl true
  def icon, do: :circle

  @impl true
  def refresh(_state), do: @frame_ms

  @impl true
  def init, do: %{match: nil, seen: nil, held: [], now: 0}

  @impl true
  def awake?(%{match: %{phase: phase}}), do: :lists.member(phase, Match.playing())
  def awake?(_state), do: false

  @doc "Which way the held keys push the paddle: -1 left, 1 right, 0 both or neither."
  @spec direction([charlist]) :: -1 | 0 | 1
  def direction(held), do: pushed(held, @right) - pushed(held, @left)

  defp pushed(held, group) do
    case :lists.any(fn label -> :lists.member(label, group) end, held) do
      true -> 1
      false -> 0
    end
  end

  # Hardware is only touched here and in leave/1, never from a key handler.
  @impl true
  def tick(%{match: nil} = state) do
    now = now()
    Keyboard.watch(self())
    <<coin>> = :crypto.strong_rand_bytes(1)
    match = Match.new(Identity.chip_id(), Map.get(Profile.load(), :name, ""), coin, now)

    %{state | match: match, seen: match, now: now}
  end

  def tick(state) do
    now = now()
    {match, payload} = Match.step(state.match, now, direction(state.held))

    if payload != nil, do: Ir.send(payload)
    cheer(state.seen, match, state.now, now)

    %{state | match: match, seen: match, now: now}
  end

  @impl true
  def leave(%{match: nil}), do: :ok

  def leave(_state) do
    Ir.send(Wire.encode(:bye))
    Keyboard.unwatch()

    :ok
  end

  @impl true
  def handle_info({:held, labels}, state), do: {:ok, %{state | held: labels}}
  def handle_info(_message, _state), do: :ignore

  @impl true
  def handle_ir(_from, _payload, %{match: nil}), do: :ignore

  def handle_ir(from, payload, state) do
    case Match.hear(state.match, from, payload, state.now) do
      {:ok, match} -> {:ok, %{state | match: match}}
      :ignore -> :ignore
    end
  end

  defp now, do: :erlang.monotonic_time(:millisecond)

  defp cheer(old, new, then, now) do
    cond do
      new.me > old.me -> Pixels.flash(@won_hue)
      new.them > old.them -> Pixels.flash(@lost_hue)
      new.phase == :revealing and old.phase != :revealing -> Pixels.flash(server_hue(new))
      new.phase == :serving and count(old, then) != count(new, now) -> Pixels.flash(@count_hue)
      true -> :ok
    end
  end

  defp server_hue(%{server: :me}), do: @won_hue
  defp server_hue(_match), do: @them_hue

  defp count(%{phase: :serving, since: since}, now) do
    min(max(3 - div(now - since, @count_ms), 1), 3)
  end

  defp count(_match, _now), do: nil

  @impl true
  def render(%{match: nil}), do: [centred("Pong", @status_y, Theme.fg())]
  def render(%{match: match, now: now}), do: alert(match) ++ scene(match, now)

  defp alert(%{lost: true}), do: [centred("Link lost", @alert_y, Theme.alert())]
  defp alert(_match), do: []

  defp scene(%{phase: phase} = match, _now) when phase == :searching or phase == :pairing do
    [
      centred("Waiting for opponent", @status_y, Theme.fg()),
      centred("Hold the tops together", @note_y, Theme.dim())
    ] ++ paddle(match)
  end

  defp scene(%{phase: :flipping} = match, now) do
    coin(Coin.face(now - match.since, match.server), match)
  end

  defp scene(%{phase: :revealing} = match, _now) do
    [centred(serves(match), @coin_y + Coin.radius() + 12, Theme.fg())] ++
      coin(Coin.face(Coin.spin_ms(), match.server), match)
  end

  defp scene(%{phase: :serving} = match, now) do
    [centred(number(count(match, now)), @status_y, Theme.fg()), score(match)] ++ paddle(match)
  end

  defp scene(%{phase: :rally} = match, _now),
    do: [score(match)] ++ ball(match.ball) ++ paddle(match)

  defp scene(%{phase: :over} = match, _now) do
    {text, colour} =
      if match.me > match.them, do: {"You win", Theme.ok()}, else: {"You lose", Theme.alert()}

    [
      centred(text, @status_y, colour),
      score(match),
      centred("Esc to leave", @note_y, Theme.dim())
    ]
  end

  defp scene(%{phase: :left} = match, _now) do
    [centred("Opponent left", @status_y, Theme.warn()), score(match)]
  end

  defp scene(_match, _now), do: []

  defp serves(%{server: :me, name: ""}), do: "You serve"
  defp serves(%{server: :me, name: name}), do: Text.cp437(name) <> " serves"
  defp serves(%{peer_name: ""}), do: "They serve"
  defp serves(%{peer_name: name}), do: Text.cp437(name) <> " serves"

  defp coin({width, face}, match) do
    cx = div(Theme.width(), 2)
    colour = face_colour(face)

    letter =
      case width > 400 do
        true -> [centred(initial(face_name(face, match)), @coin_y - 8, Theme.bg(), colour)]
        false -> []
      end

    letter ++
      for {dy, half} <- Coin.rows(), div(half * width, 1024) > 0 do
        w = div(half * width, 1024)
        {:rect, cx - w, @coin_y + dy, 2 * w, 2, colour}
      end
  end

  defp face_colour(:me), do: Theme.ok()
  defp face_colour(:them), do: Theme.warn()

  defp face_name(:me, match), do: match.name
  defp face_name(:them, match), do: match.peer_name

  defp initial(""), do: "?"
  defp initial(name), do: :binary.part(Text.cp437(name), 0, 1)

  defp score(match) do
    text = number(match.me) <> " - " <> number(match.them)

    {:text, Theme.width() - 8 - @char_w * byte_size(text), @score_y, :default16px, Theme.dim(),
     Theme.bg(), text}
  end

  defp paddle(match) do
    [
      {:rect, Physics.px(match.paddle), @top + Physics.paddle_y(), Physics.paddle_w(),
       Physics.paddle_h(), Theme.accent()}
    ]
  end

  defp ball(nil), do: []

  defp ball(ball) do
    size = Physics.ball_size()
    y = Physics.px(ball.y)
    top = max(y, 0)
    bottom = min(y + size, Physics.height())

    case bottom > top do
      true -> [{:rect, Physics.px(ball.x), @top + top, size, bottom - top, Theme.fg()}]
      false -> []
    end
  end

  defp number(n), do: :erlang.integer_to_binary(n)

  defp centred(text, y, colour), do: centred(text, y, colour, Theme.bg())

  defp centred(text, y, colour, bg) do
    {:text, div(Theme.width() - @char_w * byte_size(text), 2), y, :default16px, colour, bg, text}
  end
end
