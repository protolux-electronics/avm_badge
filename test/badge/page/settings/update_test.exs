defmodule Badge.Page.Settings.UpdateTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Settings
  alias Badge.Page.Settings.Update
  alias Badge.Theme

  defp status(overrides) do
    base = %{
      identifier: "90DA7247F804",
      state: :current,
      percent: 0,
      offer: nil,
      reason: nil,
      firmware: %{name: "badge", version: "0.1.0", sha: "a3f9c1e2"},
      slot: "main.avm",
      target: nil,
      trial: false
    }

    Map.merge(base, overrides)
  end

  defp page(overrides), do: %{Update.init() | status: status(overrides)}

  defp bodies(state) do
    for {:text, _x, _y, _f, _c, _b, body} <- Update.render(state), do: body
  end

  defp says?(state, text) do
    :lists.any(fn body -> :binary.match(body, text) != :nomatch end, bodies(state))
  end

  describe "identity" do
    test "names itself for the tab strip" do
      assert Update.title() == "Update"
    end

    test "starts with nothing known, so the first tick fills it in" do
      assert Update.init().status == nil
    end
  end

  describe "what the screen says" do
    test "before the first tick it says it is still looking" do
      assert says?(Update.init(), "connecting")
    end

    test "an unprovisioned badge says so rather than blaming the network" do
      assert says?(page(%{state: :unprovisioned}), "not provisioned")
    end

    test "waiting on the radio names the radio" do
      assert says?(page(%{state: :waiting}), "waiting for wifi")
    end

    test "up to date says so" do
      assert says?(page(%{state: :current}), "up to date")
    end

    test "an offer names the version" do
      assert says?(page(%{state: :offered, offer: "0.2.0"}), "0.2.0")
    end

    test "a download shows how far it has got" do
      assert says?(page(%{state: :downloading, percent: 45}), "45%")
    end

    test "a finished download names the slot it landed in" do
      assert says?(page(%{state: :ready, target: "alt.avm"}), "alt.avm")
    end

    test "a failure shows the reason, not just that it failed" do
      assert says?(page(%{state: :failed, reason: "checksum mismatch"}), "checksum mismatch")
    end

    test "the running firmware is shown whatever the link is doing" do
      assert says?(page(%{state: :waiting}), "0.1.0")
      assert says?(page(%{state: :waiting}), "a3f9c1e2")
    end

    test "firmware on trial says so" do
      assert says?(page(%{trial: true}), "on trial")
    end

    test "the hub identifier is shown whatever the link is doing" do
      assert says?(page(%{state: :waiting}), "90DA7247F804")
      assert says?(page(%{state: :failed, reason: "nope"}), "90DA7247F804")
    end

    test "an unknown identifier says so rather than going blank" do
      assert says?(page(%{identifier: nil}), "unknown")
    end

    test "waiting names what it is waiting for when the link knows" do
      assert says?(page(%{state: :waiting, reason: "wifi connecting"}), "wifi connecting")
    end

    test "a dropped socket shows why while it reconnects" do
      assert says?(page(%{state: :connecting, reason: "closed"}), "closed")
    end
  end

  describe "the progress bar" do
    test "is drawn only while downloading" do
      refute rects(page(%{state: :current})) != []
      assert rects(page(%{state: :downloading, percent: 45})) != []
    end

    test "fills in proportion, and never past the track" do
      [{fill, _}, {track, _}] = widths(page(%{state: :downloading, percent: 50}))

      assert fill == div(track, 2)
    end

    test "is empty at nothing and full at everything" do
      [{none, _}, {track, _}] = widths(page(%{state: :downloading, percent: 0}))
      [{all, _}, {^track, _}] = widths(page(%{state: :downloading, percent: 100}))

      assert none == 0
      assert all == track
    end
  end

  defp rects(state) do
    for {:rect, _x, _y, _w, _h, _c} = item <- Update.render(state), do: item
  end

  defp widths(state) do
    for {:rect, _x, _y, w, h, _c} <- rects(state), do: {w, h}
  end

  describe "the help line" do
    test "offers install only when there is something to install" do
      assert says?(page(%{state: :offered, offer: "0.2.0"}), "Enter install")
      refute says?(page(%{state: :current}), "Enter install")
    end

    test "offers reboot once an update has landed" do
      assert says?(page(%{state: :ready, target: "alt.avm"}), "Enter reboot")
    end

    test "offers revert only when there is a previous slot to go back to" do
      assert says?(page(%{trial: true}), "r revert")
      refute says?(page(%{trial: false}), "r revert")
    end

    test "says there is nothing to do rather than going blank" do
      assert says?(page(%{state: :waiting}), "nothing to do yet")
    end
  end

  describe "confirming" do
    test "Enter on a landed update asks before restarting" do
      {:ok, next} = Update.handle_key({:edit, :newline}, page(%{state: :ready}))

      assert next.confirm == :reboot
      assert says?(next, "Esc cancel")
    end

    test "r asks before reverting" do
      {:ok, next} = Update.handle_key({:char, ?r}, page(%{trial: true}))

      assert next.confirm == :revert
    end

    test "r does nothing when there is nothing to revert to" do
      assert Update.handle_key({:char, ?r}, page(%{trial: false})) == :ignore
    end

    test "escape leaves the confirm, not the page" do
      confirmed = %{page(%{state: :ready}) | confirm: :reboot}

      assert {:ok, %{confirm: nil}} = Update.handle_key({:nav, :home}, confirmed)
    end

    test "escape at rest is left alone, so the router still reaches home" do
      assert Update.handle_key({:nav, :home}, page(%{})) == :ignore
    end
  end

  describe "the carousel" do
    test "the arrows slide between tabs at rest" do
      assert Update.handle_key({:move, :left}, page(%{})) == :ignore
      assert Update.handle_key({:move, :right}, page(%{})) == :ignore
    end

    test "the arrows are swallowed while a confirm is up" do
      confirmed = %{page(%{state: :ready}) | confirm: :reboot}

      assert {:ok, ^confirmed} = Update.handle_key({:move, :left}, confirmed)
      assert {:ok, ^confirmed} = Update.handle_key({:move, :right}, confirmed)
    end
  end

  describe "drawing inside the lines" do
    test "every state fits the content area" do
      states = [
        Update.init(),
        page(%{state: :unprovisioned}),
        page(%{state: :waiting}),
        page(%{state: :connecting}),
        page(%{state: :current}),
        page(%{state: :offered, offer: "0.2.0"}),
        page(%{state: :downloading, percent: 45}),
        page(%{state: :ready, target: "alt.avm"}),
        page(%{state: :failed, reason: "a very long reason indeed, far too long"}),
        page(%{trial: true}),
        %{page(%{state: :ready}) | confirm: :reboot},
        %{page(%{trial: true}) | confirm: :revert},
        page(%{state: :waiting, reason: "a wait reason that runs on and on and on"})
      ]

      for state <- states do
        for {:text, x, y, _f, _c, _b, body} <- Update.render(state) do
          assert y >= Settings.content_top()
          assert y < Theme.height()
          assert x >= 0
          assert x + 8 * byte_size(body) <= Theme.width()
        end
      end
    end
  end
end
