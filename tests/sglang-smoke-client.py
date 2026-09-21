#!/usr/bin/env python3
"""Stdlib HTTP client and runtime probe for the isolated SGLang smoke."""

from __future__ import annotations

import importlib.metadata
import json
import os
import platform
import re
import socket
import sys
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:30000"


def http_timeout_seconds() -> int:
    raw_value = os.environ.get("GB10_SGLANG_HTTP_TIMEOUT_SECONDS", "20")
    if re.fullmatch(r"[1-9][0-9]*", raw_value) is None:
        raise RuntimeError(
            "GB10_SGLANG_HTTP_TIMEOUT_SECONDS must be an integer from 1 through 3600"
        )
    value = int(raw_value)
    if value > 3600:
        raise RuntimeError(
            "GB10_SGLANG_HTTP_TIMEOUT_SECONDS must be an integer from 1 through 3600"
        )
    return value


def fetch(path: str, payload: dict[str, object] | None = None) -> bytes:
    data = None
    headers: dict[str, str] = {}
    if payload is not None:
        data = json.dumps(
            payload, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(BASE_URL + path, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=http_timeout_seconds()) as response:
        return response.read()


def proc_status_value(name: str) -> str:
    with open("/proc/self/status", encoding="utf-8") as stream:
        for line in stream:
            key, separator, value = line.partition(":")
            if separator and key == name:
                return value.strip()
    raise RuntimeError(f"missing {name!r} in /proc/self/status")


def runtime() -> dict[str, object]:
    import torch

    if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
        raise RuntimeError("SGLang container did not enumerate a CUDA GPU")
    properties = torch.cuda.get_device_properties(0)
    capability = tuple(torch.cuda.get_device_capability(0))
    interfaces = sorted(name for _, name in socket.if_nameindex())
    return {
        "architecture": platform.machine(),
        "build": {
            "commit": os.environ.get("SGLANG_BUILD_COMMIT", ""),
            "image_tag": os.environ.get("SGLANG_IMAGE_TAG", ""),
        },
        "credentials_absent": not any(
            os.environ.get(name)
            for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "NGC_API_KEY")
        ),
        "gpu": {
            "compute_capability": f"{capability[0]}.{capability[1]}",
            "count": torch.cuda.device_count(),
            "name": properties.name,
            "total_memory_bytes": properties.total_memory,
        },
        "offline": {
            "hf_datasets": os.environ.get("HF_DATASETS_OFFLINE") == "1",
            "hf_hub": os.environ.get("HF_HUB_OFFLINE") == "1",
            "transformers": os.environ.get("TRANSFORMERS_OFFLINE") == "1",
        },
        "security": {
            "effective_capabilities_hex": proc_status_value("CapEff"),
            "network_interfaces": interfaces,
            "no_new_privileges": proc_status_value("NoNewPrivs") == "1",
            "proxy_environment_absent": not any(
                os.environ.get(name)
                for name in (
                    "ALL_PROXY",
                    "HTTP_PROXY",
                    "HTTPS_PROXY",
                    "all_proxy",
                    "http_proxy",
                    "https_proxy",
                )
            ),
        },
        "software": {
            "container_cuda": os.environ.get("CUDA_VERSION", ""),
            "python": platform.python_version(),
            "python_implementation": platform.python_implementation(),
            "sglang": importlib.metadata.version("sglang"),
            "torch": torch.__version__,
            "torch_cuda": torch.version.cuda,
        },
    }


def generate() -> dict[str, object]:
    payload: dict[str, object] = {
        "sampling_params": {"max_new_tokens": 256, "temperature": 0},
        "text": "Calculate 12 multiplied by 17. Return the final integer.",
    }
    document = json.loads(fetch("/generate", payload))
    if not isinstance(document, dict):
        raise RuntimeError("SGLang generation response is not a JSON object")
    text = document.get("text")
    if not isinstance(text, str):
        raise RuntimeError("SGLang generation response has no string text field")
    if re.search(r"(?<!\d)204(?!\d)", text) is None:
        raise RuntimeError("SGLang response did not contain the expected integer 204")
    meta_info = document.get("meta_info")
    if not isinstance(meta_info, dict):
        raise RuntimeError("SGLang generation response has no meta_info object")
    finish_reason = meta_info.get("finish_reason")
    if not isinstance(finish_reason, dict) or finish_reason.get("type") != "stop":
        raise RuntimeError(
            "SGLang generation response finish_reason.type was not stop"
        )
    return document


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"ready", "runtime", "generate"}:
        raise SystemExit("usage: sglang-smoke-client.py {ready|runtime|generate}")
    mode = sys.argv[1]
    try:
        if mode == "ready":
            fetch("/health")
            print("ready")
        elif mode == "runtime":
            print(json.dumps(runtime(), separators=(",", ":"), sort_keys=True))
        else:
            print(json.dumps(generate(), separators=(",", ":"), sort_keys=True))
    except (
        importlib.metadata.PackageNotFoundError,
        json.JSONDecodeError,
        OSError,
        RuntimeError,
        urllib.error.URLError,
    ) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
