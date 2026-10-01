defmodule Badge.Page.ShareTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Share, as: Page
  alias Badge.Peers
  alias Badge.Profile
  alias Badge.Sharing
  alias Badge.Sharing.Wire
  alias Badge.Theme

  @me <<0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6>>
  @other <<0, 0, 0, 0, 0, 1>>

  # A page after its first tick, without touching NVS.
  defp loaded(overrides \\ %{name: "Gus"}, shared \\ [:name]) do
    profile = Map.merge(Profile.blank(), overrides)

    Page.recycle(%{
      Page.init()
      | loaded: true,
        profile: profile,
        shared: shared,
        saved_shared: shared,
        id: @me,
        chip: "A1B2C3D4E5F6"
    })
  end

  defp on(state, screen), do: %{state | screen: screen}

  defp press(state, event) do
    {:ok, next} = Page.handle_key(event, state)
    next
  end

  defp press(state, _event, 0), do: state
  defp press(state, event, n), do: press(press(state, event), event, n - 1)

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Page.render(state), do: body)

  defp colour_of(state, text) do
    [c] =
      for {:text, _x, _y, _f, c, _b, body} <- Page.render(state),
          :binary.match(body, text) != :nomatch,
          do: c

    c
  end

  defp says?(state, text), do: Enum.any?(texts(state), &(:binary.match(&1, text) != :nomatch))

  describe "identity" do
    test "announces itself for the home grid" do
      assert Page.title() == "Share"
      assert Page.icon() == :triangle
    end

    test "does not trap escape" do
      assert Page.handle_key({:nav, :home}, loaded()) == :ignore
    end
  end

  describe "paging" do
    test "right and left page through three screens, and wrap" do
      assert Page.screens() == 3
      assert press(loaded(), {:move, :right}).screen == 1
      assert press(loaded(), {:move, :right}, 3).screen == 0
      assert press(loaded(), {:move, :left}).screen == 2
    end

    test "each screen shows which one it is" do
      for screen <- 0..2 do
        dots = for {:rect, _x, 228, 6, 6, colour} <- Page.render(on(loaded(), screen)), do: colour

        assert length(dots) == 3
        assert Enum.count(dots, &(&1 == Theme.fg())) == 1
      end
    end
  end

  describe "the share screen" do
    test "draws two badges facing each other, the right one turned, at twice size" do
      images =
        for {:scaled_cropped_image, x, y, w, h, _bg, 0, 0, 2, 2, [], {:rgba8888, iw, ih, data}} <-
              Page.render(loaded()),
            do: {x, y, w, h, iw, ih, data}

      assert [{lx, y, w, h, iw, ih, left}, {rx, y, w, h, iw, ih, right}] = images
      assert {w, h} == {iw * 2, ih * 2}
      assert rx == lx + w
      assert lx + rx + w == Theme.width()
      assert right == Badge.Icons.half_turn(left)
    end

    test "shows two badges meeting, whatever else it has to say" do
      for state <- [Page.init(), loaded(), loaded(%{})] do
        art =
          for {:scaled_cropped_image, _x, 90, _w, _h, _bg, _, _, _, _, _, _} = item <-
                Page.render(state),
              do: item

        assert length(art) == 2
      end
    end

    test "what it says sits below the badges, above the dots" do
      for state <- [loaded(), loaded(%{}), %{loaded() | met: {"Pat", :new}}] do
        for {:text, _x, y, _f, _c, _b, _body} <- Page.render(state), y > 90 do
          assert y >= 154 and y + 16 <= 228
        end
      end
    end

    test "shows this badge's own chip id and says what to do" do
      assert "A1B2C3D4E5F6" in texts(loaded())
      assert says?(loaded(), "hold another badge")
    end

    test "warns, and has nothing to beam, when the profile has no name" do
      state = loaded(%{})

      assert state.cycle == []
      assert colour_of(state, "Set your name first") == Theme.alert()
      refute "A1B2C3D4E5F6" in texts(state)
    end

    test "says nothing until the stores have been read" do
      refute says?(Page.init(), "Set your name")
    end

    test "a new badge reads as saved, in the good colour" do
      state = %{loaded() | met: {"Pat", :new}}

      assert "Pat" in texts(state)
      assert colour_of(state, "added to your badges") == Theme.ok()
    end

    test "a badge already collected says so, in its own colour" do
      state = %{loaded() | met: {"Pat", :known}}

      assert colour_of(state, "already in your badges") == Theme.select()
    end

    test "a badge that changed what it shares is distinct from both" do
      assert colour_of(%{loaded() | met: {"Pat", :updated}}, "updated") == Theme.warn()
    end

    test "counts what has been collected" do
      one = %{loaded() | peers: [%{id: @other, profile: %{name: "Pat"}}]}

      assert says?(loaded(), "0 badges collected")
      assert says?(one, "1 badge collected")
    end

    test "ticks at the beam cadence only while there is something to beam" do
      assert Page.beam_ms() == 200
      assert Page.refresh(loaded()) == Page.beam_ms()
      assert Page.refresh(loaded(%{})) == 333
      assert Page.refresh(on(loaded(), 1)) == 333
    end
  end

  describe "ticking" do
    test "a loaded page ticks to a map render can use" do
      ticked = Page.tick(loaded())

      assert is_map(ticked)
      assert is_list(Page.render(ticked))
    end
  end

  describe "beaming the profile" do
    test "the mask names what is beamed, not what is ticked" do
      Process.register(self(), Badge.Ir.Link)
      Page.tick(loaded(%{name: "Gus", company: "Protolux"}, [:name, :company, :email]))

      assert_receive {:"$gen_cast", {:transmit, payload}}
      assert Wire.decode(payload) == {:ok, :name, [:name, :company], "Gus"}
    end

    test "walks the cycle one frame a tick, name first, and wraps" do
      state = loaded(%{name: "Gus", company: "Protolux"}, [:name, :company])

      assert state.cycle == [{:name, "Gus"}, {:company, "Protolux"}]

      one = Page.tick(state)
      two = Page.tick(one)
      three = Page.tick(two)

      assert {one.next, two.next, three.next} == {1, 0, 1}
    end

    test "a field that is shared but empty is skipped" do
      assert loaded(%{name: "Gus"}, [:name, :company]).cycle == [{:name, "Gus"}]
    end

    test "any other screen, or the detail, never advances" do
      for screen <- [1, 2] do
        assert Page.tick(on(loaded(), screen)).next == 0
      end

      assert Page.tick(%{loaded() | mode: :detail}).next == 0
    end

    test "paging away resets the cycle, so returning starts from the name" do
      part_way = Page.tick(loaded(%{name: "Gus", company: "P"}, [:name, :company]))

      assert part_way.next == 1
      assert Page.tick(on(part_way, 1)).next == 0
    end

    test "nothing goes out without a name" do
      assert Page.tick(loaded(%{})).next == 0
    end
  end

  describe "hearing a badge" do
    defp name_frame(name, shared \\ [:name]), do: Wire.encode(:name, shared, name)

    test "a new badge is collected and reported, without writing to NVS" do
      {:ok, next} = Page.handle_ir(@other, name_frame("Pat"), loaded())

      assert next.met == {"Pat", :new}
      assert next.announced == {@other, "Pat"}
      assert Peers.find(next.peers, @other).profile == %{name: "Pat"}
      assert next.stored == []
    end

    test "a badge already collected is reported as known" do
      state = %{loaded() | peers: [%{id: @other, profile: %{name: "Pat"}}]}
      {:ok, next} = Page.handle_ir(@other, name_frame("Pat"), state)

      assert next.met == {"Pat", :known}
    end

    test "a badge under a new name is reported as updated" do
      state = %{loaded() | peers: [%{id: @other, profile: %{name: "Pat"}}]}
      {:ok, next} = Page.handle_ir(@other, name_frame("Patricia"), state)

      assert next.met == {"Patricia", :updated}
    end

    test "the same badge beaming its name again changes nothing but the quiet count" do
      {:ok, once} = Page.handle_ir(@other, name_frame("Pat"), loaded())
      {:ok, twice} = Page.handle_ir(@other, name_frame("Pat"), %{once | quiet: 3})

      assert twice == once
    end

    test "other fields fill the peer in silently" do
      {:ok, state} = Page.handle_ir(@other, name_frame("Pat", [:name, :company]), loaded())

      {:ok, next} =
        Page.handle_ir(@other, Wire.encode(:company, [:name, :company], "Protolux"), state)

      assert Peers.find(next.peers, @other).profile == %{name: "Pat", company: "Protolux"}
      assert next.met == state.met
    end

    test "a bare name from older firmware is a name" do
      {:ok, next} = Page.handle_ir(@other, "Pat", loaded())

      assert next.met == {"Pat", :new}
    end

    test "a frame that is not ours is dropped" do
      assert Page.handle_ir(@other, <<0, 1, "x">>, loaded()) == :ignore
    end

    test "our own frame reflected back is dropped" do
      assert Page.handle_ir(@me, name_frame("Gus"), loaded()) == :ignore
    end

    test "a badge heard on any other screen, in the detail, or without a name is dropped" do
      for state <- [on(loaded(), 1), on(loaded(), 2), %{loaded() | mode: :detail}, loaded(%{})] do
        assert Page.handle_ir(@other, name_frame("Pat"), state) == :ignore
      end
    end
  end

  describe "writing what was heard" do
    test "peers are held while the beam is busy" do
      {:ok, heard} = Page.handle_ir(@other, name_frame("Pat"), loaded())
      settling = heard |> Page.tick() |> Page.tick() |> Page.tick() |> Page.tick()

      assert settling.stored == []
      assert settling.quiet == 4
    end

    test "a frame resets the quiet count" do
      {:ok, heard} = Page.handle_ir(@other, name_frame("Pat"), loaded())
      {:ok, again} = Page.handle_ir(@other, name_frame("Pat"), Page.tick(Page.tick(heard)))

      assert again.quiet == 0
    end

    test "leaving before anything was read writes nothing" do
      assert Page.leave(Page.init()) == :ok
    end
  end

  describe "the sharing screen" do
    defp choosing(overrides \\ %{name: "Gus", company: "Protolux"}, shared \\ [:name]) do
      on(loaded(overrides, shared), 1)
    end

    test "lists every shareable field with a box, name ticked and nothing else" do
      bodies = texts(choosing())

      for key <- Sharing.fields(), do: assert(Profile.label(key) in bodies)
      refute Profile.label(:qr) in bodies
      assert Enum.count(bodies, &(&1 == "[x]")) == 1
      assert Enum.count(bodies, &(&1 == "[ ]")) == length(Sharing.fields()) - 1
    end

    test "shows each field's value, or a dash" do
      assert "Protolux" in texts(choosing())
      assert "-" in texts(choosing())
    end

    test "up and down move the cursor over the fields, without running off" do
      last = length(Sharing.fields()) - 1

      assert press(choosing(), {:move, :down}).cursor == 1
      assert press(choosing(), {:move, :down}, 20).cursor == last
      assert press(choosing(), {:move, :up}).cursor == 0
    end

    test "enter ticks a field, and again clears it" do
      ticked = choosing() |> press({:move, :down}) |> press({:edit, :newline})

      assert ticked.shared == [:name, :company]
      assert ticked.cycle == [{:name, "Gus"}, {:company, "Protolux"}]
      assert press(ticked, {:edit, :newline}).shared == [:name]
    end

    test "space and x toggle a field just as enter does" do
      for key <- [{:char, ?\s}, {:char, ?x}, {:char, ?X}] do
        ticked = choosing() |> press({:move, :down}) |> press(key)

        assert ticked.shared == [:name, :company], "#{inspect(key)} did not tick"
        assert press(ticked, key).shared == [:name], "#{inspect(key)} did not clear"
      end
    end

    test "other characters leave the fields alone" do
      assert Page.handle_key({:char, ?a}, press(choosing(), {:move, :down})) == :ignore
    end

    test "the name cannot be cleared" do
      assert press(choosing(), {:edit, :newline}).shared == [:name]
    end

    test "an empty field cannot be ticked" do
      pressed = choosing(%{name: "Gus"}) |> press({:move, :down}) |> press({:edit, :newline})

      assert pressed.shared == [:name]
      assert pressed.cycle == [{:name, "Gus"}]
    end

    test "a tick left on a field that has since been emptied can still be cleared" do
      cleared =
        choosing(%{name: "Gus"}, [:name, :company])
        |> press({:move, :down})
        |> press({:edit, :newline})

      assert cleared.shared == [:name]
    end

    test "the change is not written while the screen is showing" do
      ticked = choosing() |> press({:move, :down}) |> press({:edit, :newline})

      assert Page.tick(ticked).saved_shared == [:name]
    end

    test "paging away starts the cursor at the top again" do
      assert press(press(choosing(), {:move, :down}, 3), {:move, :right}).cursor == 0
    end

    test "the rows stay above the key hint" do
      for {:text, _x, y, _f, _c, _b, _body} <- Page.render(choosing()), do: assert(y <= 216)
    end
  end

  describe "the collected screen" do
    defp peer(n, name, extra \\ %{}) do
      %{id: <<0, 0, 0, 0, 0, n>>, profile: Map.merge(%{name: name}, extra)}
    end

    defp collected(peers), do: %{on(loaded(), 2) | peers: peers}

    defp with_peers(n), do: collected(for i <- 1..n, do: peer(i, "Badge #{i}"))

    defp images(state),
      do: for({:image, _x, _y, _bg, _img} = item <- Page.render(state), do: item)

    test "a name with no icons beside it is shown whole" do
      assert "Bartholomew Cubbins the Third" in texts(
               collected([peer(1, "Bartholomew Cubbins the Third")])
             )
    end

    test "a name beside every icon is cut to what fits" do
      everything = for key <- Sharing.fields(), key != :name, into: %{}, do: {key, "x"}
      state = collected([peer(1, "Bartholomew Cubbins the Third", everything)])

      assert "Bartholomew Cubbins t" in texts(state)
      refute "Bartholomew Cubbins the Third" in texts(state)
      assert length(images(state)) == 7
    end

    test "an empty collection says so" do
      assert says?(collected([]), "no badges yet")
    end

    test "names the badges collected, and counts them" do
      state = collected([peer(1, "Ada"), peer(2, "Grace")])

      assert "Ada" in texts(state)
      assert "Grace" in texts(state)
      assert says?(state, "Collected 2")
    end

    test "a badge's row carries one icon per field it shared" do
      assert length(images(collected([peer(1, "Ada", %{github: "ada", company: "Analytical"})]))) ==
               2

      assert images(collected([peer(1, "Ada")])) == []
    end

    test "a peer with no name still lists rather than blanking the row" do
      assert Profile.placeholder() in texts(
               collected([%{id: <<0, 0, 0, 0, 0, 9>>, profile: %{}}])
             )
    end

    test "shows only as many as fit, rather than overflowing" do
      for {:text, _x, y, _f, _c, _b, _body} <- Page.render(with_peers(40)), do: assert(y <= 216)
    end

    test "down moves the cursor and the window follows it" do
      state = press(with_peers(10), {:move, :down}, 7)

      assert state.cursor == 7
      assert state.top == 2
      assert "Badge 8" in texts(state)
      refute "Badge 1" in texts(state)
    end

    test "the cursor stops at both ends, and a short list never scrolls" do
      assert press(with_peers(10), {:move, :down}, 99).cursor == 9
      assert press(with_peers(10), {:move, :up}, 99).cursor == 0
      assert press(with_peers(3), {:move, :down}, 9).top == 0
    end

    test "up brings the window back with the cursor" do
      state = with_peers(10) |> press({:move, :down}, 9) |> press({:move, :up}, 9)

      assert state.top == 0
    end

    test "a long list says where you are in it" do
      assert says?(with_peers(10), "1-6 of 10")
      refute says?(with_peers(3), "of 3")
    end

    test "paging away starts the list at the top again" do
      assert press(press(with_peers(10), {:move, :down}, 8), {:move, :right}).top == 0
    end
  end

  describe "the detail" do
    defp opened(extra \\ %{}) do
      press(collected([peer(1, "Ada Lovelace", extra)]), {:edit, :newline})
    end

    test "enter on a row opens it, and escape comes back to the list" do
      state = opened()

      assert state.mode == :detail
      assert state.opened.profile.name == "Ada Lovelace"

      back = press(state, {:nav, :home})

      assert back.mode == :show
      assert back.screen == 2
      assert back.opened == nil
    end

    test "enter opens the row under the cursor" do
      state = press(press(with_peers(3), {:move, :down}), {:edit, :newline})

      assert state.opened.profile.name == "Badge 2"
    end

    test "enter on an empty list does nothing" do
      assert Page.handle_key({:edit, :newline}, collected([])) == :ignore
    end

    test "shows the name large, then what they shared with its icon" do
      state = opened(%{github: "ada", company: "Analytical Engines"})
      big = for {:text, _x, _y, :dogica, _c, _b, body} <- Page.render(state), do: body

      assert "Ada Lovelace" in big
      assert "ada" in texts(state)
      assert "Analytical Engines" in texts(state)
      assert length(images(state)) == 2
      assert says?(state, "Esc back")
    end

    test "the detail does not page, and has no dots" do
      state = opened()

      assert press(state, {:move, :right}).mode == :detail
      assert press(state, {:move, :right}).screen == 2
      refute Enum.any?(Page.render(state), &match?({:rect, _x, 228, 6, 6, _c}, &1))
    end
  end
end
