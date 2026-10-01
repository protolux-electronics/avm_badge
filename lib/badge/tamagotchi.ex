defmodule Badge.Tamagotchi do
  @moduledoc """
  A five-minute pet, as plain data. `advance/2` takes elapsed seconds.

  Feed, play and train refill their meters. Any unattended meter is fatal
  after 60 seconds. Poop appears every 30 seconds and must be cleaned within
  60 seconds. Surviving 300 seconds wins. No process or storage is used.
  """

  def new do
    %{
      age: 0,
      needs: %{hunger: 0, happiness: 0, training: 0},
      poop: 0,
      dirty: 0,
      stage: :egg,
      status: :alive,
      reason: nil,
      animation: :idle,
      animation_left: 0
    }
  end

  def meters(state) do
    %{
      hunger: meter(state.needs.hunger),
      happiness: meter(state.needs.happiness),
      training: meter(state.needs.training)
    }
  end

  defp meter(neglect), do: max(100 - div(neglect * 100, 60), 0)

  def care(%{status: :alive} = state, :feed), do: refill(state, :hunger, :feed)
  def care(%{status: :alive} = state, :play), do: refill(state, :happiness, :play)
  def care(%{status: :alive} = state, :train), do: refill(state, :training, :train)

  def care(%{status: :alive} = state, :clean),
    do: animate(%{state | poop: 0, dirty: 0}, :clean)

  def care(state, _action), do: state

  defp refill(state, need, animation) do
    animate(%{state | needs: Map.put(state.needs, need, 0)}, animation)
  end

  defp animate(state, animation), do: %{state | animation: animation, animation_left: 2}

  def advance(state, seconds) when seconds <= 0, do: state
  def advance(%{status: :dead} = state, _seconds), do: state
  def advance(%{status: :won} = state, _seconds), do: state

  def advance(state, seconds), do: advance(second(state), seconds - 1)

  defp second(%{status: :dying, animation_left: 1} = state),
    do: %{state | status: :dead, animation: :dead, animation_left: 0}

  defp second(%{status: :dying} = state),
    do: %{state | animation_left: state.animation_left - 1}

  defp second(state) do
    age = state.age + 1
    stage = stage(age)

    needs = %{
      hunger: state.needs.hunger + 1,
      happiness: state.needs.happiness + 1,
      training: state.needs.training + 1
    }

    dirty = if state.poop > 0, do: state.dirty + 1, else: 0
    poop = if rem(age, 30) == 0, do: min(state.poop + 1, 3), else: state.poop
    left = max(state.animation_left - 1, 0)
    animation = if left == 0, do: :idle, else: state.animation

    next = %{
      state
      | age: age,
        stage: stage,
        needs: needs,
        poop: poop,
        dirty: dirty,
        animation: animation,
        animation_left: left
    }

    reason = reason(next)

    cond do
      reason != nil ->
        %{next | status: :dying, reason: reason, animation: :dying, animation_left: 3}

      age >= 300 ->
        %{next | status: :won, animation: :won, animation_left: 0}

      stage != state.stage ->
        animate(next, :grow)

      true ->
        next
    end
  end

  defp reason(%{needs: %{hunger: n}}) when n >= 60, do: :starved
  defp reason(%{needs: %{happiness: n}}) when n >= 60, do: :lonely
  defp reason(%{needs: %{training: n}}) when n >= 60, do: :untrained
  defp reason(%{dirty: n}) when n >= 60, do: :unclean
  defp reason(_state), do: nil

  defp stage(age) when age < 5, do: :egg
  defp stage(age) when age < 90, do: :baby
  defp stage(age) when age < 180, do: :child
  defp stage(_age), do: :adult
end
