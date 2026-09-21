#!/usr/bin/env python3
"""Small stdlib-only client used inside a network-isolated TRT-LLM container."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import platform
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path


BASE_URL = "http://127.0.0.1:8000"
EDGE_METRICS_DIR = Path("/tmp/gb10-perf")
SENSITIVE_ENVIRONMENT = (
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AZURE_CLIENT_SECRET",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "HF_TOKEN",
    "HUGGING_FACE_HUB_TOKEN",
    "NGC_API_KEY",
    "NVIDIA_API_KEY",
)
PROXY_ENVIRONMENT = (
    "ALL_PROXY",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "all_proxy",
    "http_proxy",
    "https_proxy",
)


def fetch(url: str, data: bytes | None = None) -> bytes:
    request = urllib.request.Request(url, data=data)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read()


def model_id() -> str:
    document = json.loads(fetch(BASE_URL + "/v1/models"))
    if not isinstance(document, dict):
        raise RuntimeError("model-list response is not an object")
    models = document.get("data")
    if not isinstance(models, list) or not models:
        raise RuntimeError("model list is empty")
    first = models[0]
    if not isinstance(first, dict):
        raise RuntimeError("first model entry is not an object")
    identifier = first.get("id")
    if not isinstance(identifier, str) or not identifier:
        raise RuntimeError("first model has no non-empty id")
    return identifier


def edge_metrics() -> list[object]:
    records: list[object] = []
    if not EDGE_METRICS_DIR.is_dir():
        return records
    for path in sorted(EDGE_METRICS_DIR.glob("*.jsonl")):
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                if line.strip():
                    records.append(json.loads(line))
    return records


def process_status() -> dict[str, str]:
    selected: dict[str, str] = {}
    with Path("/proc/self/status").open(encoding="ascii") as stream:
        for line in stream:
            name, _, value = line.partition(":")
            if name in {"CapEff", "NoNewPrivs"}:
                selected[name] = value.strip()
    return selected


def runtime() -> dict[str, object]:
    import torch

    capability = tuple(torch.cuda.get_device_capability(0))
    driver_text = ""
    driver_path = Path("/proc/driver/nvidia/version")
    if driver_path.is_file():
        driver_text = driver_path.read_text(encoding="utf-8", errors="replace")
    driver_match = re.search(
        r"Kernel Module(?: for \S+)?\s+([0-9]+(?:\.[0-9]+)+)", driver_text
    )
    return {
        "architecture": platform.machine().lower(),
        "credentials_absent": not any(
            os.environ.get(name) for name in SENSITIVE_ENVIRONMENT
        ),
        "cuda_environment": os.environ.get("CUDA_VERSION"),
        "device": {
            "compute_capability": f"{capability[0]}.{capability[1]}",
            "name": torch.cuda.get_device_name(0),
        },
        "driver": driver_match.group(1) if driver_match else None,
        "network_interfaces": sorted(path.name for path in Path("/sys/class/net").iterdir()),
        "process_status": process_status(),
        "proxy_environment_absent": not any(
            os.environ.get(name) for name in PROXY_ENVIRONMENT
        ),
        "python": platform.python_version(),
        "software": {
            "pytorch": importlib.metadata.version("torch"),
            "tensorrt_llm": importlib.metadata.version("tensorrt-llm"),
            "torch_cuda": torch.version.cuda,
        },
        "torch_cuda_available": torch.cuda.is_available(),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=("ready", "runtime", "completion", "stable-metrics", "edge-metrics"),
    )
    args = parser.parse_args()

    try:
        if args.mode == "ready":
            model_id()
            print("ready")
        elif args.mode == "runtime":
            print(json.dumps(runtime(), separators=(",", ":"), sort_keys=True))
        elif args.mode == "completion":
            payload = json.dumps(
                {
                    "ignore_eos": True,
                    "max_tokens": 16,
                    "model": model_id(),
                    "prompt": "one two three four",
                    "temperature": 0,
                },
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            sys.stdout.buffer.write(fetch(BASE_URL + "/v1/completions", payload))
        elif args.mode == "stable-metrics":
            sys.stdout.buffer.write(fetch(BASE_URL + "/perf_metrics"))
        else:
            print(json.dumps(edge_metrics(), separators=(",", ":"), sort_keys=True))
    except (OSError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
