#!/usr/bin/env python3
"""Offline CUDA smoke test for OpenMed privacy-filter-nemotron-v2."""

from __future__ import annotations

import json
import math
import sys
import time

import torch
import transformers
from transformers import AutoModelForTokenClassification, AutoTokenizer


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: privacy-filter-smoke.py MODEL_PATH", file=sys.stderr)
        return 2
    model_path = sys.argv[1]
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable")

    started = time.monotonic()
    tokenizer = AutoTokenizer.from_pretrained(
        model_path,
        local_files_only=True,
        trust_remote_code=False,
    )
    tokenizer_loaded = time.monotonic()
    model = AutoModelForTokenClassification.from_pretrained(
        model_path,
        local_files_only=True,
        trust_remote_code=False,
        dtype=torch.bfloat16,
        device_map={"": "cuda:0"},
        low_cpu_mem_usage=True,
    )
    model_loaded = time.monotonic()
    model.eval()

    sample = (
        "Patient Sarah Johnson, MRN 4872910, can be reached at "
        "sarah.johnson@example.com or 415-555-0123."
    )
    encoded = tokenizer(sample, return_tensors="pt").to("cuda")
    with torch.no_grad():
        logits = model(**encoded).logits
    inferred = time.monotonic()
    if not torch.isfinite(logits).all().item():
        raise RuntimeError("non-finite logits")
    predictions = logits.argmax(-1).cpu()[0].tolist()
    id2label = {int(key): value for key, value in model.config.id2label.items()}
    labels = [id2label[index] for index in predictions if id2label[index] != "O"]
    if not labels:
        raise RuntimeError("the deterministic PII sample produced no non-O labels")

    result = {
        "status": "pass",
        "device": torch.cuda.get_device_name(0),
        "compute_capability": ".".join(map(str, torch.cuda.get_device_capability(0))),
        "torch": torch.__version__,
        "torch_cuda": torch.version.cuda,
        "transformers": transformers.__version__,
        "sequence_tokens": int(encoded["input_ids"].shape[-1]),
        "non_o_token_count": len(labels),
        "unique_non_o_labels": sorted(set(labels)),
        "finite_checksum": math.isfinite(float(logits.float().sum().item())),
        "tokenizer_load_seconds": round(tokenizer_loaded - started, 3),
        "model_load_seconds": round(model_loaded - tokenizer_loaded, 3),
        "inference_seconds": round(inferred - model_loaded, 3),
        "elapsed_seconds": round(inferred - started, 3),
    }
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, RuntimeError, ValueError) as error:
        print(f"privacy-filter smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
