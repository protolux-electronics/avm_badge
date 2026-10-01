defmodule Badge.Page.Tamagotchi do
  @moduledoc """
  A fresh five-minute pet on every visit, ticking only while this page shows.

  Square feeds, triangle plays, cross trains and circle cleans. F/P/T/C work
  too. Enter restarts a finished game; Esc leaves without saving anything.
  The Hunger meter shows fullness: all three meters should stay high.
  """

  use Badge.Page

  alias Badge.Tamagotchi
  alias Badge.Tamagotchi.Art
  alias Badge.Theme

  @impl true
  def title, do: "Tamagotchi"

  @impl true
  def icon, do: :cross

  @impl true
  def refresh(_state), do: 200

  @impl true
  def init, do: %{pet: Tamagotchi.new(), at: nil, fraction: 0, phase: 0}

  @impl true
  def tick(%{pet: %{status: :dead}} = state), do: state
  def tick(%{at: nil} = state), do: %{state | at: now()}

  def tick(state) do
    at = now()
    next = step(state, max(at - state.at, 0))
    %{next | at: at}
  end

  @doc "Advances by elapsed milliseconds, without reading a clock."
  def step(state, milliseconds) do
    total = state.fraction + max(milliseconds, 0)
    pet = Tamagotchi.advance(state.pet, div(total, 1000))
    fraction = rem(total, 1000)
    %{state | pet: pet, fraction: fraction, phase: div(fraction, 250)}
  end

  @impl true
  def handle_key({:nav, :square}, state), do: care(state, :feed)
  def handle_key({:nav, :triangle}, state), do: care(state, :play)
  def handle_key({:nav, :cross}, state), do: care(state, :train)
  def handle_key({:nav, :circle}, state), do: care(state, :clean)
  def handle_key({:char, key}, state) when key == ?f or key == ?F, do: care(state, :feed)
  def handle_key({:char, key}, state) when key == ?p or key == ?P, do: care(state, :play)
  def handle_key({:char, key}, state) when key == ?t or key == ?T, do: care(state, :train)
  def handle_key({:char, key}, state) when key == ?c or key == ?C, do: care(state, :clean)

  def handle_key({:edit, :newline}, %{pet: %{status: status}})
      when status == :dead or status == :won, do: {:ok, init()}

  def handle_key(_event, _state), do: :ignore

  defp care(state, action), do: {:ok, %{state | pet: Tamagotchi.care(state.pet, action)}}

  @impl true
  def render(%{pet: pet, phase: phase}) do
    meters = Tamagotchi.meters(pet)

    meter("Happiness", meters.happiness, 30) ++
      meter("Hunger", meters.hunger, 50) ++
      meter("Training", meters.training, 70) ++
      [
        text(8, 92, stage(pet.stage)),
        text(168, 92, time(pet.age) <> " / 5:00"),
        centred(message(pet), 184)
      ] ++
      controls(pet) ++ Art.frame(pet, phase)
  end

  defp meter(label, value, y) do
    colour =
      cond do
        value <= 25 -> Theme.alert()
        value <= 50 -> Theme.warn()
        true -> Theme.fg()
      end

    fill = if value > 0, do: [{:rect, 106, y + 3, div(value * 140, 100), 10, colour}], else: []

    [text(8, y, label), text(264, y, Integer.to_string(value) <> "%")] ++
      fill ++
      [{:rect, 104, y + 1, 144, 14, Theme.dim()}]
  end

  defp controls(%{status: status}) when status == :dead or status == :won,
    do: [centred("Enter: new pet", 204), centred("Esc: Games (no save)", 224)]

  defp controls(_pet),
    do: [
      text(8, 204, "Sq/F Feed"),
      text(168, 204, "Tr/P Play"),
      text(8, 224, "Cr/T Train"),
      text(168, 224, "Ci/C Clean")
    ]

  defp message(%{status: :alive, stage: :egg}), do: "60s neglect = death"
  defp message(%{status: :won}), do: "Grown up! You win!"
  defp message(%{status: :dying}), do: "Oh no..."
  defp message(%{status: :dead, reason: :starved}), do: "RIP - starvation"
  defp message(%{status: :dead, reason: :lonely}), do: "RIP - loneliness"
  defp message(%{status: :dead, reason: :untrained}), do: "RIP - poor discipline"
  defp message(%{status: :dead, reason: :unclean}), do: "RIP - dirty home"

  defp message(pet) do
    case Art.pose(pet) do
      :feed -> "Nom nom!"
      :play -> "Let's play!"
      :train -> "One, two!"
      :clean -> "Sweep sweep!"
      :grow -> "Growing!"
      :hungry -> "Feed me!"
      :sad -> "Play with me!"
      :dirty -> "Clean my home!"
      _pose -> if pet.needs.training >= 45, do: "Train me!", else: "Keep all meters high!"
    end
  end

  defp stage(:egg), do: "Egg"
  defp stage(:baby), do: "Baby"
  defp stage(:child), do: "Child"
  defp stage(:adult), do: "Adult"

  defp time(age) do
    seconds = rem(age, 60)
    zero = if seconds < 10, do: "0", else: ""
    Integer.to_string(div(age, 60)) <> ":" <> zero <> Integer.to_string(seconds)
  end

  defp centred(body, y), do: text(div(Theme.width() - byte_size(body) * 8, 2), y, body)
  defp text(x, y, body), do: {:text, x, y, :default16px, Theme.fg(), Theme.bg(), body}
  defp now, do: :erlang.monotonic_time(:millisecond)
end
