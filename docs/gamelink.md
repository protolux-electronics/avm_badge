# GameLink: multiplayer for badge pages

GameLink lets a page play with 2 to 8 badges nearby. Badges find each other
by pointing their IR beams, then talk over ESP-NOW, the ESP32's own
peer-to-peer radio. A page opens a session, sends payloads, and gets events
through one callback. It never sees an address, a transport or a retry.

## What it needs

- **A base image with the `espnow` port driver.** `badge-v1`, which
  `BASE_IMAGE` names today, has none. On it GameLink does nothing harmful: the
  page gets `{:waiting, :no_radio}`, and `hint/1` says "This badge needs a
  firmware update". Games work once a base image with the `atomvm_espnow`
  component is released and flashed.
- **Every badge on wifi, on the same channel.** ESP-NOW rides the wifi radio,
  so it can only reach badges tuned to the same channel. In practice that
  means the same network and, on a network with several access points, the
  same access point. The radio opens only while wifi is associated.
- **Line of sight to join.** Pointing one badge at another at close range
  carries the invitation. Once joined, badges play at radio range.

## Quick start

```elixir
GameLink.open("buzzer/1", 8)          # from tick/1: seek or host a session
GameLink.send(:all, <<1>>, :reliable) # from tick/1 or handle_link/2
GameLink.close()                      # from leave/1
```

Events arrive in `Badge.Page.handle_link/2`. `use Badge.Page` supplies a
default that ignores them all, so only a page that plays overrides it.

## API

| Call | What it does |
|---|---|
| `open(app_id, max_players, opts \\ [])` | Starts seeking a session for `app_id` (at most 15 bytes) with 2-8 players, host included. `opts` takes `needs: [:low_latency]` |
| `send(to, payload, mode \\ :latest)` | Sends to a slot (0-7) or `:all`. Payload at most 200 bytes; **byte 0 is your message type** |
| `lock()` | Host only: admit nobody new and stop advertising. Away members may still return |
| `close()` | Leaves the session. The host's close ends it for everyone |
| `max_payload()` | 200 |
| `hint(reason)` | The text to show for a `{:waiting, reason}`, at most 36 characters of code page 437 |

- All calls are casts and return `:ok`. A malformed `open/3` or `send/3`
  raises `ArgumentError`.
- **Call them from `tick/1`, `handle_link/2` or `leave/1`**, never from
  `init/0` or a key handler. They run inside `Badge.UI`, and `open/3` tags
  the session with the page on screen. A key handler sets a flag in the state;
  the next tick acts on it.
- Put a version in `app_id` (`"buzzer/1"`). Only badges with the same id meet,
  so a changed payload layout gets a new id.
- The player's name is the profile name, cut to 12 bytes; "Badge" if unset.
- Leaving the page ends the session: `Badge.UI` releases it on every page
  change, even when `leave/1` forgets to close.

## Events

```elixir
@callback handle_link(event, state) :: {:ok, state} | :ignore

{:waiting, reason}                          # show hint(reason); it resumes by itself
{:session, me :: slot, [{slot, name}]}      # you are in; slot 0 is the host
{:joined, slot, name}                       # a player joined or came back: reset that slot
{:left, slot, :bye | :timeout}              # left, or silent for 3 s (their slot is kept 60 s)
{:message, from :: slot, payload}
{:overflow, slot}                           # the reliable window to that slot is full; the send was refused
{:closed, :host_left | :reset}              # the session is over; open/3 again to play on
```

The page contract:

- Events arrive in order, only while your page is on screen, and only for the
  session your page opened.
- `reason` is opaque. Show `hint(reason)` and never branch on it; new reasons
  may appear.
- `{:joined, slot, _}` can repeat for a slot that timed out and came back.
  Treat it as a fresh player in that slot: the host should resend its state.
- `{:closed, :reset}` means GameLink restarted. Nothing of the session is
  left.
- **Payloads come from other badges and are untrusted.** Match exact binaries,
  guard every field, and return `:ignore` for anything else. A raise in
  `handle_link/2` is logged and sends the badge to Home, ending the session.

Hints the page may show:

| Reason | Hint |
|---|---|
| `:no_radio` | This badge needs a firmware update |
| `:other_no_radio` | Other badge needs a firmware update |
| `:no_wifi` | Join wifi to play (or "Join *network* to play" once the host's network is known) |
| `:other_no_wifi` | Other badge has no wifi |
| `:different_network` | Join the same wifi to play (or "Join *network* to play") |
| `:other_access_point` | Same wifi, other access point |
| `:unreachable`, `:searching` | Waiting for the other badges |
| `:full` / `:started` | Game is full / Game already started |
| `:update_needed` | One badge needs a firmware update |

## Delivery modes

| Game shape | Example | Mode |
|---|---|---|
| Real-time state | positions at 5-10 Hz: the newest wins, a lost one does not matter | `:latest` |
| Events and turns | "player 3 solved lock B": exactly once, in order | `:reliable` |

**`:latest`** is one frame, no resend. While your page is busy, only the newest
pending message per sender and message type (byte 0) is kept, so give each
kind of state its own type byte. At most 32 are held.

**`:reliable`** is delivered in order and exactly once per sender. Up to 16
messages per destination may be unacknowledged; a receiver acknowledges only
what its page has taken, so a stalled page slows its senders instead of
dropping. A send into a full window is refused with `{:overflow, slot}`.
Messages to a player who times out are dropped: resync on `{:joined, …}`.

## Limits

| Limit | Value |
|---|---|
| Players | 2-8, including the host |
| Payload | 200 bytes in either mode. Byte 0 is your message type |
| Send rate | `:latest` at most 30/(N-1) per second per badge: 30 at N=2, 10 at N=4, 4 at N=8. `send(:all)` counts once. The excess is dropped and logged |
| Real-time state | 5-10 Hz at N ≤ 4, 4 Hz at N = 8 |
| Reliable | 16 unacknowledged per destination |
| Delivery to the page | at most 16 events per batch, one batch per UI turn under load |
| Latency | about 5-8 ms one way on air, plus up to one UI turn |
| Liveness | a player silent for 3 s is `{:left, slot, :timeout}`; a host silent for 60 s is `{:closed, :host_left}` |
| Where to call | `tick/1`, `handle_link/2`, `leave/1` |
| Forbidden | calling `:espnow` yourself; branching on `reason` |

## Joining

1. Every badge that opens the same `app_id` beams an offer over IR every
   500 ms.
2. Point two badges at each other. Whichever hears the other's offer asks to
   join over ESP-NOW; the one asked becomes host (slot 0). IR is often
   one-way, and one direction is enough.
3. While the host admits, the host **and** every member beam the session, so
   a newcomer can point at any player. Admission is still the host's.
4. `lock/0` stops admitting. A late badge sees "Game already started".

Nothing else is needed from the page: a lobby is just a render of the
`{:session, …}`, `{:joined, …}` and `{:left, …}` events, with Enter on the host
(`me == 0`) to start.

When a badge is off wifi or on another channel, it keeps seeking and shows the
hint; it joins by itself once the networks agree. The host's offer carries its
network name, so the hint can say which one to join.

## Example: a buzzer

A complete page for up to 8 players. The host starts a round with Enter; the
first badge to press Space wins it, refereed by the host.

```elixir
defmodule Badge.Page.Buzzer do
  @moduledoc "A quiz buzzer for 2-8 badges: the first to press Space wins the round."

  use Badge.Page

  alias Badge.GameLink
  alias Badge.Text
  alias Badge.Theme

  # Byte 0 of every payload is the message type.
  @round 1
  @buzz 2
  @winner 3

  @impl true
  def title, do: "Buzzer"

  @impl true
  def init,
    do: %{open: false, me: nil, names: %{}, hint: "Point at a badge", winner: nil, out: nil}

  # GameLink is called from tick/1, never from init/0 or a key handler.
  @impl true
  def tick(%{open: false} = state) do
    GameLink.open("buzzer/1", 8)
    %{state | open: true}
  end

  def tick(%{out: :round} = state) do
    GameLink.lock()
    GameLink.send(:all, <<@round>>, :reliable)
    %{state | out: nil, winner: nil}
  end

  def tick(%{out: :buzz, me: 0} = state), do: win(%{state | out: nil}, 0)

  def tick(%{out: :buzz} = state) do
    GameLink.send(0, <<@buzz>>, :reliable)
    %{state | out: nil}
  end

  def tick(state), do: state

  @impl true
  def leave(_state), do: GameLink.close()

  @impl true
  def handle_key({:edit, :newline}, %{me: 0, names: names} = state) when map_size(names) >= 2,
    do: {:ok, %{state | out: :round}}

  def handle_key({:char, ?\s}, %{me: me, winner: nil} = state) when is_integer(me),
    do: {:ok, %{state | out: :buzz}}

  def handle_key(_event, _state), do: :ignore

  @impl true
  def handle_link({:session, me, members}, state),
    do: {:ok, %{state | me: me, names: :maps.from_list(members), hint: nil}}

  def handle_link({:joined, slot, name}, state),
    do: {:ok, %{state | names: :maps.put(slot, name, state.names)}}

  def handle_link({:left, slot, _why}, state),
    do: {:ok, %{state | names: :maps.remove(slot, state.names)}}

  def handle_link({:waiting, reason}, state), do: {:ok, %{state | hint: GameLink.hint(reason)}}
  def handle_link({:closed, _why}, _state), do: {:ok, init()}
  def handle_link({:message, 0, <<@round>>}, state), do: {:ok, %{state | winner: nil}}
  def handle_link({:message, from, <<@buzz>>}, %{me: 0} = state), do: {:ok, win(state, from)}

  def handle_link({:message, 0, <<@winner, slot>>}, state) when slot < 8,
    do: {:ok, %{state | winner: slot}}

  def handle_link(_event, _state), do: :ignore

  # The host referees: the first buzz it hears wins.
  defp win(%{winner: nil} = state, slot) do
    GameLink.send(:all, <<@winner, slot>>, :reliable)
    %{state | winner: slot}
  end

  defp win(state, _slot), do: state

  @impl true
  def render(state) do
    rows =
      :lists.map(
        fn {slot, name} -> line(70 + 18 * slot, name, Theme.dim()) end,
        :maps.to_list(state.names)
      )

    [line(40, status(state), Theme.fg()) | rows]
  end

  defp status(%{me: nil, hint: hint}), do: hint
  defp status(%{winner: nil, me: 0}), do: "Space: buzz  Enter: round"
  defp status(%{winner: nil}), do: "Space to buzz"
  defp status(state), do: :maps.get(state.winner, state.names, "?") <> " buzzed first"

  defp line(y, text, colour),
    do: {:text, 16, y, :default16px, colour, Theme.bg(), Text.cp437(text)}
end
```

To try it, add the module to `@pages` in `Badge.Pages`.

### Recommended pattern: an authoritative host

- Members send **inputs**: `:latest` for continuous input, `:reliable` for
  events.
- The host applies them and broadcasts **snapshots**: `:latest` at 5-10 Hz for
  motion, `:reliable` for milestones.
- On `{:joined, slot, _}` the host sends that slot a full `:reliable`
  snapshot.
- Keep state in plain maps and use `:maps`; see the AtomVM notes in
  `CLAUDE.md`.

## Testing

- **Host tests:** `Badge.GameLink.Switchboard` (in `sim/lib`) wires N
  `Badge.GameLink.State`s through a fake transport with no timers, so a test can
  open, point, tick and read each badge's events. See
  `sim/test/badge/game_link/switchboard_test.exs`.
- **The simulator** does not play yet. It does not start GameLink, so
  `open/3` does nothing there; `Badge.Sim.GameLink.Loopback` is a stub
  transport that sends nowhere.
- **On hardware:** `GAMELINK_PROBE=1 mix atomvm.esp32.flash` adds a bare
  probe page to the grid. On two badges it pairs, pings once a second and on
  Enter, and prints every event and the round trip as `Probe:` lines on the
  serial console. A normal build leaves it out.

## Troubleshooting

- **"This badge needs a firmware update"**: the base image has no `espnow`
  driver. The log shows `GameLink: no radio: …` once.
- **"Same wifi, other access point"**: the badges are on one network but
  different channels. Moving closer does not help, because a connected badge
  does not roam; reconnect wifi, or use a network with one access point.
- **Nothing happens when pointing**: the IR beam is short and narrow. Hold the
  badges close, facing each other.
- Every GameLink log line starts `GameLink:` and reaches the Settings Log tab.

## Security

Frames are not encrypted. Anyone in radio range with a stock badge can see
rosters and game data; they cannot join without the session token, which only
travels in the IR offer and in a unicast welcome, and a join is bound to the
sender's address. Accepted risks: custom firmware sniffing tokens or spoofing
an address, forged leave or roster frames, and jamming. Do not send anything
secret, and treat every payload as hostile input.
