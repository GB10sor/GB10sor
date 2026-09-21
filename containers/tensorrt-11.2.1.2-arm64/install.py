#!/usr/bin/env python3
"""Install the exact NVIDIA TensorRT SBSA artifacts without package resolution."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent
MANIFEST_PATH = ROOT / "artifacts.json"
EXPECTED_DISTRIBUTIONS = {
    "tensorrt",
    "tensorrt-cu13",
    "tensorrt-cu13-bindings",
    "tensorrt-cu13-libs",
}
EXPECTED_ARTIFACTS = {
    "tensorrt-cu13-libs": (
        "tensorrt_cu13_libs-11.2.1.2-py3-none-manylinux_2_35_aarch64.whl",
        "https://pypi.nvidia.com/tensorrt-cu13-libs/tensorrt_cu13_libs-11.2.1.2-py3-none-manylinux_2_35_aarch64.whl",
        "ef6f7f89aadc6ab5417b40d4b9dacb308af2bf952fb1a29b987dac8d29006b22",
    ),
    "tensorrt-cu13-bindings": (
        "tensorrt_cu13_bindings-11.2.1.2-cp312-none-manylinux_2_35_aarch64.whl",
        "https://pypi.nvidia.com/tensorrt-cu13-bindings/tensorrt_cu13_bindings-11.2.1.2-cp312-none-manylinux_2_35_aarch64.whl",
        "994c8d528ef55a4d3a1416f485499d7210c2e903f3c9c93cc721501786549c58",
    ),
    "tensorrt-cu13": (
        "tensorrt_cu13-11.2.1.2.tar.gz",
        "https://pypi.nvidia.com/tensorrt-cu13/tensorrt_cu13-11.2.1.2.tar.gz",
        "5a15c04615c59338d8f95205f5a24e7dfe18086d4a3449ddd5992e75f0f829b9",
    ),
    "tensorrt": (
        "tensorrt-11.2.1.2.tar.gz",
        "https://pypi.nvidia.com/tensorrt/tensorrt-11.2.1.2.tar.gz",
        "adf00e5ee6d87e1bf991dfefad64f939b5639712ca79aac1d6c3cc88935c8088",
    ),
}


def fail(message: str) -> None:
    raise SystemExit(f"TensorRT edge installer: {message}")


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def main() -> None:
    if os.environ.get("GB10_ACCEPT_NVIDIA_TENSORRT_SLA") != "yes":
        fail("license acceptance is required before downloading or installing")
    if platform.machine().lower() not in {"aarch64", "arm64"}:
        fail(f"expected an ARM64 build, found {platform.machine()!r}")
    if sys.version_info[:2] != (3, 12):
        fail(f"the pinned binding requires CPython 3.12, found {platform.python_version()}")

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    product = manifest["product"]
    artifacts = manifest["artifacts"]
    if manifest.get("schemaVersion") != 1:
        fail("unsupported artifact-manifest schema")
    if product != {
        "name": "NVIDIA TensorRT",
        "productVersion": "11.2.1",
        "pythonPackageVersion": "11.2.1.2",
        "cudaVersion": "13.3.1.008",
        "architecture": "aarch64",
        "pythonAbi": "cp312",
    }:
        fail("unexpected product identity in artifact manifest")
    if os.environ.get("CUDA_VERSION") != product["cudaVersion"]:
        fail(
            f"expected base CUDA {product['cudaVersion']}, "
            f"found {os.environ.get('CUDA_VERSION')!r}"
        )
    if {item["distribution"] for item in artifacts} != EXPECTED_DISTRIBUTIONS:
        fail("artifact manifest does not contain the exact distribution set")
    observed_artifacts = {
        item["distribution"]: (item["filename"], item["url"], item["sha256"])
        for item in artifacts
    }
    if observed_artifacts != EXPECTED_ARTIFACTS:
        fail("artifact manifest filenames or SHA-256 values are not the qualified set")

    download_root = Path(tempfile.mkdtemp(prefix="gb10-tensorrt-artifacts."))
    try:
        paths: list[Path] = []
        for artifact in artifacts:
            url = artifact["url"]
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme != "https" or parsed.hostname != "pypi.nvidia.com":
                fail(f"refusing non-NVIDIA artifact URL: {url}")
            if parsed.path.rsplit("/", 1)[-1] != artifact["filename"]:
                fail(f"artifact URL/filename mismatch: {url}")
            if len(artifact["sha256"]) != 64 or any(
                character not in "0123456789abcdef"
                for character in artifact["sha256"]
            ):
                fail(f"invalid SHA-256 for {artifact['filename']}")

            destination = download_root / artifact["filename"]
            request = urllib.request.Request(
                url,
                headers={"User-Agent": "gb10sor-tensorrt-edge-builder/1"},
            )
            with urllib.request.urlopen(request, timeout=300) as response:
                if urllib.parse.urlparse(response.geturl()).hostname != "pypi.nvidia.com":
                    fail(f"artifact redirected away from pypi.nvidia.com: {url}")
                with destination.open("wb") as output:
                    shutil.copyfileobj(response, output, length=1024 * 1024)
            observed = digest(destination)
            if observed != artifact["sha256"]:
                fail(
                    f"SHA-256 mismatch for {artifact['filename']}: "
                    f"expected {artifact['sha256']}, found {observed}"
                )
            paths.append(destination)

        install_environment = os.environ.copy()
        install_environment.update(
            {
                "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                "PIP_NO_INDEX": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "SOURCE_DATE_EPOCH": "0",
            }
        )
        subprocess.run(
            [
                sys.executable,
                "-m",
                "pip",
                "install",
                "--force-reinstall",
                "--no-cache-dir",
                "--no-compile",
                "--no-deps",
                "--no-index",
                "--no-build-isolation",
                *map(str, paths),
            ],
            check=True,
            env=install_environment,
        )

        expected_version = product["pythonPackageVersion"]
        for distribution in EXPECTED_DISTRIBUTIONS:
            observed_version = importlib.metadata.version(distribution)
            if observed_version != expected_version:
                fail(
                    f"installed {distribution} version mismatch: "
                    f"expected {expected_version}, found {observed_version}"
                )
        import tensorrt

        if str(tensorrt.__version__) != expected_version:
            fail(
                f"TensorRT import version mismatch: expected {expected_version}, "
                f"found {tensorrt.__version__}"
            )
    finally:
        shutil.rmtree(download_root, ignore_errors=True)


if __name__ == "__main__":
    main()
