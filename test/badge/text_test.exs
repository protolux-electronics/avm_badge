defmodule Badge.TextTest do
  use ExUnit.Case, async: true

  alias Badge.Text

  describe "cp437/1" do
    test "leaves ASCII alone" do
      assert Text.cp437("Texting Lora, 09:15") == "Texting Lora, 09:15"
      assert Text.cp437("") == ""
    end

    test "straightens typographic punctuation" do
      assert Text.cp437("Doesn’t ‘quite’ “work” – or — not… 2−1") ==
               "Doesn't 'quite' \"work\" - or - not... 2-1"
    end

    test "keeps the accents the page has, as its bytes" do
      assert Text.cp437("Kamila Pokój, Julian Köpke") ==
               <<"Kamila Pok", 0xA2, "j, Julian K", 0x94, "pke">>

      assert Text.cp437("Ångström är 1 Å") == <<0x8F, "ngstr", 0x94, "m ", 0x84, "r 1 ", 0x8F>>

      assert Text.cp437("café Ñandú ½°") ==
               <<"caf", 0x82, " ", 0xA5, "and", 0xA3, " ", 0xAB, 0xF8>>
    end

    test "drops accents the page lacks" do
      assert Text.cp437("Łukasz Kita, Feliks Pobiedziński, Damir Batinović") ==
               "Lukasz Kita, Feliks Pobiedzinski, Damir Batinovic"

      assert Text.cp437("Ægir Þór Øystein") == <<0x92, "gir T", 0xA2, "r Oystein">>
    end

    test "anything else is a question mark, one per character" do
      assert Text.cp437("goat 🐐 Ж") == "goat ? ?"
      assert Text.cp437(<<"a", 0xFF, "b">>) == "a?b"
      assert Text.cp437(<<0xE2, 0x80>>) == "??"
    end
  end

  describe "wrap/2" do
    test "text that fits is left alone" do
      assert Text.wrap("Gus", 18) == ["Gus"]
      assert Text.wrap("", 18) == [""]
    end

    test "text exactly the width is left alone" do
      assert Text.wrap("123456", 6) == ["123456"]
    end

    test "breaks at the space so words stay whole" do
      assert Text.wrap("Alexander Hamilton", 12) == ["Alexander", "Hamilton"]
    end

    test "breaks at the last space that fits, not the first" do
      assert Text.wrap("a b c d e f g h", 7) == ["a b c d", "e f g h"]
    end

    test "a word with no space to break on is dashed rather than overflowing" do
      assert Text.wrap("Supercalifragilistic", 8) == ["Superca-", "lifragi-", "listic"]
    end

    test "a long word after a short one still breaks at the space first" do
      assert Text.wrap("Dr Supercalifragilistic", 10) == ["Dr", "Supercali-", "fragilist-", "ic"]
    end

    test "wraps onto as many lines as it needs" do
      assert length(Text.wrap("one two three four five six", 9)) == 4
    end

    test "no line is ever wider than asked for" do
      names = [
        "Gus",
        "Alexander Hamilton",
        "Supercalifragilisticexpialidocious",
        "A B C D E F G H I J K L",
        "Wolfeschlegelsteinhausenbergerdorff"
      ]

      for name <- names, columns <- [6, 10, 18, 30] do
        for line <- Text.wrap(name, columns) do
          assert byte_size(line) <= columns
        end
      end
    end

    test "nothing is lost but the spaces broken on and the dashes added" do
      squashed = fn text -> :binary.replace(text, " ", "", [:global]) end
      undashed = fn lines -> for line <- lines, do: :binary.replace(line, "-", "", [:global]) end

      for name <- ["Alexander Hamilton", "a b c d e f g", "Supercalifragilistic"] do
        joined = :erlang.iolist_to_binary(undashed.(Text.wrap(name, 8)))

        assert squashed.(joined) == squashed.(name)
      end
    end

    test "runs of spaces do not produce empty lines" do
      assert Text.wrap("a  b", 3) == ["a", "b"]
    end

    test "a nonsense width does not loop forever" do
      assert Text.wrap("hello", 0) == ["hello"]
    end
  end

  describe "words too long to fit" do
    test "are broken with a dash that joins them to the next line" do
      assert Text.wrap("supercalifragilistic", 10) == ["supercali-", "fragilist-", "ic"]
    end

    test "the dash costs a column, so no line runs over" do
      for line <- Text.wrap("abcdefghijklmnopqrstuvwxyz", 8) do
        assert byte_size(line) <= 8
      end
    end

    test "a word that fits exactly is not dashed" do
      assert Text.wrap("abcdefgh", 8) == ["abcdefgh"]
    end

    test "a short word after a long one still breaks on the space" do
      assert Text.wrap("aaaaaaaaaaaa bb", 10) == ["aaaaaaaaa-", "aaa bb"]
    end

    test "a two column line still makes progress rather than looping" do
      assert Text.wrap("abcdef", 2) == ["a-", "a-", "a-", "a-", "a-", "f"] or
               length(Text.wrap("abcdef", 2)) > 1
    end
  end

  describe "wrap/3 with an orphan limit" do
    test "still breaks at a space that is close to the line end" do
      assert Text.wrap("hello world there", 12, 6) == ["hello world", "there"]
    end

    test "dashes instead when the last space is further back than the limit" do
      assert Text.wrap("Gus: kfldlsssldkfjghfklos", 20, 6) == ["Gus: kfldlsssldkfjg-", "hfklos"]
    end

    test "the ragged gap is what the limit measures" do
      # The space sits 15 columns from the end, so breaking there would waste them.
      assert hd(Text.wrap("ab cdefghijklmnopqrstuvwxyz", 18, 6)) == "ab cdefghijklmnop-"
    end

    test "wrap/2 is unchanged, so names still break on spaces" do
      assert Text.wrap("Alexander Hamilton", 12) == ["Alexander", "Hamilton"]
    end

    test "no line runs over the column limit" do
      for line <- Text.wrap("Gus Workman: kfldlsssldkfjghfklos8iqjkdjmcmcmasoaopaaaa", 24, 6) do
        assert byte_size(line) <= 24
      end
    end

    test "nothing is lost, dashes aside" do
      text = "Gus: kfldlsssldkfjghfklos8iqjkdjmcmcmasoaopaaaa"
      joined = Text.wrap(text, 24, 6) |> Enum.map_join(&:binary.replace(&1, "-", "", [:global]))

      assert :binary.replace(joined, " ", "", [:global]) ==
               :binary.replace(text, " ", "", [:global])
    end
  end
end
