defmodule Badge.Page.AgentTest do
  use ExUnit.Case, async: true

  alias Badge.Eliza
  alias Badge.Page.Agent
  alias Badge.Theme

  defp type(state, string) do
    :lists.foldl(
      fn char, acc ->
        {:ok, next} = Agent.handle_key({:char, char}, acc)
        next
      end,
      state,
      :erlang.binary_to_list(string)
    )
  end

  defp say(state, string) do
    {:ok, next} = Agent.handle_key({:edit, :newline}, type(state, string))
    next
  end

  defp texts(items) do
    for {:text, _x, _y, _font, _fg, _bg, body} <- items, do: body
  end

  defp draft(items) do
    [line] = for {:text, _x, 214, _font, _fg, _bg, body} <- items, do: body
    line
  end

  describe "identity" do
    test "announces itself for the apps grid" do
      assert Agent.title() == "Agent"
    end
  end

  describe "init/0" do
    test "opens with the greeting and an empty draft" do
      items = Agent.render(Agent.init())

      assert hd(texts(items)) == "How do you do. Please tell me your"
      assert draft(items) == "> _"
    end
  end

  describe "typing" do
    test "characters land in the draft with the caret after them" do
      assert draft(Agent.render(type(Agent.init(), "hi"))) == "> hi_"
    end

    test "backspace removes the last character" do
      {:ok, state} = Agent.handle_key({:edit, :backspace}, type(Agent.init(), "hi"))

      assert draft(Agent.render(state)) == "> h_"
    end

    test "left and right move the caret inside the draft" do
      {:ok, state} = Agent.handle_key({:move, :left}, type(Agent.init(), "hi"))

      assert draft(Agent.render(state)) == "> h_i"

      {:ok, state} = Agent.handle_key({:move, :right}, state)

      assert draft(Agent.render(state)) == "> hi_"
    end

    test "a long draft scrolls under the caret rather than off the panel" do
      long = :erlang.list_to_binary(:lists.duplicate(60, ?a))
      line = draft(Agent.render(type(Agent.init(), long)))

      assert byte_size(line) == 38
      assert :binary.last(line) == ?_
    end

    test "enter on an empty draft is left for the router" do
      assert Agent.handle_key({:edit, :newline}, Agent.init()) == :ignore
    end
  end

  describe "conversation" do
    test "enter posts the line, appends the reply and clears the draft" do
      state = say(Agent.init(), "Men are all alike")

      assert [{:eliza, "In what way?"}, {:you, "> Men are all alike"} | _rest] =
               Agent.lines(state)

      assert draft(Agent.render(state)) == "> _"
    end

    test "the reply comes from Eliza's own state, so answers cycle" do
      state = Agent.init() |> say("yes") |> say("yes")

      assert [{:eliza, "You are sure."} | _rest] = Agent.lines(state)
    end

    test "long lines wrap to the panel width" do
      state = say(Agent.init(), "I am unhappy because nothing I do ever seems to work out well")

      for {_who, line} <- Agent.lines(state) do
        assert byte_size(line) <= 38
      end
    end

    test "a goodbye starts a fresh conversation" do
      state = Agent.init() |> say("yes") |> say("bye") |> say("yes")

      assert [{:eliza, "You seem to be quite positive."} | _rest] = Agent.lines(state)
      assert Eliza.farewell?(elem(:lists.nth(3, Agent.lines(state)), 1))
    end

    test "keeps only the newest lines" do
      state = :lists.foldl(fn _n, acc -> say(acc, "yes") end, Agent.init(), :lists.seq(1, 50))

      assert length(Agent.lines(state)) <= 64
    end
  end

  describe "scrolling" do
    setup do
      {:ok,
       state: :lists.foldl(fn _n, acc -> say(acc, "yes") end, Agent.init(), :lists.seq(1, 6))}
    end

    test "up shows older lines and hides the caret", %{state: state} do
      {:ok, scrolled} = Agent.handle_key({:move, :up}, state)

      assert hd(texts(Agent.render(scrolled))) != hd(texts(Agent.render(state)))
      assert draft(Agent.render(scrolled)) == "> "
    end

    test "down comes back, and at the newest line is left for the router", %{state: state} do
      {:ok, scrolled} = Agent.handle_key({:move, :up}, state)
      {:ok, back} = Agent.handle_key({:move, :down}, scrolled)

      assert Agent.render(back) == Agent.render(state)
      assert Agent.handle_key({:move, :down}, back) == :ignore
    end

    test "up stops at the oldest line", %{state: state} do
      last =
        :lists.foldl(
          fn _n, acc ->
            case Agent.handle_key({:move, :up}, acc) do
              {:ok, next} -> next
              :ignore -> acc
            end
          end,
          state,
          :lists.seq(1, 40)
        )

      assert Agent.handle_key({:move, :up}, last) == :ignore
      assert hd(texts(Agent.render(last))) == "How do you do. Please tell me your"
    end

    test "typing brings the newest line back", %{state: state} do
      {:ok, scrolled} = Agent.handle_key({:move, :up}, state)
      typed = type(scrolled, "a")

      assert draft(Agent.render(typed)) == "> a_"
    end

    test "with nothing to scroll to, up is left for the router" do
      assert Agent.handle_key({:move, :up}, Agent.init()) == :ignore
    end
  end

  describe "render/1" do
    test "every item sits inside the content area" do
      state = :lists.foldl(fn _n, acc -> say(acc, "yes") end, Agent.init(), :lists.seq(1, 6))

      for item <- Agent.render(state) do
        y =
          case item do
            {:rect, _x, y, _w, _h, _c} -> y
            {:text, _x, y, _f, _fg, _bg, _b} -> y
          end

        assert y >= Theme.content_top()
        assert y < Theme.height()
      end
    end

    test "shows at most eight transcript rows" do
      state = :lists.foldl(fn _n, acc -> say(acc, "yes") end, Agent.init(), :lists.seq(1, 6))
      rows = for {:text, _x, y, _f, _fg, _bg, _b} <- Agent.render(state), y < 206, do: y

      assert length(rows) == 8
    end

    test "does not trap escape" do
      assert Agent.handle_key({:nav, :home}, Agent.init()) == :ignore
    end
  end
end
