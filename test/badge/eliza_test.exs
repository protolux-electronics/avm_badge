defmodule Badge.ElizaTest do
  use ExUnit.Case, async: true

  alias Badge.Eliza

  defp converse(lines) do
    {replies, _state} =
      :lists.foldl(
        fn line, {replies, state} ->
          {reply, state} = Eliza.respond(line, state)
          {[reply | replies], state}
        end,
        {[], Eliza.new()},
        lines
      )

    :lists.reverse(replies)
  end

  defp reply(line), do: hd(converse([line]))

  describe "clauses/1" do
    test "lowercases and splits on spaces" do
      assert Eliza.clauses("I Feel FINE") == [["i", "feel", "fine"]]
    end

    test "punctuation ends a clause" do
      assert Eliza.clauses("Well, my boyfriend made me come here.") ==
               [["well"], ["my", "boyfriend", "made", "me", "come", "here"]]
    end

    test "applies the pre-substitutions, including one word to two" do
      assert Eliza.clauses("I'm sure I dont know") == [["i", "am", "sure", "i", "don't", "know"]]
    end

    test "keeps apostrophes and drops everything else" do
      assert Eliza.clauses("can't -- (really)") == [["can't", "really"]]
    end

    test "an empty or blank line has no clauses" do
      assert Eliza.clauses("") == []
      assert Eliza.clauses("  ...  ") == []
    end
  end

  describe "match/2" do
    test "a star takes any run of words, including none" do
      assert Eliza.match([:*, "i", "am", :*], ["i", "am"]) == {:ok, [[], []]}

      assert Eliza.match([:*, "i", "am", :*], ["well", "i", "am", "so", "sad"]) ==
               {:ok, [["well"], ["so", "sad"]]}
    end

    test "a synonym set takes exactly one word and captures it" do
      pattern = [:*, "i", {:any, ["want", "need"]}, :*]

      assert Eliza.match(pattern, ["i", "need", "help"]) == {:ok, [[], ["need"], ["help"]]}
      assert Eliza.match(pattern, ["i", "like", "help"]) == :nomatch
    end

    test "a literal must be present" do
      assert Eliza.match([:*, "if", :*], ["no", "way"]) == :nomatch
    end
  end

  describe "respond/2" do
    test "opens as the 1966 transcript did" do
      assert Eliza.greeting() == "How do you do. Please tell me your problem."
    end

    test "follows the famous transcript" do
      replies =
        converse([
          "Men are all alike.",
          "They're always bugging us about something or other.",
          "Well, my boyfriend made me come here.",
          "He says I'm depressed much of the time.",
          "It's true. I am unhappy.",
          "I need some help, that much seems certain."
        ])

      assert replies == [
               "In what way?",
               "Can you think of a specific example?",
               "Your boyfriend made you come here?",
               "I am sorry to hear that you are depressed.",
               "Do you think coming here will help you not to be unhappy?",
               "What would it mean to you if you got some help?"
             ]
    end

    test "reflects pronouns in what it echoes" do
      assert reply("I think you hate me") == "Why do you think I hate you?"
      assert reply("I remember my dog") == "Do you often think of your dog?"
    end

    test "the highest ranked keyword wins wherever it sits" do
      assert reply("I am sorry my computer is broken") == "Do computers worry you?"
    end

    test "the first clause with a keyword answers, and the rest is dropped" do
      assert reply("Well, I dreamed of flying. Also my cat.") == "Really, of flying?"
    end

    test "cycles through a rule's answers rather than repeating" do
      assert converse(["yes", "yes", "yes"]) ==
               ["You seem to be quite positive.", "You are sure.", "I see."]
    end

    test "passes over an answer that would echo nothing" do
      assert converse(["my car", "my car"]) == ["Your car?", "Why do you say your car?"]
    end

    test "a keyword whose patterns all fail falls through to the stock replies" do
      assert reply("no doubt") == "Are you saying no just to be negative?"
      assert reply("xyzzy") == "I'm not sure I understand you fully."
    end

    test "remembers a 'my' line and brings it back when there is nothing to say" do
      assert converse(["my boss is afraid of me", "bullies", "and so on"]) == [
               "Your boss is afraid of you?",
               "Does that have anything to do with the fact that your boss is afraid of you?",
               "I'm not sure I understand you fully."
             ]
    end

    test "goes to another rule when told to" do
      assert reply("I apologise") == "Please don't apologise."
      assert reply("my mother") == "Tell me more about your family."
      assert reply("everybody hates me") == "Really, everybody?"
    end

    test "an empty line gets a stock reply rather than a crash" do
      assert reply("") == "I'm not sure I understand you fully."
    end

    test "says goodbye and knows it did" do
      goodbye = reply("ok bye then")

      assert Eliza.farewell?(goodbye)
      refute Eliza.farewell?(reply("hello"))
    end

    test "every reply is a binary that starts with a capital" do
      for line <- ["what", "because", "why not", "always", "i can't sleep", "are you real"] do
        <<first, _rest::binary>> = reply(line)

        assert first >= ?A and first <= ?Z
      end
    end
  end
end
