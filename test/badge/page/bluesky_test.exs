defmodule Badge.Page.BlueskyTest do
  use ExUnit.Case, async: true

  alias Badge.Bluesky
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

      assert row(items, @head_y) == ["Feeds", "Posts", ""]
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
      assert row(Page.render(down), @head_y) == ["Feeds", "Posts", "2/3"]
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
      assert row(Page.render(state), @head_y) == ["Feeds", "Following", "1/1"]
    end

    test "Feeds lists the saved feeds, the one shown starred", %{feeds: feeds} do
      items = Page.render(feeds)

      assert coloured(items, @head_y) == [
               {"Feeds", Theme.select()},
               {"Following", Theme.dim()},
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
      assert row(Page.render(chosen), @head_y) == ["Feeds", "Discover", ""]
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

  describe "a long post" do
    test "is cut where the rows run out, and the next post is not started" do
      long = post(%{lines: for(n <- 1..9, do: "Line " <> :erlang.integer_to_binary(n))})
      items = Page.render(shown([long, post(%{})]))

      assert row(items, @top + 9 * @pitch) == ["Line 9"]
      assert row(items, @top + 10 * @pitch) == []
      refute "42 likes  7 reposts  3 replies" in texts(items)
      assert length(texts(items)) == 3 + 2 + 9
    end

    test "a post that just fits leaves room for nothing else" do
      long = post(%{lines: for(n <- 1..8, do: "Line " <> :erlang.integer_to_binary(n))})
      items = Page.render(press(shown([post(%{}), long, post(%{})]), {:move, :down}))

      assert row(items, @top) == ["Goatmire", "2h"]
      assert row(items, @top + 8 * @pitch) == ["Line 8"]
      assert row(items, @top + 9 * @pitch) == ["42 likes  7 reposts  3 replies"]
      assert length(texts(items)) == 3 + 2 + 8 + 1
    end
  end
end
