#!/usr/bin/env python3
"""Credential-free OpenAI-compatible readiness and completion checks."""

from __future__ import annotations

import json
import base64
import hashlib
import io
import math
import os
import struct
import sys
import urllib.error
import urllib.request
import zlib
import wave


BASE_URL = "http://127.0.0.1:8000"


def probe_family() -> str:
    """Return the fail-closed, profile-selected functional probe family."""

    family = os.environ.get("GB10_MODEL_PROBE_FAMILY", "generic")
    if family not in {"generic", "deepseek-v41"}:
        raise RuntimeError("GB10_MODEL_PROBE_FAMILY must be generic or deepseek-v41")
    return family


def exact_completion_probe() -> tuple[str, str]:
    if probe_family() == "deepseek-v41":
        # Pinned Boot-10 evidence identifies this as a byte-stable correctness
        # probe. The checkpoint can turn arbitrary copy-only sentinels into a
        # long continuation even when request-level thinking is disabled.
        return "What is 17 * 23 + 145? Reply with only the number.", "536"
    return "Return exactly GB10_OK. Do not add any other text.", "GB10_OK"


def integrity_probes() -> tuple[tuple[str, str, str], ...]:
    if probe_family() == "deepseek-v41":
        return (
            ("math-source", "What is 17 * 23 + 145? Reply with only the number.", "536"),
            ("math-multiply", "What is 37 * 4? Reply with only the number.", "148"),
            ("math-subtract", "What is 1000 - 357? Reply with only the number.", "643"),
            ("math-divide", "What is 144 / 12 + 7? Reply with only the number.", "19"),
        )
    return (
        ("copy", "Return exactly GLM53_COPY_729. Do not add any other text.", "GLM53_COPY_729"),
        ("arithmetic", "Compute 37 * 4. Return exactly the integer and nothing else.", "148"),
        ("punctuation", "Return exactly [GB10:TRIPS:OK]. Do not add any other text.", "[GB10:TRIPS:OK]"),
        ("sequence", "Return exactly A1-B2-C3-D4. Do not add any other text.", "A1-B2-C3-D4"),
    )


def request_timeout() -> float:
    raw = os.environ.get("GB10SOR_OPENAI_TIMEOUT_SECONDS", "120")
    try:
        timeout = float(raw)
    except ValueError as error:
        raise RuntimeError("GB10SOR_OPENAI_TIMEOUT_SECONDS is not numeric") from error
    if not 1 <= timeout <= 900:
        raise RuntimeError("GB10SOR_OPENAI_TIMEOUT_SECONDS must be 1..900")
    return timeout


def completion_token_budget(default: int = 512) -> int:
    """Return a bounded profile-selected output budget for reasoning models."""

    raw = os.environ.get("GB10_MODEL_SMOKE_MAX_TOKENS")
    if raw is None:
        return default
    try:
        budget = int(raw)
    except ValueError as error:
        raise RuntimeError("GB10_MODEL_SMOKE_MAX_TOKENS is not an integer") from error
    if not 64 <= budget <= 4096:
        raise RuntimeError("GB10_MODEL_SMOKE_MAX_TOKENS must be 64..4096")
    return budget


def completion_matches(content: object, expected: str) -> bool:
    """Apply the fail-closed, profile-selected visible-answer policy."""

    mode = os.environ.get("GB10_COMPLETION_MATCH", "exact")
    if mode not in {"exact", "final-nonempty-line"}:
        raise RuntimeError(
            "GB10_COMPLETION_MATCH must be exact or final-nonempty-line"
        )
    if not isinstance(content, str):
        return False
    if mode == "exact":
        return content.strip() == expected
    lines = [line.strip() for line in content.splitlines() if line.strip()]
    return bool(lines) and lines[-1] == expected


def add_chat_template_kwargs(payload: dict[str, object]) -> None:
    """Apply profile-selected, model-native reasoning controls to a request."""

    kwargs: dict[str, object] = {}
    thinking = os.environ.get("GB10_CHAT_TEMPLATE_THINKING")
    if thinking is not None:
        if thinking not in {"true", "false"}:
            raise RuntimeError("GB10_CHAT_TEMPLATE_THINKING must be true or false")
        kwargs["thinking"] = thinking == "true"

    enable_thinking = os.environ.get("GB10_CHAT_TEMPLATE_ENABLE_THINKING")
    if enable_thinking is not None:
        if enable_thinking not in {"true", "false"}:
            raise RuntimeError(
                "GB10_CHAT_TEMPLATE_ENABLE_THINKING must be true or false"
            )
        kwargs["enable_thinking"] = enable_thinking == "true"

    mode = os.environ.get("GB10_CHAT_TEMPLATE_THINKING_MODE")
    if mode is not None:
        if mode not in {"disabled", "adaptive", "enabled"}:
            raise RuntimeError(
                "GB10_CHAT_TEMPLATE_THINKING_MODE must be disabled, adaptive, or enabled"
            )
        kwargs["thinking_mode"] = mode

    effort = os.environ.get("GB10_CHAT_TEMPLATE_REASONING_EFFORT")
    if effort is not None:
        if effort not in {"none", "low", "medium", "high", "max"}:
            raise RuntimeError(
                "GB10_CHAT_TEMPLATE_REASONING_EFFORT must be none, low, medium, high, or max"
            )
        kwargs["reasoning_effort"] = effort

    if kwargs:
        payload["chat_template_kwargs"] = kwargs

    openai_effort = os.environ.get("GB10_OPENAI_REASONING_EFFORT")
    if openai_effort is not None:
        if openai_effort not in {"none", "minimal", "low", "medium", "high", "xhigh", "max"}:
            raise RuntimeError(
                "GB10_OPENAI_REASONING_EFFORT must be none, minimal, low, medium, high, xhigh, or max"
            )
        payload["reasoning_effort"] = openai_effort


def safe_completion_diagnostic(body: dict[str, object], attempt: int) -> dict[str, object]:
    """Return response metadata without exposing generated or reasoning text."""

    diagnostic: dict[str, object] = {"status": "fail", "attempt": attempt}
    choices = body.get("choices")
    if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
        diagnostic["response_shape"] = "invalid"
        return diagnostic
    choice = choices[0]
    diagnostic["finish_reason"] = choice.get("finish_reason")
    message = choice.get("message")
    if isinstance(message, dict):
        for field in ("content", "reasoning_content"):
            value = message.get(field)
            diagnostic[f"{field}_present"] = isinstance(value, str) and bool(value)
            diagnostic[f"{field}_characters"] = len(value) if isinstance(value, str) else 0
    usage = body.get("usage")
    if isinstance(usage, dict):
        diagnostic["usage"] = {
            key: value
            for key, value in usage.items()
            if key in {"prompt_tokens", "completion_tokens", "total_tokens"}
            and isinstance(value, int)
        }
    return diagnostic


def request(path: str, payload: dict[str, object] | None = None) -> object:
    data = None
    headers: dict[str, str] = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE_URL + path, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=request_timeout()) as response:
        return json.load(response)


def red_png_data_url() -> str:
    """Return a generated 64x64 RGB PNG without relying on fixture files."""

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    width = height = 64
    scanlines = b"".join(b"\x00" + (b"\xff\x00\x00" * width) for _ in range(height))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(scanlines, level=9))
        + chunk(b"IEND", b"")
    )
    return "data:image/png;base64," + base64.b64encode(png).decode("ascii")


def tone_wav_base64() -> str:
    """Return a deterministic half-second 440 Hz mono PCM WAV."""

    sample_rate = 16_000
    frames = bytearray()
    for index in range(sample_rate // 2):
        sample = int(0.20 * 32767 * math.sin(2 * math.pi * 440 * index / sample_rate))
        frames.extend(struct.pack("<h", sample))
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(bytes(frames))
    return base64.b64encode(output.getvalue()).decode("ascii")


def streamed_content(model: str) -> tuple[str, int, bool, str]:
    if probe_family() == "deepseek-v41":
        prompt = "What is 17 * 23 + 145? Reply with only the number."
        expected = "536"
    else:
        prompt = "Return exactly GB10_STREAM_OK. Do not add any other text."
        expected = "GB10_STREAM_OK"
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": prompt,
            }
        ],
        "temperature": 0,
        "max_tokens": completion_token_budget(),
        "stream": True,
    }
    add_chat_template_kwargs(payload)
    req = urllib.request.Request(
        BASE_URL + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    parts: list[str] = []
    chunks = 0
    done = False
    with urllib.request.urlopen(req, timeout=request_timeout()) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8").strip()
            if not line or line.startswith(":"):
                continue
            if not line.startswith("data: "):
                raise RuntimeError(f"stream returned a non-SSE line: {line!r}")
            data = line[6:]
            if data == "[DONE]":
                done = True
                break
            event = json.loads(data)
            choices = event.get("choices")
            if not isinstance(choices, list) or len(choices) != 1:
                raise RuntimeError("stream event did not contain exactly one choice")
            delta = choices[0].get("delta")
            if not isinstance(delta, dict):
                raise RuntimeError("stream event did not contain a delta object")
            content = delta.get("content")
            if isinstance(content, str):
                parts.append(content)
            chunks += 1
    return "".join(parts).strip(), chunks, done, expected


def output_integrity(model: str) -> dict[str, object]:
    """Reject quiet decode corruption with repeated, exact ASCII probes.

    The receipt intentionally records only lengths and hashes, not generated
    text. Exact answers exercise copying, arithmetic, punctuation, and a
    second deterministic pass while keeping private qualification evidence
    free of model output.
    """

    probes = integrity_probes()
    receipts: list[dict[str, object]] = []
    for pass_number in (1, 2):
        for name, prompt, expected in probes:
            payload: dict[str, object] = {
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0,
                "max_tokens": completion_token_budget(256),
                "stream": False,
            }
            add_chat_template_kwargs(payload)
            body = request("/v1/chat/completions", payload)
            if not isinstance(body, dict):
                raise RuntimeError(f"integrity {name} returned a non-object response")
            choices = body.get("choices")
            if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
                raise RuntimeError(f"integrity {name} returned an invalid choice shape")
            choice = choices[0]
            if choice.get("finish_reason") != "stop":
                raise RuntimeError(f"integrity {name} did not finish with stop")
            message = choice.get("message")
            if not isinstance(message, dict):
                raise RuntimeError(f"integrity {name} returned an invalid message")
            content = message.get("content")
            if not isinstance(content, str):
                raise RuntimeError(f"integrity {name} returned non-text content")
            normalized = content.strip()
            if "\ufffd" in normalized or any(ord(character) < 32 for character in normalized):
                raise RuntimeError(f"integrity {name} returned replacement or control characters")
            try:
                encoded = normalized.encode("ascii", errors="strict")
            except UnicodeEncodeError as error:
                raise RuntimeError(f"integrity {name} returned non-ASCII text") from error
            if normalized != expected:
                raise RuntimeError(
                    f"integrity {name} returned the wrong exact answer "
                    f"(length={len(normalized)}, sha256={hashlib.sha256(encoded).hexdigest()})"
                )
            receipts.append(
                {
                    "pass": pass_number,
                    "probe": name,
                    "characters": len(normalized),
                    "sha256": hashlib.sha256(encoded).hexdigest(),
                }
            )
    return {"status": "pass", "passes": 2, "probesPerPass": len(probes), "receipts": receipts}


def main() -> int:
    actions = {"ready", "completion", "integrity", "multimodal", "audio", "stream", "structured", "reasoning"}
    if len(sys.argv) != 3 or sys.argv[1] not in actions:
        print(
            "usage: model-openai-smoke.py ready|completion|integrity|multimodal|audio|stream|structured|reasoning MODEL",
            file=sys.stderr,
        )
        return 2
    action, model = sys.argv[1:]
    if action == "ready":
        body = request("/v1/models")
        assert isinstance(body, dict)
        data = body.get("data")
        assert isinstance(data, list) and data
        identifiers = [item.get("id") for item in data if isinstance(item, dict)]
        if model not in identifiers:
            raise RuntimeError(f"served model mismatch: expected {model!r}, got {identifiers!r}")
        print(json.dumps(body, sort_keys=True))
        return 0

    if action == "integrity":
        print(json.dumps(output_integrity(model), sort_keys=True))
        return 0

    if action == "reasoning":
        payload: dict[str, object] = {
            "model": model,
            "messages": [{"role": "user", "content": "Think through 19 + 23, then give the final answer 42."}],
            "temperature": 0,
            "max_tokens": completion_token_budget(2048),
            "stream": False,
        }
        add_chat_template_kwargs(payload)
        kwargs = payload.setdefault("chat_template_kwargs", {})
        assert isinstance(kwargs, dict)
        kwargs["enable_thinking"] = True
        body = request("/v1/chat/completions", payload)
        assert isinstance(body, dict)
        choices = body.get("choices")
        if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
            raise RuntimeError("reasoning response has an invalid choice shape")
        message = choices[0].get("message")
        if not isinstance(message, dict):
            raise RuntimeError("reasoning response has no assistant message")
        reasoning = message.get("reasoning_content")
        content = message.get("content")
        if not isinstance(reasoning, str) or not reasoning.strip():
            raise RuntimeError("reasoning parser returned no separate reasoning_content")
        if not isinstance(content, str) or "42" not in content:
            raise RuntimeError("reasoning response did not contain the expected final answer")
        print(json.dumps({
            "status": "pass",
            "reasoningCharacters": len(reasoning),
            "answerContains42": True,
            "finishReason": choices[0].get("finish_reason"),
        }, sort_keys=True))
        return 0

    if action == "multimodal":
        payload: dict[str, object] = {
            "model": model,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are a deterministic multimodal validation endpoint. "
                        "Follow the user's exact-output instruction literally."
                    ),
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                "What single color fills this image? Answer with one word."
                                if probe_family() == "deepseek-v41"
                                else (
                                    "Inspect the attached image. Reply with exactly the nine uppercase ASCII "
                                    "characters VISION_OK. Do not add colons, Markdown, code fences, "
                                    "explanations, or any other punctuation."
                                )
                            ),
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": red_png_data_url()},
                        },
                    ],
                }
            ],
            "temperature": 0,
            # Inkling can consume tens of native reasoning tokens before its
            # visible answer. Match the existing text/audio smoke budget so a
            # valid multimodal response is not truncated before content.
            # Reasoning models can consume most of a smaller budget before
            # emitting the schema-constrained visible answer. Keep the exact
            # schema gate, but leave enough room for the answer to appear.
            "max_tokens": completion_token_budget(2048),
            "stream": False,
        }
        add_chat_template_kwargs(payload)
        if os.environ.get("GB10_MULTIMODAL_DISABLE_THINKING") == "1":
            kwargs = payload.setdefault("chat_template_kwargs", {})
            assert isinstance(kwargs, dict)
            kwargs["enable_thinking"] = False
        body = request("/v1/chat/completions", payload)
        assert isinstance(body, dict)
        choices = body.get("choices")
        assert isinstance(choices, list) and len(choices) == 1
        message = choices[0].get("message")
        assert isinstance(message, dict)
        content = message.get("content")
        expected = "red" if probe_family() == "deepseek-v41" else "VISION_OK"
        normalized = content.strip() if isinstance(content, str) else None
        if expected == "red" and isinstance(normalized, str):
            normalized = normalized.lower()
        if normalized != expected:
            print(
                json.dumps(
                    {"status": "fail", "modality": "image+text", "response": body},
                    sort_keys=True,
                )
            )
            raise RuntimeError(f"multimodal request returned {content!r}, expected exact {expected!r}")
        usage = body.get("usage")
        assert isinstance(usage, dict) and isinstance(usage.get("prompt_tokens"), int)
        print(json.dumps({"status": "pass", "modality": "image+text", "response": body}, sort_keys=True))
        return 0

    if action == "audio":
        payload = {
            "model": model,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                "Listen to the attached tone. Reply with exactly AUDIO_OK. "
                                "Do not add any other text."
                            ),
                        },
                        {
                            "type": "input_audio",
                            "input_audio": {"data": tone_wav_base64(), "format": "wav"},
                        },
                    ],
                }
            ],
            "temperature": 0,
            "max_tokens": completion_token_budget(),
            "stream": False,
        }
        add_chat_template_kwargs(payload)
        body = request("/v1/chat/completions", payload)
        assert isinstance(body, dict)
        choices = body.get("choices")
        assert isinstance(choices, list) and len(choices) == 1
        message = choices[0].get("message")
        assert isinstance(message, dict)
        content = message.get("content")
        if not isinstance(content, str) or content.strip() != "AUDIO_OK":
            print(
                json.dumps(
                    {"status": "fail", "modality": "audio+text", "response": body},
                    sort_keys=True,
                )
            )
            raise RuntimeError(f"audio request returned {content!r}, expected exact 'AUDIO_OK'")
        print(json.dumps({"status": "pass", "modality": "audio+text", "response": body}, sort_keys=True))
        return 0

    if action == "stream":
        content, chunks, done, expected = streamed_content(model)
        if not completion_matches(content, expected):
            raise RuntimeError("stream did not satisfy the selected visible-answer policy")
        if chunks < 1 or not done:
            raise RuntimeError(f"stream framing failed: chunks={chunks}, done={done}")
        print(json.dumps({"status": "pass", "content": content, "chunks": chunks, "done": done}, sort_keys=True))
        return 0

    if action == "structured":
        payload = {
            "model": model,
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "Return only this JSON object with no Markdown or explanation: "
                        '{"status":"GB10_OK","count":10}'
                    ),
                }
            ],
            "temperature": 0,
            # Reasoning-capable models may spend more than 512 native tokens
            # before emitting their schema-constrained visible answer. Keep
            # the exact parsed-value gate, but do not truncate that answer.
            "max_tokens": completion_token_budget(2048),
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "gb10_result",
                    "strict": True,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "status": {"type": "string", "enum": ["GB10_OK"]},
                            "count": {"type": "integer", "const": 10},
                        },
                        "required": ["status", "count"],
                        "additionalProperties": False,
                    },
                },
            },
        }
        add_chat_template_kwargs(payload)
        body = request("/v1/chat/completions", payload)
        assert isinstance(body, dict)
        choices = body.get("choices")
        assert isinstance(choices, list) and len(choices) == 1
        message = choices[0].get("message")
        assert isinstance(message, dict)
        content = message.get("content")
        if not isinstance(content, str):
            print(
                json.dumps(
                    {"status": "fail", "schema": "gb10_result", "response": body},
                    sort_keys=True,
                )
            )
            raise RuntimeError(f"structured response content is {content!r}, not text")
        if not content.strip():
            print(
                json.dumps(
                    {"status": "fail", "schema": "gb10_result", "response": body},
                    sort_keys=True,
                )
            )
            raise RuntimeError("structured response content is empty")
        try:
            parsed = json.loads(content)
        except json.JSONDecodeError:
            diagnostic = safe_completion_diagnostic(body, 1)
            diagnostic.update(
                {
                    "schema": "gb10_result",
                    "json_parse": "fail",
                    "content": content,
                }
            )
            print(json.dumps(diagnostic, sort_keys=True))
            raise
        if parsed != {"status": "GB10_OK", "count": 10}:
            raise RuntimeError(f"structured response returned {parsed!r}")
        print(json.dumps({"status": "pass", "schema": "gb10_result", "parsed": parsed}, sort_keys=True))
        return 0

    completion_prompt, completion_expected = exact_completion_probe()
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": completion_prompt,
            }
        ],
        "temperature": 0,
        # Muse Glimmer can emit a bounded internal reasoning trace before the
        # exact assistant content. 64 tokens truncated the verified checkpoint
        # before it reached its answer on GB10.
        "max_tokens": completion_token_budget(),
        "stream": False,
    }
    add_chat_template_kwargs(payload)
    responses: list[dict[str, object]] = []
    for attempt in range(2):
        body = request("/v1/chat/completions", payload)
        assert isinstance(body, dict)
        choices = body.get("choices")
        assert isinstance(choices, list) and len(choices) == 1
        choice = choices[0]
        assert isinstance(choice, dict)
        if choice.get("finish_reason") != "stop":
            print(json.dumps(safe_completion_diagnostic(body, attempt + 1), sort_keys=True))
            raise RuntimeError(
                f"attempt {attempt + 1} finish_reason is {choice.get('finish_reason')!r}, not 'stop'"
            )
        message = choice.get("message")
        assert isinstance(message, dict)
        content = message.get("content")
        if not completion_matches(content, completion_expected):
            # Preserve only response shape and token counts. This makes a
            # reasoning-parser mismatch diagnosable without recording model
            # output or chain-of-thought in qualification evidence.
            print(json.dumps(safe_completion_diagnostic(body, attempt + 1), sort_keys=True))
            raise RuntimeError(
                f"attempt {attempt + 1} did not satisfy the selected visible-answer policy"
            )
        usage = body.get("usage")
        assert isinstance(usage, dict)
        prompt_tokens = usage.get("prompt_tokens")
        completion_tokens = usage.get("completion_tokens")
        if not isinstance(prompt_tokens, int) or prompt_tokens <= 0:
            raise RuntimeError(f"attempt {attempt + 1} reported invalid prompt token usage")
        if not isinstance(completion_tokens, int) or completion_tokens <= 0:
            raise RuntimeError(f"attempt {attempt + 1} reported invalid completion token usage")
        responses.append(body)
    print(json.dumps({"status": "pass", "attempts": 2, "responses": responses}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, RuntimeError, UnicodeDecodeError, urllib.error.URLError) as error:
        print(f"model smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
