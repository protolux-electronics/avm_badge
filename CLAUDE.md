# AtomVM badge firmware

Elixir firmware for an ESP32-S3 conference badge: ST7789 display via AtomGL,
6x13 GPIO keyboard matrix, SK6812 NeoPixels. Runs on AtomVM, not the BEAM.

## Commands

- `mix test` — 783 tests across 45 files, no board needed. 2 are excluded as
  `:regenerates_assets` because they rewrite tracked files
- `mix atomvm.esp32.flash` — builds, checks, flashes; port auto-detects, don't
  pass `--port`
- `ls /dev/cu.usbmodem*` on macOS or `ls /dev/ttyACM*` on Linux — the board
  re-enumerates, so its path changes between sessions
- Board resets after flashing, so chain flash and read to catch boot output;
  use `stty -f <port>` on macOS or `stty -F <port>` on Linux:
  `( mix atomvm.esp32.flash >/dev/null 2>&1; stty -F <port> 115200 raw -echo; timeout 25 cat <port> )`
- Never run unbounded `cat`/`screen` on the port — it blocks the next flash
- `Badge.Log` is the group leader of everything the badge spawns: each
  `io:format` line is echoed, kept for the Settings Log tab, and forwarded to
  the hub while the agent is up. ESP-IDF's own `I (…)` lines are not seen
- Reflashing does not need `erase-flash`: `nvs` is unchanged by the repartition,
  so wifi credentials, profile and peers survive
- No `flash-elixir` target in this AtomVM revision, and **`idf.py flash` does
  not write `boot.avm`** — the esp32 build emits no `.avm` at all and its
  `flash_args` covers only the bootloader, the VM and the partition table
- `boot.avm` comes from a **top-level** AtomVM build, not the esp32 one:
  `cmake -B build . && make -C build elixir_esp32boot` writes
  `build/libs/esp32boot/elixir_esp32boot.avm`. The plain `esp32boot` target
  omits `exavmlib` and cannot run this firmware
- Base image rebuild (rare): `. $IDF_PATH/export.sh; idf.py build` in
  `AtomVM/src/platforms/esp32`, then flash `0x10000` only — the app lives at
  `0x2B8000` and survives. Rebuild `elixir_esp32boot` alongside it and flash
  that at `0x1F0000`; the VM and its standard libraries should come from the
  same source. Reproducing the build is documented in
  `AtomVM/src/platforms/esp32/BADGE-BUILD.md`

## Flash layout

- `boot.avm` at `0x1F0000`, 544K, holds the standard libraries the VM starts
  from. It ships as a `badge-v1` release asset and `mix badge.base` writes it
  with the VM on both paths, so no local AtomVM checkout is needed. Without a
  valid one the VM aborts before any Elixir runs — `E AtomVM: Invalid startup
  avmpack` then `abort()`, rebooting about once a second
- Two packbeam slots: `main.avm` at `0x2B8000` and `alt.avm` at `0x35C000`, 656K
  each. NervesHub writes whichever one is not running and flips
  `atomvm`/`boot_path` in NVS
- `assets.avm` at `0x278000` holds the rickroll frames and the `.uf` fonts,
  mounted by `Badge.start/0`. `firmware/tools/flashassets.sh` packs it and
  writes it in one step, auto-detecting the port; it is **not** updated over the
  air. Run `firmware/tools/gif.py` first if the frames changed
- `python3 firmware/tools/check_partitions.py <partitions.csv> [label=path ...]`
  fails if an artifact outgrows its partition. `flashassets.sh` checks the
  assets partition itself
- If `assets.avm` is missing or unflashed, the badge boots normally and prints
  `Badge: no assets partition:` — but opening Sudo Mode kills the `Badge.UI`
  GenServer, which restarts and resets the page to Home. It does **not**
  crash-loop. What Sudo Mode should draw when frames are absent is a pending
  follow-up decision.
- `dogica` and `pixel_operator` are compiled into `main.avm`, so text survives a
  missing assets partition. `w95fa` is read from it on demand; a failed read
  logs `UI: font ~p not in assets partition` once and is not retried.

## Chat transport

- The chat rides a websocket from the `atomvm_websocket_client` ESP-IDF
  component; `Badge.Chat.Socket` wraps it, `Badge.Chat.Link` owns the port and
  `Badge.Chat.Link.State` holds every transition as plain data. The state
  machine is the only part that can be tested on the host, so put logic there
  and keep the GenServer a shell
- Two channels on one socket: `rooms:badge` for the room list, activity and
  the ban notice, and `chat:<slug>` for whichever room is entered. Both are
  joined with their own `join_ref`; **a rejoin must not reuse the old one** or
  Phoenix drops the channel's messages silently
- **Replies are dispatched by ref, not by topic.** A room carries both a join
  reply and a `new_msg` reply on the same topic. Matching on topic alone is
  why a banned badge used to post into silence
- A banned badge connects and joins `rooms:badge`, which answers with the
  reason and no room list. Ban and unban both disconnect the socket server-side
  so the reconnect picks the new state up
- Rooms carry a third wire key, `description` (admin-set, 80 characters), next
  to `slug` and `name`. `Badge.Page.Chat.Rooms` draws it, wrapped to two
  lines, under a rule at the bottom of the list — only for the highlighted
  room
- The room list scrolls: `offset` follows `selected` so it never runs off
  either end, and more rooms than fit between the heading and footer rules
  stay reachable
- The server is the `chat_url` NVS key, falling back to
  `wss://badge-chat.protolux.io` compiled into `Badge.Chat.Socket`. Write it
  with `tools/provision.py --chat-url ...` or `AVM_BADGE_SERVER_URL`. Store a
  base only (`scheme://host[:port]`) - the path and query are the module's
- **The scheme picks the transport.** `wss://` verifies against the ESP-IDF
  public CA bundle, which carries ISRG Root X1/X2, so Let's Encrypt needs
  nothing on the badge. `ws://` runs in the clear, which is how a server on the
  bench is reached: `mix phx.server` already binds `0.0.0.0:4000`, so point the
  badge at `ws://<lan-ip>:4000`. No tunnel and no certificates
- No CA is pinned any more. TLS 1.3 handshakes still take this hardware past
  the driver's ten second default, hence `network_timeout_ms`
- Match `{:websocket, _port, ...}` messages WITHOUT pinning the port: the
  driver's port term is not the one `open_port` returned, and a pinned match
  drops every message silently
- The socket opens only after `Wifi.status()` shows `synced: true` - at the
  epoch every certificate is "not yet valid"
- Both links are page-scoped: `Badge.Chat.Link` connects on entry to the chat
  page and disconnects on the way out, and `Badge.Update.Link` does the same for
  the Update tab. A badge on the home grid holds no socket. Entering chat
  therefore costs a handshake it used not to

## Firmware updates

- `Badge.Update.Link` owns the NervesHub agent; `Badge.Page.Settings.Update`
  only renders its `status/0` map. Updates and reboots are both `manual`, so
  nothing installs or restarts without a keypress
- Credentials are NVS keys `nh_key`, `nh_secret` and optional `nh_host` in the
  `:badge` namespace, written by `tools/provision.py`. It reads the partition,
  merges what you pass, and writes it back, so anything you do not pass is
  kept. Values come from a flag, else `BADGE_NH_KEY`-style env vars, else the
  badge. `--dry-run` reads and shows the merge without writing
- `provision.py` does not preserve ESP-IDF's own `nvs.net80211`, `phy` and
  `misc` namespaces; they rebuild on the next boot, costing one slower wifi
  connect while the PHY recalibrates
- **ExAtomVM writes no `priv/application.bin`**, and `firmware: boot` needs one.
  Without it the agent refuses to start and NervesHub cannot parse an upload.
  `mix atomvm.application_bin` writes it and is aliased onto `atomvm.packbeam`
  and `atomvm.esp32.flash`, which calls packbeam directly past the alias
- There is **no automatic rollback**. `:nh_ota.revert/0` is reached from the
  Update tab; firmware that will not boot needs a cable
- The agent commits a pending update when it joins, so opening the Update tab
  is what takes new firmware off trial
- The agent runs only while the Update tab is showing; elsewhere the badge is
  offline to NervesHub. The hub row names what blocks it
- `atomvm.check` flags `json:encode/1`, `json:decode/1` and
  `erlang:binary_part/3` falsely - AtomVM ships `libs/estdlib/src/json.erl`,
  and `binary_part/3` is both a BIF and a NIF in `libAtomVM`. `erlang:--/2`,
  `erlang:phash2/2`, `File`, `Mix` and `String` come from Mix tasks that are
  packed but never run. `GenServer`, `Supervisor`, `network` and `uart` are
  flagged from `lib/badge/` for the same reason: the checker cannot see
  AtomVM's own libraries
- **Internal RAM, not free heap, is the scarce resource.** `Power:` reports
  ~2MB free, which is almost all PSRAM; FreeRTOS task stacks and DMA buffers
  can only come from the ~300K of internal RAM. A websocket that cannot get it
  fails with `websocket_client: Error create websocket task` and the device
  panics. `CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL` in `sdkconfig.defaults.in` is
  what decides this: at 4096 the 1K chunk binaries a partition read produces
  were served from internal RAM and piled up as garbage AtomVM never collected,
  because its heap is in PSRAM. 512 leaves ~90K internal instead of ~30K
- Neither `esp32_free_heap_size` nor `esp32_largest_free_block` can see this -
  both report `MALLOC_CAP_DEFAULT`, which includes PSRAM. Measuring it needs
  `heap_caps_get_free_size(MALLOC_CAP_INTERNAL)` from C
- `Badge.Update.Link` reads flash and opens the socket in spawned processes,
  never in its own: `status/0` is called from the render loop, and a `call`
  queued behind a 671K hash or a TLS handshake stalls the page

## AtomVM is not the BEAM

- **No `String` module.** Only the `String.Chars` protocol. Text is charlists or
  binaries.
- **`Enum` is a subset.** No `with_index`, `take`, `drop`, `sort`, `zip`,
  `uniq`, `sum`, `max`, `min`. `count/1` exists; **`count/2` does not**. Use
  `:lists` (complete) for anything missing.
- **Module attributes run on the host compiler** — full Elixir is legal inside
  them; only runtime code is constrained.
- **`Process.send_after/3` costs ~6.6 ms per call** (spawns two processes plus a
  synchronous `gen_server:call` to a singleton). Loop with `Process.sleep/1` in
  a process that receives nothing else.
- **`:port.call/2` blocks** waiting for a reply even when the driver pre-acks.
- **FreeRTOS tick is 10 ms** (`CONFIG_FREERTOS_HZ=100`) — the floor for any
  sleep or timer.
- **SPI `peripheral:` must be a string** (`"spi2"`), not an atom, or
  `:spi.open/1` throws `{bardarg,...}`.
- **`:erlang.get/1` returns `:undefined`**, not `nil` — `||` defaults don't
  work.
- **Charlists cost 2 machine words per character.** Large ones in messages cause
  OOM reboots; prefer binaries.
- Use plain maps, not structs.
- `mix atomvm.check` is the real compatibility gate and runs during flash. Host
  tests passing proves nothing.

## Skins

- Colours, the title bar and rules come from a `Badge.Skin` module, read at
  render time through `Badge.Theme`. **Never capture a Theme colour in a
  module attribute** — it freezes the Dark palette into that module. Geometry
  (`width`, `height`, `bar_h`, `content_top`) is fixed and may be compile-time
- The active skin sits in the rendering process's dictionary: `Badge.UI.init`
  activates the one saved under the `skin` NVS key, and the Theme row on the
  Display tab switches it live and stores it once editing ends. Host tests
  see `Badge.Skin.Dark` unless they call `Badge.Skin.activate/1`
- Icons carry real alpha and AtomGL blends them onto the background colour the
  item names, so they sit on any skin. Monochrome icons are `.mask` files
  baked once per colour in `Badge.Icons.tints/0`; a skin's `glyph/0` picks one,
  and a new glyph colour must be added to that list or the icon draws nothing.
  No extra fonts are involved

## AtomGL display

- `{:update, list}` **repaints the entire screen** — no damage rect. Cost is per
  frame, not per change.
- Updates are pre-acked at enqueue; the render queue is 32 deep and drops
  oldest.
- Z-order is tail-to-head: background rect **last**, cursor **first**.
- `:default16px` (8x16) is the only built-in font.
- Rotation 3 needs AtomGL branch `led-modes` (`11be5f9`) in the base image.
  Without it the panel is **silently black** — no error anywhere in Elixir.

## Testing

- Pure modules (`Keymap`, `TextBuffer`, `KeyRepeat`) are host-tested; hardware
  modules are not.
- Warnings that `:spi`, `:port`, `:gpio`, `GPIO` are undefined are expected on
  host — not defects.
- `@impl true` goes on the **first clause only** of a multi-clause callback; a
  lint hook false-positives here.
- Visual and interactive behaviour (panel content, typing feel, LED colour)
  needs a human.
- Measure on hardware before optimising — several plausible theories were wrong
  this session.

## Conventions

- Commit subjects: capitalised, one line, no body, no `Co-Authored-By`.
- Comments: at most one line, local clarification only. No rationale, no
  measurements.
- Docstrings: may be multi-line but concise — how to use it, not why it was
  built that way.
- Design rationale lives in `../docs/` (outside this repo), not in code.
- Never discard uncommitted changes; report them instead.
- Always use the superpowers skills for brainstorming, writing plans, etc. But
  the superpower artifacts should not be committed to the repo
- Always use /i-have-adhd skill to format output to the user
