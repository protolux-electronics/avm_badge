#!/usr/bin/env python3
import glob
import sys

PORT_PATTERNS = ("/dev/cu.usbmodem*", "/dev/ttyACM*")


class PortDetectionError(SystemExit):
    pass


def find_port(patterns=PORT_PATTERNS):
    found = sorted({path for pattern in patterns for path in glob.glob(pattern)})
    if not found:
        raise PortDetectionError(f"no board found at {' or '.join(patterns)}")
    if len(found) > 1:
        devices = ", ".join(found)
        raise PortDetectionError(
            f"more than one board: {devices}; pass a port explicitly"
        )
    return found[0]


def main():
    try:
        print(find_port())
    except PortDetectionError as error:
        sys.exit(f"serial port: {error}")


if __name__ == "__main__":
    main()
