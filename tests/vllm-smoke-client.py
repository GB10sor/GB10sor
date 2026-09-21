#!/usr/bin/env python3
"""Loopback-only client and runtime adapter for the pinned GB10 vLLM smoke."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import platform
import re
import sys
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:8000"
EXPECTED_MODEL = os.environ.get("GB10_VLLM_MODEL", "")
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


def api_request(path: str, body: dict[str, object] | None = None) -> dict[str, object]:
    data = None
    headers: dict[str, str] = {}
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(BASE_URL + path, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def network_has_default_route() -> bool:
    try:
        with open("/proc/net/route", encoding="ascii") as routes:
            next(routes, None)
            for line in routes:
                fields = line.split()
                if len(fields) >= 4 and fields[0] != "lo" and fields[1] == "00000000":
                    return True
    except FileNotFoundError:
        return True
    return False


def ready() -> None:
    payload = api_request("/v1/models")
    model_ids = [item.get("id") for item in payload.get("data", [])]
    model_present = EXPECTED_MODEL in model_ids
    if not model_present:
        raise AssertionError(f"expected served model {EXPECTED_MODEL!r}, found {model_ids!r}")
    print(
        json.dumps(
            {
                "status": "pass",
                "model_present": model_present,
                "models": model_ids,
            },
            sort_keys=True,
        )
    )


def metadata() -> None:
    import torch

    expected_commit = os.environ["GB10_VLLM_EXPECTED_COMMIT"]
    expected_image_tag = os.environ["GB10_VLLM_EXPECTED_IMAGE_TAG"]
    expected_cuda = os.environ["GB10_VLLM_EXPECTED_CUDA"]
    expected_version = os.environ.get("GB10_VLLM_EXPECTED_VERSION", "")
    observed_commit = os.environ.get("VLLM_BUILD_COMMIT", "")
    observed_image_tag = os.environ.get("VLLM_IMAGE_TAG", "")
    observed_cuda = os.environ.get("CUDA_VERSION", "")
    vllm_version = importlib.metadata.version("vllm")
    architecture = platform.machine().lower()
    credentials_absent = not any(os.environ.get(name) for name in SENSITIVE_ENVIRONMENT)
    network_disabled = not network_has_default_route()

    if not torch.cuda.is_available():
        raise AssertionError("torch.cuda.is_available() is false")
    device_name = torch.cuda.get_device_name(0)
    capability = tuple(torch.cuda.get_device_capability(0))

    assertions = {
        "architecture_aarch64": architecture in {"aarch64", "arm64"},
        "build_commit_exact": observed_commit == expected_commit,
        "compute_capability_12_1": capability == (12, 1),
        "credentials_absent": credentials_absent,
        "cuda_version_exact": observed_cuda == expected_cuda,
        "device_name_contains_gb10": "GB10" in device_name.upper(),
        "image_tag_exact": observed_image_tag == expected_image_tag,
        "network_disabled": network_disabled,
        "package_version_accepted": not expected_version or vllm_version == expected_version,
        "proxy_environment_absent": not any(
            os.environ.get(name) for name in PROXY_ENVIRONMENT
        ),
    }
    failed = [name for name, passed in assertions.items() if not passed]
    if failed:
        raise AssertionError(f"runtime adapter assertions failed: {', '.join(failed)}")

    print(
        json.dumps(
            {
                "status": "pass",
                "release_channel": os.environ["GB10_VLLM_RELEASE_CHANNEL"],
                "vllm_version": vllm_version,
                "build_commit": observed_commit,
                "image_tag": observed_image_tag,
                "cuda_version": observed_cuda,
                "torch_cuda_version": torch.version.cuda,
                "model_revision": os.environ["GB10_VLLM_MODEL_REVISION"],
                "device": {
                    "architecture": architecture,
                    "compute_capability": f"{capability[0]}.{capability[1]}",
                    "name": device_name,
                },
                "assertions": assertions,
            },
            sort_keys=True,
        )
    )


def completion() -> None:
    payload = api_request(
        "/v1/chat/completions",
        {
            "model": EXPECTED_MODEL,
            "messages": [
                {
                    "role": "system",
                    "content": "Return only the final integer. Do not explain.",
                },
                {"role": "user", "content": "Calculate 12 multiplied by 17."},
            ],
            "temperature": 0,
            "seed": 20260824,
            "max_tokens": 256,
        },
    )
    choices = payload.get("choices", [])
    if not choices:
        raise AssertionError("vLLM returned no completion choices")
    choice = choices[0]
    answer = choice.get("message", {}).get("content", "")
    answer_contains_204 = bool(re.search(r"(?<!\d)204(?!\d)", answer))
    finish_reason = choice.get("finish_reason")
    if not answer_contains_204:
        raise AssertionError("response did not contain the expected integer 204")
    if finish_reason != "stop":
        raise AssertionError(f"expected finish_reason 'stop', found {finish_reason!r}")

    print(
        json.dumps(
            {
                "status": "pass",
                "model": payload.get("model", EXPECTED_MODEL),
                "answer": answer,
                "answer_contains_204": answer_contains_204,
                "answer_sha256": hashlib.sha256(answer.encode("utf-8")).hexdigest(),
                "completion_tokens": payload.get("usage", {}).get("completion_tokens"),
                "finish_reason": finish_reason,
                "api_response": payload,
            },
            sort_keys=True,
        )
    )


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"ready", "metadata", "completion"}:
        print(f"usage: {sys.argv[0]} ready|metadata|completion", file=sys.stderr)
        return 2
    try:
        {"ready": ready, "metadata": metadata, "completion": completion}[sys.argv[1]]()
    except (AssertionError, KeyError, urllib.error.URLError, ValueError) as error:
        print(f"vLLM smoke client failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
