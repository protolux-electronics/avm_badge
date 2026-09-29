defmodule Badge.Bluesky.MentionTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky.Mention

  @people [
    {"lawik.bsky.social", "did:plc:lawik"},
    {"Lars.example.com", "did:plc:lars"},
    {"goatmire.bsky.social", "did:plc:goatmire"}
  ]

  describe "written/1 and facets/2" do
    test "finds handles with a dot, by byte range, without a sentence's full stop" do
      assert Mention.written("Thanks @lawik.bsky.social. And @goat and a@b.c") ==
               [{"lawik.bsky.social", 7, 25}]
    end

    test "a known handle becomes a mention facet, any case" do
      assert Mention.facets("Hi @LAWIK.bsky.social!", @people) == [
               %{
                 "index" => %{"byteStart" => 3, "byteEnd" => 21},
                 "features" => [
                   %{"$type" => "app.bsky.richtext.facet#mention", "did" => "did:plc:lawik"}
                 ]
               }
             ]
    end

    test "a handle is compared lowercased" do
      assert Mention.key("Lawik.Bsky.Social") == "lawik.bsky.social"
    end

    test "every written handle is listed once, lowercased, to be resolved" do
      assert Mention.handles("@a.b @Lawik.bsky.social @A.b and @nodot") == [
               "a.b",
               "lawik.bsky.social"
             ]
    end

    test "only a handle that resolved is linked" do
      assert Mention.facets("@a.b", @people) == []
    end
  end
end
