# AtomVM badge firmware

Elixir firmware for an ESP32-S3 conference badge: ST7789 display via AtomGL,
6x13 GPIO keyboard matrix, SK6812 NeoPixels. Runs on AtomVM, not the BEAM.

Setup, flashing and the ESP-IDF workflow are in `README.md`.

## Commands

- `mix test` — the whole suite, no board needed. 2 tests are excluded as
  `:regenerates_assets` because they rewrite tracked files
- `mix atomvm.check` — the real compatibility gate, and it runs during flash.
  Host tests passing proves nothing
- `mix atomvm.esp32.flash` — builds, checks, flashes the `main.avm` partition
  it reads off the board. The port auto-detects; never pass `--port`
- The check's `warning: missing atomvm dependency` is expected: the standard
  library is the fork's `boot.avm`, and the `atomvm` package would pack a
  second copy into the 656K slot
- `mix atomvm.esp32.flash`, `mix badge.base` and `mix badge.assets --flash`
  run esptool through Pythonx (`ExAtomVM.EsptoolHelper`), which fetches
  Python and esptool on first use; nothing needs to be on PATH
- **Never run `mix atomvm.esp32.install` on the badge.** It erases the whole
  flash, NVS included, and installs upstream AtomVM. `mix badge.base` is the
  badge's equivalent
- `iex -S mix` — the firmware on fake hardware, panel at
  http://localhost:3240. `mix sim.check` renders every page once, headless
- Two mix targets: `:host` is the simulator (`sim/lib` plus
  `phoenix_playground`), `:badge` is the firmware (`lib` only). `mix.exs`
  picks `:badge` for any `atomvm.*` or `badge.*` task, so flashing needs no
  env var; anything else built for the badge wants `MIX_TARGET=badge`

## Working with the board

- **Opening the serial port resets the badge.** The S3's USB-serial-JTAG
  bridge resets the chip when the host asserts DTR/RTS, and clearing them
  first does not avoid it. A reader cannot watch a running badge, so
  `mix atomvm.esp32.monitor` resets it and shows the boot (see `README.md`)
- Never run unbounded `cat`/`screen` on the port, and give the monitor a
  `--timeout` — an open port blocks the next flash
- `Badge.Log` is the group leader of everything the badge spawns: each
  `io:format` line is echoed, kept for the Settings Log tab, and forwarded to
  the hub while the agent is up. ESP-IDF's own `I (…)` lines are not seen
- Reflashing never erases NVS, so wifi credentials, profile and peers survive

## Flash layout

- `boot.avm` at `0x1F0000` (544K) holds the standard libraries the VM starts
  from. Without a valid one the VM aborts before any Elixir runs — `E AtomVM:
  Invalid startup avmpack`, then a reboot loop
- Two packbeam slots: `main.avm` at `0x2B8000` and `alt.avm` at `0x35C000`,
  656K each. NervesHub writes whichever is not running and flips
  `atomvm`/`boot_path` in NVS
- `assets.avm` at `0x278000` holds the rickroll frames, the `.uf` fonts and
  the splash logo, mounted by `Badge.start/0`. `mix badge.assets --flash`
  packs and writes it; it is **not** updated over the air
- `python3 tools/check_partitions.py <partitions.csv> [label=path ...]` fails
  if an artifact outgrows its partition
- `mix badge.fits` refuses to flash a `main.avm`/`alt.avm` build over 656K
  (0xA4000 = 671,744 bytes); wired into `mix atomvm.esp32.flash`
- A missing assets partition is survivable: the badge boots, prints
  `Badge: no assets partition:` and skips the splash. `:atomvm.read_priv/2`
  answers `:undefined` rather than raising, so a guard that only catches will
  hand AtomGL `:undefined`
- `dogica` and `pixel_operator` are compiled into `main.avm`, so text survives
  a missing assets partition. `w95fa` is read from it on demand

## AtomVM is not the BEAM

- **No `String` module.** Only the `String.Chars` protocol. Text is charlists
  or binaries
- **`Enum` is a subset.** No `with_index`, `take`, `drop`, `sort`, `zip`,
  `uniq`, `sum`, `max`, `min`. `count/1` exists, `count/2` does not. Use
  `:lists` (complete) for anything missing
- **`x in list` compiles to `Enum.__in__/2`** and `atomvm.check` flags it; use
  `:lists.member/2` in runtime code
- **Module attributes run on the host compiler** — full Elixir is legal inside
  them; only runtime code is constrained
- **`Process.send_after/3` costs ~6.6 ms per call.** Loop with
  `Process.sleep/1` in a process that receives nothing else
- **`:erlang.get/1` returns `:undefined`**, not `nil` — `||` defaults do not
  work
- **No `:erlang.nodes/0`.** A node cannot list its own connections
- **Charlists cost 2 machine words per character.** Large ones in messages
  cause OOM reboots; prefer binaries
- **`:port.call/2` blocks** waiting for a reply even when the driver pre-acks
- **FreeRTOS tick is 10 ms** — the floor for any sleep or timer
- **SPI `peripheral:` must be a string** (`"spi2"`), not an atom
- Use plain maps, not structs
- `atomvm.check` is clean, so any entry it lists is real. `use GenServer`
  injects `handle_call/3` and `handle_cast/2` defaults that call
  `erlang:phash2/2`, which the check flags, so every GenServer defines both

## Performance on the badge

- **A process whose heap is mostly live collects on nearly every
  allocation**, and each collection copies the whole live heap. Keep large
  terms out of `Badge.UI`'s page state and out of any GenServer the render
  loop calls — hold them as `term_to_binary` entries, which live off-heap, and
  unpack only what a frame draws
- A `GenServer.call` from `Badge.UI` costs 20-40 ms, since the reply waits for
  a round of every other process. Poll once a minute, not per tick
- Integers past 2^27 are boxed on this 32-bit VM and every compare allocates
- **Internal RAM, not free heap, is the scarce resource.** `Power:` reports
  ~2MB free, which is almost all PSRAM; FreeRTOS task stacks and DMA buffers
  come from ~300K of internal RAM. A websocket that cannot get it fails with
  `websocket_client: Error create websocket task` and the device panics.
  `CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL` decides this, and neither
  `esp32_free_heap_size` nor `esp32_largest_free_block` can see it
- Measure on hardware before optimising; plausible theories have been wrong

## AtomGL display

- `{:update, list}` **repaints the entire screen** — no damage rect. Cost is
  per frame, not per change
- Updates are pre-acked at enqueue; the render queue is 32 deep, dropping
  oldest
- Z-order is tail-to-head: background rect **last**, cursor **first**
- `:default16px` (8x16) is the only built-in font: code page 437, drawn a byte
  per glyph. Fold text with `Badge.Text.cp437/1` first, or UTF-8 above ASCII
  comes out as box-drawing garbage
- Rotation 3 needs AtomGL branch `led-modes` in the base image. Without it the
  panel is **silently black** — no error anywhere in Elixir

## Skins

- Colours, the title bar and rules come from a `Badge.Skin` module, read
  through `Badge.Theme` **at render time**. Never capture a Theme colour in a
  module attribute — it freezes the Dark palette into that module. Geometry
  (`width`, `height`, `bar_h`, `content_top`) is fixed and may be compile-time
- The active skin lives in the rendering process's dictionary. Host tests see
  `Badge.Skin.Dark` unless they call `Badge.Skin.activate/1`
- Monochrome icons are `.mask` files baked once per colour in
  `Badge.Icons.tints/0`; a skin's `glyph/0` picks one, and a new glyph colour
  must be added to that list or the icon draws nothing

## Pages

- A page is a `Badge.Page` behaviour module listed in `Badge.Pages`, opened by
  a shape key from the home grid. `init/0` is pure; hardware is touched only
  from `tick/1`, `leave/1` and `handle_ir/3`, never from a key handler
- **A dying page GenServer kills `Badge.UI` silently** — the badge drops back
  to Home and AtomVM prints nothing. An unmatched clause on a callback, or a
  `call` to a process that has exited, is enough
- A page ends itself by returning `{:goto, page}` from `tick/1`
- **Shape keys are not global.** Every key reaches the page on screen first,
  and one it ignores goes nowhere; only `Badge.Page.Home` turns a shape key
  into navigation, by storing the module and returning `{:goto, _}` from its
  own `tick/1`. Escape (`{:nav, :home}`) is the one key `Badge.UI` answers
  itself, and only when the page ignored it, so a page can spend it backing
  out a level

## Sharing

- `Badge.Page.Share` beams the profile over IR while its first screen shows
  and records what it hears. `Badge.Sharing` holds the share set (NVS key
  `share`, field names joined by spaces, name always in it) and
  `Badge.Sharing.Wire` the frame: `<tag> <mask> <value>`, one field per
  frame, tags below 0x20 so a bare name from older firmware still decodes
- One frame every 200 ms: 2400 baud carries 240 bytes/s and the longest frame
  is 44 bytes on the wire. **The beam is full duplex**; no quiet time is
  needed to hear the other badge
- Peers are written a second after the last frame and on leaving the page. The
  list caps at 32 entries *and* 4 kB, because the blob must fit one NVS page;
  a failed write is logged, never raised
- Page tests never write NVS — that would exit the test process.
  `sim/test/badge/sim/share_nvs_test.exs` starts `Badge.Sim.Nvs` and covers
  the writes

## Chat transport

- The chat rides a websocket from the `atomvm_websocket_client` ESP-IDF
  component. `Badge.Chat.Link.State` holds every transition as plain data and
  is the only part testable on the host, so put logic there and keep the
  GenServer a shell
- Two channels on one socket: `rooms:badge` and `chat:<slug>`. Each is joined
  with its own `join_ref`; **a rejoin must not reuse the old one** or Phoenix
  drops the channel's messages silently
- **Replies are dispatched by ref, not by topic** — a room carries both a join
  reply and a `new_msg` reply on the same topic
- Match `{:websocket, _port, ...}` **without pinning the port**: the driver's
  port term is not the one `open_port` returned, and a pinned match drops
  every message silently
- The socket opens only after `Wifi.status()` shows `synced: true` — at the
  epoch every certificate is "not yet valid"
- The server is the `chat_url` NVS key, falling back to
  `wss://badge-chat.protolux.io`. The scheme picks the transport: `wss://`
  verifies against the ESP-IDF CA bundle, `ws://` runs in the clear for a
  server on the bench
- `Badge.Chat.Link` and `Badge.Update.Link` are page-scoped: they connect on
  entry and disconnect on the way out

## Clustering

- `Badge.Page.Cluster` joins the badge to an Erlang cluster; the node stays up
  after the page is left, unlike the other links. The node is `badge@<ip>`, a
  long name, and the cookie is the `dist_cookie` NVS key
- The app starts `epmd` itself: `net_kernel_sup` starts `erl_epmd`, the
  *client*, so without `epmd:start_link/1` nothing answers which port the node
  is on
- **`Badge.Cluster.Link` must trap exits** — `epmd:start_link/1` links epmd to
  its caller, so epmd dying would take the Link, and the Link down kills
  `Badge.UI`
- `rpc` from OTP into AtomVM works, as do message passing, monitors and group
  leader IO. There is no TLS, no `global`, no `pg`, and `iex --remsh` does not
  work (it needs `erpc`). Drive it from a local `iex` holding
  `tools/cluster.exs`

## Schedule

- The programme is **compiled in**: `assets/schedule.json` is parsed on the
  host and packed into `Badge.Schedule.Link`. Nothing is parsed on the device.
  `mix badge.schedule` refreshes the file; commit it and flash
- Times are Swedish local, converted through `Badge.Zone` for
  `Europe/Stockholm`, not the badge's own zone. A clock before 2024 is unset
- **The over-the-air refresh is off (`@fetch false`)**: this VM's `:ssl` does
  not survive a handshake to goatmire.com — `verify_peer` corrupts the heap
  right after certificate validation, `verify_none` spins the task watchdog.
  The chat's TLS is unaffected: it runs in the websocket component's own task,
  not through `otp_ssl`. Fix in the VM, then flip the attribute
- **`ssl:recv/2` with a length blocks until exactly that many bytes arrive**,
  so a read loop asking for 4096 hangs on the response's last piece; read with
  length 0

## Firmware updates

- `Badge.Update.Link` owns the NervesHub agent and runs only while the Update
  tab shows; elsewhere the badge is offline to NervesHub. Updates and reboots
  are both `manual`, so nothing installs without a keypress
- The product's shared secret is **compiled into `Badge.Update.Link`**, so a
  badge flashed from a clone updates itself with no provisioning. NVS keys
  `nh_key`, `nh_secret` and optional `nh_host` override it per badge, written
  by `tools/provision.py`. The repo is public, so rotating the credential in
  NervesHub is the only way to withdraw it
- **ExAtomVM writes no `priv/application.bin`**, and `firmware: boot` needs
  one. `mix atomvm.application_bin` writes it and is aliased onto
  `atomvm.packbeam` and `atomvm.esp32.flash`
- There is **no automatic rollback**. `:nh_ota.revert/0` is on the Update tab;
  firmware that will not boot needs a cable
- The agent commits a pending update when it joins, so opening the Update tab
  is what takes new firmware off trial
- `Badge.Update.Link` reads flash and opens its socket in spawned processes,
  never its own: `status/0` is called from the render loop

## Provisioning

- `tools/provision.py` is the only provisioning tool: wifi, NervesHub, the
  chat URL and the UTC offset. It reads the badge's NVS, merges what you pass
  and writes it back, so anything you do not pass is kept. `--dry-run` shows
  the merge, `--forget-wifi` drops the saved network alone
- It needs ESP-IDF for the NVS parser and image generator. The generator lives
  inside IDF's own virtualenv, so the tool finds that interpreter itself
- `provision.py` still shells out to esptool: `esptool`, then `esptool.py`,
  then `python3 -m esptool`, then IDF's own virtualenv. A Homebrew esptool has
  its own private Python, so the module forms come last
- ESP-IDF's own `nvs.net80211`, `phy` and `misc` namespaces are not preserved;
  they rebuild on the next boot, costing one slower wifi connect

## Testing

- Pure modules are host-tested; hardware modules are not. Visual and
  interactive behaviour (panel content, typing feel, LED colour) needs a human
- AtomVM-only modules (`:spi`, `:port`, `GPIO`, `I2C`, …) go in a
  `@compile {:no_warn_undefined, ...}` in each file that calls them; a new
  caller adds the module there
- `@impl true` goes on the **first clause only** of a multi-clause callback; a
  lint hook false-positives here
- Light sleep is refused on USB power because it kills the serial port. To
  test it, flip `Badge.Sleep.allowed?/1` locally, read the Log tab, and replug
  before the next flash

## Conventions

- Commit messages: one line, capitalised, at most 50 characters, no body, no
  trailers of any kind (no `Co-Authored-By`)
- Comments: at most one line, local clarification only. No rationale, no
  measurements
- Docstrings: multi-line is fine, but concise — how to use it, not why it was
  built that way
- Design rationale lives in `../docs/`, not in code
- Never discard uncommitted changes; report them instead
- Use the superpowers skills for brainstorming and plans, but never commit
  their artifacts
- Use the i-have-adhd skill to format output to the user
