defmodule Badge.Sim.Fakes do
  @moduledoc "External services and input processes that do not run on the host."

  alias Badge.Bluesky
  alias Badge.Chat.Link.State
  alias Badge.Page
  alias Badge.Sim.Fake

  @feed ~s({"feed":[) <>
          ~s({"post":{"uri":"at://did:plc:sim/app.bsky.feed.post/1","author":{"handle":"goatmire.bsky.social","displayName":"Goatmire"},) <>
          ~s("record":{"text":"Badges are flashed and the goats are restless. See you in Varberg! #goatmire",) <>
          ~s("createdAt":"2026-09-28T09:12:00.000Z"},"likeCount":42,"repostCount":7,"replyCount":3}},) <>
          ~s({"post":{"uri":"at://did:plc:sim/app.bsky.feed.post/2","author":{"handle":"lawik.bsky.social","displayName":"Lars Wikman"},) <>
          ~s("record":{"text":"The schedule is up.\\n\\nTwo days of Elixir by the sea.",) <>
          ~s("createdAt":"2026-09-27T16:40:00.000Z"},"likeCount":18,"repostCount":4,"replyCount":1},) <>
          ~s("reason":{"$type":"app.bsky.feed.defs#reasonRepost"}},) <>
          ~s({"post":{"uri":"at://did:plc:sim/app.bsky.feed.post/3","author":{"handle":"goatmire.bsky.social","displayName":"Goatmire"},) <>
          ~s("record":{"text":"Tickets for the workshops are nearly gone.",) <>
          ~s("createdAt":"2026-09-25T08:00:00.000Z"},"likeCount":9,"repostCount":1,"replyCount":0}}]})

  @feeds [
    %{kind: :timeline, uri: nil, name: "Following"},
    %{kind: :feed, uri: "at://did:plc:sim/app.bsky.feed.generator/whats-hot", name: "Discover"},
    %{kind: :feed, uri: "at://did:plc:sim/app.bsky.feed.generator/elixir", name: "Elixir"},
    %{kind: :list, uri: "at://did:plc:sim/app.bsky.graph.list/goats", name: "Goatmire folks"}
  ]

  def children do
    [
      fake(
        Badge.Wifi,
        fn
          :status, d ->
            %{
              radio: Map.get(d, :radio, :connected),
              ip: Map.get(d, :ip, "192.168.1.42"),
              ssid: Map.get(d, :ssid, "SimNet"),
              synced: true,
              offset: 120,
              zone: "Europe/Stockholm",
              scanning: false,
              scan_id: Map.get(d, :scan_id, 0)
            }

          :networks, _ ->
            [
              %{ssid: "SimNet", rssi: -48, authmode: :wpa2_psk},
              %{ssid: "Kontoret", rssi: -61, authmode: :wpa2_psk},
              %{ssid: "Open Sesame", rssi: -70, authmode: :open}
            ]
        end,
        fn
          :scan, d -> Map.update(d, :scan_id, 1, &(&1 + 1))
          {:connect, ssid, _psk}, d -> Map.merge(d, %{radio: :connected, ssid: ssid})
          :forget, d -> Map.merge(d, %{radio: :disabled, ssid: nil})
          _, d -> d
        end
      ),
      fake(Badge.Keyboard, fn {:holding?, _label}, _ -> false end),
      fake(Badge.Update.Link, fn :status, _ ->
        %{
          identifier: "90DA72000001",
          state: :current,
          percent: 0,
          offer: nil,
          reason: nil,
          firmware: %{name: "avm_badge", version: "sim", sha: "deadbeef"},
          slot: "main.avm",
          target: nil,
          trial: false
        }
      end),
      fake(Badge.Chat.Link, fn :status, _ -> State.status(State.new("ws://sim")) end),
      fake(
        Badge.Bluesky.Link,
        fn
          :status, d ->
            password = Map.get(d, :password)
            default = if password, do: {:timeline, nil}, else: {:author, Map.get(d, :actor)}

            %{
              state: :ready,
              actor: Map.get(d, :actor),
              account: password != nil,
              feed: Map.get(d, :feed, default),
              reason: nil,
              version: Map.get(d, :version, 1),
              count: 3,
              more: false,
              append: false,
              post: Map.get(d, :post, :none)
            }

          :posts, _ ->
            {:ok, posts} = Bluesky.parse(@feed, Page.Bluesky.columns())
            Bluesky.pack(posts)

          :feeds, d ->
            if Map.get(d, :password), do: Bluesky.pack(@feeds), else: {}
        end,
        fn
          {:open, actor, password}, d ->
            Map.merge(d, %{actor: actor, password: password})

          {:post, _text}, d ->
            Map.put(d, :post, {:ok, "at://did:plc:sim/app.bsky.feed.post/sim"})

          {:select, key}, d ->
            Map.merge(d, %{feed: key, version: Map.get(d, :version, 1) + 1})

          {:open_thread, uri}, d ->
            Map.merge(d, %{
              feed: {:thread, uri},
              back: Map.get(d, :feed),
              version: Map.get(d, :version, 1) + 1
            })

          :close_thread, d ->
            d
            |> Map.put(:version, Map.get(d, :version, 1) + 1)
            |> then(
              &if(Map.get(d, :back), do: Map.put(&1, :feed, d.back), else: Map.delete(&1, :feed))
            )

          _, d ->
            d
        end
      ),
      fake(
        Badge.Cluster.Link,
        fn :status, d ->
          %{
            state: Map.get(d, :state, :off),
            node: Map.get(d, :node),
            cookie: Map.get(d, :cookie, "goatmire"),
            ip: "192.168.1.42",
            peers: Map.get(d, :peers, []),
            reason: nil
          }
        end,
        fn
          :open, d -> Map.merge(d, %{state: :up, node: "badge@192.168.1.42", peers: ["host@sim"]})
          :close, d -> Map.merge(d, %{state: :off, node: nil, peers: []})
          {:cookie, ""}, d -> Map.put(d, :cookie, "goatmire")
          {:cookie, value}, d -> Map.put(d, :cookie, value)
          _, d -> d
        end
      ),
      fake(Badge.Ir.Link, fn _, _ -> :ok end)
    ]
  end

  defp fake(name, calls, casts \\ fn _msg, data -> data end) do
    %{id: name, start: {Fake, :start_link, [{name, calls, casts}]}}
  end
end
