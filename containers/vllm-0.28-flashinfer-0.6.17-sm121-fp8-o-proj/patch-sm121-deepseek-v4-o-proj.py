#!/usr/bin/env python3
"""Patch vLLM 0.28 DeepSeek V4's SM121 output projection fail-closed.

The source hash and exact replacement counts make this overlay refuse an
unknown vLLM source.  SM90/SM100 behavior is not changed because this image is
an SM121-only qualification candidate.
"""

from __future__ import annotations

import hashlib
from pathlib import Path


TARGET = Path(
    "/usr/local/lib/python3.12/dist-packages/vllm/models/deepseek_v4/"
    "nvidia/ops/o_proj.py"
)
EXPECTED_SHA256 = "ffb28e7cc44124bb2878e596617b70ec2659c7b26a2048a06facc343fa4d24e1"
IMPORT_NEEDLE = "from vllm.utils.deep_gemm import fp8_einsum\n"
IMPORT_REPLACEMENT = """from vllm.models.deepseek_v4.nvidia.ops.sm121_einsum_fallback import (
    fp8_einsum_torch as fp8_einsum,
)
"""
RECIPE_NEEDLE = """    einsum_recipe = (1, 128, 128) if cap.major <= 9 else (1, 1, 128)
    tma_aligned_scales = cap.major >= 10
"""
RECIPE_REPLACEMENT = """    # SM121 correctness fallback: retain unpacked FP32 block scales.
    einsum_recipe = (1, 128, 128)
    tma_aligned_scales = False
"""


def main() -> None:
    source = TARGET.read_bytes()
    actual = hashlib.sha256(source).hexdigest()
    if actual != EXPECTED_SHA256:
        raise SystemExit(
            f"refusing to patch unexpected vLLM source: {actual} != {EXPECTED_SHA256}"
        )
    text = source.decode("utf-8")
    if text.count(IMPORT_NEEDLE) != 1:
        raise SystemExit("refusing to patch: fp8_einsum import is missing or ambiguous")
    if text.count(RECIPE_NEEDLE) != 1:
        raise SystemExit("refusing to patch: scale-layout block is missing or ambiguous")
    text = text.replace(IMPORT_NEEDLE, IMPORT_REPLACEMENT)
    text = text.replace(RECIPE_NEEDLE, RECIPE_REPLACEMENT)
    TARGET.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
