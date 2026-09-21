#!/usr/bin/env python3
"""Offline runtime, provenance, and deterministic-response probe for SGLang fd73."""

from __future__ import annotations

import hashlib
import importlib
import importlib.metadata
import json
import os
import pathlib
import platform
import re
import runpy
import socket
import struct
import sys
import urllib.error
import urllib.request


BASE_URL = "http://127.0.0.1:30000"
EXPECTED_VERSION = "0.5.19.dev20260824+gfd73d4b019"
EXPECTED_DEPENDENCIES = {
    "apache-tvm-ffi": "0.1.11",
    "av": "16.1.0",
    "cuda-python": "13.3.1",
    "cuda-tile": "1.6.0rc5",
    "decord2": "3.4.0",
    "flashinfer-python": "0.6.17",
    "nvidia-cutlass-dsl": "4.6.2",
    "quack-kernels": "0.6.4",
    "sgl-deep-ep": "0.1.2",
    "sgl-deep-gemm": "0.1.5.post3",
    "sglang-kernel": "0.4.6.post1",
    "torch": "2.13.0+cu130",
    "torchaudio": "2.11.0+cu130",
    "torchvision": "0.28.0+cu130",
}
RUST_EXTENSION_MODULES = (
    "sglang.srt.rust_extensions._grpc",
    "sglang.srt.rust_extensions._multimodal",
    "sglang.srt.rust_extensions._server",
)


def required_environment(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"required environment variable is absent: {name}")
    return value


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
        data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
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


def package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError as error:
        raise RuntimeError(f"required distribution is absent: {name}") from error


def distribution_inventory() -> dict[str, object]:
    """Return every base distribution except the intentionally overlaid SGLang."""
    distributions: list[dict[str, str]] = []
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name")
        if not name:
            raise RuntimeError("installed distribution has no Name metadata")
        normalized_name = re.sub(r"[-_.]+", "-", name).lower()
        if normalized_name == "sglang":
            continue
        distributions.append(
            {
                "location": str(pathlib.Path(distribution.locate_file("")).resolve()),
                "name": normalized_name,
                "version": distribution.version,
            }
        )
    distributions.sort(key=lambda item: (item["name"], item["version"], item["location"]))
    return {"excluded_distribution": "sglang", "distributions": distributions}


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def path_inside(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def elf_identity(path: pathlib.Path) -> dict[str, object]:
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise RuntimeError(f"compiled extension is not ELF: {path}")
    if header[4] != 2 or header[5] != 1:
        raise RuntimeError(f"compiled extension is not little-endian ELF64: {path}")
    machine = struct.unpack_from("<H", header, 18)[0]
    if machine != 183:
        raise RuntimeError(f"compiled extension is not EM_AARCH64: {path} ({machine})")
    return {
        "elf_class": "ELF64",
        "elf_data": "little-endian",
        "elf_machine": "EM_AARCH64",
        "path": str(path),
        "sha256": sha256_file(path),
        "size": path.stat().st_size,
    }


def provenance() -> dict[str, object]:
    overlay_root = pathlib.Path(
        required_environment("GB10_SGLANG_OVERLAY_ROOT")
    ).resolve(strict=True)
    source_commit = required_environment("GB10_SGLANG_SOURCE_COMMIT")
    if source_commit != "fd73d4b0190693234455e6fd8f0d227ab5f4bd23":
        raise RuntimeError(f"unexpected source commit: {source_commit}")
    if platform.machine() != "aarch64":
        raise RuntimeError(f"runtime architecture is not aarch64: {platform.machine()}")
    if platform.python_version() != "3.12.3":
        raise RuntimeError(f"runtime Python is not 3.12.3: {platform.python_version()}")

    sglang = importlib.import_module("sglang")
    module_path = pathlib.Path(str(sglang.__file__)).resolve(strict=True)
    if not path_inside(module_path, overlay_root):
        raise RuntimeError(f"sglang module did not resolve from overlay: {module_path}")
    if package_version("sglang") != EXPECTED_VERSION:
        raise RuntimeError(
            f"unexpected sglang version: {package_version('sglang')}"
        )

    dependency_versions = {
        name: package_version(name) for name in sorted(EXPECTED_DEPENDENCIES)
    }
    if dependency_versions != dict(sorted(EXPECTED_DEPENDENCIES.items())):
        raise RuntimeError(
            "base dependency graph changed: "
            + json.dumps(dependency_versions, sort_keys=True)
        )

    extensions: list[dict[str, object]] = []
    for module_name in RUST_EXTENSION_MODULES:
        extension = importlib.import_module(module_name)
        extension_path = pathlib.Path(str(extension.__file__)).resolve(strict=True)
        if not path_inside(extension_path, overlay_root):
            raise RuntimeError(
                f"Rust extension did not resolve from overlay: {extension_path}"
            )
        extensions.append({"module": module_name, **elf_identity(extension_path)})

    return {
        "architecture": platform.machine(),
        "assertions": {
            "all_rust_extensions_elf_aarch64": True,
            "all_rust_extensions_from_overlay": True,
            "architecture_aarch64": True,
            "base_dependency_versions_exact": True,
            "python_exact": True,
            "sglang_module_from_overlay": True,
            "sglang_version_exact": True,
            "source_commit_exact": True,
        },
        "base_dependencies": dependency_versions,
        "overlay": {
            "filename": required_environment("GB10_SGLANG_OVERLAY_FILENAME"),
            "root": str(overlay_root),
            "sglang_module": str(module_path),
            "source_commit": source_commit,
            "version": package_version("sglang"),
            "wheel_sha256": required_environment("GB10_SGLANG_OVERLAY_SHA256"),
            "wheel_size": int(required_environment("GB10_SGLANG_OVERLAY_SIZE")),
        },
        "python": platform.python_version(),
        "rust_extensions": extensions,
    }


def runtime() -> dict[str, object]:
    import torch

    provenance_document = provenance()
    if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
        raise RuntimeError("SGLang container did not enumerate a CUDA GPU")
    properties = torch.cuda.get_device_properties(0)
    capability = tuple(torch.cuda.get_device_capability(0))
    interfaces = sorted(name for _, name in socket.if_nameindex())
    return {
        **provenance_document,
        "build": {
            "base_commit": required_environment("SGLANG_BUILD_COMMIT"),
            "base_image_tag": required_environment("SGLANG_IMAGE_TAG"),
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
            "pip_no_index": os.environ.get("PIP_NO_INDEX") == "1",
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
            "sglang": package_version("sglang"),
            "torch": torch.__version__,
            "torch_cuda": torch.version.cuda,
        },
    }


def model_info() -> dict[str, object]:
    document = json.loads(fetch("/model_info"))
    if not isinstance(document, dict):
        raise RuntimeError("SGLang model-info response is not a JSON object")
    return document


def generate() -> dict[str, object]:
    payload: dict[str, object] = {
        "sampling_params": {"max_new_tokens": 256, "temperature": 0},
        "text": "Calculate 12 multiplied by 17. Return the final integer.",
    }
    document = json.loads(fetch("/generate", payload))
    if not isinstance(document, dict):
        raise RuntimeError("SGLang generation response is not a JSON object")
    text = document.get("text")
    if not isinstance(text, str) or re.search(r"(?<!\d)204(?!\d)", text) is None:
        raise RuntimeError("SGLang response did not contain the expected integer 204")
    meta_info = document.get("meta_info")
    if not isinstance(meta_info, dict):
        raise RuntimeError("SGLang generation response has no meta_info object")
    finish_reason = meta_info.get("finish_reason")
    if not isinstance(finish_reason, dict) or finish_reason.get("type") != "stop":
        raise RuntimeError("SGLang generation finish_reason.type was not stop")
    return document


def serve(arguments: list[str]) -> None:
    """Launch SGLang from this real, read-only file for multiprocessing safety."""
    pathlib.Path("/tmp/server-overlay-provenance.json").write_text(
        json.dumps(provenance(), separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )
    pathlib.Path("/tmp/server-python-pid").write_text(
        f"{os.getpid()}\n", encoding="utf-8"
    )
    sys.argv = ["sglang.launch_server", *arguments]
    runpy.run_module("sglang.launch_server", run_name="__main__")


def main() -> None:
    modes = {
        "generate",
        "inventory",
        "model",
        "provenance",
        "ready",
        "runtime",
        "serve",
    }
    if len(sys.argv) < 2 or sys.argv[1] not in modes:
        raise SystemExit(
            "usage: sglang-source-overlay-smoke-client.py "
            "{generate|inventory|model|provenance|ready|runtime|serve [SERVER_ARGS...]}"
        )
    mode = sys.argv[1]
    if mode != "serve" and len(sys.argv) != 2:
        raise SystemExit(f"mode {mode!r} does not accept additional arguments")
    try:
        if mode == "serve":
            serve(sys.argv[2:])
        elif mode == "ready":
            fetch("/health")
            print("ready")
        elif mode == "generate":
            print(json.dumps(generate(), separators=(",", ":"), sort_keys=True))
        elif mode == "inventory":
            print(
                json.dumps(
                    distribution_inventory(), separators=(",", ":"), sort_keys=True
                )
            )
        elif mode == "model":
            print(json.dumps(model_info(), separators=(",", ":"), sort_keys=True))
        elif mode == "provenance":
            print(json.dumps(provenance(), separators=(",", ":"), sort_keys=True))
        else:
            print(json.dumps(runtime(), separators=(",", ":"), sort_keys=True))
    except (
        ImportError,
        json.JSONDecodeError,
        OSError,
        RuntimeError,
        urllib.error.URLError,
        ValueError,
    ) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
