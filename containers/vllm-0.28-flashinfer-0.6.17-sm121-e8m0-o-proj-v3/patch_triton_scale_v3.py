#!/usr/bin/env python3
"""Upgrade the reviewed vLLM 0.28 SM121 scale fallback, fail closed."""

from __future__ import annotations

import hashlib
from pathlib import Path


TARGET = Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/model_executor/kernels/"
    "linear/scaled_mm/triton.py"
)
EXPECTED_SHA256 = "33f898cf08cf4a37b0d3cbc281bef6204d7f34dfb2b142f18cf556a25fad5a82"
OLD = """        # SM121 workaround: E8M0 is exponent-only and converts exactly to
        # float32.  Triton's block-scaled op cannot consume E8M0 scales.
        if Bs.dtype == torch.float8_e8m0fnu:
            Bs = Bs.float()
"""
NEW = """        # SM121 workaround: use vLLM's exact exponent-only conversion.
        # Some ModelOpt checkpoints expose the same E8M0 payload as uint8.
        if Bs.dtype in (torch.float8_e8m0fnu, torch.uint8):
            from vllm.model_executor.layers.quantization.utils.fp8_utils import (
                _upcast_e8m0_to_fp32,
            )
            Bs = _upcast_e8m0_to_fp32(Bs).contiguous()
"""


def main() -> None:
    source = TARGET.read_bytes()
    actual = hashlib.sha256(source).hexdigest()
    if actual != EXPECTED_SHA256:
        raise SystemExit(
            f"refusing unexpected patched vLLM source: {actual} != {EXPECTED_SHA256}"
        )
    text = source.decode("utf-8")
    if text.count(OLD) != 1:
        raise SystemExit("refusing ambiguous or missing reviewed SM121 scale block")
    TARGET.write_text(text.replace(OLD, NEW), encoding="utf-8")


if __name__ == "__main__":
    main()
