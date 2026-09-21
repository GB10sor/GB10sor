#!/usr/bin/env python3
"""Create deterministic, network-free target/draft fixtures for TRT-LLM.

The two checkpoints intentionally have identical seeded weights.  This is a
mechanism/correctness smoke fixture, not a performance proxy for a small draft
model: every greedy draft should agree with the target, making acceptance an
objective runtime assertion.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import torch
import tensorrt_llm
from tokenizers import Tokenizer
from tokenizers.models import WordLevel
from tokenizers.pre_tokenizers import Whitespace
from transformers import LlamaConfig, LlamaForCausalLM, PreTrainedTokenizerFast


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    destination = args.destination.resolve()
    target = destination / "target"
    draft = destination / "draft"
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"fixture destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    if not torch.cuda.is_available():
        raise SystemExit("torch.cuda.is_available() is false")
    device_name = torch.cuda.get_device_name(0)
    capability = tuple(torch.cuda.get_device_capability(0))
    if "GB10" not in device_name.upper():
        raise SystemExit(f"expected a GB10 GPU, found {device_name!r}")
    if capability != (12, 1):
        raise SystemExit(
            f"expected GB10 compute capability 12.1, found {capability[0]}.{capability[1]}"
        )

    ordinary_tokens = ["zero", "one", "two", "three", "four"] + [
        f"token-{index}" for index in range(248)
    ]
    vocabulary = {token: index for index, token in enumerate(ordinary_tokens)}
    vocabulary.update({"<unk>": 253, "<bos>": 254, "<eos>": 255})

    backend = Tokenizer(WordLevel(vocab=vocabulary, unk_token="<unk>"))
    backend.pre_tokenizer = Whitespace()
    tokenizer = PreTrainedTokenizerFast(
        tokenizer_object=backend,
        bos_token="<bos>",
        eos_token="<eos>",
        unk_token="<unk>",
        pad_token="<eos>",
    )
    tokenizer.model_max_length = 128

    config = LlamaConfig(
        attention_bias=False,
        attention_dropout=0.0,
        bos_token_id=254,
        eos_token_id=255,
        hidden_act="silu",
        hidden_size=512,
        initializer_range=0.0,
        intermediate_size=1024,
        max_position_embeddings=128,
        mlp_bias=False,
        num_attention_heads=8,
        num_hidden_layers=2,
        num_key_value_heads=8,
        pad_token_id=255,
        tie_word_embeddings=False,
        torch_dtype="float16",
        use_cache=True,
        vocab_size=256,
    )

    torch.manual_seed(20260824)
    model = LlamaForCausalLM(config).half().eval()
    with torch.no_grad():
        for parameter in model.parameters():
            parameter.zero_()

    target.mkdir()
    model.save_pretrained(target, safe_serialization=True)
    tokenizer.save_pretrained(target)
    shutil.copytree(target, draft)

    summary = {
        "draft_equals_target": True,
        "fixture_kind": "deterministic-zero-weight-tiny-llama",
        "gpu": {
            "compute_capability": f"{capability[0]}.{capability[1]}",
            "name": device_name,
        },
        "hidden_size": config.hidden_size,
        "num_hidden_layers": config.num_hidden_layers,
        "seed": 20260824,
        "tensorrt_llm_version": getattr(tensorrt_llm, "__version__", "unknown"),
        "vocab_size": config.vocab_size,
    }
    (destination / "fixture.json").write_text(
        json.dumps(summary, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
