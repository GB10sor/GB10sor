#!/usr/bin/env python3
"""Bounded standard-library acceptance client for MiniMax Music 3."""

from __future__ import annotations

import hashlib
import io
import json
import sys
import urllib.error
import urllib.request
import wave


BASE_URL = "http://127.0.0.1:8000"


def request_json(path: str) -> dict:
    with urllib.request.urlopen(f"{BASE_URL}{path}", timeout=30) as response:
        return json.load(response)


def ready(expected_model: str) -> None:
    payload = request_json("/v1/models")
    model_ids = [item.get("id") for item in payload.get("data", [])]
    if expected_model not in model_ids:
        raise RuntimeError(f"expected model is absent: {model_ids!r}")
    print(json.dumps({"status": "pass", "model": expected_model, "models": model_ids}, sort_keys=True))


def generate(expected_model: str) -> None:
    body = json.dumps(
        {
            "model": expected_model,
            "input": "[Verse]\nCircuit lights are glowing low\n[Chorus]\nBuild it once and let it flow",
            "instructions": "A concise instrumental electronic test cue at 92 BPM with soft synthesizer and a clear steady beat",
            "seed": 42,
            "max_new_tokens": 250,
        }
    ).encode()
    request = urllib.request.Request(
        f"{BASE_URL}/v1/audio/speech",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=900) as response:
        audio = response.read()
        content_type = response.headers.get_content_type()
    if len(audio) < 4096:
        raise RuntimeError(f"audio response is unexpectedly small: {len(audio)} bytes")
    with wave.open(io.BytesIO(audio), "rb") as wav:
        channels = wav.getnchannels()
        sample_rate = wav.getframerate()
        sample_width = wav.getsampwidth()
        frames = wav.getnframes()
    if channels != 2 or sample_rate != 32000 or sample_width != 2 or frames <= 0:
        raise RuntimeError(
            f"unexpected WAV format: channels={channels}, sample_rate={sample_rate}, "
            f"sample_width={sample_width}, frames={frames}"
        )
    print(
        json.dumps(
            {
                "status": "pass",
                "model": expected_model,
                "content_type": content_type,
                "bytes": len(audio),
                "sha256": hashlib.sha256(audio).hexdigest(),
                "channels": channels,
                "sample_rate": sample_rate,
                "sample_width_bytes": sample_width,
                "frames": frames,
                "duration_seconds": frames / sample_rate,
                "seed": 42,
                "max_new_tokens": 250,
            },
            sort_keys=True,
        )
    )


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in {"ready", "generate"}:
        raise SystemExit("usage: music3-smoke.py ready|generate MODEL_ID")
    action, model = sys.argv[1:]
    try:
        if action == "ready":
            ready(model)
        else:
            generate(model)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:2000]
        raise RuntimeError(f"HTTP {error.code}: {detail}") from error


if __name__ == "__main__":
    main()
