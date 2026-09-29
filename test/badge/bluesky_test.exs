defmodule Badge.BlueskyTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky

  # Trimmed from public.api.bsky.app's answer for bsky.app on 2026-09-28.
  @body ~s({"feed":[) <>
          ~s({"post":{"uri":"at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3m", ) <>
          ~s("author":{"did":"did:plc:z72i7hdynmk6r22z27h6tvur","handle":"bsky.app",) <>
          ~s("displayName":"Bluesky"},) <>
          ~s("record":{"$type":"app.bsky.feed.post","createdAt":"2026-09-21T18:04:06.128Z",) <>
          ~s("text":"If you're in line to vote for @bsky38.com, please stay in line! ) <>
          ~s(Polls close in just under 5 hours."},) <>
          ~s("replyCount":90,"repostCount":85,"likeCount":721,"indexedAt":"2026-09-21T18:04:06.128Z"}},) <>
          ~s({"post":{"author":{"handle":"kenjennings.bsky.social","displayName":"Ken Jennings"},) <>
          ~s("record":{"createdAt":"2026-09-18T22:34:18.503Z",) <>
          ~s("text":"I don’t usually meddle on the writing side of Jeopardy!, but tonight ) <>
          ~s(I called in a favor for our Bluesky viewers."},) <>
          ~s("replyCount":157,"repostCount":772,"likeCount":10244},) <>
          ~s("reason":{"$type":"app.bsky.feed.defs#reasonRepost",) <>
          ~s("by":{"handle":"bsky.app"},"indexedAt":"2026-09-18T23:00:00.000Z"}},) <>
          ~s({"post":{"author":{"handle":"avclub.com","displayName":"The A.V. Club"},) <>
          ~s("record":{"createdAt":"2026-09-14T19:47:12.655Z",) <>
          ~s("text":"Less than 4 hours until the #Emmys kick off!\\n\\nPin it now so you don't miss a thing!"},) <>
          ~s("replyCount":30,"repostCount":36,"likeCount":521},) <>
          ~s("reason":{"$type":"app.bsky.feed.defs#reasonRepost","by":{"handle":"bsky.app"}}}) <>
          ~s(],"cursor":"2026-09-14T19:47:12.655Z"})

  @columns 38

  defp posts do
    {:ok, posts} = Bluesky.parse(@body, @columns)
    posts
  end

  describe "the server" do
    test "is the public AppView unless provisioned" do
      assert Bluesky.base_url(nil) == "https://public.api.bsky.app"
      assert Bluesky.base_url("") == "https://public.api.bsky.app"
      assert Bluesky.base_url("http://bench:8080") == "http://bench:8080"
    end

    test "a later page is asked for from its cursor" do
      assert Bluesky.path("goat.bsky.social", "2026-09-14T19:47:12.655Z") ==
               "/xrpc/app.bsky.feed.getAuthorFeed?actor=goat.bsky.social&limit=5&filter=posts_no_replies" <>
                 "&cursor=2026-09-14T19%3A47%3A12.655Z"
    end

    test "the path asks for a few top-level posts of the account" do
      assert Bluesky.path("goat.bsky.social") ==
               "/xrpc/app.bsky.feed.getAuthorFeed?actor=goat.bsky.social&limit=5&filter=posts_no_replies"
    end
  end

  describe "actor/1" do
    test "drops the at sign and the spaces around a handle" do
      assert Bluesky.actor("@gus.bsky.social") == "gus.bsky.social"
      assert Bluesky.actor("  gus.bsky.social ") == "gus.bsky.social"

      assert Bluesky.actor("did:plc:z72i7hdynmk6r22z27h6tvur") ==
               "did:plc:z72i7hdynmk6r22z27h6tvur"
    end

    test "an empty field names nobody" do
      assert Bluesky.actor(nil) == nil
      assert Bluesky.actor("") == nil
      assert Bluesky.actor("@") == nil
      assert Bluesky.actor("   ") == nil
    end
  end

  describe "a real answer" do
    test "yields every post, newest first" do
      assert [first, second, third] = posts()

      assert first.who == "Bluesky"
      assert first.handle == "bsky.app"
      assert second.who == "Ken Jennings"
      assert third.handle == "avclub.com"
    end

    test "wraps the text to the columns and folds it to the panel font" do
      [first, second, _third] = posts()

      assert first.lines == [
               "If you're in line to vote for",
               "@bsky38.com, please stay in line!",
               "Polls close in just under 5 hours."
             ]

      for line <- first.lines, do: assert(byte_size(line) <= @columns)
      assert hd(second.lines) == "I don't usually meddle on the writing"
    end

    test "paragraphs wrap on their own" do
      [_first, _second, third] = posts()

      assert third.lines == [
               "Less than 4 hours until the #Emmys",
               "kick off!",
               "Pin it now so you don't miss a thing!"
             ]
    end

    test "carriage returns and blank lines make no empty lines" do
      body =
        ~s({"feed":[{"post":{"author":{"handle":"a.b"},"record":{"text":"One\\r\\n\\r\\nTwo\\n"}}}]})

      assert {:ok, [post]} = Bluesky.parse(body, 38)
      assert post.lines == ["One", "Two"]
    end

    test "a repost is marked and its own post is not" do
      [first, second, third] = posts()

      refute first.repost
      assert second.repost
      assert third.repost
    end

    test "carries the counts and when it was written" do
      [first | _rest] = posts()

      assert first.likes == 721
      assert first.reposts == 85
      assert first.replies == 90
      assert first.created == 1_790_013_846
    end
  end

  describe "threads" do
    @thread ~s({"thread":{"$type":"app.bsky.feed.defs#threadViewPost",) <>
              ~s("post":{"uri":"at://a/p/1","author":{"handle":"a.b","displayName":"A"},) <>
              ~s("record":{"text":"Root"},"replyCount":2},) <>
              ~s("parent":{"post":{"uri":"at://a/p/0"}},) <>
              ~s("replies":[{"post":{"uri":"at://c/p/2","author":{"handle":"c.d"},"record":{"text":"First"}}},) <>
              ~s({"$type":"app.bsky.feed.defs#notFoundPost","uri":"at://x"},) <>
              ~s({"post":{"uri":"at://e/p/3","author":{"handle":"e.f"},"record":{"text":"Second"}}}]}})

    test "a thread is its post, then its replies" do
      assert {:ok, {[root, first, second], nil}} =
               Bluesky.parse_thread(@thread, 38, fn -> :ok end)

      assert {root.uri, root.who, root.lines, root.replies} == {"at://a/p/1", "A", ["Root"], 2}
      assert {first.uri, first.lines} == {"at://c/p/2", ["First"]}
      assert second.lines == ["Second"]
      refute root.repost
    end

    test "thread posts carry what a reply to them needs" do
      body =
        ~s({"thread":{"post":{"uri":"at://a/p/2","cid":"c2","author":{"handle":"a.b"},) <>
          ~s("record":{"text":"Mid","reply":{"root":{"uri":"at://a/p/1","cid":"c1"},) <>
          ~s("parent":{"uri":"at://a/p/1","cid":"c1"}}}},"replies":[]}})

      assert {:ok, {[post], nil}} = Bluesky.parse_thread(body, 38, fn -> :ok end)
      assert {post.cid, post.root} == {"c2", {"at://a/p/1", "c1"}}

      assert Bluesky.reply_to(post) == %{
               root: {"at://a/p/1", "c1"},
               parent: {"at://a/p/2", "c2"}
             }
    end

    test "a reply to a thread's first post has it as root and parent" do
      post = %{uri: "at://a/p/1", cid: "c1", root: nil}

      assert Bluesky.reply_to(post) == %{root: {"at://a/p/1", "c1"}, parent: {"at://a/p/1", "c1"}}
      assert Bluesky.reply_to(%{uri: "at://a/p/1", cid: nil}) == nil
    end

    test "at most twenty replies are kept" do
      reply = ~s({"post":{"author":{"handle":"r.s"},"record":{"text":"r"}}})

      body =
        ~s({"thread":{"post":{"author":{"handle":"a.b"},"record":{"text":"Root"}},"replies":[) <>
          Enum.join(List.duplicate(reply, 30), ",") <> "]}}"

      assert {:ok, {posts, nil}} = Bluesky.parse_thread(body, 38, fn -> :ok end)
      assert length(posts) == 21
    end

    test "anything else is not a thread" do
      assert Bluesky.parse_thread(~s({"error":"NotFound"}), 38, fn -> :ok end) == :error
    end

    test "the path asks for direct replies only" do
      assert Bluesky.thread_path("at://a/p/1") ==
               "/xrpc/app.bsky.feed.getPostThread?uri=at%3A%2F%2Fa%2Fp%2F1&depth=1&parentHeight=0"
    end

    test "feed posts carry their URI, nil when the answer has none" do
      assert [first, second, _third] = posts()
      assert first.uri == "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3m"
      assert second.uri == nil
    end

    test "an oversized answer reads as such" do
      assert Bluesky.describe(:too_large) == "answer too large for the badge"
    end
  end

  describe "parse_page/3" do
    test "carries the next page's cursor" do
      assert {:ok, {posts, "2026-09-14T19:47:12.655Z"}} =
               Bluesky.parse_page(@body, @columns, fn -> :ok end)

      assert length(posts) == 3
    end

    test "what a post is not drawn from is not decoded" do
      body =
        ~s({"feed":[{"post":{"author":{"handle":"a.b","avatar":"https://x"},) <>
          ~s("record":{"text":"Hi"},"embed":{"images":[]}},) <>
          ~s("reply":{"parent":{"author":{"handle":"c.d"}}}}]})

      assert {:ok, {[post], nil}} = Bluesky.parse_page(body, 38, fn -> :ok end)
      assert post.handle == "a.b"
      assert post.lines == ["Hi"]
    end

    test "no cursor, or no posts, is the end" do
      body = ~s({"feed":[{"post":{"author":{"handle":"a.b"},"record":{"text":"Hi"}}}]})

      assert {:ok, {[_post], nil}} = Bluesky.parse_page(body, 38, fn -> :ok end)

      assert {:ok, {[], nil}} =
               Bluesky.parse_page(~s({"feed":[],"cursor":"x"}), 38, fn -> :ok end)
    end
  end

  describe "an answer we cannot use" do
    test "no feed is not a feed" do
      assert Bluesky.parse(~s({"error":"InvalidRequest","message":"Profile not found"}), 38) ==
               :error

      assert Bluesky.parse(~s({"feed":"nope"}), 38) == :error
    end

    test "malformed json is not a feed" do
      assert Bluesky.parse("{not json", 38) == :error
      assert Bluesky.parse("", 38) == :error
    end

    test "an item without text is left out, and counts default to zero" do
      body =
        ~s({"feed":[{"post":{"author":{"handle":"a.b"},"record":{"createdAt":"bad"}}},) <>
          ~s({"post":{"author":{"handle":"a.b"},"record":{"text":"Hi","createdAt":"bad"}}}]})

      assert {:ok, [post]} = Bluesky.parse(body, 38)
      assert post.who == "a.b"
      assert post.created == nil
      assert post.lines == ["Hi"]
      assert {post.likes, post.reposts, post.replies} == {0, 0, 0}
    end

    test "a long post is cut short with an ellipsis" do
      text = :erlang.iolist_to_binary(:lists.duplicate(20, "word word word word "))
      body = ~s({"feed":[{"post":{"author":{"handle":"a.b"},"record":{"text":"#{text}"}}}]})

      assert {:ok, [post]} = Bluesky.parse(body, 10)
      assert length(post.lines) == 8
      assert :lists.last(post.lines) == "..."
    end
  end

  describe "age/2" do
    test "is empty without a clock or a time" do
      assert Bluesky.age(nil, 100) == ""
      assert Bluesky.age(100, nil) == ""
    end

    test "rounds down to the largest whole unit" do
      now = 1_789_754_646

      assert Bluesky.age(now - 5, now) == "now"
      assert Bluesky.age(now - 59, now) == "now"
      assert Bluesky.age(now - 60, now) == "1m"
      assert Bluesky.age(now - 3_599, now) == "59m"
      assert Bluesky.age(now - 3_600, now) == "1h"
      assert Bluesky.age(now - 5 * 86_400 - 1, now) == "5d"
    end
  end

  describe "counts/1" do
    test "reads as one line" do
      assert Bluesky.counts(hd(posts())) == "721 likes  85 reposts  90 replies"
    end

    test "one of anything is singular" do
      post = %{likes: 1, reposts: 0, replies: 1}

      assert Bluesky.counts(post) == "1 like  0 reposts  1 reply"
    end
  end

  describe "pack/1 and unpack/2" do
    test "hold each post as a binary and give it back by index" do
      packed = Bluesky.pack(posts())

      assert tuple_size(packed) == 3
      for entry <- :erlang.tuple_to_list(packed), do: assert(is_binary(entry))
      assert Bluesky.unpack(packed, 1) == :lists.nth(2, posts())
    end

    test "no posts is an empty tuple" do
      assert Bluesky.pack([]) == {}
    end
  end
end
