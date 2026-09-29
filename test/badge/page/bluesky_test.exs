defmodule Badge.Page.BlueskyTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky
  alias Badge.Bluesky.Draft
  alias Badge.Page.Bluesky, as: Page
  alias Badge.Theme

  @actor "goat.bsky.social"
  @now 1_789_800_000

  @head_y 26
  @rule_y 44
  @top 50
  @pitch 18
  @notice_y @top + 2 * @pitch

  @hot "at://did:plc:sim/app.bsky.feed.generator/whats-hot"
  @list "at://did:plc:sim/app.bsky.graph.list/goats"

  defp post(overrides) do
    Map.merge(
      %{
        who: "Goatmire",
        handle: "goatmire.bsky.social",
        repost: false,
        created: @now - 2 * 3_600,
        lines: ["Badges are flashed.", "See you in Varberg!"],
        likes: 42,
        reposts: 7,
        replies: 3
      },
      overrides
    )
  end

  defp status(overrides \\ %{}) do
    Map.merge(%{state: :ready, actor: @actor, reason: nil, version: 1, count: 0}, overrides)
  end

  defp named(bluesky \\ "@" <> @actor) do
    Page.apply_profile(%{name: "Goat", bluesky: bluesky}, Page.init())
  end

  defp shown(posts, overrides \\ %{}) do
    status = status(Map.merge(%{count: length(posts)}, overrides))

    Page.apply_posts(Bluesky.pack(posts), 1, Page.apply_status(status, named(), @now))
  end

  defp texts(items), do: for({:text, _x, _y, _font, _fg, _bg, body} <- items, do: body)

  defp row(items, y), do: for({:text, _x, ^y, _font, _fg, _bg, body} <- items, do: body)

  defp coloured(items, y), do: for({:text, _x, ^y, _font, fg, _bg, body} <- items, do: {body, fg})

  defp press(state, event) do
    {:ok, next} = Page.handle_key(event, state)
    next
  end

  describe "identity" do
    test "announces itself for the home grid" do
      assert Page.title() == "Bluesky"
      assert Page.icon() == :triangle
    end

    test "repaints slowly, since a frame is a whole panel" do
      assert Page.refresh(Page.init()) == 500
    end

    test "wraps to the width of the panel in the body font" do
      assert Page.columns() == 38
    end

    test "opens knowing nothing" do
      assert Page.init().loaded == false
      assert Page.init().actor == nil
      assert Page.current(Page.init()) == 0
    end
  end

  describe "without a handle" do
    test "says where to set one" do
      items = Page.render(named(""))

      assert texts(items) == ["No Bluesky handle", "Set it on the Name page"]
    end

    test "every key is left for the router" do
      assert Page.handle_key({:move, :down}, named("")) == :ignore
      assert Page.handle_key({:move, :left}, named("")) == :ignore
      assert Page.handle_key({:edit, :newline}, named("")) == :ignore
      assert Page.handle_key({:nav, :home}, named("")) == :ignore
    end

    test "leaving touches no link" do
      assert Page.leave(named("")) == :ok
    end
  end

  describe "before the posts arrive" do
    test "shows the tabs and says whose posts it is fetching" do
      items = Page.render(Page.apply_status(status(%{state: :loading}), named(), nil))

      assert row(items, @head_y) == ["Feeds", "Posts", "Post", ""]
      assert row(items, @notice_y) == ["Fetching @" <> @actor]
    end

    test "a link still on another account reads as fetching" do
      items = Page.render(Page.apply_status(status(%{actor: "old.bsky.social"}), named(), nil))

      assert row(items, @notice_y) == ["Fetching @" <> @actor]
    end

    test "says it is waiting for wifi" do
      items = Page.render(Page.apply_status(status(%{state: :waiting}), named(), nil))

      assert row(items, @notice_y) == ["Waiting for wifi"]
    end

    test "shows a failure with its reason and how to retry" do
      state = Page.apply_status(status(%{state: :failed, reason: {:ssl, :closed}}), named(), nil)

      assert texts(Page.render(state)) == [
               "Feeds",
               "Posts",
               "Post",
               "",
               "Feed unavailable",
               "{ssl,closed}",
               "Enter tries again"
             ]
    end

    test "an HTTP failure reads as the server's own words" do
      state =
        Page.apply_status(
          status(%{state: :failed, reason: {:http, 400, "InvalidRequest"}}),
          named(),
          nil
        )

      assert row(Page.render(state), @notice_y + @pitch) == ["400 InvalidRequest"]

      plain = Page.apply_status(status(%{state: :failed, reason: {:http, 502, ""}}), named(), nil)

      assert row(Page.render(plain), @notice_y + @pitch) == ["HTTP 502"]
    end

    test "an empty feed says so" do
      items = Page.render(Page.apply_status(status(), named(), nil))

      assert row(items, @notice_y) == ["No posts yet"]
    end

    test "the arrows have nothing to move and Esc is left for the router" do
      state = Page.apply_status(status(%{state: :loading}), named(), nil)

      assert Page.handle_key({:move, :down}, state) == :ignore
      assert Page.handle_key({:move, :up}, state) == :ignore
      assert Page.handle_key({:nav, :home}, state) == :ignore
    end

    test "the rule is drawn whatever is shown" do
      items = Page.render(Page.apply_status(status(%{state: :loading}), named(), nil))

      assert [{:rect, 8, @rule_y, 304, 1, _colour}] =
               for({:rect, _x, _y, _w, _h, _c} = rect <- items, do: rect)
    end
  end

  describe "with posts" do
    setup do
      posts = [
        post(%{}),
        post(%{
          who: "Lars Wikman",
          repost: true,
          created: @now - 3 * 86_400,
          lines: ["The schedule is up."]
        }),
        post(%{who: "Goatmire", lines: ["Tickets are nearly gone."], created: nil})
      ]

      %{state: shown(posts), posts: posts}
    end

    test "the head shows the tabs, Posts lit, and where the top post is", %{state: state} do
      items = Page.render(state)

      assert coloured(items, @head_y) == [
               {"Feeds", Theme.dim()},
               {"Posts", Theme.select()},
               {"Post", Theme.dim()},
               {"1/3", Theme.muted()}
             ]
    end

    test "a post is who wrote it and when, the text, then the counts", %{state: state} do
      items = Page.render(state)

      assert coloured(items, @top) == [{"Goatmire", Theme.accent()}, {"2h", Theme.dim()}]
      assert row(items, @top + @pitch) == ["Badges are flashed."]
      assert row(items, @top + 2 * @pitch) == ["See you in Varberg!"]

      assert coloured(items, @top + 3 * @pitch) == [
               {"42 likes  7 reposts  3 replies", Theme.dim()}
             ]
    end

    test "a blank row separates posts and a repost is marked", %{state: state} do
      items = Page.render(state)

      assert row(items, @top + 4 * @pitch) == []

      assert coloured(items, @top + 5 * @pitch) == [
               {"repost: Lars Wikman", Theme.accent()},
               {"3d", Theme.dim()}
             ]
    end

    test "the age is right-aligned", %{state: state} do
      items = Page.render(state)

      assert [{:text, x, @top, _font, _fg, _bg, "2h"}] =
               for({:text, _x, @top, _f, _c, _b, "2h"} = item <- items, do: item)

      assert x == Theme.width() - 8 - 2 * 8
    end

    test "a post without a time has no age", %{state: state} do
      items = Page.render(press(press(state, {:move, :down}), {:move, :down}))

      assert coloured(items, @top) == [{"Goatmire", Theme.accent()}, {"", Theme.dim()}]
    end

    test "nothing is drawn below the panel", %{state: state} do
      for {:text, _x, y, _font, _fg, _bg, _body} <- Page.render(state) do
        assert y + 16 <= Theme.height()
      end
    end

    test "Down moves the top post and Up brings it back", %{state: state} do
      down = press(state, {:move, :down})

      assert Page.current(down) == 1
      assert row(Page.render(down), @head_y) == ["Feeds", "Posts", "Post", "2/3"]
      assert row(Page.render(down), @top) == ["repost: Lars Wikman", "3d"]
      assert Page.current(press(down, {:move, :up})) == 0
    end

    test "the arrows stop at both ends rather than wrapping", %{state: state} do
      assert Page.handle_key({:move, :up}, state) == :ignore

      last = press(press(state, {:move, :down}), {:move, :down})

      assert Page.handle_key({:move, :down}, last) == :ignore
    end

    test "Esc is left for the router", %{state: state} do
      assert Page.handle_key({:nav, :home}, state) == :ignore
    end

    test "a fresh feed with fewer posts pulls the cursor back", %{state: state, posts: posts} do
      last = press(press(state, {:move, :down}), {:move, :down})

      assert Page.current(Page.apply_posts(Bluesky.pack([hd(posts)]), 2, last)) == 0
      assert Page.current(Page.apply_posts({}, 3, last)) == 0
    end

    test "a failed refresh keeps the posts on the panel", %{state: state} do
      failed =
        Page.apply_status(status(%{state: :failed, reason: :closed, count: 3}), state, @now)

      assert row(Page.render(failed), @top + @pitch) == ["Badges are flashed."]
    end
  end

  describe "the Feeds tab, logged out" do
    test "Left turns to it and Right back" do
      state = press(shown([post(%{})]), {:move, :left})

      assert Page.tab(Page.init()) == :posts
      assert Page.tab(state) == :feeds
      assert Page.tab(press(state, {:move, :right})) == :posts
      assert Page.handle_key({:move, :left}, state) == :ignore
    end

    test "says where to log in" do
      state = press(shown([post(%{})]), {:move, :left})

      assert texts(Page.render(state)) == [
               "Feeds",
               "Posts",
               "Post",
               "",
               "Not logged in",
               "Set an app password under",
               "Settings > Bluesky"
             ]

      assert Page.handle_key({:edit, :newline}, state) == :ignore
    end
  end

  describe "logged in" do
    setup do
      feeds = [
        %{kind: :timeline, uri: nil, name: "Following"},
        %{kind: :feed, uri: @hot, name: "Discover"},
        %{kind: :list, uri: @list, name: "Goatmire folks"}
      ]

      state = Page.apply_login("abcd-efgh", named())
      status = status(%{count: 1, account: true, feed: {:timeline, nil}})
      state = Page.apply_status(status, state, @now)

      state =
        Page.apply_posts(
          Bluesky.pack([post(%{})]),
          1,
          Page.apply_feeds(Bluesky.pack(feeds), state)
        )

      %{state: state, feeds: press(state, {:move, :left})}
    end

    test "an empty password is no password" do
      assert Page.apply_login("", named()).password == nil
      assert Page.apply_login(nil, named()).password == nil
    end

    test "the posts tab is named after the feed shown", %{state: state} do
      assert row(Page.render(state), @head_y) == ["Feeds", "Following", "Post", "1/1"]
    end

    test "Feeds lists the saved feeds, the one shown starred", %{feeds: feeds} do
      items = Page.render(feeds)

      assert coloured(items, @head_y) == [
               {"Feeds", Theme.select()},
               {"Following", Theme.dim()},
               {"Post", Theme.dim()},
               {"1/3", Theme.muted()}
             ]

      assert row(items, @top) == [">", "Following", "*"]
      assert coloured(items, @top + @pitch) == [{"Discover", Theme.fg()}]
      assert row(items, @top + 2 * @pitch) == ["Goatmire folks"]
    end

    test "Up and Down pick a feed and stop at the ends", %{feeds: feeds} do
      assert Page.handle_key({:move, :up}, feeds) == :ignore

      down = press(feeds, {:move, :down})

      assert Page.current(down) == 1

      assert coloured(Page.render(down), @top) == [
               {"Following", Theme.accent()},
               {"*", Theme.accent()}
             ]

      assert row(Page.render(down), @top + @pitch) == [">", "Discover"]

      last = press(down, {:move, :down})

      assert Page.handle_key({:move, :down}, last) == :ignore
    end

    test "Enter on the feed shown just turns back to it", %{feeds: feeds} do
      back = press(feeds, {:edit, :newline})

      assert Page.tab(back) == :posts
      assert row(Page.render(back), @top + @pitch) == ["Badges are flashed."]
    end

    test "Enter on another feed shows it and waits for its posts", %{feeds: feeds} do
      chosen = press(press(feeds, {:move, :down}), {:edit, :newline})

      assert Page.tab(chosen) == :posts
      assert Page.shown(chosen) == {:feed, @hot}
      assert row(Page.render(chosen), @head_y) == ["Feeds", "Discover", "Post", ""]
      assert row(Page.render(chosen), @notice_y) == ["Fetching Discover"]
    end

    test "the posts tab keeps its place while feeds are picked", %{state: state} do
      state = Page.apply_posts(Bluesky.pack([post(%{}), post(%{})]), 2, state)
      down = press(state, {:move, :down})
      turned = press(press(press(down, {:move, :left}), {:move, :down}), {:move, :right})

      assert Page.current(turned) == 1
      assert Page.current(press(turned, {:move, :left})) == 1
    end

    test "the loading notice names the feed", %{state: state} do
      loading = Page.apply_posts({}, 2, %{state | status: %{state.status | state: :loading}})

      assert row(Page.render(loading), @notice_y) == ["Fetching Following"]
    end

    test "no saved feeds yet reads as the fetch under way", %{state: state} do
      empty =
        press(
          Page.apply_feeds({}, %{state | status: %{state.status | state: :loading}}),
          {:move, :left}
        )

      assert row(Page.render(empty), @notice_y) == ["Fetching Following"]
      assert Page.handle_key({:edit, :newline}, empty) == :ignore
    end

    test "fewer feeds pull the pick back", %{feeds: feeds} do
      last = press(press(feeds, {:move, :down}), {:move, :down})

      assert Page.current(Page.apply_feeds({}, last)) == 0
    end

    test "a long list scrolls with the pick, none below the panel" do
      many =
        for n <- 1..14,
            do: %{
              kind: :feed,
              uri: "u" <> :erlang.integer_to_binary(n),
              name: "F" <> :erlang.integer_to_binary(n)
            }

      state = Page.apply_feeds(Bluesky.pack(many), Page.apply_login("pw", shown([post(%{})])))

      state =
        :lists.foldl(
          fn _n, acc -> press(acc, {:move, :down}) end,
          press(state, {:move, :left}),
          :lists.seq(1, 12)
        )

      items = Page.render(state)

      assert Page.current(state) == 12
      assert row(items, @top) == ["F4"]
      assert row(items, @top + 9 * @pitch) == [">", "F13"]

      for {:text, _x, y, _font, _fg, _bg, _body} <- items do
        assert y + 16 <= Theme.height()
      end
    end
  end

  describe "paging" do
    setup do
      state = shown([post(%{}), post(%{lines: ["Second."]})], %{more: true, append: false})

      %{state: state, last: press(state, {:move, :down})}
    end

    test "the counter says there is more", %{state: state} do
      assert row(Page.render(state), @head_y) == ["Feeds", "Posts", "Post", "1/2+"]
    end

    test "under the last post, Down is offered", %{last: last} do
      items = Page.render(last)

      assert row(items, @top + 4 * @pitch) == ["Down for more"]
    end

    test "Down on the last post asks for more and says so", %{last: last} do
      asking = press(last, {:move, :down})

      assert Page.current(asking) == 1
      assert row(Page.render(asking), @top + 4 * @pitch) == ["Loading more..."]
      assert Page.handle_key({:move, :down}, asking) == :ignore
    end

    test "a failed page says why", %{last: last} do
      failed = %{last | status: %{last.status | state: :failed, append: true, reason: :closed}}

      assert row(Page.render(failed), @top + 4 * @pitch) == ["Could not load more: closed"]
    end

    test "at the end there is nothing to ask for" do
      last = press(shown([post(%{}), post(%{lines: ["Second."]})]), {:move, :down})

      assert Page.handle_key({:move, :down}, last) == :ignore
      assert row(Page.render(last), @top + 4 * @pitch) == []
      assert row(Page.render(last), @head_y) == ["Feeds", "Posts", "Post", "2/2"]
    end
  end

  describe "the Post tab" do
    setup do
      state = Page.apply_login("pw", shown([post(%{})], %{post: :none}))

      %{compose: press(state, {:move, :right})}
    end

    defp typing(state, text),
      do: :lists.foldl(&press(&2, {:char, &1}), state, :erlang.binary_to_list(text))

    test "Right from the posts opens it and Left goes back", %{compose: compose} do
      assert Page.tab(compose) == :compose
      assert Page.tab(press(compose, {:move, :left})) == :posts
      assert Page.tab(press(compose, {:nav, :home})) == :posts
    end

    test "the head lights Post and counts the draft", %{compose: compose} do
      assert coloured(Page.render(typing(compose, "Hi")), @head_y) == [
               {"Feeds", Theme.dim()},
               {"Following", Theme.dim()},
               {"Post", Theme.select()},
               {"2/300", Theme.muted()}
             ]
    end

    test "an empty draft asks for a post", %{compose: compose} do
      assert row(Page.render(compose), @top) == ["Type a post"]
      assert row(Page.render(compose), 216) == ["Tab post   Enter new line"]
    end

    test "typing shows the draft, a line at a time", %{compose: compose} do
      typed = typing(press(typing(compose, "Hello"), {:edit, :newline}), "#goatmire")

      assert row(Page.render(typed), @top) == ["Hello"]
      assert row(Page.render(typed), @top + @pitch) == ["#goatmire"]
      assert Page.tab(press(press(typed, {:move, :left}), {:move, :right})) == :compose
    end

    test "Tab asks first, and any other key goes back to editing", %{compose: compose} do
      asked = press(typing(compose, "Hello"), {:edit, :tab})

      assert row(Page.render(asked), 216) == ["Tab again to post, any key edits"]
      assert press(asked, {:char, ?x}).stage == :editing
      assert Draft.text(press(asked, {:char, ?x}).draft) == "Hello"
      assert press(asked, {:nav, :home}).stage == :editing
    end

    test "a blank draft cannot be posted", %{compose: compose} do
      assert press(typing(compose, "  "), {:edit, :tab}).stage == :editing
    end

    test "Tab again sends it and waits", %{compose: compose} do
      sending = press(press(typing(compose, "Hello"), {:edit, :tab}), {:edit, :tab})

      assert sending.stage == :sending
      assert row(Page.render(sending), 216) == ["Posting..."]
      assert press(sending, {:char, ?x}) == sending
    end

    test "a landed post clears the draft; a failed one keeps it", %{compose: compose} do
      sending = press(press(typing(compose, "Hello"), {:edit, :tab}), {:edit, :tab})

      landed = Page.apply_sent(%{sending | status: %{sending.status | post: {:ok, "at://p"}}})

      assert row(Page.render(landed), 216) == ["Posted"]
      assert Draft.count(landed.draft) == 0

      failed = Page.apply_sent(%{sending | status: %{sending.status | post: {:error, :closed}}})

      assert row(Page.render(failed), 216) == ["Post failed: closed"]
      assert Draft.text(failed.draft) == "Hello"
      assert press(failed, {:char, ?!}).stage == :editing
    end

    test "logged out, it says where to log in" do
      compose = press(shown([post(%{})]), {:move, :right})

      assert row(Page.render(compose), @notice_y) == ["Not logged in"]
      assert Page.handle_key({:char, ?a}, compose) == :ignore
    end

    test "a long draft keeps its end in view" do
      compose = press(Page.apply_login("pw", shown([post(%{})], %{post: :none})), {:move, :right})

      long =
        :lists.foldl(
          fn n, acc ->
            press(typing(acc, "line" <> :erlang.integer_to_binary(n)), {:edit, :newline})
          end,
          compose,
          :lists.seq(1, 12)
        )

      items = Page.render(long)

      assert row(items, @top) == ["line5"]

      for {:text, _x, y, _font, _fg, _bg, _body} <- items, do: assert(y + 16 <= Theme.height())
    end
  end

  describe "threads" do
    setup do
      posts = [post(%{uri: "at://a/p/1"}), post(%{uri: "at://a/p/2", lines: ["Second."]})]

      %{state: press(shown(posts), {:move, :down})}
    end

    test "Enter opens the thread of the post at the top", %{state: state} do
      thread = press(state, {:edit, :newline})

      assert Page.shown(thread) == {:thread, "at://a/p/2"}
      assert thread.posts == {}
      assert row(Page.render(thread), @head_y) == ["Feeds", "Thread", "Reply", ""]
      assert row(Page.render(thread), @notice_y) == ["Fetching thread"]
    end

    test "Esc and Left go back to the feed, at the post it left from", %{state: state} do
      thread = press(state, {:edit, :newline})

      replies =
        Page.apply_posts(
          Bluesky.pack([post(%{uri: "at://r/1"}), post(%{uri: "at://r/2"})]),
          5,
          thread
        )

      assert Page.current(press(replies, {:move, :down})) == 1

      for key <- [{:nav, :home}, {:move, :left}] do
        back = press(press(replies, {:move, :down}), key)

        assert Page.tab(back) == :posts
        assert Page.current(back) == 1
        refute Page.shown(back) == {:thread, "at://a/p/2"}
      end
    end

    test "a thread opened from a thread goes back to where the feed was", %{state: state} do
      thread = press(state, {:edit, :newline})
      replies = Page.apply_posts(Bluesky.pack([post(%{uri: "at://r/1"})]), 5, thread)
      nested = press(replies, {:edit, :newline})

      assert Page.shown(nested) == {:thread, "at://r/1"}
      assert Page.current(press(nested, {:nav, :home})) == 1
    end

    test "outside a thread, Esc is the router's and Left is Feeds", %{state: state} do
      assert Page.handle_key({:nav, :home}, state) == :ignore
      assert Page.tab(press(state, {:move, :left})) == :feeds
    end

    test "writing from a thread replies to the post at the top", %{state: state} do
      thread = press(Page.apply_login("pw", state), {:edit, :newline})

      replies =
        Page.apply_posts(
          Bluesky.pack([
            post(%{uri: "at://a/p/2", cid: "c2", root: nil}),
            post(%{uri: "at://r/1", cid: "c3", root: {"at://a/p/2", "c2"}, who: "Lars"})
          ]),
          5,
          thread
        )

      compose = press(press(replies, {:move, :down}), {:move, :right})

      assert row(Page.render(compose), @head_y) == ["Feeds", "Thread", "Reply", "0/300"]
      assert row(Page.render(compose), @top) == ["Reply to Lars"]
      assert row(Page.render(compose), 216) == ["Tab reply   Enter new line"]

      assert compose.reply_to.reply == %{root: {"at://a/p/2", "c2"}, parent: {"at://r/1", "c3"}}

      sending = press(press(press(compose, {:char, ?y}), {:edit, :tab}), {:edit, :tab})

      assert row(Page.render(sending), 216) == ["Replying..."]
    end

    test "the tab says Reply as soon as a thread opens, and Post once it closes", %{state: state} do
      assert row(Page.render(state), @head_y) == ["Feeds", "Posts", "Post", "2/2"]

      thread = press(state, {:edit, :newline})

      assert row(Page.render(thread), @head_y) == ["Feeds", "Thread", "Reply", ""]

      back = press(thread, {:nav, :home})

      assert [_feeds, _name, "Post", _place] = row(Page.render(back), @head_y)
    end

    test "writing from a feed is a new post", %{state: state} do
      compose = press(Page.apply_login("pw", state), {:move, :right})

      assert compose.reply_to == nil
      assert row(Page.render(compose), @top) == ["Type a post"]
    end

    test "a post without a URI opens nothing" do
      assert Page.handle_key({:edit, :newline}, shown([post(%{})])) == :ignore
    end
  end

  describe "mentions while writing" do
    setup do
      state = Page.apply_login("pw", shown([post(%{})], %{post: :none, handles: %{}}))

      %{compose: press(state, {:move, :right})}
    end

    defp handles(state, handles), do: %{state | status: %{state.status | handles: handles}}

    test "typing looks nothing up and highlights nothing", %{compose: compose} do
      typed = typing(compose, "Hi @a.b and more")

      assert typed.asked == []
      assert coloured(Page.render(typed), @top) == [{"Hi @a.b and more", Theme.fg()}]
      assert press(typed, {:edit, :tab}).asked == []
    end

    test "unchecked mentions are offered to Down, which checks them all", %{compose: compose} do
      typed = typing(compose, "Hi @a.b @c.d")

      assert row(Page.render(typed), 216) == ["Down check mentions   Tab post"]

      checked = press(typed, {:move, :down})

      assert checked.asked == ["a.b", "c.d"]
      assert row(Page.render(checked), 216) == ["Tab post   Enter new line"]
      assert press(checked, {:move, :down}).asked == ["a.b", "c.d"]
    end

    test "a checked mention shows how its check went", %{compose: compose} do
      checked = press(typing(compose, "Hi @a.b @c.d @e.f!"), {:move, :down})

      items = Page.render(handles(checked, %{"a.b" => {:ok, "did:plc:a"}, "c.d" => :failed}))

      assert coloured(items, @top) == [
               {"Hi ", Theme.fg()},
               {"@a.b", Theme.select()},
               {" ", Theme.fg()},
               {"@c.d", Theme.alert()},
               {" ", Theme.fg()},
               {"@e.f", Theme.muted()},
               {"!", Theme.fg()}
             ]
    end

    test "editing a checked handle makes it unchecked again", %{compose: compose} do
      checked = press(typing(compose, "Hi @a.b"), {:move, :down})
      edited = typing(checked, "c")
      items = Page.render(handles(edited, %{"a.b" => {:ok, "did:plc:a"}}))

      assert coloured(items, @top) == [{"Hi @a.bc", Theme.fg()}]
      assert row(items, 216) == ["Down check mentions   Tab post"]
    end

    test "a checked mention broken across rows keeps its colour on both", %{compose: compose} do
      long = press(typing(compose, :binary.copy("x", 36) <> " @a.b"), {:move, :down})
      items = Page.render(handles(long, %{"a.b" => {:ok, "did:plc:a"}}))

      assert {"@", Theme.select()} in coloured(items, @top)
      assert {"a.b", Theme.select()} in coloured(items, @top + @pitch)
    end

    test "a reply offers the check too" do
      thread =
        Page.apply_login(
          "pw",
          shown([post(%{uri: "at://a", cid: "c", root: nil})], %{
            post: :none,
            handles: %{},
            feed: {:thread, "at://a"}
          })
        )

      compose = typing(press(thread, {:move, :right}), "@a.b")

      assert row(Page.render(compose), 216) == ["Down check mentions   Tab reply"]
    end
  end

  describe "likes" do
    test "a liked post shows a heart in the alert colour before its counts" do
      items = Page.render(shown([post(%{liked: "at://l"})]))

      assert coloured(items, @top + 3 * @pitch) == [
               {"<3", Theme.alert()},
               {"42 likes  7 reposts  3 replies", Theme.dim()}
             ]
    end

    test "a post not liked has no heart" do
      assert row(Page.render(shown([post(%{liked: nil})])), @top + 3 * @pitch) == [
               "42 likes  7 reposts  3 replies"
             ]
    end

    test "l toggles the like when logged in, and is left alone otherwise" do
      state = Page.apply_login("pw", shown([post(%{uri: "at://a"})]))

      assert {:ok, ^state} = Page.handle_key({:char, ?l}, state)
      assert Page.handle_key({:char, ?l}, shown([post(%{uri: "at://a"})])) == :ignore
    end
  end

  describe "reload" do
    test "r goes back to the top of the feed and asks for it again" do
      state = press(shown([post(%{}), post(%{}), post(%{})]), {:move, :down})

      assert Page.current(state) == 1

      reloaded = press(state, {:char, ?r})

      assert Page.current(reloaded) == 0
      assert Page.tab(reloaded) == :posts
      assert Page.current(press(state, {:char, ?R})) == 0
    end

    test "r in the composer is typed, not a reload" do
      compose = press(Page.apply_login("pw", shown([post(%{})], %{post: :none})), {:move, :right})

      assert Draft.text(press(compose, {:char, ?r}).draft) == "r"
    end
  end

  describe "a long post" do
    test "is cut where the rows run out, and the next post is not started" do
      long = post(%{lines: for(n <- 1..9, do: "Line " <> :erlang.integer_to_binary(n))})
      items = Page.render(shown([long, post(%{})]))

      assert row(items, @top + 9 * @pitch) == ["Line 9"]
      assert row(items, @top + 10 * @pitch) == []
      refute "42 likes  7 reposts  3 replies" in texts(items)
      assert length(texts(items)) == 4 + 2 + 9
    end

    test "a post that just fits leaves room for nothing else" do
      long = post(%{lines: for(n <- 1..8, do: "Line " <> :erlang.integer_to_binary(n))})
      items = Page.render(press(shown([post(%{}), long, post(%{})]), {:move, :down}))

      assert row(items, @top) == ["Goatmire", "2h"]
      assert row(items, @top + 8 * @pitch) == ["Line 8"]
      assert row(items, @top + 9 * @pitch) == ["42 likes  7 reposts  3 replies"]
      assert length(texts(items)) == 4 + 2 + 8 + 1
    end
  end
end
