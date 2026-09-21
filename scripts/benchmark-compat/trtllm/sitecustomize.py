"""Narrow llama-benchy compatibility shim for TensorRT-LLM OpenAI servers.

llama-benchy 0.4.0 unconditionally adds ``return_token_ids`` to streaming
chat-completion requests. TensorRT-LLM 1.3.0rc26 rejects that extension as an
unknown request field, including when its value is false. The server still
returns OpenAI streaming usage, which llama-benchy uses for total token counts.

This module is loaded only when the adapter explicitly enables its directory
on PYTHONPATH for a ``runtime: trtllm`` recipe. It makes no changes unless the
guard environment variable is also set.
"""

from __future__ import annotations

import os


if os.environ.get("GB10_LLAMA_BENCHY_TRTLLM_COMPAT") == "1":
    try:
        from llama_benchy.client import LLMClient
    except ModuleNotFoundError:
        # The outer sparkrun interpreter does not install llama-benchy. The
        # later uvx child does and imports this module again.
        pass
    else:
        _original_build_generation_payload = LLMClient._build_generation_payload

        def _build_generation_payload_without_return_token_ids(
            self, messages, max_tokens, no_cache
        ):
            payload = _original_build_generation_payload(
                self, messages, max_tokens, no_cache
            )
            payload.pop("return_token_ids", None)
            return payload

        LLMClient._build_generation_payload = (
            _build_generation_payload_without_return_token_ids
        )
