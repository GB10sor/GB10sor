#!/usr/bin/env python3
"""Verify one TP4 DeepSeek V4.1 sparse Engram store before a model launch.

The store deliberately has holes outside its rank's rows.  A marker and an
apparent file size are insufficient: inspect allocated extents for every byte
of the two local embedding tensors and require exact safetensors metadata.
"""

import argparse
import json
import os
from pathlib import Path
import stat
import struct
import sys


LAYERS = {1: ("model-00047-of-00048.safetensors", 384006168),
          14: ("model-00048-of-00048.safetensors", 384016682)}
DTYPES = {"weight": ("F8_E4M3", 256), "scale": ("F8_E8M0", 8)}
RANGES = {
    1: [(0, 96000564), (96000564, 192001740),
        (192001740, 288003654), (288003654, 384006168)],
    14: [(0, 96003054), (96003054, 192007016),
         (192007016, 288011564), (288011564, 384016682)],
}


def fail(message):
    raise ValueError(message)


def check_storage(path):
    if not path.is_absolute() or str(path) == "/":
        fail("Engram path must be an absolute directory")
    for component in [path, *path.parents]:
        if component.is_symlink():
            fail("Engram path traverses a symlink")
    if path.resolve(strict=True) != path or not path.is_dir():
        fail("Engram path does not resolve to its own directory")
    mountinfo = Path("/proc/self/mountinfo").read_text().splitlines()
    targets = []
    owning = None
    for line in mountinfo:
        left, right = line.split(" - ", 1)
        target = left.split()[4].replace("\\040", " ")
        source_fields = right.split()
        targets.append(target)
        if str(path) == target or str(path).startswith(target.rstrip("/") + "/"):
            if owning is None or len(target) > len(owning[0]):
                owning = (target, source_fields[0], source_fields[1])
    if owning is None:
        fail("Engram filesystem mount not found")
    _, fstype, source = owning
    if fstype not in {"ext4", "xfs", "btrfs"} or not source.startswith("/dev/nvme"):
        fail("Engram rows are not on this Spark's NVMe filesystem")
    prefix = str(path).rstrip("/") + "/"
    if any(target == str(path) or target.startswith(prefix) for target in targets):
        fail("Engram directory contains a nested mount")
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            if (Path(root) / name).is_symlink():
                fail("Engram directory contains a symlink")
    return fstype, source


def read_header(fd, size):
    length_bytes = os.pread(fd, 8, 0)
    if len(length_bytes) != 8:
        fail("truncated safetensors header")
    length = struct.unpack("<Q", length_bytes)[0]
    if length > 16 * 1024 * 1024 or length + 8 > size:
        fail("invalid safetensors header length")
    raw = os.pread(fd, length, 8)
    if len(raw) != length:
        fail("truncated safetensors metadata")
    return 8 + length, json.loads(raw)


def require_allocated(fd, begin, end):
    if end <= begin:
        fail("empty Engram row range")
    try:
        if os.lseek(fd, begin, os.SEEK_DATA) != begin:
            fail("Engram row range begins in a sparse hole")
        if os.lseek(fd, begin, os.SEEK_HOLE) < end:
            fail("Engram row range contains a sparse hole")
    except OSError as error:
        fail(f"cannot verify Engram allocated extents: {error}")


def verify(path, rank):
    fstype, source = check_storage(path)
    marker_path = path / "engram-local.json"
    if not marker_path.is_file():
        fail("Engram marker missing")
    marker = json.loads(marker_path.read_text())
    if marker.get("tensorParallel", 4) != 4 or marker.get("rank", rank) != rank:
        fail("Engram marker TP/rank mismatch")
    layers = marker.get("layers")
    if not isinstance(layers, dict) or set(layers) != {"1", "14"}:
        fail("Engram marker layer set mismatch")
    expected_files = {name for name, _ in LAYERS.values()}
    if {p.name for p in path.glob("*.safetensors")} != expected_files:
        fail("Engram safetensors file set mismatch")
    ranges = {}
    for layer, (filename, total_rows) in LAYERS.items():
        row_range = layers[str(layer)]
        if (not isinstance(row_range, list) or len(row_range) != 2 or
                not all(type(x) is int for x in row_range)):
            fail(f"invalid layer {layer} row range")
        start, end = row_range
        if not 0 <= start < end <= total_rows:
            fail(f"layer {layer} row range out of bounds")
        if (start, end) != RANGES[layer][rank]:
            fail(f"layer {layer} is not the complete TP4 rank {rank} range")
        file_path = path / filename
        file_stat = file_path.stat()
        if not stat.S_ISREG(file_stat.st_mode):
            fail(f"{filename} is not a regular file")
        fd = os.open(file_path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            header_size, header = read_header(fd, file_stat.st_size)
            for kind, (dtype, width) in DTYPES.items():
                tensor = f"layers.{layer}.engram.embed.{kind}"
                meta = header.get(tensor)
                if meta is None or meta.get("dtype") != dtype or meta.get("shape") != [total_rows, width]:
                    fail(f"{tensor} metadata mismatch")
                offsets = meta.get("data_offsets")
                if (not isinstance(offsets, list) or len(offsets) != 2 or
                        offsets[1] - offsets[0] != total_rows * width):
                    fail(f"{tensor} byte extent mismatch")
                begin = header_size + offsets[0] + start * width
                finish = header_size + offsets[0] + end * width
                if finish > file_stat.st_size:
                    fail(f"{tensor} is truncated")
                require_allocated(fd, begin, finish)
            if max(value["data_offsets"][1] for value in header.values()
                   if isinstance(value, dict) and "data_offsets" in value) + header_size != file_stat.st_size:
                fail(f"{filename} apparent size mismatch")
        finally:
            os.close(fd)
        ranges[str(layer)] = [start, end, total_rows]
    return {"rank": rank, "tensorParallel": 4, "storageType": fstype,
            "storageSource": source, "completeAllocatedRows": ranges,
            "readOnlyRuntimeMountRequired": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("rank", type=int)
    args = parser.parse_args()
    if args.rank not in range(4):
        fail("rank must be 0..3")
    print(json.dumps(verify(args.path, args.rank), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"verify-deepseek-v41-engram-local: {error}", file=sys.stderr)
        sys.exit(1)
