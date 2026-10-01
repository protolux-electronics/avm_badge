#!/usr/bin/env python3
"""Generate compact payload-independent QR geometry for Badge.QR.

Every module is two bytes. Fixed function modules carry a sentinel, and data
modules carry the bit they take from the codeword stream, with the mask bit
the chosen mask applies to that position. Format bits are resolved against
that mask here, so the runtime encoder never scores or selects one.
"""

import argparse
import base64
from pathlib import Path

FIXED_LIGHT = 0xFFFE
FIXED_DARK = 0xFFFF
DATA_BITS = 12
DATA_POSITION = (1 << DATA_BITS) - 1


def parse_versions(value):
    versions = []

    for part in value.split(","):
        if "-" in part:
            first, last = (int(item) for item in part.split("-", 1))
            versions.extend(range(first, last + 1))
        else:
            versions.append(int(part))

    versions = sorted(set(versions))

    if not versions or versions[0] < 1 or versions[-1] > 40:
        raise ValueError("QR versions must be between 1 and 40")

    if versions[-1] * 4 + 17 > DATA_POSITION:
        raise ValueError(f"versions above {(DATA_POSITION - 17) // 4} do not fit a data token")

    return versions


def alignment_positions(version, size):
    if version == 1:
        return []

    count = version // 7 + 2
    step = (version * 8 + count * 3 + 5) // (count * 4 - 4) * 2
    return list(reversed([size - 7 - index * step for index in range(count - 1)] + [6]))


def version_bits(version):
    remainder = version

    for _ in range(12):
        remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25)

    return version << 12 | remainder


def format_bits(mask):
    data = (1 << 3) | mask
    remainder = data

    for _ in range(10):
        remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)

    return ((data << 10) | remainder) ^ 0x5412


def mask_applies(mask, x, y):
    return (
        (x + y) % 2 == 0,
        y % 2 == 0,
        x % 3 == 0,
        (x + y) % 3 == 0,
        (x // 3 + y // 2) % 2 == 0,
        x * y % 2 + x * y % 3 == 0,
        (x * y % 2 + x * y % 3) % 2 == 0,
        ((x + y) % 2 + x * y % 3) % 2 == 0,
    )[mask]


def geometry(version, mask):
    size = version * 4 + 17
    cells = [None] * (size * size)
    functions = [False] * (size * size)

    def set_function(x, y, value):
        if 0 <= x < size and 0 <= y < size:
            index = y * size + x
            cells[index] = FIXED_DARK if value else FIXED_LIGHT
            functions[index] = True

    for index in range(size):
        value = index % 2 == 0
        set_function(6, index, value)
        set_function(index, 6, value)

    for center_x, center_y in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                distance = max(abs(dx), abs(dy))
                set_function(center_x + dx, center_y + dy, distance not in (2, 4))

    positions = alignment_positions(version, size)
    skipped = {(0, 0), (0, len(positions) - 1), (len(positions) - 1, 0)}

    for row, center_y in enumerate(positions):
        for column, center_x in enumerate(positions):
            if (row, column) not in skipped:
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        set_function(center_x + dx, center_y + dy, max(abs(dx), abs(dy)) != 1)

    format_value = format_bits(mask)

    def set_format(x, y, bit):
        index = y * size + x
        cells[index] = FIXED_DARK if (format_value >> bit) & 1 else FIXED_LIGHT
        functions[index] = True

    for bit in range(6):
        set_format(8, bit, bit)

    set_format(8, 7, 6)
    set_format(8, 8, 7)
    set_format(7, 8, 8)

    for bit in range(9, 15):
        set_format(14 - bit, 8, bit)

    for bit in range(8):
        set_format(size - 1 - bit, 8, bit)

    for bit in range(8, 15):
        set_format(8, size - 15 + bit, bit)

    set_function(8, size - 8, True)

    if version >= 7:
        bits = version_bits(version)

        for bit in range(18):
            value = (bits >> bit) & 1
            a = size - 11 + bit % 3
            b = bit // 3
            set_function(a, b, value)
            set_function(b, a, value)

    data_bit = 0

    for right in range(size - 1, 0, -2):
        column = right - 1 if right <= 6 else right
        upward = ((column + 1) & 2) == 0

        for vertical in range(size):
            y = size - 1 - vertical if upward else vertical

            for x in (column, column - 1):
                index = y * size + x

                if not functions[index]:
                    flag = int(mask_applies(mask, x, y)) << DATA_BITS
                    cells[index] = data_bit | flag
                    data_bit += 1

    if any(value is None for value in cells):
        raise RuntimeError(f"version {version}: incomplete geometry")

    return size, b"".join(value.to_bytes(2, "big") for value in cells)


def module_source(versions, mask):
    records = [(version, *geometry(version, mask)) for version in versions]
    lines = [
        "defmodule Badge.QR.Geometry do",
        "  @moduledoc false",
        "",
        f"  @mask {mask}",
        f"  @versions {versions!r}",
        f"  @fixed_light {FIXED_LIGHT}",
        f"  @fixed_dark {FIXED_DARK}",
        f"  @data_position {DATA_POSITION}",
    ]

    for version, _size, template in records:
        encoded = base64.b64encode(template).decode("ascii")
        value_indent = " " * (7 + len(str(version)))
        close_indent = " " * (5 + len(str(version)))
        lines.extend(
            [
                f"  @v{version} Base.decode64!(",
                f'{value_indent}"{encoded}"',
                f"{close_indent})",
            ]
        )

    lines.extend(
        [
            "",
            "  def mask, do: @mask",
            "",
            "  def versions, do: @versions",
            "",
            "  def fixed_light, do: @fixed_light",
            "",
            "  def fixed_dark, do: @fixed_dark",
            "",
            "  def data_position, do: @data_position",
            "",
        ]
    )

    for version, size, _template in records:
        lines.append(
            f"  def for_version({version}), do: %{{size: {size}, template: @v{version}}}"
        )

    lines.extend(["  def for_version(_version), do: nil", "end", ""])
    return "\n".join(lines)


def main():
    root = Path(__file__).resolve().parent.parent
    default_output = root / "lib" / "badge" / "qr" / "geometry.ex"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--versions", default="1-8")
    parser.add_argument("--mask", type=int, default=0, help="fixed mask, 0 to 7")
    parser.add_argument("--output", type=Path, default=default_output)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    if not 0 <= args.mask <= 7:
        raise SystemExit("--mask must be between 0 and 7")

    source = module_source(parse_versions(args.versions), args.mask)

    if args.check:
        if not args.output.exists() or args.output.read_text() != source:
            raise SystemExit(f"{args.output} is stale; regenerate with {Path(__file__).name}")

        print(f"{args.output} is current")
        return

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(source)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
