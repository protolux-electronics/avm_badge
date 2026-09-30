defmodule Badge.Page.AgentTest do
  use ExUnit.Case, async: true

  alias Badge.Font
  alias Badge.Page.Agent
  alias Badge.QR
  alias Badge.Theme

  defp state(qr), do: %{ref: make_ref(), pid: nil, qr: qr}

  defp encoded do
    {:ok, code} = QR.encode(Agent.source())
    state({:ok, code})
  end

  defp texts(items), do: for({:text, _x, _y, _font, _fg, _bg, body} <- items, do: body)

  test "keeps its place and name in the apps grid" do
    assert Agent.title() == "Agent"
  end

  test "points at ELIZA's source pinned to a commit, not a branch" do
    assert Agent.source() =~
             ~r|^https://github\.com/protolux-electronics/avm_badge/blob/[0-9a-f]{7,40}/lib/badge/eliza\.ex$|
  end

  test "the address fits a QR code" do
    assert {:ok, _code} = QR.encode(Agent.source())
  end

  test "draws the code once it is encoded, and says where she went" do
    items = Agent.render(encoded())

    assert Enum.any?(items, &(elem(&1, 0) == :scaled_cropped_image))
    assert "ELIZA moved out." in texts(items)
  end

  test "says so while the code is still encoding, or if it cannot be" do
    assert "Encoding..." in texts(Agent.render(state(:pending)))
    assert "No QR code" in texts(Agent.render(state({:error, :too_long})))
  end

  test "takes the encoded code from its own reply, and ignores others" do
    pending = state(:pending)
    {:ok, code} = QR.encode(Agent.source())

    assert {:ok, %{qr: {:ok, ^code}}} = Agent.handle_info({pending.ref, {:ok, code}}, pending)
    assert Agent.handle_info({make_ref(), {:ok, code}}, pending) == :ignore
  end

  test "every line fits between the code and the right edge" do
    for {:text, x, y, font, _fg, _bg, body} <- Agent.render(encoded()) do
      assert x + Font.width(font, body) <= Theme.width() - 8, "#{inspect(body)} runs off"
      assert y + 16 <= Theme.height(), "#{inspect(body)} runs off the bottom"
    end
  end

  test "leaves no encoder running behind it" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(pid)

    assert Agent.leave(%{state(:pending) | pid: pid}) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
