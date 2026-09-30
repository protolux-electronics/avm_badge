# Building atomvm_ble_hid into the badge's AtomVM fork

The fork is [protolux-electronics/AtomVM](https://github.com/protolux-electronics/AtomVM).
The lines below are not on its `main` yet: they are committed on a local fork
branch `ble-hid` (on top of `main` at `d5a1dc3`), which is what was built and
measured. The fork's `src/platforms/esp32/BADGE-BUILD.md` covers the build as
a whole. ESP-IDF picks up any component under `src/platforms/esp32/components/`,
so the work is: put the component there, switch Bluetooth on in
`sdkconfig.defaults.in`, rebuild the VM, and flash it with a `boot.avm` from
the same checkout.

## 1. Put the component in the fork

The AtomGL and websocket components are submodules of their own repositories.
This one lives in `avm_badge/components/atomvm_ble_hid`, so give it the same
shape by splitting it out into its own repository (once, and again whenever
it changes):

    cd avm_badge
    git subtree split --prefix=components/atomvm_ble_hid -b atomvm_ble_hid
    git push git@github.com:protolux-electronics/atomvm_ble_hid.git atomvm_ble_hid:main

then, in the fork:

    git submodule add -b main https://github.com/protolux-electronics/atomvm_ble_hid.git \
        src/platforms/esp32/components/atomvm_ble_hid

For a local build a symlink does the same job and needs no new repository:

    ln -s /Users/Stefan.Fochler/Developer/avm_badge/components/atomvm_ble_hid \
        src/platforms/esp32/components/atomvm_ble_hid

The symlink only resolves while the `avm_badge` checkout it points into has
the `ble-keyboard` branch checked out. On any other branch the directory is
missing and **the VM builds without the driver, silently**. Check that
`CONFIG_AVM_BLE_HID_ENABLE=y` is in the generated `sdkconfig` and that
`libatomvm_ble_hid.a` appears in `build/esp-idf/atomvm_ble_hid/` before
flashing.

## 2. sdkconfig.defaults.in

Append to `src/platforms/esp32/sdkconfig.defaults.in` (never the generated
`sdkconfig.defaults`):

    # Bluetooth LE keyboard (components/atomvm_ble_hid): NimBLE, peripheral only.
    CONFIG_BT_ENABLED=y
    CONFIG_BT_NIMBLE_ENABLED=y
    CONFIG_BT_CONTROLLER_ENABLED=y
    # The host's heap lives in PSRAM; the controller stays in internal RAM.
    CONFIG_BT_NIMBLE_MEM_ALLOC_MODE_EXTERNAL=y
    CONFIG_BT_NIMBLE_ROLE_PERIPHERAL=y
    CONFIG_BT_NIMBLE_ROLE_BROADCASTER=y
    CONFIG_BT_NIMBLE_ROLE_CENTRAL=n
    CONFIG_BT_NIMBLE_ROLE_OBSERVER=n
    CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1
    CONFIG_BT_NIMBLE_MAX_BONDS=3
    CONFIG_BT_NIMBLE_NVS_PERSIST=y
    CONFIG_BT_NIMBLE_SECURITY_ENABLE=y
    CONFIG_BT_NIMBLE_SM_SC=y
    CONFIG_BT_NIMBLE_50_FEATURE_SUPPORT=n
    CONFIG_BT_NIMBLE_MESH=n
    CONFIG_BT_NIMBLE_HID_SERVICE=y
    CONFIG_BT_NIMBLE_SVC_GAP_APPEARANCE=0x3C1
    CONFIG_BT_NIMBLE_LOG_LEVEL_NONE=y
    CONFIG_ESP_COEX_SW_COEXIST_ENABLE=y
    # The controller lives in internal RAM; a peripheral needs neither scanning,
    # test mode nor six activities (828 bytes each).
    CONFIG_BT_CTRL_BLE_SCAN=n
    CONFIG_BT_CTRL_DTM_ENABLE=n
    CONFIG_BT_CTRL_BLE_MAX_ACT=2
    # On the S3, IRAM and the heap share one SRAM: wifi code in flash and its
    # buffers in PSRAM leave room for the Bluetooth controller.
    CONFIG_ESP_WIFI_IRAM_OPT=n
    CONFIG_ESP_WIFI_RX_IRAM_OPT=n
    CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y
    # 3 marks every HID characteristic as needing an authenticated, encrypted
    # link (the service checks == 3, one above the Kconfig help's numbering), so a
    # Mac pairs with a passkey instead of reading the keyboard unauthenticated.
    CONFIG_BT_NIMBLE_SM_LVL=3
    # The host hears battery level changes instead of polling for them.
    CONFIG_BT_NIMBLE_SVC_BAS_BATTERY_LEVEL_NOTIFY=y

`CONFIG_BT_NIMBLE_NVS_PERSIST` keeps bonds in the NVS namespace
`nimble_bond`. `tools/provision.py` in `avm_badge` carries that namespace
over when it rewrites NVS, so provisioning does not unpair the Mac.

`CONFIG_AVM_BLE_HID_ENABLE` defaults to `y` once the NimBLE HID service is
on; without these lines the driver is silently left out and
`open_port({spawn, "ble_hid"}, _)` fails.

## 3. Build

ESP-IDF v5.5.5, as for any badge build. The CMake defaults already give
`-DAVM_USE_LIBSODIUM=ON -DATOMVM_ELIXIR_SUPPORT=on`; keep libsodium, the
NervesHub agent verifies firmware signatures with it. `set-target`, not
`reconfigure`, because the component list changed:

    cd src/platforms/esp32
    . $IDF_PATH/export.sh
    idf.py set-target esp32s3
    idf.py build

`boot.avm` is not produced by `idf.py`; build it from the same checkout the
way the fork's `badge-image` workflow does (needs Erlang, Elixir and
`rebar3` on `PATH`):

    cmake -B build .
    make -C build elixir_esp32boot
    # -> build/libs/esp32boot/elixir_esp32boot.avm, flashed as boot.avm

## 4. Check the size

The VM must fit the 1920K `factory` partition; changing the partition table
means a serial reflash of every badge, so it is not an option. From
`avm_badge`:

    python3 tools/check_partitions.py \
        /path/to/AtomVM/src/platforms/esp32/partitions-elixir.csv \
        factory=/path/to/AtomVM/src/platforms/esp32/build/atomvm-esp32.bin

Measured 2026-09-30, fork branch `ble-hid` (`main` at `d5a1dc3` plus the
lines above), ESP-IDF v5.5.5:

| Image                               | Bytes     | Free in `factory` |
|-------------------------------------|-----------|-------------------|
| `badge-v1` VM, no Bluetooth         | 1,742,512 | 223,568           |
| with `atomvm_ble_hid`, NimBLE log level `ERROR` | 1,955,136 | 10,944 |
| with `atomvm_ble_hid`, NimBLE log level `NONE`  | 1,931,552 | 34,528 |
| as above, controller trimmed, wifi out of IRAM  | 1,927,632 | 38,448 |

The first image with the stack enabled failed at `esp_bt_controller_init` with
`ESP_ERR_NO_MEM`: the controller allocates from internal, DMA-capable RAM
only, and the badge had too little of it free. The controller and wifi lines
above are the answer; if the driver still logs `Internal RAM at open` with a
failure, the next lever is `network:stop/0` while the page is open.

Without `CONFIG_BT_NIMBLE_SM_LVL`, NimBLE's HID service leaves every
characteristic readable over a plain link and esp_hid enforces nothing. Apple
hosts ignore a peripheral's security request and pair only when access to a
protected characteristic fails, so a Mac connected, subscribed and never
paired: the driver refused to send over the unencrypted link and the Mac,
holding no bond, never reconnected on its own.

`boot.avm` from the same checkout (OTP 28, Elixir 1.19, as in CI) is 527,616
bytes of the 557,056-byte partition.

With the log level at `ERROR`, `idf.py size-components` put the Bluetooth part at about 184 kB of flash
(`libbt` 92 kB, `libbtdm_app` 73 kB, `libesp_hid` 7 kB, `libcoexist` 6 kB,
this driver 4 kB, `libbtbb` 3 kB) and about 16 kB of static internal RAM,
mostly the controller's. What the stack allocates while running is only
visible on the badge: the Keyboard page shows it, and the Log tab records
free internal RAM before and after `open`.

If a later change overflows `factory`, the levers are, in order:
`CONFIG_BT_NIMBLE_SVC_DIS_*` strings off, then optimising components for size; `-DAVM_USE_LIBSODIUM=OFF` is not one, since updates need
it.

## 5. Flash

The VM goes to `0x10000` and `boot.avm` to `0x1F0000`, both from the same
build. The application at `0x2B8000`, the assets partition and NVS survive.

    python -m esptool --chip esp32s3 write_flash \
        0x10000 build/atomvm-esp32.bin \
        0x1F0000 ../../../build/libs/esp32boot/elixir_esp32boot.avm
