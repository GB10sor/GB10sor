#!/usr/bin/env python3
"""Bounded GB10 probe for the patched Qwen sparse-attention resolver."""

import json

import torch
from flashinfer.decode import trtllm_batch_decode_with_kv_cache
from sglang.srt.layers.attention.qwen_sparse_attn_backend import (
    _resolve_trtllm_sparse_decode,
)
from sglang.srt.models.registry import ModelRegistry


assert torch.cuda.is_available()
assert torch.cuda.get_device_capability(0) == (12, 1)
assert _resolve_trtllm_sparse_decode() is trtllm_batch_decode_with_kv_cache
assert "Qwen4ExpForConditionalGeneration" in str(ModelRegistry.models)

torch.manual_seed(7)
device = "cuda"
query = torch.randn((1, 24, 256), device=device, dtype=torch.bfloat16)
key = torch.randn((1, 2, 64, 256), device=device, dtype=torch.bfloat16)
value = torch.randn_like(key)
workspace = torch.empty(128 * 1024 * 1024, device=device, dtype=torch.uint8)
block_tables = torch.zeros((1, 1), device=device, dtype=torch.int32)
sequence_lengths = torch.tensor([64], device=device, dtype=torch.int32)

# Do not force backend="trtllm-gen": FlashInfer 0.6.17 selects its supported
# XQA implementation for SM121 when this public wrapper is used in auto mode.
output = trtllm_batch_decode_with_kv_cache(
    query=query,
    kv_cache=(key, value),
    workspace_buffer=workspace,
    block_tables=block_tables,
    seq_lens=sequence_lengths,
    max_seq_len=64,
    bmm1_scale=256**-0.5,
    bmm2_scale=1.0,
)
torch.cuda.synchronize()

assert output.shape == (1, 24, 256)
assert torch.isfinite(output).all()
print(
    json.dumps(
        {
            "architecture": "Qwen4ExpForConditionalGeneration",
            "cudaCapability": list(torch.cuda.get_device_capability(0)),
            "device": torch.cuda.get_device_name(0),
            "outputChecksum": round(float(output.float().sum()), 8),
            "outputDtype": str(output.dtype),
            "outputShape": list(output.shape),
            "probe": "sm121-flashinfer-auto-qsa",
            "status": "pass",
        },
        sort_keys=True,
    )
)
