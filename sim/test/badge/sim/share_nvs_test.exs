defmodule Badge.Sim.ShareNvsTest do
  use ExUnit.Case, async: false

  alias Badge.Page.Share, as: Page
  alias Badge.Peers
  alias Badge.Profile
  alias Badge.Sharing
  alias Badge.Sharing.Wire

  @me <<0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6>>
  @other <<0, 0, 0, 0, 0, 1>>

  setup do
    start_supervised!(Badge.Sim.Nvs)
    :ok
  end

  defp loaded do
    profile = Map.merge(Profile.blank(), %{name: "Gus", company: "Protolux"})

    Page.recycle(%{
      Page.init()
      | loaded: true,
        profile: profile,
        shared: [:name],
        saved_shared: [:name],
        id: @me,
        chip: "A1B2C3D4E5F6"
    })
  end

  defp tick(state, n), do: :lists.foldl(fn _i, acc -> Page.tick(acc) end, state, :lists.seq(1, n))

  defp press(state, event) do
    {:ok, next} = Page.handle_key(event, state)
    next
  end

  test "peers are written once the beam has been quiet for a second" do
    {:ok, heard} = Page.handle_ir(@other, Wire.encode(:name, [:name], "Pat"), loaded())
    settled = tick(heard, 5)

    assert settled.stored == settled.peers
    assert Peers.load() == settled.peers
  end

  test "leaving the page writes what has not settled yet" do
    {:ok, heard} = Page.handle_ir(@other, Wire.encode(:name, [:name], "Pat"), loaded())

    assert Page.leave(heard) == :ok
    assert Peers.load() == heard.peers
  end

  test "the share set is written once the sharing screen is left" do
    chosen =
      %{loaded() | screen: 1}
      |> press({:move, :down})
      |> press({:edit, :newline})
      |> press({:move, :right})

    written = Page.tick(chosen)

    assert written.saved_shared == [:name, :company]
    assert Sharing.load() == [:name, :company]
  end

  test "leaving from the sharing screen writes the share set too" do
    chosen = %{loaded() | screen: 1} |> press({:move, :down}) |> press({:edit, :newline})

    assert Page.leave(chosen) == :ok
    assert Sharing.load() == [:name, :company]
  end
end
