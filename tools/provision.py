#!/usr/bin/env python3
"""Provision the badge's NVS settings without losing what is already there.

Reads the badge's NVS partition, merges in whatever you supply, and writes it
back. A value you do not supply is read off the badge and written back
unchanged, so provisioning NervesHub credentials keeps the display name, the
peer list and the saved wifi network.

Each value comes from the first of: the flag, the environment variable, the
badge.

    --nh-key      BADGE_NH_KEY        NervesHub shared secret key
    --nh-secret   BADGE_NH_SECRET     its secret
    --nh-host     BADGE_NH_HOST       hub host; the firmware defaults this
    --wifi-ssid   BADGE_WIFI_SSID
    --wifi-psk    BADGE_WIFI_PSK

Needs ESP-IDF: . $IDF_PATH/export.sh

The three namespaces ESP-IDF owns (`nvs.net80211`, `phy`, `misc`) are not
preserved; they hold wifi driver config and RF calibration, and are rebuilt on
the next boot at the cost of a slower first connection.
"""
import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile

from serial_port import find_port

NVS_OFFSET = 0x9000
NVS_SIZE = 0x6000
NAMESPACE = "badge"
CHIP = "esp32s3"

# Never printed back, whether they were supplied or read off the badge.
SECRET = {"nh_secret", "wifi_psk"}

SETTINGS = [
    ("nh_key", "--nh-key", "BADGE_NH_KEY"),
    ("nh_secret", "--nh-secret", "BADGE_NH_SECRET"),
    ("nh_host", "--nh-host", "BADGE_NH_HOST"),
    ("wifi_ssid", "--wifi-ssid", "BADGE_WIFI_SSID"),
    ("wifi_psk", "--wifi-psk", "BADGE_WIFI_PSK"),
    ("chat_url", "--chat-url", "AVM_BADGE_SERVER_URL"),
]


def load_parser():
    """ESP-IDF's NVS parser, which ships as a script rather than a package."""
    idf = os.environ.get("IDF_PATH")
    if not idf:
        sys.exit("IDF_PATH is unset. Run: . $IDF_PATH/export.sh")

    path = os.path.join(idf, "components/nvs_flash/nvs_partition_tool/nvs_parser.py")
    if not os.path.exists(path):
        sys.exit(f"no NVS parser at {path}")

    spec = importlib.util.spec_from_file_location("nvs_parser", path)
    if spec is None or spec.loader is None:
        sys.exit(f"could not load the NVS parser at {path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def entry_data(entry):
    buf = bytearray()
    for child in entry.children:
        buf += child.raw
    return bytes(buf[: entry.data["size"]])


def read_namespace(parser, image):
    """Every key of the badge namespace, as {key: bytes}."""
    partition = parser.NVS_Partition("nvs", bytearray(image))

    names = {}
    for page in partition.pages:
        for entry in page.entries:
            if entry.state == "Written" and entry.metadata["namespace"] == 0:
                names[entry.data["value"]] = entry.key

    values, indexes = {}, {}
    for page in partition.pages:
        for entry in page.entries:
            if entry.state != "Written":
                continue
            if names.get(entry.metadata["namespace"]) != NAMESPACE:
                continue

            kind = entry.metadata["type"]
            if kind == "blob_index":
                indexes[entry.key] = entry
            elif kind in ("string", "blob"):
                values[entry.key] = entry_data(entry)

    # A blob too large for one entry is stored as an index plus chunks.
    for key, index in indexes.items():
        buf = bytearray()
        for page in partition.pages:
            for entry in page.entries:
                if (
                    entry.state == "Written"
                    and entry.metadata["type"] == "blob_data"
                    and entry.metadata["namespace"] == index.metadata["namespace"]
                    and entry.key == key
                ):
                    for child in entry.children:
                        buf += child.raw
        values[key] = bytes(buf[: index.data["size"]])

    return values


def write_csv(path, values):
    with open(path, "w", newline="") as fh:
        fh.write("key,type,encoding,value\n")
        fh.write(f"{NAMESPACE},namespace,,\n")
        for key in sorted(values):
            fh.write(f"{key},data,hex2bin,{values[key].hex()}\n")


def run(command, dry_run, quiet=False):
    if dry_run:
        print("  " + " ".join(command))
        return
    subprocess.run(command, check=True, capture_output=quiet)


def shown(key, value):
    if key in SECRET:
        return f"<{len(value)} bytes>"
    if not value:
        return "(empty)"
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError:
        return f"<{len(value)} bytes>"
    # `peers` is an encoded term, not text.
    if not text.isprintable():
        return f"<{len(value)} bytes>"
    return text


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    for _key, flag, env in SETTINGS:
        ap.add_argument(flag, help=f"or {env}")
    ap.add_argument("--port", help="serial device; auto-detected when omitted")
    ap.add_argument("--dry-run", action="store_true", help="say what would happen")
    args = ap.parse_args()

    supplied = {}
    for key, flag, env in SETTINGS:
        value = getattr(args, flag.lstrip("-").replace("-", "_")) or os.environ.get(env)
        if value:
            supplied[key] = value.encode()

    # NervesHub is optional; a badge without credentials simply never updates.
    for key in ("nh_key", "nh_secret"):
        if key not in supplied:
            print(f"warning: {key} not supplied, keeping whatever the badge holds",
                  file=sys.stderr)

    device = args.port or find_port()
    parser = load_parser()

    with tempfile.TemporaryDirectory() as work:
        image = os.path.join(work, "nvs.bin")
        source = os.path.join(work, "nvs.csv")
        merged = os.path.join(work, "merged.bin")

        # Read even on a dry run: it changes nothing, and without it there is
        # no merge to show.
        print(f"Reading NVS from {device}")
        run(
            ["python3", "-m", "esptool", "--chip", CHIP, "--port", device,
             "read_flash", hex(NVS_OFFSET), hex(NVS_SIZE), image],
            dry_run=False,
            quiet=True,
        )

        existing = read_namespace(parser, open(image, "rb").read())
        values = dict(existing)
        values.update(supplied)

        print(f"\n{NAMESPACE} namespace, {len(values)} keys:")
        for key in sorted(values):
            if key in supplied and existing.get(key) != supplied[key]:
                mark = "set  "
            elif key in supplied:
                mark = "same "
            else:
                mark = "kept "
            print(f"  {mark}{key:12} {shown(key, values[key])}")

        write_csv(source, values)

        run(
            ["python3", "-m", "esp_idf_nvs_partition_gen.nvs_partition_gen",
             "generate", source, merged, hex(NVS_SIZE)],
            args.dry_run,
        )
        run(
            ["python3", "-m", "esptool", "--chip", CHIP, "--port", device,
             "write_flash", hex(NVS_OFFSET), merged],
            args.dry_run,
        )

    if not args.dry_run:
        print("\nProvisioned. The badge reboots itself; wifi reconnects a little slower once.")


if __name__ == "__main__":
    main()
