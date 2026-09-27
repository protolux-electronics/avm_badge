defmodule Badge.Page.ConnectFourTest do
  use ExUnit.Case, async: true

  alias Badge.ConnectFour.Protocol
  alias Badge.Page.ConnectFour

  defp playing(player), do: %{ConnectFour.init() | link: %{Protocol.new() | phase: :playing, player: player}, screen: :game}

  describe "handle_key/2" do
    test "Esc stays unclaimed on every screen, so the home grid is always reachable" do
      assert ConnectFour.handle_key({:nav, :home}, ConnectFour.init()) == :ignore
      assert ConnectFour.handle_key({:nav, :home}, playing(0)) == :ignore
      assert ConnectFour.handle_key({:nav, :home}, %{playing(0) | screen: :over}) == :ignore
    end

    test "a shape key is claimed while pairing, rather than switching apps" do
      assert {:ok, _state} = ConnectFour.handle_key({:nav, :square}, ConnectFour.init())
    end

    test "a shape key is claimed once the game is over, rather than switching apps" do
      state = %{playing(0) | screen: :over}

      assert {:ok, ^state} = ConnectFour.handle_key({:nav, :square}, state)
    end

    test "a shape key is claimed on the opponent's turn, rather than switching apps" do
      state = playing(1)

      assert {:ok, ^state} = ConnectFour.handle_key({:nav, :square}, state)
    end

    test "a shape key drops a disc on this player's turn" do
      state = playing(0)

      assert {:ok, next} = ConnectFour.handle_key({:nav, :square}, state)
      assert next != state
    end
  end
end
