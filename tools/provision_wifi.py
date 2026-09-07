#!/usr/bin/env python3
"""Provision wifi credentials into the badge's NVS partition.

Credentials go straight from this prompt to the device. Nothing is written
into the repository, and the temporary files live outside it and are deleted
before exit.

AtomVM reads NVS values with nvs_get_blob (nvs_nif.c:83), so every value is
written with hex2bin encoding. A CSV 'string' row would produce an NVS string
type instead, which reads back as undefined with no error anywhere.

Usage:
  python3 tools/provision_wifi.py [--port /dev/cu.usbmodemXXXX]  # macOS
  python3 tools/provision_wifi.py [--port /dev/ttyACM0]           # Linux
  python3 tools/provision_wifi.py --clear   # forget the saved network
"""

import argparse
import getpass
import os
import shutil
import subprocess
import sys
import tempfile

from serial_port import find_port

# From AtomVM/src/platforms/esp32/partitions-elixir.csv
NVS_OFFSET = "0x9000"
NVS_SIZE = "0x6000"
NAMESPACE = "badge"

# UTC-12 to UTC+14, matching Badge.Clock.
MIN_OFFSET = -720
MAX_OFFSET = 840


def select_port(explicit):
    if explicit:
        return explicit

    return find_port()


def prompt():
    ssid = input("SSID: ").strip()
    if not ssid:
        sys.exit("SSID cannot be empty.")

    psk = getpass.getpass("Passphrase (hidden): ")
    if len(psk) < 8:
        sys.exit("WPA2 passphrases are at least 8 characters.")

    raw = input(
        f"UTC offset in minutes [{MIN_OFFSET}..{MAX_OFFSET}], e.g. -420 for PDT: "
    ).strip()
    try:
        offset = int(raw)
    except ValueError:
        sys.exit(f"'{raw}' is not a whole number of minutes.")

    if not MIN_OFFSET <= offset <= MAX_OFFSET:
        sys.exit(
            f"{offset} is outside {MIN_OFFSET}..{MAX_OFFSET}; "
            "the firmware would read it as 0."
        )

    return ssid, psk, offset


def empty_csv():
    """A valid, formatted NVS image with the namespace and no keys.

    Erasing the region to 0xFF would also clear it, but leaves the partition
    unformatted; writing a generated image keeps it well-formed.
    """
    return "\n".join(["key,type,encoding,value", f"{NAMESPACE},namespace,,", ""])


def csv_for(ssid, psk, offset):
    def row(key, value):
        return f"{key},data,hex2bin,{value.encode('utf-8').hex()}"

    return "\n".join(
        [
            "key,type,encoding,value",
            f"{NAMESPACE},namespace,,",
            row("wifi_ssid", ssid),
            row("wifi_psk", psk),
            row("utc_offset_m", str(offset)),
            "",
        ]
    )


def run(argv, what):
    result = subprocess.run(argv)
    if result.returncode != 0:
        sys.exit(f"{what} failed with exit code {result.returncode}.")


def flash_csv(port, csv_text):
    workdir = tempfile.mkdtemp(prefix="badge-provision-")
    csv_path = os.path.join(workdir, "wifi.csv")
    bin_path = os.path.join(workdir, "wifi-nvs.bin")

    try:
        with open(csv_path, "w") as handle:
            handle.write(csv_text)

        run(
            [
                sys.executable,
                "-m",
                "esp_idf_nvs_partition_gen",
                "generate",
                csv_path,
                bin_path,
                NVS_SIZE,
            ],
            "nvs_partition_gen",
        )
        run(
            [
                sys.executable,
                "-m",
                "esptool",
                "--port",
                port,
                "write_flash",
                NVS_OFFSET,
                bin_path,
            ],
            "esptool",
        )
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", help="serial device; auto-detected when omitted")
    parser.add_argument(
        "--clear", action="store_true", help="forget the saved network and offset"
    )
    args = parser.parse_args()

    port = select_port(args.port)

    if args.clear:
        print(f"Clearing all saved settings on {port}.")
        if input("Continue? [y/N] ").strip().lower() != "y":
            sys.exit("Cancelled.")

        flash_csv(port, empty_csv())
        print("\nCleared. Reset the badge; it will boot with the radio off.")
        return

    ssid, psk, offset = prompt()

    print(f"\nProvisioning {ssid!r} to {port} (offset {offset} minutes).")
    print("This erases everything else in the NVS partition.")
    if input("Continue? [y/N] ").strip().lower() != "y":
        sys.exit("Cancelled.")

    flash_csv(port, csv_for(ssid, psk, offset))
    print("\nDone. Reset the badge; it should associate within a few seconds.")


if __name__ == "__main__":
    main()
