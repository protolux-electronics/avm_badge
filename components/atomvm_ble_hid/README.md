# atomvm_ble_hid

An AtomVM port driver that makes an ESP32 a Bluetooth LE keyboard (HID over
GATT). NimBLE is the host; ESP-IDF's `esp_hid` builds the HID (0x1812),
Battery (0x180F) and Device Information (0x180A, with a PnP ID) services
from a boot keyboard report map. The driver owns advertising, pairing and
bonding.

- Pairing is LE Secure Connections with MITM protection. The device's IO
  capability is *keyboard only*, so the host shows a six-digit passkey and the
  owner types it.
- Bonds (LTK, IRK) persist in NVS with `CONFIG_BT_NIMBLE_NVS_PERSIST=y`, and
  the device advertises from its public, efuse-derived Bluetooth address, so a
  bonded host reconnects after a reboot without pairing again.
- Reports are sent only over an encrypted link.
- A numeric comparison request is rejected: with nothing to show it on, it
  could not be checked.
- One port at a time: there is one Bluetooth stack. Opening a second port
  while one is still open tears the first down. A port killed with its owner
  leaves the stack running until the next open does that.

See `FORK.md` for wiring the component into the badge's AtomVM fork.

## Opening

```erlang
Port = erlang:open_port({spawn, "ble_hid"}, [{owner, self()}, {name, <<"Badge 1A2B">>}]).
```

| Option  | Meaning                                                        |
|---------|----------------------------------------------------------------|
| `owner` | pid that receives the events. Required.                        |
| `name`  | advertised and GAP device name, at most 29 bytes. Defaults to `"Badge "` and the last two bytes of the factory MAC in hex. |

Opening starts the controller and the NimBLE host, so it costs internal RAM
until the port is closed. `open_port` raises `badarg` when the stack cannot
start (or when the driver is not in the image).

## Events

Every event reaches the owner as `{ble_hid, Port, Event}`. Match the port
without pinning it: the term in the message is the driver's own, not the one
`open_port` returned.

| Event                   | When                                                   |
|-------------------------|--------------------------------------------------------|
| `advertising`           | advertising started or restarted                       |
| `{connected, Addr}`     | a host connected; `Addr` is 6 bytes, most significant first |
| `passkey_input`         | the host shows a passkey; answer with `{passkey, N}`   |
| `{passkey_display, N}`  | the host wants the device to show `N` instead          |
| `{encrypted, Bonded}`   | the link is encrypted; `Bonded` is a boolean           |
| `ready`                 | encrypted and the host listens to the keyboard report  |
| `disconnected`          | the host went away; advertising restarts by itself     |
| `{error, Reason}`       | `adv_failed`, `pairing_failed` or `host_reset`         |

## Commands

All are `port:call/2`, which blocks until the driver answers.

| Request            | Reply                                                     |
|--------------------|-----------------------------------------------------------|
| `{report, Bin}`    | `ok`, or `{error, Reason}` with `Reason` one of `not_connected`, `not_encrypted`, `send_failed`. `Bin` is the 8-byte boot keyboard input report: modifiers, reserved, six usages |
| `{passkey, N}`     | `ok`, or `{error, no_passkey}` or `{error, pairing_failed}`. `N` is 0..999999 |
| `forget`           | `ok`. Deletes every bond and drops the connection; advertising carries on |
| `mem`              | `{ok, InternalFree, LargestInternalBlock}` now, in bytes  |
| `mem_at_open`      | the same two figures, taken just before the stack started |
| `close`            | `ok`. Disconnects, stops the host and the controller and destroys the port |

A malformed request answers `badarg`; any request to a port that has been
closed or replaced answers `{error, noproc}`.

## Report map

Report id 1, 8-byte input (modifier bits, a reserved byte, six key usages
0..101), 1-byte output for the five LEDs, which the driver accepts and
ignores. Boot protocol is served from the same map by `esp_hid`.

## Configuration

`CONFIG_AVM_BLE_HID_ENABLE` (default on) depends on `BT_NIMBLE_ENABLED` and
`BT_NIMBLE_HID_SERVICE`; without them the driver is not compiled in and
opening the port fails.
