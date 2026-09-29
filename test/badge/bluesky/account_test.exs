defmodule Badge.Bluesky.AccountTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky.Account

  @hot "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot"
  @list "at://did:plc:abc/app.bsky.graph.list/3kgoats"

  describe "parse_did/1" do
    test "reads resolveHandle's answer" do
      assert Account.parse_did(~s({"did":"did:plc:abc"})) == {:ok, "did:plc:abc"}
      assert Account.parse_did(~s({"error":"InvalidRequest"})) == :error
    end
  end

  describe "parse_did_document/1" do
    test "finds the PDS by its id" do
      body =
        ~s({"id":"did:plc:abc","service":[) <>
          ~s({"id":"#bsky_notif","type":"BskyNotificationService","serviceEndpoint":"https://n"},) <>
          ~s({"id":"#atproto_pds","type":"AtprotoPersonalDataServer",) <>
          ~s("serviceEndpoint":"https://morel.us-east.host.bsky.network"}]})

      assert Account.parse_did_document(body) == {:ok, "https://morel.us-east.host.bsky.network"}
    end

    test "a full id or the type alone is enough" do
      by_id = ~s({"service":[{"id":"did:web:x#atproto_pds","serviceEndpoint":"https://a"}]})

      by_type =
        ~s({"service":[{"type":"AtprotoPersonalDataServer","serviceEndpoint":"https://b"}]})

      assert Account.parse_did_document(by_id) == {:ok, "https://a"}
      assert Account.parse_did_document(by_type) == {:ok, "https://b"}
    end

    test "a document without a PDS is not one" do
      assert Account.parse_did_document(~s({"service":[]})) == :error
      assert Account.parse_did_document(~s({"id":"did:plc:abc"})) == :error
    end
  end

  describe "parse_session/2" do
    test "keeps the DID, the PDS and the access token" do
      body =
        ~s({"did":"did:plc:abc","handle":"goat.bsky.social","accessJwt":"a.b.c","refreshJwt":"r"})

      assert Account.parse_session(body, "https://pds") ==
               {:ok, %{did: "did:plc:abc", pds: "https://pds", access: "a.b.c"}}
    end

    test "anything else is not a session" do
      assert Account.parse_session(~s({"error":"AuthenticationRequired"}), "https://pds") ==
               :error
    end
  end

  describe "parse_preferences/1" do
    test "takes the saved feeds in the account's order" do
      body =
        ~s({"preferences":[{"$type":"app.bsky.actor.defs#adultContentPref","enabled":false},) <>
          ~s({"$type":"app.bsky.actor.defs#savedFeedsPrefV2","items":[) <>
          ~s({"type":"feed","value":"#{@hot}","pinned":true,"id":"1"},) <>
          ~s({"type":"timeline","value":"following","pinned":true,"id":"2"},) <>
          ~s({"type":"list","value":"#{@list}","pinned":false,"id":"3"},) <>
          ~s({"type":"somethingNew","value":"x","id":"4"}]}]})

      assert Account.parse_preferences(body) ==
               {:ok, [{:feed, @hot}, {:timeline, nil}, {:list, @list}]}
    end

    test "the older preference puts Following first, then pinned and saved, once each" do
      body =
        ~s({"preferences":[{"$type":"app.bsky.actor.defs#savedFeedsPref",) <>
          ~s("pinned":["#{@hot}"],"saved":["#{@hot}","#{@list}"]}]})

      assert Account.parse_preferences(body) ==
               {:ok, [{:timeline, nil}, {:feed, @hot}, {:list, @list}]}
    end

    test "with no saved feeds, Following alone" do
      assert Account.parse_preferences(~s({"preferences":[]})) == {:ok, [{:timeline, nil}]}
    end

    test "at most twenty are kept" do
      items =
        for n <- 1..25,
            do: ~s({"type":"feed","value":"at://d/app.bsky.feed.generator/#{n}"})

      body =
        ~s({"preferences":[{"$type":"app.bsky.actor.defs#savedFeedsPrefV2","items":[) <>
          Enum.join(items, ",") <> "]}]}"

      assert {:ok, keys} = Account.parse_preferences(body)
      assert length(keys) == 20
    end

    test "anything else is not preferences" do
      assert Account.parse_preferences(~s({"error":"ExpiredToken"})) == :error
    end
  end

  describe "parse_generators/1 and parse_list_name/1" do
    test "name each generator and list, folded to the panel font" do
      body = ~s({"feeds":[{"uri":"#{@hot}","displayName":"Discover"},{"uri":"x"}]})

      assert Account.parse_generators(body) == {:ok, [{@hot, "Discover"}]}

      assert Account.parse_list_name(~s({"list":{"name":"Café goats"}})) ==
               {:ok, Badge.Text.cp437("Café goats")}

      assert Account.parse_list_name(~s({"items":[]})) == :error
    end
  end

  describe "feed_path/1" do
    test "each kind of feed has its own method, asking for five posts" do
      assert Account.feed_path({:timeline, nil}) == "/xrpc/app.bsky.feed.getTimeline?limit=5"

      assert Account.feed_path({:feed, "at://d/g/x"}) ==
               "/xrpc/app.bsky.feed.getFeed?feed=at%3A%2F%2Fd%2Fg%2Fx&limit=5"

      assert Account.feed_path({:list, "at://d/l/x"}) ==
               "/xrpc/app.bsky.feed.getListFeed?list=at%3A%2F%2Fd%2Fl%2Fx&limit=5"

      assert Account.feed_path({:author, "goat.bsky.social"}) ==
               "/xrpc/app.bsky.feed.getAuthorFeed?actor=goat.bsky.social&limit=5&filter=posts_no_replies"
    end
  end

  test "key/1 is a feed's kind and URI" do
    assert Account.key(%{kind: :feed, uri: @hot, name: "Discover"}) == {:feed, @hot}
  end
end
