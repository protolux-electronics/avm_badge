defmodule Badge.Page.NameTest do
  use ExUnit.Case, async: true

  alias Badge.Font
  alias Badge.Page.Name
  alias Badge.Peers
  alias Badge.Profile
  alias Badge.QR
  alias Badge.Theme

  defp showing(overrides) do
    %{Name.init() | profile: Map.merge(Profile.blank(), overrides), loaded: true}
  end

  defp press(state, event) do
    {:ok, next} = Name.handle_key(event, state)
    next
  end

  defp press(state, _event, 0), do: state
  defp press(state, event, n), do: press(press(state, event), event, n - 1)

  defp editing(overrides \\ %{name: "Gus"}), do: press(showing(overrides), {:char, ?e})

  defp luminance(colour) do
    r = div(colour, 0x10000)
    g = div(rem(colour, 0x10000), 0x100)
    b = rem(colour, 0x100)

    (r * 30 + g * 59 + b * 11) |> div(100)
  end

  defp type(state, text) do
    :lists.foldl(&press(&2, {:char, &1}), state, :erlang.binary_to_list(text))
  end

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Name.render(state), do: body)

  defp name_lines(state) do
    for {:text, _x, _y, :dogica, _c, _b, body} <- Name.render(state), do: body
  end

  defp rule_y(state) do
    [y] =
      for {:rect, _x, y, _w, _h, colour} <- Name.render(state), colour == Theme.accent(), do: y

    y
  end

  describe "identity" do
    test "announces itself for the home grid" do
      assert Name.title() == "Name"
      assert Name.icon() == :square
    end

    test "does not trap escape" do
      assert Name.handle_key({:nav, :home}, Name.init()) == :ignore
    end
  end

  describe "the name" do
    test "a short name is one line" do
      assert name_lines(showing(%{name: "Gus"})) == ["Gus"]
    end

    test "an empty name falls back rather than showing a blank badge" do
      assert name_lines(showing(%{})) == [Profile.placeholder()]
    end

    test "a name that exactly fills the line stays on one" do
      exact = :erlang.list_to_binary(:lists.duplicate(Name.columns(), ?x))

      assert name_lines(showing(%{name: exact})) == [exact]
    end

    test "a long name breaks at the space" do
      assert name_lines(showing(%{name: "Bartholomew Cubbins"})) == ["Bartholomew", "Cubbins"]
    end

    test "a long name with no space is dashed rather than running off the panel" do
      lines = name_lines(showing(%{name: "Wolfeschlegelsteinhausen"}))

      assert length(lines) == 2
      assert hd(lines) == "Wolfeschlegelstei-"
    end

    test "no name line is wider than the panel" do
      for name <- ["Gus", "Alexander Hamilton", "Wolfeschlegelsteinhausenbergerdorff"] do
        for line <- name_lines(showing(%{name: name})) do
          assert 16 + Font.advance(:dogica) * byte_size(line) <= Theme.width()
        end
      end
    end

    test "the column count matches what actually fits" do
      assert Name.columns() == div(Theme.width() - 32, Font.advance(:dogica))
    end
  end

  describe "the rule" do
    test "sits under a one-line name" do
      assert rule_y(showing(%{name: "Gus"})) > Theme.content_top()
    end

    test "moves down when the name takes two lines" do
      assert rule_y(showing(%{name: "Bartholomew Cubbins"})) > rule_y(showing(%{name: "Gus"}))
    end

    test "never overlaps the last line of the name" do
      for name <- ["Gus", "Bartholomew Cubbins"] do
        state = showing(%{name: name})

        lowest =
          :lists.max(for {:text, _x, y, :dogica, _c, _b, _body} <- Name.render(state), do: y)

        assert rule_y(state) > lowest
      end
    end
  end

  describe "the details" do
    test "shows what has been filled in" do
      bodies = texts(showing(%{name: "Gus", company: "Protolux", email: "gus@example.com"}))

      assert "Protolux" in bodies
      assert "gus@example.com" in bodies
    end

    test "sit below the name in the hierarchy, so the name reads first" do
      state = showing(%{name: "Gus", company: "Protolux"})

      [name_colour] =
        for {:text, _x, _y, :dogica, colour, _b, _body} <- Name.render(state), do: colour

      [detail_colour] =
        for {:text, _x, _y, :default16px, colour, _b, "Protolux"} <- Name.render(state),
            do: colour

      assert name_colour == Theme.fg()
      assert detail_colour == Theme.muted()
      assert luminance(detail_colour) < luminance(name_colour)
    end

    test "are still brighter than the chrome, so they do not read as a hint" do
      assert luminance(Theme.muted()) > luminance(Theme.dim())
    end

    test "leaves out what has not" do
      bodies = texts(showing(%{name: "Gus"}))

      assert bodies == ["Gus", "E to edit"]
    end

    test "handles are shown with an icon rather than a text marker" do
      state = showing(%{name: "Gus", github: "gusrs", bluesky: "gus.example"})
      bodies = texts(state)

      assert "gusrs" in bodies
      assert "gus.example" in bodies

      icons = for {:image, _x, _y, _bg, _img} <- Name.render(state), do: :icon

      assert length(icons) == 2
    end

    test "every detail line starts at the same x, whatever its icon" do
      state = showing(%{name: "Gus", github: "gusrs", links: "a.example", company: "Protolux"})

      xs =
        for {:text, x, _y, :default16px, _c, _b, body} <- Name.render(state),
            body in ["gusrs", "a.example", "Protolux"],
            do: x

      assert length(xs) == 3
      assert length(:lists.usort(xs)) == 1
    end

    test "each link gets its own icon, not just the first" do
      state = showing(%{name: "Gus", links: "a.example b.example"})
      icons = for {:image, _x, _y, _bg, _img} <- Name.render(state), do: :icon

      assert length(icons) == 2
    end

    test "gives each link its own line" do
      bodies = texts(showing(%{name: "Gus", links: "one.example two.example"}))

      assert "one.example" in bodies
      assert "two.example" in bodies
    end

    test "drops details that would collide with the hint" do
      full = %{
        name: "Bartholomew Cubbins",
        company: "A",
        email: "B",
        github: "C",
        mastodon: "D",
        bluesky: "E",
        links: "F G H I J K"
      }

      for {:text, _x, y, _f, _c, _b, _body} <- Name.render(showing(full)) do
        assert y <= 216
      end
    end
  end

  describe "render/1" do
    test "tells you how to edit" do
      assert "E to edit" in texts(showing(%{name: "Gus"}))
    end

    test "emits no background rect" do
      refute Enum.any?(Name.render(showing(%{name: "Gus"})), fn
               {:rect, 0, 0, 320, 240, _colour} -> true
               _item -> false
             end)
    end

    test "everything sits inside the panel" do
      for item <- Name.render(showing(%{name: "Bartholomew Cubbins", company: "Protolux"})) do
        {x, y} =
          case item do
            {:rect, x, y, _w, _h, _c} -> {x, y}
            {:text, x, y, _f, _c, _b, _body} -> {x, y}
            {:image, x, y, _bg, _img} -> {x, y}
          end

        assert x >= 0
        assert y >= Theme.content_top()
        assert y < Theme.height()
      end
    end
  end

  describe "paging between badge screens" do
    defp screen(state, n), do: %{state | screen: n}

    defp big_lines(state) do
      for {:text, _x, _y, font, _c, _b, body} <- Name.render(state),
          font in [:w95fa, :dogica],
          do: {font, body}
    end

    test "right and left page through, and wrap" do
      state = showing(%{name: "Gus"})

      assert press(state, {:move, :right}).screen == 1
      assert press(state, {:move, :right}, Name.screens()).screen == 0
      assert press(state, {:move, :left}).screen == Name.screens() - 1
    end

    test "paging is only for the badge, not the editor" do
      assert press(editing(), {:move, :right}).screen == 0
    end

    test "the big screen shows the name and nothing else" do
      state = screen(showing(%{name: "Gus", company: "Protolux"}), 1)
      bodies = for {:text, _x, _y, _f, _c, _b, body} <- Name.render(state), do: body

      assert bodies == ["Gus"]
    end

    test "a name that fits uses the large font" do
      assert big_lines(screen(showing(%{name: "Gus Ross"}), 1)) == [{:w95fa, "Gus Ross"}]
    end

    test "a name too wide for the large font drops to dogica and wraps" do
      lines = big_lines(screen(showing(%{name: "Bartholomew Cubbins"}), 1))

      assert Enum.all?(lines, fn {font, _body} -> font == :dogica end)
      assert length(lines) > 1
    end

    test "whichever font is used, nothing runs off the panel" do
      for name <- ["Gus", "Gus Ross", "Bartholomew Cubbins", "Wolfeschlegelsteinhausen"] do
        state = screen(showing(%{name: name}), 1)

        for {:text, x, _y, font, _c, _b, body} <- Name.render(state) do
          assert x >= 0
          assert x + Badge.Font.width(font, body) <= Theme.width()
        end
      end
    end

    test "the big name is centred, which needs the font measured not guessed" do
      state = screen(showing(%{name: "Gus Ross"}), 1)

      [{:text, x, _y, font, _c, _b, body}] =
        for item = {:text, _x, _y, f, _c, _b, _t} <- Name.render(state), f == :w95fa, do: item

      assert x == div(Theme.width() - Badge.Font.width(font, body), 2)
    end

    test "a dot marks which screen you are on" do
      for index <- 0..(Name.screens() - 1) do
        state = screen(showing(%{name: "Gus"}), index)

        bright =
          for {:rect, _x, _y, 6, 6, colour} <- Name.render(state), colour == Theme.fg(), do: :dot

        dim =
          for {:rect, _x, _y, 6, 6, colour} <- Name.render(state), colour == Theme.dim(), do: :dot

        assert length(bright) == 1
        assert length(dim) == Name.screens() - 1
      end
    end
  end

  describe "the share screen" do
    defp sharing(overrides \\ %{}) do
      %{screen(showing(Map.merge(%{name: "Gus"}, overrides)), 2) | chip: "A1B2C3D4E5F6"}
    end

    test "shows this badge's own chip id" do
      assert "A1B2C3D4E5F6" in texts(sharing())
    end

    test "says what to do rather than offering a switch" do
      shown = texts(sharing())

      assert Enum.any?(shown, &(:binary.match(&1, "hold another badge") != :nomatch))
      refute Enum.any?(shown, &(:binary.match(&1, "sharing is") != :nomatch))
      refute Enum.any?(shown, &(:binary.match(&1, "turn on") != :nomatch))
    end

    test "enter is no longer the share screen's key" do
      assert Name.handle_key({:edit, :newline}, sharing()) == :ignore
    end

    defp met(greeting, name \\ "Pat") do
      %{sharing() | met: {name, greeting}}
    end

    defp colour_of(state, text) do
      [c] =
        for {:text, _x, _y, _f, c, _b, body} <- Name.render(state),
            :binary.match(body, text) != :nomatch,
            do: c

      c
    end

    test "before anyone is heard it says what to do" do
      assert Enum.any?(
               texts(sharing()),
               &(:binary.match(&1, "hold another badge") != :nomatch)
             )
    end

    test "a new badge reads as saved, in the good colour" do
      assert "Pat" in texts(met(:new))
      assert colour_of(met(:new), "added to your badges") == Theme.ok()
    end

    test "a badge already collected says so, in its own colour" do
      assert colour_of(met(:known), "already in your badges") == Theme.select()
      refute colour_of(met(:known), "already in your badges") == Theme.ok()
    end

    test "a renamed badge is distinct from both new and known" do
      assert colour_of(met(:renamed), "name updated") == Theme.warn()
    end

    test "the panel slows down on the screen that feeds it" do
      assert Name.refresh(sharing()) == 333
      assert Name.refresh(showing(%{name: "Gus"})) == 100
    end
  end

  describe "deciding what a heard badge means" do
    defp known(pairs) do
      Enum.reduce(pairs, [], fn {id, name}, acc -> Peers.add(acc, id, %{name: name}) end)
    end

    test "an unheard chip id is new" do
      assert Name.greeting([], "aaaaaa", "Pat") == :new
      assert Name.greeting(known([{"bbbbbb", "Gus"}]), "aaaaaa", "Pat") == :new
    end

    test "the same chip id under the same name is already known" do
      assert Name.greeting(known([{"aaaaaa", "Pat"}]), "aaaaaa", "Pat") == :known
    end

    test "the same chip id under a new name is a rename, not a new badge" do
      assert Name.greeting(known([{"aaaaaa", "Pat"}]), "aaaaaa", "Patricia") == :renamed
    end

    test "a rename replaces rather than duplicating" do
      peers = known([{"aaaaaa", "Pat"}])
      renamed = Peers.add(peers, "aaaaaa", %{name: "Patricia"})

      assert Peers.count(renamed) == 1
      assert Profile.display_name(Peers.find(renamed, "aaaaaa").profile) == "Patricia"
    end
  end

  describe "ticking" do
    test "a loaded, idle page ticks to a map, not something render cannot use" do
      profile = Map.put(Profile.blank(), :name, "Gus")

      state = %{
        Name.init()
        | loaded: true,
          mode: :show,
          profile: profile,
          saved: profile
      }

      ticked = Name.tick(state)

      assert is_map(ticked)
      assert is_list(Name.render(ticked))
    end
  end

  describe "hearing a badge" do
    test "the same badge beaming again changes nothing" do
      state = %{sharing() | announced: {"aaaaaa", "Pat"}}

      assert Name.handle_ir("aaaaaa", "Pat", state) == :ignore
    end

    test "a badge already collected is reported without rewriting the list" do
      peers = [%{id: "aaaaaa", profile: %{name: "Pat"}}]
      state = %{sharing() | peers: peers}

      {:ok, next} = Name.handle_ir("aaaaaa", "Pat", state)

      assert next.met == {"Pat", :known}
      assert next.peers == peers
      assert next.announced == {"aaaaaa", "Pat"}
    end

    test "a new badge is collected" do
      {:ok, next} = Name.handle_ir("aaaaaa", "Pat", sharing())

      assert next.met == {"Pat", :new}
      assert Peers.count(next.peers) == 1
    end

    test "collecting a badge does not write to NVS from the handler" do
      {:ok, next} = Name.handle_ir("aaaaaa", "Pat", sharing())

      assert Peers.count(next.peers) == 1
      assert next.stored == []
    end

    test "a badge heard on any other screen is dropped" do
      for other <- [0, 1, 3] do
        state = %{sharing() | screen: other}

        assert Name.handle_ir("aaaaaa", "Pat", state) == :ignore
      end
    end
  end

  describe "beaming the profile" do
    # persist/1 writes to NVS unless the profile already matches the saved one.
    defp beaming(state \\ sharing()), do: %{state | saved: state.profile}

    test "transmits on every third tick and no other" do
      assert Name.beam_ticks() == 3

      one = Name.tick(beaming())
      two = Name.tick(one)
      three = Name.tick(two)

      assert one.beam == 1
      assert two.beam == 2
      assert three.beam == 0
    end

    test "a screen that is not sharing never advances the counter" do
      for other <- [0, 1, 3] do
        state = beaming(%{sharing() | screen: other})

        assert Name.tick(state).beam == 0
        assert state |> Name.tick() |> Name.tick() |> Map.get(:beam) == 0
      end
    end

    test "paging away resets the counter, so returning starts a fresh cycle" do
      part_way = beaming() |> Name.tick() |> Name.tick()

      assert part_way.beam == 2
      assert Name.tick(%{part_way | screen: 3}).beam == 0
    end
  end

  describe "scrolling the collected list" do
    defp with_peers(n) do
      peers = for i <- 1..n, do: %{id: <<i::48>>, profile: %{name: "Badge #{i}"}}

      %{screen(showing(%{name: "Gus"}), 3) | peers: peers}
    end

    test "a list that fits does not scroll" do
      assert Name.scroll(with_peers(3), 1).top == 0
    end

    test "scrolling stops at the last full window" do
      assert Name.scroll(with_peers(10), 99).top == 4
    end

    test "scrolling stops at the top" do
      assert Name.scroll(with_peers(10), -99).top == 0
    end

    test "the window shows the names it has scrolled to" do
      scrolled = Name.scroll(with_peers(10), 2)

      assert "Badge 3" in texts(scrolled)
      refute "Badge 1" in texts(scrolled)
    end

    test "a short list says nothing about scrolling" do
      refute Enum.any?(texts(with_peers(3)), &(:binary.match(&1, "of 3") != :nomatch))
    end

    test "a long list says where you are in it" do
      assert Enum.any?(texts(with_peers(10)), &(:binary.match(&1, "1-6 of 10") != :nomatch))
    end

    test "up and down belong to the collected screen alone" do
      assert Name.handle_key({:move, :down}, screen(showing(%{name: "Gus"}), 1)) == :ignore
      assert press(with_peers(10), {:move, :down}).top == 1
    end

    test "paging away from the list starts it at the top again" do
      scrolled = Name.scroll(with_peers(10), 3)

      assert press(scrolled, {:move, :right}).top == 0
    end

    test "enter is not a key this page uses on any screen" do
      for screen <- [0, 1, 2, 3] do
        assert Name.handle_key({:edit, :newline}, screen(showing(%{name: "Gus"}), screen)) ==
                 :ignore
      end
    end
  end

  describe "the collected screen" do
    defp collected(peers) do
      %{screen(showing(%{name: "Gus"}), 3) | peers: peers}
    end

    defp peer(n, name) do
      %{id: <<0, 0, 0, 0, 0, n>>, profile: Map.put(Profile.blank(), :name, name)}
    end

    test "an empty collection says none" do
      assert Enum.any?(texts(collected([])), &(:binary.match(&1, "0 badges") != :nomatch))
    end

    test "one badge is singular" do
      assert Enum.any?(
               texts(collected([peer(1, "A")])),
               &(:binary.match(&1, "1 badge") != :nomatch)
             )
    end

    test "counts what has been collected" do
      peers = for n <- 1..5, do: peer(n, "P")

      assert Enum.any?(texts(collected(peers)), &(:binary.match(&1, "5 badges") != :nomatch))
    end

    test "names the badges collected" do
      bodies = texts(collected([peer(1, "Ada"), peer(2, "Grace")]))

      assert "Ada" in bodies
      assert "Grace" in bodies
    end

    test "shows only as many as fit, rather than overflowing" do
      peers = for n <- 1..40, do: peer(n, "P")

      for {:text, _x, y, _f, _c, _b, _body} <- Name.render(collected(peers)) do
        assert y < Theme.height()
      end
    end

    test "a peer with no name still lists rather than blanking the row" do
      bare = %{id: <<0, 0, 0, 0, 0, 9>>, profile: %{}}

      assert Profile.placeholder() in texts(collected([bare]))
    end
  end

  describe "the QR screen" do
    defp qrcode(overrides \\ %{}) do
      profile =
        %{name: "Gus", qr: "github", github: "gus"}
        |> Map.merge(overrides)
        |> then(&Map.merge(Profile.blank(), &1))

      %{screen(showing(profile), 4) | qr_result: :none}
    end

    defp qr_items(state) do
      for item = {:scaled_cropped_image, _, _, _, _, _, _, _, _, _, _, _} <- Name.render(state),
          do: item
    end

    test "is the fifth and last screen" do
      assert Name.screens() == 5
      assert press(screen(showing(%{name: "Gus"}), 3), {:move, :right}).screen == 4
    end

    test "leaves the space above the code empty, so a big code cannot run into text" do
      for length <- [20, 60, 140, 271] do
        {:ok, code} = QR.encode(:binary.copy("a", length))
        items = Name.render(%{qrcode() | qr_result: {:ok, code}})

        [{:scaled_cropped_image, _x, top, _w, height, _bg, 0, 0, _xs, _ys, [], _img}] =
          qr_items(%{qrcode() | qr_result: {:ok, code}})

        for {:text, _x, y, _f, _c, _b, _body} <- items do
          assert top + height <= y
        end
      end
    end

    test "shows the chosen handle under the code" do
      assert "gus" in texts(qrcode())
    end

    test "draws the link's own icon" do
      assert Enum.any?(Name.render(qrcode()), &match?({:image, _x, _y, _bg, _img}, &1))
    end

    test "asks for a link when there is nothing to encode" do
      assert "Set a link in the editor" in texts(qrcode(%{qr: "", github: ""}))
    end

    test "says so while a code is being built" do
      assert "Generating..." in texts(%{qrcode() | qr_result: :pending})
    end

    test "says so when a link will not fit in a code" do
      assert "Link is too long" in texts(%{qrcode() | qr_result: {:error, :too_long}})
    end

    test "draws the code once it is built" do
      {:ok, code} = QR.encode("https://github.com/gus")

      assert [{:scaled_cropped_image, x, y, w, h, 0xFFFFFF, 0, 0, scale, scale, [], _img}] =
               qr_items(%{qrcode() | qr_result: {:ok, code}})

      assert w == (code.size + 8) * scale
      assert x == div(Theme.width() - w, 2)
      assert y >= Theme.content_top()
      assert y + h <= Theme.height()
    end

    test "a longer link draws a smaller code, never one off the panel" do
      for length <- [20, 60, 140, 271] do
        {:ok, code} = QR.encode(:binary.copy("a", length))

        assert [{:scaled_cropped_image, x, y, w, h, _bg, 0, 0, scale, _ys, [], _img}] =
                 qr_items(%{qrcode() | qr_result: {:ok, code}})

        assert scale >= 1
        assert x >= 0
        assert x + w <= Theme.width()
        assert y >= Theme.content_top()
        assert y + h <= Theme.height()
      end
    end

    test "the pending screen is a still frame: one line and the dots, nothing that could move" do
      items = Name.render(%{qrcode() | qr_result: :pending})
      bodies = for {:text, _x, _y, _f, _c, _b, body} <- items, do: body
      rects = for {:rect, _x, _y, _w, _h, _c} <- items, do: :rect

      assert "Generating..." in bodies
      assert length(bodies) == 2
      assert length(rects) == Name.screens()
    end
  end

  describe "encoding the QR in the background" do
    # saved: profile, so persist/1 does not write to NVS from a test.
    defp ready(overrides) do
      profile = Map.merge(Profile.blank(), Map.merge(%{name: "Gus"}, overrides))

      %{Name.init() | loaded: true, mode: :show, profile: profile, saved: profile}
    end

    # The code is only built while its own screen is up, so that the encode
    # cannot slow the panel down on the screens that never show it.
    defp showing_link(overrides \\ %{}) do
      %{ready(Map.merge(%{qr: "github", github: "gus"}, overrides)) | screen: 4}
    end

    defp relink(state, overrides) do
      profile = Map.merge(state.profile, overrides)

      %{state | profile: profile, saved: profile}
    end

    test "no other screen starts a worker, however the profile reads" do
      for screen <- [0, 1, 2, 3] do
        ticked = Name.tick(%{showing_link() | screen: screen})

        assert ticked.qr_pid == nil
        assert ticked.qr_result == :none
      end
    end

    test "a page with no link to show never starts a worker" do
      ticked = Name.tick(ready(%{}))

      assert ticked.qr_result == :none
      assert ticked.qr_pid == nil
    end

    test "the QR screen starts the encode, and the result arrives as a message" do
      started = Name.tick(showing_link())

      assert started.qr_result == :pending
      assert is_pid(started.qr_pid)
      assert started.qr_payload == "https://github.com/gus"

      {:ok, done} = Name.handle_info({started.qr_ref, started.qr_payload, {:ok, :code}}, started)

      assert done.qr_result == {:ok, :code}
      assert done.qr_pid == nil
    end

    test "a second tick leaves a running encode alone" do
      started = Name.tick(showing_link())

      assert Name.tick(started) == started
    end

    test "a result that cannot be encoded is not retried forever" do
      started = Name.tick(showing_link())

      {:ok, failed} =
        Name.handle_info({started.qr_ref, started.qr_payload, {:error, :too_long}}, started)

      assert Name.tick(failed).qr_result == {:error, :too_long}
    end

    test "changing the link starts a new encode" do
      started = Name.tick(showing_link())
      changed = Name.tick(relink(started, %{github: "pat"}))

      assert changed.qr_payload == "https://github.com/pat"
      assert changed.qr_result == :pending
    end

    test "clearing the link drops the code" do
      started = Name.tick(showing_link())
      cleared = Name.tick(relink(started, %{github: ""}))

      assert cleared.qr_result == :none
      assert cleared.qr_payload == nil
      assert cleared.qr_pid == nil
    end

    test "nothing is encoded while the editor is open" do
      editing = press(showing_link(), {:char, ?e})

      assert Name.tick(editing).qr_result == :none
    end

    test "leaving the QR screen drops a half-built code" do
      started = Name.tick(showing_link())
      left = Name.tick(%{started | screen: 0})

      assert left.qr_result == :none
      assert left.qr_payload == nil
      assert left.qr_pid == nil

      assert Name.tick(%{left | screen: 4}).qr_result == :pending
    end

    test "leaving the QR screen keeps a code that is already built" do
      started = Name.tick(showing_link())

      {:ok, done} =
        Name.handle_info({started.qr_ref, started.qr_payload, {:ok, :code}}, started)

      left = Name.tick(%{done | screen: 0})

      assert left.qr_result == {:ok, :code}
      assert left.qr_pid == nil

      assert Name.tick(%{left | screen: 4}).qr_result == {:ok, :code}
    end

    test "leaving the page stops the worker" do
      started = Name.tick(showing_link())
      ref = Process.monitor(started.qr_pid)

      assert Name.leave(started) == :ok
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 500
    end

    test "a message from an older worker is ignored" do
      started = Name.tick(showing_link())

      assert Name.handle_info({make_ref(), "https://github.com/pat", {:ok, :stale}}, started) ==
               :ignore

      assert Name.handle_info({make_ref(), "x", :anything}, started) == :ignore
    end
  end

  describe "opening the editor" do
    test "E opens it, and so does a capital E" do
      assert editing().mode == :fields
      assert press(showing(%{name: "Gus"}), {:char, ?E}).mode == :fields
    end

    test "the badge itself ignores escape, so the router still goes home" do
      assert Name.handle_key({:nav, :home}, showing(%{name: "Gus"})) == :ignore
    end

    test "other keys on the badge are left alone" do
      assert Name.handle_key({:char, ?z}, showing(%{name: "Gus"})) == :ignore
      assert Name.handle_key({:move, :up}, showing(%{name: "Gus"})) == :ignore
    end
  end

  describe "the field list" do
    test "lists every field with its label" do
      bodies = texts(editing())

      for key <- Profile.keys() do
        assert Profile.label(key) in bodies
      end
    end

    test "starts on the first field" do
      assert Name.selected(editing()) == hd(Profile.keys())
    end

    test "up and down move, and stop at the ends" do
      assert Name.selected(press(editing(), {:move, :down})) == :lists.nth(2, Profile.keys())
      assert Name.selected(press(editing(), {:move, :up})) == hd(Profile.keys())
      assert Name.selected(press(editing(), {:move, :down}, 20)) == :lists.last(Profile.keys())
    end

    test "escape leaves the editor rather than the page" do
      assert press(editing(), {:nav, :home}).mode == :show
    end

    test "an empty required field is called out in the alert colour" do
      blank = press(showing(%{}), {:char, ?e})

      colours =
        for {:text, 88, _y, _f, colour, _b, _body} <- Name.render(blank), do: colour

      assert Theme.alert() in colours
    end

    test "a filled required field is not" do
      colours = for {:text, 88, _y, _f, colour, _b, _body} <- Name.render(editing()), do: colour

      refute Theme.alert() in colours
    end

    test "an empty field shows a placeholder rather than nothing" do
      assert "-" in texts(editing())
    end

    test "a value longer than the column is cut to fit" do
      long = :erlang.list_to_binary(:lists.duplicate(40, ?x))
      state = press(showing(%{name: "Gus", links: long}), {:char, ?e})

      for {:text, 88, _y, _f, _c, _b, body} <- Name.render(state) do
        assert byte_size(body) <= 28
      end
    end
  end

  describe "typing in a field" do
    test "enter opens the highlighted field, prefilled" do
      state = press(editing(), {:edit, :newline})

      assert state.mode == :typing
      assert :binary.match(hd(texts(state)) <> Enum.join(texts(state)), "Gus") != :nomatch
    end

    test "characters and backspace edit it" do
      state = editing() |> press({:edit, :newline}) |> press({:edit, :backspace}) |> type("s")

      assert Badge.Field.value(state.field) == "Gus"
    end

    test "spaces are allowed, since names and links need them" do
      state = editing() |> press({:edit, :newline}) |> type(" Ross")

      assert Badge.Field.value(state.field) == "Gus Ross"
    end

    test "enter commits the value back to the profile" do
      state =
        editing() |> press({:edit, :newline}) |> type(" Ross") |> press({:edit, :newline})

      assert state.mode == :fields
      assert Map.get(state.profile, :name) == "Gus Ross"
    end

    test "escape cancels, leaving the value as it was" do
      state = editing() |> press({:edit, :newline}) |> type(" Ross") |> press({:nav, :home})

      assert state.mode == :fields
      assert Map.get(state.profile, :name) == "Gus"
    end

    test "the field cannot grow past its capacity" do
      long = :erlang.list_to_binary(:lists.duplicate(60, ?x))
      state = editing() |> press({:edit, :newline}) |> type(long)

      assert Badge.Field.value(state.field) |> byte_size() <= Profile.capacity(:name)
    end

    test "the entry screen names the field and says what the keys do" do
      bodies = texts(editing() |> press({:edit, :newline}))

      assert Profile.label(:name) in bodies
      assert Enum.any?(bodies, &(:binary.match(&1, "Esc cancel") != :nomatch))
    end

    test "editing a different field edits that one" do
      state =
        editing()
        |> press({:move, :down})
        |> press({:edit, :newline})
        |> type("Protolux")
        |> press({:edit, :newline})

      assert Map.get(state.profile, :company) == "Protolux"
      assert Map.get(state.profile, :name) == "Gus"
    end
  end

  describe "choosing the QR link" do
    defp on_the_choice(state) do
      press(state, {:move, :down}, length(Profile.keys()) - 1)
    end

    defp stored(state), do: Profile.qr_key(state.profile)

    defp filled, do: %{name: "Gus", github: "gus", linkedin: "gus-workman"}

    defp picking(overrides \\ %{}) do
      editing(Map.merge(filled(), overrides)) |> on_the_choice() |> press({:edit, :newline})
    end

    test "the row is the last one, and starts at none" do
      state = on_the_choice(editing())

      assert Name.selected(state) == :qr
      assert stored(state) == :none
    end

    test "enter opens a picker rather than the keyboard" do
      assert picking().mode == :picking
    end

    test "the picker opens on the choice already stored" do
      assert picking(%{qr: "linkedin"}).pick == 2
    end

    test "up and down move the picker and stop at the ends" do
      assert picking() |> press({:move, :down}) |> Map.get(:pick) == 1
      assert picking() |> press({:move, :up}) |> Map.get(:pick) == 0

      at_the_end = picking(%{links: "https://example.com", qr: "links"})

      assert at_the_end.pick == 3
      assert at_the_end |> press({:move, :down}) |> Map.get(:pick) == 3
    end

    test "enter takes the highlighted choice and returns to the fields" do
      taken = picking() |> press({:move, :down}) |> press({:edit, :newline})

      assert taken.mode == :fields
      assert stored(taken) == :github
    end

    test "escape leaves the picker without changing the choice" do
      left = picking() |> press({:move, :down}) |> press({:nav, :home})

      assert left.mode == :fields
      assert stored(left) == :none
    end

    test "only links that are filled in can be picked" do
      bodies = texts(picking())

      assert "GitHub" in bodies
      assert "LinkedIn" in bodies
      refute "Bluesky" in bodies
      refute "Link" in bodies
    end

    test "an empty profile offers only None" do
      labels =
        for {:text, 8, y, _f, _c, _b, body} <- Name.render(picking(%{github: "", linkedin: ""})),
            y < 200,
            do: body

      assert labels == ["None"]
    end

    test "the picker shows the handle each choice would encode" do
      assert "gus-workman" in texts(picking())
    end

    test "left and right change nothing, on any row" do
      for state <- [editing(), on_the_choice(editing())] do
        assert press(state, {:move, :right}).profile == state.profile
        assert press(state, {:move, :left}).profile == state.profile
      end
    end

    test "the row shows the label rather than the stored name" do
      state = on_the_choice(editing(%{name: "Gus", qr: "linkedin"}))

      assert "LinkedIn" in texts(state)
    end

    test "the choice reaches the page, which encodes it" do
      chosen = picking() |> press({:move, :down}) |> press({:edit, :newline})

      # saved: profile, so tick/1 does not write the edited profile to NVS from a test.
      state = %{chosen | mode: :show, screen: 4, saved: chosen.profile}

      assert Name.tick(state).qr_payload == "https://github.com/gus"
    end
  end

  describe "every editor screen" do
    test "stays inside the panel" do
      states = [editing(), press(editing(), {:edit, :newline})]

      for state <- states, {:text, x, y, _f, _c, _b, body} <- Name.render(state) do
        assert x >= 0
        assert x + 8 * byte_size(body) <= Theme.width()
        assert y >= Theme.content_top()
        assert y < Theme.height()
      end
    end
  end

  describe "the big font" do
    test "is only asked for on the screen that draws with it" do
      assert Name.fonts(screen(showing(%{name: "Gus"}), 1)) == [:w95fa]
    end

    test "is not held while any other screen is showing" do
      for other <- [0, 2, 3] do
        assert Name.fonts(screen(showing(%{name: "Gus"}), other)) == []
      end
    end
  end
end
