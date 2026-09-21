#!/usr/bin/env python3
"""Apply upstream vLLM PR #54057 to the pinned 0.28 runtime fail-closed."""

import os
from pathlib import Path


path = Path(
    os.environ.get(
        "GB10_VLLM_SM120_SOURCE_PATH",
        "/usr/local/lib/python3.12/dist-packages/vllm/v1/attention/backends/mla/"
        "flashinfer_mla_sparse_sm120.py",
    )
)
original = path.read_text(encoding="utf-8")
needle = "    is_sparse = True\n"
replacement = "    is_sparse = True\n    masked_mha_available = False\n"

if original.count(needle) != 1:
    raise SystemExit("refusing unexpected SM120 sparse-MLA source")
if "masked_mha_available" in original:
    raise SystemExit("refusing source that already declares masked_mha_available")

path.write_text(original.replace(needle, replacement), encoding="utf-8")
patched = path.read_text(encoding="utf-8")
if patched.count(replacement) != 1:
    raise SystemExit("SM120 sparse-MLA patch verification failed")
