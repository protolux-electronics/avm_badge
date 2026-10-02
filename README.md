# Badge Firmware

Firmware for the AVM badge, an ESP32-S3 device with a 6x13 no-diode GPIO
keyboard matrix, a 320x240 ST7789 SPI display, and a 4-LED SK6812 chain. It
runs on [AtomVM](https://github.com/atomvm/AtomVM), an Erlang/Elixir VM for
microcontrollers, and is written in Elixir.

## Requirements

- **Elixir and Erlang/OTP** — Elixir 1.13 or newer. There are many ways to
  install them; a version manager is the least painful, since it pins the
  pair per project:
  [mise](https://mise.jdx.dev/lang/elixir.html) (`mise use erlang elixir`) or
  [asdf](https://asdf-vm.com/) (`asdf plugin add erlang && asdf plugin add
  elixir`) are both good choices

- **`curl`** — `mix badge.base` downloads the VM release with it. macOS and
  most Linux distributions already have it. Without `curl` it uses an
  authenticated [`gh`](https://cli.github.com/) instead (`brew install gh`
  on macOS, then `gh auth login`)

That is all. esptool is **not** needed: the flash tasks run it inside an
embedded Python through [Pythonx](https://hex.pm/packages/pythonx), which
downloads Python and esptool the first time a task needs them. ESP-IDF is
**not** needed to build or flash the firmware either — see
[Advanced](#advanced) for the two things that do want it.

## Getting started

Plug the badge in over USB, then:

    git clone https://github.com/protolux-electronics/avm_badge.git
    cd avm_badge
    mix deps.get
    mix badge.base             # once per board: bootloader, VM, boot.avm
    mix badge.assets --flash   # once per board: fonts, icons, splash logo
    mix atomvm.esp32.flash     # the firmware itself, every time

The first of these to flash downloads Python and esptool, so it needs a
network connection and takes a minute longer. Later runs reuse them.

The serial port is auto-detected, so do not pass `--port`. It appears as
`/dev/cu.usbmodem*` on macOS and `/dev/ttyACM*` on Linux, and the path changes
between sessions because the board re-enumerates. On Linux your user needs to
be in the `dialout` group (or your distribution's equivalent) to open it.

To watch it boot, open the console; the task resets the board and follows it
through the reset:

    mix atomvm.esp32.monitor --timeout 25

You should see the AtomVM banner, then `Badge: starting`, then the home grid
on the panel. The six shape keys open the pages; the arrows page the grid.

To get the badge online, open Settings (the diamond key), go to the WiFi tab,
pick a network and type its passphrase. The badge remembers it. The clock,
chat and Settings → Update all need a network.

`mix badge.assets --flash` writes the assets partition, which holds the extra
fonts, the splash logo and the rickroll frames. It is **not** updated over the
air, so run it again whenever anything under `assets/` changes — see
[Assets](#assets). A badge without it still boots and prints
`Badge: no assets partition:`, it just skips the splash.

Reflashing leaves NVS alone, so the profile, the badges you have collected and
the wifi credentials all survive.

### Games

On the second home screen, circle opens **Games**, using the same shape-key
grid as Home: square opens Connect Four, triangle Raycaster, cross Tamagoatchi.
Esc returns from a game to Games, then from Games to Home.

Tamagoatchi starts a newborn goat every visit; exiting discards it. Keep all
three meters high: square/F feeds (Hunger shows fullness), triangle/P plays,
cross/T trains, and circle/C cleans the poop. A meter left unattended for
60 seconds, or poop left for 60 seconds, kills the goat. It grows from newborn
to kid, young goat and adult goat; surviving five minutes wins. Enter starts a
new goat after a win or death. There is no background game or saved progress.

### Flashing a batch

    tools/flashstation.exs

takes over the terminal and flashes badges as they are plugged in, several
at a time. Each board gets a column: it is written in one go (base image,
assets, firmware), watched until the boot log says `Badge: starting`, then
the column turns green with a big OK or red with the error. Unplug it and
the column goes away. Unlike the mix tasks, the station runs a standalone
`esptool` on your `PATH`. If there is none, it installs one on the first run,
through `mise`, `brew` or `pipx`, whichever it finds. A C compiler is needed
once, for the `muontrap` wrapper that keeps every child process contained.
With `BADGE_NH_KEY`/`BADGE_NH_SECRET` or `AVM_BADGE_SERVER_URL` set and
ESP-IDF sourced, it provisions NVS as well.

### Without a board

    iex -S mix     # the firmware against fake hardware, panel at
                   # http://localhost:3240
    mix test       # the whole suite, on the host
    mix sim.check  # renders every page once, no browser

The simulator draws the badge itself: click its keys or type. On a wide
window a panel beside it shows the screen large, the log, or both. After
editing code, press **Reload and reboot** to recompile and restart the badge
on the new code, with no need to restart `iex`. A compile error shows in the
log and leaves the badge off until the next reload compiles.

## How it fits together

`Badge.start/0` opens the two SPI buses the board needs (panel and LED chain)
and starts a `Supervisor` with three children: `Badge.Screen` owns the AtomGL
display port and text buffer, `Badge.Keyboard` scans the matrix and dispatches
key events, and `Badge.Pixels` drives the LED chain and runs its idle
animation. See the moduledocs in `lib/badge/` for how each part works;
`lib/badge/hardware.ex` is the single source of truth for pin assignments.

## Testing

Pure modules (`Badge.TextBuffer`, `Badge.Keymap`, `Badge.Sharing`, the wire
formats) are tested on the host; anything that talks to GPIO, SPI or AtomGL is
verified on hardware instead. `mix test` needs no board.

## NervesHub

Over-the-air updates work out of the box: the badge product's shared secret is
compiled into `Badge.Update.Link`, so firmware you built yourself updates from
the same hub as everyone else's. Open Settings → Update to see it.

To point a badge at your own product instead, export your credentials and
provision them into NVS, where they override the built-in pair:

    export BADGE_NH_KEY=...
    export BADGE_NH_SECRET=...
    python3 tools/provision.py

## Chat server

Badges talk to `wss://badge-chat.protolux.io` unless told otherwise. To point
one at a server on your bench:

    export AVM_BADGE_SERVER_URL=ws://192.168.1.50:4000
    tools/provision.py

Give a base only — scheme, host and optional port. The scheme picks the
transport: `wss://` verifies against the public certificate authorities built
into the image, so a Let's Encrypt certificate needs no work on the badge;
`ws://` runs in the clear, which is what makes a local server reachable without
certificates or a tunnel. `mix phx.server` in `avm_badge_server` already
listens on `0.0.0.0:4000`.

## Flash layout

Partition table read back off the board (`esptool read_flash` +
`gen_esp32part.py`):

```
nvs         data  nvs      0x9000     24K
phy_init    data  phy      0xf000      4K
factory     app   factory  0x10000  1920K
boot.avm    data  phy      0x1f0000  544K
assets.avm  data  phy      0x278000  256K
main.avm    data  phy      0x2b8000  656K
alt.avm     data  phy      0x35c000  656K
```

This table is compiled into the AtomVM image. Changing it means a serial
reflash of every badge.

## Base image

The VM this firmware runs on is a fork of AtomVM, built and published by CI at
[protolux-electronics/AtomVM](https://github.com/protolux-electronics/AtomVM).
`BASE_IMAGE` names the release this firmware expects.

    mix badge.base            # bootloader, partition table, VM, boot.avm
    mix badge.base --vm-only  # just the VM and boot.avm

`boot.avm` holds the standard libraries the VM starts from. It is written
alongside the VM every time, because the two must come from the same build —
a VM with no matching `boot.avm` aborts at startup with `Invalid startup
avmpack` and reboots in a loop.

Both verify the download's SHA256 before flashing and raise on a mismatch.

Do not use `mix atomvm.esp32.install` on the badge: it erases the whole flash,
NVS included, and installs upstream AtomVM rather than this fork.

## Assets

Sources live in `assets/src/`. To regenerate:

    tools/mkfonts.sh                    # assets/fonts/*.uf
    python3 tools/icons.py              # assets/icons/*.rgba
    python3 tools/gif.py                # assets/rickroll/*.rgba
    mix badge.assets                    # packs assets.avm
    mix badge.assets --flash            # packs it and writes the partition

`assets.avm` is not updated over the air.

## Advanced

Two jobs need [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/):
provisioning NVS, and changing the VM itself. Everything else above works
without it.

Install it once (v5.5 or newer, matching the fork's CI), then source its
environment in any shell that needs it:

    git clone -b v5.5 --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf
    ~/esp/esp-idf/install.sh esp32s3
    . ~/esp/esp-idf/export.sh

### Provisioning NVS

`tools/provision.py` borrows three things from ESP-IDF: its NVS parser, to
read what the badge already holds, its NVS image generator, to write the
merged result back, and `esptool`, if none is on your `PATH`. The generator
and `esptool` live inside ESP-IDF's own virtualenv rather than on your `PATH`,
which is why sourcing `export.sh` (or just setting `IDF_PATH`) is enough — the
tool finds the right interpreter itself.

    python3 tools/provision.py --wifi-ssid MyNetwork      # prompts for the passphrase
    python3 tools/provision.py --dry-run                  # read and show the merge
    python3 tools/provision.py --forget-wifi              # drop the saved network

Every value comes from the first of: the flag, the environment variable, the
badge. Anything you do not pass is read off the badge and written back
unchanged, so provisioning one key never loses the others.

### Changing the VM

The VM, its AtomGL display driver and the websocket component are built from
the fork at
[protolux-electronics/AtomVM](https://github.com/protolux-electronics/AtomVM).
Its `src/platforms/esp32/BADGE-BUILD.md` documents how to reproduce a badge
build, which CMake flags this board needs, and how the AtomGL and websocket
submodules fit in. The upstream
[AtomVM documentation](https://www.atomvm.net/doc/main/) covers the VM's own
build system, packbeam format and NIF interface.

Once built, flash the VM at `0x10000` and `boot.avm` at `0x1F0000`; both must
come from the same build. The application at `0x2B8000` survives.
