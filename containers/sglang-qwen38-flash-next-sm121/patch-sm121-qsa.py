#!/usr/bin/env python3
"""Apply the reviewed SM121 QSA resolver guard as a fail-closed patch."""

from hashlib import sha256
from pathlib import Path


TARGET = Path(
    "/sgl-workspace/sglang/python/sglang/srt/layers/attention/"
    "qwen_sparse_attn_backend.py"
)
SOURCE_SHA256 = "c959835d05d0f395ad7eae4330cf264af9f6f7c1bff3d45a39bb953d2536f5f2"
PATCHED_SHA256 = "a6b003ed21b3be8ba763e8627aee39baee3d84184f5bf0fc650a1a6b853119d3"

IMPORT_OLD = b"from sglang.srt.utils import is_sm100_supported"
IMPORT_NEW = b"from sglang.srt.utils import is_sm100_supported, is_sm120_supported"
GUARD_OLD = b"if not is_sm100_supported():"
GUARD_NEW = b"if not (is_sm100_supported() or is_sm120_supported()):"


source = TARGET.read_bytes()
observed_source = sha256(source).hexdigest()
if observed_source != SOURCE_SHA256:
    raise SystemExit(
        f"refusing changed QSA source: expected {SOURCE_SHA256}, "
        f"observed {observed_source}"
    )

if source.count(IMPORT_OLD) != 1 or source.count(GUARD_OLD) != 1:
    raise SystemExit("the reviewed QSA patch anchors are not unique")

patched = source.replace(IMPORT_OLD, IMPORT_NEW).replace(GUARD_OLD, GUARD_NEW)
observed_patched = sha256(patched).hexdigest()
if observed_patched != PATCHED_SHA256:
    raise SystemExit(
        f"patched QSA source digest changed: expected {PATCHED_SHA256}, "
        f"observed {observed_patched}"
    )

TARGET.write_bytes(patched)
print(f"qsa_sm121_patch=pass sha256={observed_patched}")
