"""Split a server-stored segment into frames and check every one is a JPEG.

The server concatenates each `recording.frame` payload with a 4-byte big-endian
length prefix and no container:

    [uint32 BE len(frame 1)][frame 1][uint32 BE len(frame 2)][frame 2] ...

so this is the only way to recover the frames. Two things matter:

- `trailing` must be 0: leftover bytes mean the length prefixes do not line up
  with what the client actually sent.
- every frame must be a whole JPEG (`FF D8` ... `FF D9`). A truncated frame or a
  non-mjpeg payload means the client is sending something other than what it
  announced.

Usage:
    python check_segment.py <segment-file>
    python check_segment.py --url <presigned-url> [--out <path>]
"""

import argparse
import struct
import sys
import urllib.request

SOI = b"\xff\xd8"
EOI = b"\xff\xd9"


def split_frames(raw):
    """Returns (frames, trailing).

    `trailing` is the number of bytes the prefixes leave unaccounted for, or
    None when a prefix promises more bytes than the object holds. The two are
    different failures: leftover bytes mean the framing nearly lines up, an
    overrun means it does not line up at all. Walking past the end would report
    a negative count, which reads as nonsense and hides the cause.
    """
    frames = []
    i = 0
    while i + 4 <= len(raw):
        (n,) = struct.unpack(">I", raw[i : i + 4])
        i += 4
        if i + n > len(raw):
            return frames, None
        frames.append(raw[i : i + n])
        i += n
    return frames, len(raw) - i


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", help="a segment file already on disk")
    parser.add_argument("--url", help="download the segment from a presigned URL")
    parser.add_argument("--out", help="where to save the downloaded segment")
    parser.add_argument("--dump", help="write the first N frames here, as .jpg")
    args = parser.parse_args()

    if args.url:
        with urllib.request.urlopen(args.url) as response:
            raw = response.read()
        if args.out:
            with open(args.out, "wb") as handle:
                handle.write(raw)
    elif args.path:
        with open(args.path, "rb") as handle:
            raw = handle.read()
    else:
        parser.error("give a segment path or --url")
        return

    frames, trailing = split_frames(raw)
    jpeg = [f for f in frames if f[:2] == SOI and f[-2:] == EOI]
    sizes = sorted(len(f) for f in frames)

    print(f"bytes={len(raw)}")
    print(f"frames={len(frames)}")
    print(f"trailing={'OVERRUN' if trailing is None else trailing}")
    print(f"jpeg_ok={len(jpeg)}/{len(frames)}")
    if sizes:
        print(f"size_min={sizes[0]} size_max={sizes[-1]}")

    if args.dump and frames:
        for index, frame in enumerate(frames[: int(args.dump)]):
            name = f"{args.dump}.{index}.jpg"
            with open(name, "wb") as handle:
                handle.write(frame)
            print(f"wrote {name}")

    # The failure modes this script exists to catch.
    problems = []
    if not frames:
        problems.append("no frames recovered")
    if trailing is None:
        problems.append(
            "a length prefix promises more bytes than the object holds "
            "(the framing does not line up at all)"
        )
    elif trailing != 0:
        problems.append(f"{trailing} trailing bytes (prefixes do not line up)")
    if len(jpeg) != len(frames):
        problems.append(
            f"{len(frames) - len(jpeg)} frame(s) are not whole JPEGs "
            "(truncated, or padded after the EOI)"
        )

    if problems:
        print("RESULT: FAIL - " + "; ".join(problems))
        sys.exit(1)

    print("RESULT: PASS")


if __name__ == "__main__":
    main()
