# AtomVM badge firmware

Elixir firmware for an ESP32-S3 conference badge: ST7789 display via AtomGL,
6x13 GPIO keyboard matrix, SK6812 NeoPixels. Runs on AtomVM, not the BEAM.

## Commands

- `mix test` — 1090 tests across 60 files, no board needed. 2 are excluded as
  `:regenerates_assets` because they rewrite tracked files
- `mix atomvm.esp32.flash` — builds, checks, flashes; port auto-detects, don't
  pass `--port`
- `ls /dev/cu.usbmodem*` on macOS or `ls /dev/ttyACM*` on Linux — the board
  re-enumerates, so its path changes between sessions
- Board resets after flashing, so chain flash and read to catch boot output;
  use `stty -f <port>` on macOS or `stty -F <port>` on Linux:
  `( mix atomvm.esp32.flash >/dev/null 2>&1; stty -F <port> 115200 raw -echo; timeout 25 cat <port> )`
- Never run unbounded `cat`/`screen` on the port — it blocks the next flash
- **Opening the port resets the badge.** The S3's USB-serial-JTAG bridge
  resets the chip when the host asserts DTR/RTS, which pyserial does on open
  and clearing them first does not avoid. A reader cannot watch a running
  badge; it has to hold the port open from boot
- `Badge.Log` is the group leader of everything the badge spawns: each
  `io:format` line is echoed, kept for the Settings Log tab, and forwarded to
  the hub while the agent is up. ESP-IDF's own `I (…)` lines are not seen.
  Without `:console`, as on the host, the echo goes to the console the log
  was started under, and the simulator captures the same way
- `iex -S mix` runs the firmware on the host: the pages run against fake
  hardware processes and draw on a canvas at http://localhost:3240, and the
  shell says so on start. `mix sim.check` renders every page once without a
  browser, and `mix test` includes `sim/test`
- Two mix targets: the default `:host` is the simulator, `Badge.Sim.*` in
  `sim/lib` plus the `phoenix_playground` dep; `:badge` is the firmware, `lib`
  only. `mix.exs` picks `:badge` for any `atomvm.*` or `badge.*` task when
  `MIX_TARGET` is unset, so flashing needs no env var. Anything else built for
  the badge, such as `mix test` without the sim, wants `MIX_TARGET=badge`
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
- `assets.avm` at `0x278000` holds the rickroll frames, the `.uf` fonts and
  the splash logo, mounted by `Badge.start/0`. `firmware/tools/flashassets.sh` packs it and
  writes it in one step, auto-detecting the port; it is **not** updated over the
  air. Run `firmware/tools/gif.py` first if the frames changed
- `python3 firmware/tools/check_partitions.py <partitions.csv> [label=path ...]`
  fails if an artifact outgrows its partition. `flashassets.sh` checks the
  assets partition itself
- If `assets.avm` is missing or unflashed, the badge boots normally and prints
  `Badge: no assets partition:` — but opening Sudo Mode kills the `Badge.UI`
  GenServer, which restarts and resets the page to Home. It does **not**
  crash-loop. What Sudo Mode should draw when frames are absent is a pending
  follow-up decision. The splash is skipped instead: `Splash: no logo in
  assets partition` is printed once and the badge boots to Home
- `:atomvm.read_priv/2` returns `:undefined` for a missing file or partition;
  it does not raise. A guard that only catches will hand AtomGL `:undefined`
- The boot splash is `Badge.Page.Splash`, drawing `Badge.Logo` from
  `assets/logo` (regenerate with `tools/logo.py`); it is skipped on a wake from
  deep sleep. A page ends itself by returning `{:goto, page}` from `tick/1`
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

<<<<<<< HEAD
## Clustering

- `Badge.Page.Cluster` joins the badge to an Erlang cluster over wifi, and
  `Badge.Cluster.Link` owns it. S joins, S again leaves, Enter edits the
  cookie. Unlike the chat and update links it is **not page-scoped**: the node
  stays up after the page is left, since a badge that only clustered while its
  own page showed could not be driven from anywhere
- The node is `badge@<ip>`, a long name, because nothing resolves a badge by
  name. A new lease renames it and the host reconnects
- The cookie is the `dist_cookie` NVS key, falling back to `goatmire` compiled
  into `Badge.Cluster.Link`. The page shows it, so a host can read it off the
  panel, and editing it to empty forgets the key rather than clustering on no
  secret. The link holds it in state: `status/0` runs in the render loop and
  must not read flash
- The app starts `epmd` itself. `net_kernel_sup` starts **`erl_epmd`, the
  client**, not the local epmd server, so without `epmd:start_link/1` there is
  nothing for a host to ask which port the node is on
- **`Badge.Cluster.Link` must trap exits.** `epmd:start_link/1` links epmd to
  whoever called it, so epmd dying takes the Link with it, and the Link dying
  fails the `status/0` call the render loop makes, which kills `Badge.UI`. The
  badge silently drops back to Home and nothing is printed: AtomVM reports no
  crash for a dying GenServer
- Peers on the page are hosts that called `Badge.Cluster.Remote.hello/1`, not
  a live connection list, because there is no `:erlang.nodes/0`
- `Badge.Cluster.Remote` is the control surface a host drives over
  `:rpc.call/4`: keys go in through `Badge.UI.key_event/1`, the same door the
  matrix uses. `tools/cluster.exs` is the host side of it
- `rpc` from OTP into AtomVM works, as do message passing, monitors and group
  leader IO. There is no TLS, no `global` and no `pg`
- `iex --remsh` does **not** work: it starts the shell over `erpc`, and the
  badge has neither `erpc` nor `IEx`. Drive it from a local `iex` holding
  `tools/cluster.exs` instead
- The cookie is the only thing guarding the node, and rpc runs anything, so
  joining is a keypress on the badge rather than something it does at boot
=======
## Schedule

- `Badge.Page.Schedule` walks the programme from `https://goatmire.com/schedule.json`
  as one timeline: the open session sits between two rules, Up and Down open
  the neighbours, and Esc returns to now before it goes Home
- `Badge.Schedule` is pure apart from `fetch/0`; `Badge.Schedule.Link` keeps the
  fetched programme across page entries and refetches after 30 minutes, with
  `Badge.Schedule.Link.State` holding the transitions as data. `status/0`
  carries no sessions; the page asks for them only when `version` changes
- The site's times are Swedish local time, so `Schedule.now/1` converts UTC
  through `Badge.Zone` for `Europe/Stockholm`, not the badge's own zone
- The fetch is plain `:ahttp_client` over `:ssl` with `verify: :verify_peer`,
  which the fork's `ssl.erl` maps onto the ESP-IDF CA bundle. It waits for a
  system clock past 2024 rather than for `Wifi.status()`, since SNTP is what
  moves the clock. `:ssl.start/0` is called first; it is idempotent
- `atomvm.check` also flags `lists:keysort/2` and `lists:flatmap/2` falsely;
  both are in the fork's `lists.erl`
- `test/fixtures/schedule.json` is the site's answer captured on 2026-09-16
>>>>>>> 367a8c5 (Add a Schedule page that walks the programme from goatmire.com)

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
- **No `:erlang.nodes/0`.** It is not a BIF here and calling it only logs
  `function erlang:nodes/0 cannot be resolved` before the caller dies. A node
  cannot list its own connections: `net_kernel:get_state/0` reports the name
  and nothing else, and its `connections` map never leaves the process.
- **`x in list` compiles to `Enum.__in__/2`** on Elixir 1.20 and
  `atomvm.check` flags it; use `:lists.member/2` in runtime code.
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
- AtomVM-only modules (`:spi`, `:port`, `GPIO`, `I2C`, …) are listed in a
  `@compile {:no_warn_undefined, ...}` in each file that calls them, so a host
  compile is warning-free; a new caller adds the module there
- `@impl true` goes on the **first clause only** of a multi-clause callback; a
  lint hook false-positives here.
- Visual and interactive behaviour (panel content, typing feel, LED colour)
  needs a human.
- Measure on hardware before optimising — several plausible theories were wrong
  this session.
- Light sleep (`Badge.Sleep`, 30 s after the screen blanks) is refused on USB
  power because it kills the USB serial port: nothing prints until the badge
  is unplugged and replugged, and `esptool` cannot reset it. To test it,
  flip `Badge.Sleep.allowed?/1` locally, read the outcome from the Log tab,
  and replug before the next flash. `esp_light_sleep_start` switches every
  pad to its sleep configuration, which AtomVM never sets; the matrix pads
  are held (`GPIO.hold_en/1`) across the sleep so a key can still pull a
  column low

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
