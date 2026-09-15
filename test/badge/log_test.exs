defmodule Badge.LogTest do
  use ExUnit.Case, async: false

  alias Badge.Log

  setup do
    log = start_supervised!({Log, :ok})

    %{log: log}
  end

  describe "keeping lines" do
    test "a formatted print is one line, oldest first", %{log: log} do
      :io.format(log, ~c"hello ~p~n", [1])
      :io.format(log, ~c"world~n", [])

      assert Log.tail(10) == ["hello 1", "world"]
    end

    test "plain chars are split on newlines, blanks dropped", %{log: log} do
      :io.put_chars(log, "one\ntwo\n\nthree")

      assert Log.tail(10) == ["one", "two", "three"]
    end

    test "tail gives only the newest", %{log: log} do
      :io.put_chars(log, "a\nb\nc\n")

      assert Log.tail(2) == ["b", "c"]
    end

    test "the ring is bounded", %{log: log} do
      for n <- 1..60, do: :io.format(log, ~c"line ~p~n", [n])

      lines = Log.tail(100)

      assert length(lines) == 40
      assert :lists.last(lines) == "line 60"
    end

    test "a long line is clipped rather than kept whole", %{log: log} do
      :io.put_chars(log, :binary.copy("x", 200))

      assert [line] = Log.tail(1)
      assert byte_size(line) == 80
    end
  end

  describe "answering every request" do
    test "reads are answered with eof rather than blocking", %{log: log} do
      assert :io.get_line(log, "") == :eof
    end

    test "an unknown request is refused, not left hanging", %{log: log} do
      ref = make_ref()
      send(log, {:io_request, self(), ref, :bogus})

      assert_receive {:io_reply, ^ref, {:error, :request}}
    end
  end

  describe "forwarding" do
    test "nothing is sent until an agent is named", %{log: log} do
      print_from_elsewhere(log, "quiet\n")

      refute_receive {:push_extension, _event, _line}
    end

    test "lines go to the agent as hub log lines", %{log: log} do
      Log.forward(self())
      print_from_elsewhere(log, "loud\n")

      assert_receive {:push_extension, "logging:send", %{"message" => "loud"}}
    end

    test "the agent's own prints are not sent back to it", %{log: log} do
      Log.forward(self())
      :io.put_chars(log, "echo\n")

      refute_receive {:push_extension, _event, _line}
    end

    test "clearing the agent stops the flow", %{log: log} do
      Log.forward(self())
      print_from_elsewhere(log, "first\n")
      assert_receive {:push_extension, _event, _line}

      Log.forward(nil)
      print_from_elsewhere(log, "second\n")

      refute_receive {:push_extension, _event, _line}
    end
  end

  # From another process, since the test process is standing in for the agent.
  defp print_from_elsewhere(log, text) do
    parent = self()

    spawn(fn ->
      :io.put_chars(log, text)
      send(parent, :printed)
    end)

    assert_receive :printed
  end
end
