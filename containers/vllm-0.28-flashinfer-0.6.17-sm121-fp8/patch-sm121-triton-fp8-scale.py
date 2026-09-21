#!/usr/bin/env python3
"""Apply the narrow vLLM 0.28 SM121 E8M0/Triton workaround.

DeepSeek V4 checkpoints store block weight scales as E8M0.  The Triton
block-scaled kernel accepts floating-point scales, but vLLM 0.28 forwards the
E8M0 tensor unchanged.  E8M0 is exponent-only, so conversion to float32 is
lossless.  Keep this overlay local to the Triton backend; do not alter weights
or the FlashInfer/NVFP4 MoE paths.
"""

from __future__ import annotations

import hashlib
from pathlib import Path


TARGET = Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/model_executor/kernels/"
    "linear/scaled_mm/triton.py"
)
EXPECTED_SHA256 = "d90229fecb3800f3efe0f5df211f8014034d5b8e83ee8800f22f76991f2b67fc"
NEEDLE = """        return torch.ops.vllm.w8a8_triton_block_scaled_mm_func(
            A,
            B,
            As,
            Bs,
"""
REPLACEMENT = """        # SM121 workaround: E8M0 is exponent-only and converts exactly to
        # float32.  Triton's block-scaled op cannot consume E8M0 scales.
        if Bs.dtype == torch.float8_e8m0fnu:
            Bs = Bs.float()
        return torch.ops.vllm.w8a8_triton_block_scaled_mm_func(
            A,
            B,
            As,
            Bs,
"""


def main() -> None:
    source = TARGET.read_bytes()
    actual = hashlib.sha256(source).hexdigest()
    if actual != EXPECTED_SHA256:
        raise SystemExit(
            f"refusing to patch unexpected vLLM source: {actual} != {EXPECTED_SHA256}"
        )
    text = source.decode("utf-8")
    if text.count(NEEDLE) != 1:
        raise SystemExit("refusing to patch: target block is missing or ambiguous")
    TARGET.write_text(text.replace(NEEDLE, REPLACEMENT), encoding="utf-8")


if __name__ == "__main__":
    main()
