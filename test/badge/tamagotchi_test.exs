defmodule Badge.TamagotchiTest do
  use ExUnit.Case, async: true

  alias Badge.Tamagotchi, as: Pet

  defp attend(pet, actions) do
    Enum.reduce(actions, pet, fn action, state -> Pet.care(state, action) end)
  end

  defp survive(pet, seconds, actions) do
    Enum.reduce(1..seconds, pet, fn _, state ->
      state = Pet.advance(state, 1)
      if rem(state.age, 20) == 0, do: attend(state, actions), else: state
    end)
  end

  test "a new egg starts with three full meters and a clean home" do
    pet = Pet.new()
    assert pet.stage == :egg
    assert pet.age == 0
    assert pet.status == :alive
    assert pet.poop == 0
    assert Pet.meters(pet) == %{hunger: 100, happiness: 100, training: 100}
  end

  test "each unattended need is fatal at exactly one minute" do
    for {ignored, reason} <- [feed: :starved, play: :lonely, train: :untrained] do
      actions = [:feed, :play, :train, :clean] -- [ignored]
      pet = survive(Pet.new(), 59, actions)
      assert pet.status == :alive
      dying = Pet.advance(pet, 1)
      assert dying.status == :dying
      assert dying.reason == reason
      assert dying.age == 60
      assert Pet.advance(dying, 2).status == :dying
      dead = Pet.advance(dying, 3)
      assert dead.status == :dead
      assert Pet.advance(dead, 1000) == dead
      assert attend(dead, [:feed, :play, :train, :clean]) == dead
      assert attend(dying, [:feed, :play, :train, :clean]) == dying
    end
  end

  test "care refills only the selected meter and restarts its neglect clock" do
    pet = Pet.advance(Pet.new(), 40)
    assert Pet.meters(pet) == %{hunger: 34, happiness: 34, training: 34}
    fed = Pet.care(pet, :feed)
    assert fed.animation == :feed
    assert Pet.meters(fed) == %{hunger: 100, happiness: 34, training: 34}
    assert Pet.care(pet, :play).needs.happiness == 0
    assert Pet.care(pet, :train).needs.training == 0
    assert Pet.care(pet, :unknown) == pet
  end

  test "poop appears periodically, accumulates, and old poop kills despite full meters" do
    pet = survive(Pet.new(), 29, [:feed, :play, :train])
    assert pet.poop == 0
    assert Pet.advance(pet, 1).poop == 1
    pet = survive(Pet.new(), 89, [:feed, :play, :train])
    assert pet.poop == 2
    assert pet.dirty == 59
    assert pet.status == :alive
    pet = Pet.advance(pet, 1)
    assert pet.poop == 3
    assert pet.status == :dying
    assert pet.reason == :unclean
  end

  test "cleaning removes every pile and resets the sanitation deadline" do
    pet = survive(Pet.new(), 70, [:feed, :play, :train])
    clean = Pet.care(pet, :clean)
    assert clean.poop == 0
    assert clean.dirty == 0
    assert clean.animation == :clean
    pet = survive(clean, 20, [:feed, :play, :train])
    assert pet.status == :alive
    assert pet.poop == 1
    assert pet.dirty == 0
  end

  test "care grows the egg through baby, child and adult, winning at five minutes" do
    actions = [:feed, :play, :train, :clean]
    assert Pet.advance(Pet.new(), 4).stage == :egg
    baby = Pet.advance(Pet.new(), 5)
    assert baby.stage == :baby
    assert baby.animation == :grow
    child = survive(Pet.new(), 90, actions)
    assert child.stage == :child
    assert child.animation == :grow
    adult = survive(Pet.new(), 180, actions)
    assert adult.stage == :adult
    pet = survive(Pet.new(), 299, actions)
    assert pet.status == :alive
    won = Pet.advance(pet, 1)
    assert won.status == :won
    assert won.age == 300
    assert won.animation == :won
    assert Pet.advance(won, 3600) == won
    assert attend(won, actions) == won
  end

  test "a fatal unmet need wins over the finish line" do
    pet = survive(Pet.new(), 280, [:feed, :play, :train, :clean])
    pet = %{pet | needs: %{pet.needs | hunger: 40}}
    assert Pet.advance(pet, 20).status == :dying
    assert Pet.advance(pet, 20).reason == :starved
  end

  test "elapsed time can be batched without changing the rules" do
    initial = Pet.new()
    assert Pet.advance(initial, 0) == initial
    assert Pet.advance(initial, -1) == initial

    assert Pet.advance(initial, 59) ==
             Enum.reduce(1..59, initial, fn _, pet -> Pet.advance(pet, 1) end)

    assert Pet.advance(initial, 100_000).status == :dead
  end
end
