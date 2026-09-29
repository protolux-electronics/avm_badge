defmodule Badge.Bluesky.DraftTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky.Draft

  defp typed(text),
    do: :lists.foldl(&Draft.insert(&2, &1), Draft.new(), :erlang.binary_to_list(text))

  test "holds what was typed, line breaks and all" do
    draft = typed("Hi #goatmire\nsee you")

    assert Draft.text(draft) == "Hi #goatmire\nsee you"
    assert Draft.count(draft) == 20
  end

  test "backspace takes the last character, and nothing when empty" do
    assert Draft.text(Draft.backspace(typed("ab"))) == "a"
    assert Draft.backspace(Draft.new()) == Draft.new()
  end

  test "stops at the post limit" do
    full = typed(:binary.copy("x", 300))

    assert Draft.count(Draft.insert(full, ?y)) == 300
    assert Draft.limit() == 300
  end

  test "spaces and line breaks alone are blank" do
    assert Draft.blank?(Draft.new())
    assert Draft.blank?(typed(" \n "))
    refute Draft.blank?(typed(" a"))
  end

  describe "rows/2" do
    test "wraps for display only and puts the cursor at the end" do
      draft = typed("abcdefg\nhi")

      assert Draft.rows(draft, 4) == {["abcd", "efg", "hi"], {2, 2}}
      assert Draft.text(draft) == "abcdefg\nhi"
    end

    test "a full last row puts the cursor on the next" do
      assert Draft.rows(typed("abcd"), 4) == {["abcd"], {0, 1}}
    end

    test "an empty draft is one empty row" do
      assert Draft.rows(Draft.new(), 4) == {[""], {0, 0}}
    end

    test "a line break at the end opens an empty row" do
      assert Draft.rows(typed("ab\n"), 4) == {["ab", ""], {0, 1}}
    end
  end
end
