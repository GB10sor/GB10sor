#!/usr/bin/env python3
"""Credential-free long-context, concurrency, and Unicode API checks."""

from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import time
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:8000"


def probe_family() -> str:
    family = os.environ.get("GB10_MODEL_PROBE_FAMILY", "generic")
    if family not in {"generic", "deepseek-v41"}:
        raise RuntimeError("GB10_MODEL_PROBE_FAMILY must be generic or deepseek-v41")
    return family


def timeout() -> float:
    return float(os.environ.get("GB10SOR_OPENAI_TIMEOUT_SECONDS", "900"))


def add_chat_template_kwargs(payload: dict[str, object]) -> None:
    """Match the profile request contract used by model-openai-smoke.py."""
    kwargs: dict[str, object] = {}
    thinking = os.environ.get("GB10_CHAT_TEMPLATE_THINKING")
    if thinking is not None:
        if thinking not in {"true", "false"}:
            raise RuntimeError("GB10_CHAT_TEMPLATE_THINKING must be true or false")
        kwargs["thinking"] = thinking == "true"
    enable_thinking = os.environ.get("GB10_CHAT_TEMPLATE_ENABLE_THINKING")
    if enable_thinking is not None:
        if enable_thinking not in {"true", "false"}:
            raise RuntimeError("GB10_CHAT_TEMPLATE_ENABLE_THINKING must be true or false")
        kwargs["enable_thinking"] = enable_thinking == "true"
    mode = os.environ.get("GB10_CHAT_TEMPLATE_THINKING_MODE")
    if mode is not None:
        if mode not in {"disabled", "adaptive", "enabled"}:
            raise RuntimeError("GB10_CHAT_TEMPLATE_THINKING_MODE must be disabled, adaptive, or enabled")
        kwargs["thinking_mode"] = mode
    effort = os.environ.get("GB10_CHAT_TEMPLATE_REASONING_EFFORT")
    if effort is not None:
        if effort not in {"none", "low", "medium", "high", "max"}:
            raise RuntimeError("GB10_CHAT_TEMPLATE_REASONING_EFFORT must be none, low, medium, high, or max")
        kwargs["reasoning_effort"] = effort
    if kwargs:
        payload["chat_template_kwargs"] = kwargs


def completion(model: str, prompt: str, max_tokens: int = 1024) -> dict[str, object]:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": max_tokens,
        "stream": False,
    }
    add_chat_template_kwargs(payload)
    request = urllib.request.Request(
        BASE_URL + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout()) as response:
        body = json.load(response)
    if not isinstance(body, dict):
        raise RuntimeError("completion response was not an object")
    return body


def content(body: dict[str, object]) -> str:
    choices = body.get("choices")
    if not isinstance(choices, list) or len(choices) != 1:
        raise RuntimeError("completion did not return exactly one choice")
    choice = choices[0]
    if not isinstance(choice, dict):
        raise RuntimeError("completion choice was not an object")
    message = choice.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        usage = body.get("usage")
        usage = usage if isinstance(usage, dict) else {}
        details = usage.get("completion_tokens_details")
        details = details if isinstance(details, dict) else {}
        diagnostic = {
            "finish_reason": choice.get("finish_reason"),
            "content_type": type(message.get("content") if isinstance(message, dict) else None).__name__,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "reasoning_tokens": details.get("reasoning_tokens"),
        }
        raise RuntimeError(f"completion did not contain assistant text: {diagnostic}")
    return str(message["content"]).strip()


def content_matches(body: dict[str, object], expected: str) -> bool:
    """Apply the same fail-closed visible-answer policy as the smoke gate."""

    mode = os.environ.get("GB10_COMPLETION_MATCH", "exact")
    if mode not in {"exact", "final-nonempty-line"}:
        raise RuntimeError(
            "GB10_COMPLETION_MATCH must be exact or final-nonempty-line"
        )
    observed = content(body)
    if mode == "exact":
        return observed == expected
    lines = [line.strip() for line in observed.splitlines() if line.strip()]
    return bool(lines) and lines[-1] == expected


def prompt_tokens(body: dict[str, object]) -> int:
    usage = body.get("usage")
    if not isinstance(usage, dict) or not isinstance(usage.get("prompt_tokens"), int):
        raise RuntimeError("completion did not report prompt token usage")
    return int(usage["prompt_tokens"])


def main() -> int:
    if len(sys.argv) != 5 or sys.argv[1] != "all":
        print("usage: model-openai-stress.py all MODEL MIN_PROMPT_TOKENS CONCURRENCY", file=sys.stderr)
        return 2
    model = sys.argv[2]
    minimum = int(sys.argv[3])
    concurrency = int(sys.argv[4])
    if minimum < 1024 or minimum > 65536:
        raise RuntimeError("MIN_PROMPT_TOKENS must be 1024..65536")
    if concurrency < 1 or concurrency > 32:
        raise RuntimeError("CONCURRENCY must be 1..32")

    unicode_expected = "GB10_UNICODE_OK|한글|日本語|é|🙂"
    unicode_body = completion(
        model,
        "Return exactly this text, preserving every character and separator: " + unicode_expected,
    )
    if not content_matches(unicode_body, unicode_expected):
        raise RuntimeError("Unicode integrity response differed from the required text")

    # A repeated short ASCII token is intentionally tokenizer-agnostic. Grow the
    # prompt until the server-reported usage crosses the declared threshold.
    repetitions = minimum + 1024
    long_body: dict[str, object] | None = None
    deepseek_probe = probe_family() == "deepseek-v41"
    for _ in range(3):
        if deepseek_probe:
            before = repetitions // 2
            after = repetitions - before
            long_prompt = (
                ("alpha " * before)
                + "Note for the record: the vault passphrase is COPPER-LANTERN-8315. "
                + ("alpha " * after)
                + "What is the vault passphrase mentioned above? Reply with the passphrase only."
            )
            long_expected = "COPPER-LANTERN-8315"
        else:
            long_prompt = (
                "Read the entire payload. The beginning marker is GB10_LONG_BEGIN. "
                + ("alpha " * repetitions)
                + "The final marker is GB10_LONG_END. Return exactly GB10_LONG_OK."
            )
            long_expected = "GB10_LONG_OK"
        long_body = completion(model, long_prompt)
        observed = prompt_tokens(long_body)
        # Some reasoning-capable servers can complete the internal reasoning
        # stream without emitting the requested final marker on an otherwise
        # healthy long-context request.  Keep the gate strict, but retry the
        # same sized request instead of treating the first empty final field as
        # a permanent deployment failure.
        if observed >= minimum and content_matches(long_body, long_expected):
            break
        if observed < minimum:
            repetitions = int(repetitions * minimum / max(observed, 1)) + 1024
    assert long_body is not None
    observed = prompt_tokens(long_body)
    if observed < minimum or not content_matches(long_body, long_expected):
        raise RuntimeError(
            f"long-context gate failed: prompt_tokens={observed}, "
            f"finish_reason={long_body['choices'][0].get('finish_reason')!r}, "
            f"usage={long_body.get('usage')!r}"
        )

    started = time.monotonic()

    def concurrent_request(index: int) -> dict[str, object]:
        if deepseek_probe:
            left = 17 + index
            right = 23 + index
            addend = 145 + index
            expected = str(left * right + addend)
            prompt = f"What is {left} * {right} + {addend}? Reply with only the number."
        else:
            expected = f"GB10_C{index}_OK"
            prompt = f"Return exactly {expected}. Do not add any other text."
        body = completion(model, prompt)
        if not content_matches(body, expected):
            raise RuntimeError(
                f"concurrent request {index} did not satisfy the selected visible-answer policy"
            )
        return {"index": index, "content": expected, "promptTokens": prompt_tokens(body)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        results = list(executor.map(concurrent_request, range(concurrency)))
    elapsed = time.monotonic() - started

    print(
        json.dumps(
            {
                "status": "pass",
                "unicode": unicode_expected,
                "longContext": {"minimumPromptTokens": minimum, "observedPromptTokens": observed},
                "concurrency": {"requests": concurrency, "elapsedSeconds": round(elapsed, 3), "results": results},
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, RuntimeError, ValueError, urllib.error.URLError) as error:
        print(f"model stress failed: {error}", file=sys.stderr)
        raise SystemExit(1)
