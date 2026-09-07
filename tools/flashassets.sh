#!/usr/bin/env bash
# Pack assets.avm and write it to the assets partition.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
avm="$root/assets.avm"

offset=0x278000
size=262144
chip=esp32s3

port="${1:-${PORT:-}}"
if [ -z "$port" ]; then
  port="$(python3 "$root/tools/serial_port.py")"
fi

( cd "$root" && mix badge.assets >/dev/null )

actual="$(wc -c <"$avm" | tr -d ' ')"
min=10240
if [ "$actual" -lt "$min" ]; then
  echo "flashassets: assets.avm is only ${actual}B, looks empty or truncated" >&2
  exit 1
fi
if [ "$actual" -gt "$size" ]; then
  echo "flashassets: assets.avm is ${actual}B, partition holds ${size}B" >&2
  exit 1
fi
echo "flashassets: ${actual}B of ${size}B, writing to $port"

esptool.py --chip "$chip" --port "$port" --baud 921600 write_flash "$offset" "$avm"

echo "flashassets: done, the badge has reset"
