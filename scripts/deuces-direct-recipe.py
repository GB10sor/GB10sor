#!/usr/bin/env python3
"""Read-only validation of a model registry entry for Deuces-direct.

This is intentionally a small, isolated preflight. It does not inspect model
weights, contact a registry, start a container, or change network state. The
hardware launcher remains responsible for the direct link and cleanup gates.
"""
import hashlib
import json
from pathlib import Path
import re
import sys


def fail(message):
    raise SystemExit("Deuces-direct recipe failed: " + message)


def need(condition, message):
    if not condition:
        fail(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(registry_path, profile_name, topology):
    path = Path(registry_path).resolve(strict=True)
    need(path.is_file() and path.stat().st_size <= 16 * 1024 * 1024,
         "registry must be a bounded regular file")
    value = json.loads(path.read_text(encoding="utf-8"))
    need(value.get("schemaVersion") == 1 and isinstance(value.get("profiles"), dict),
         "unsupported model registry schema")
    profile = value["profiles"].get(profile_name)
    need(isinstance(profile, dict), "profile is absent from the pinned registry")
    need(profile.get("modelId") and profile.get("modelPath"), "model identity/path is missing")
    model_path = Path(profile["modelPath"])
    need(model_path.is_absolute() and ".." not in model_path.parts and str(model_path) != "/",
         "model path must be an absolute local path")
    need(profile.get("engine") in ("vllm", "sglang"), "unsupported inference engine")
    need(re.fullmatch(r"[0-9a-f]{40}", profile.get("modelRevision", "")),
         "model revision is not an exact commit")
    need(re.fullmatch(r"[0-9a-f]{64}", profile.get("weightTreeSha256", "")),
         "model weight tree is not pinned")
    image = profile.get("image", "")
    # Locally built candidate images can have host-specific manifest digests
    # after archive import even when their immutable image ID and rootfs are
    # byte-identical.  Accept either a registry digest or an exact local image
    # ID; the hardware preflight independently verifies imageId and rootfs.
    need(re.fullmatch(r"(?:(?:[^\s@]+@)?sha256:)?[0-9a-f]{64}", image),
         "runtime image is not digest pinned")
    allowed = profile.get("allowedTopologies", [])
    # Older reviewed records predate allowedTopologies. Keep those records
    # usable only for the explicit direct shell allow-list.
    direct_shell_profiles = {
        "laguna-s21-nvfp4",
        "qwen38-flash-next-direct-bounded",
        "qwen38-flash-next-nvidia-vllm",
        "deepseek-v4-sglang-target-only",
        "deepseek-v4-nvidia-anemll-vllm",
        "deepseek-v4-flash-0731-nvidia-vllm",
        "deepseek-v4-flash-0731-nvidia-v028",
        "inkling-small-nvfp4-sglang-dspark",
        "glm53-flash-nvfp4-sglang-dflash2",
        "glm53-flash-nvfp4-sglang-target-only",
    }
    need(topology == "direct", "only direct topology is accepted")
    need(profile_name in direct_shell_profiles or "direct" in allowed,
         "profile is not enabled for Deuces-direct")
    args = profile.get("topologyArgumentSets", {}).get("direct", profile.get("arguments"))
    need(isinstance(args, list) and args and all(isinstance(item, str) and "\0" not in item for item in args),
         "direct launch arguments are missing")
    for auxiliary_key in ("auxiliaryModel", "speculative"):
        auxiliary = profile.get(auxiliary_key)
        if auxiliary is None:
            continue
        need(isinstance(auxiliary, dict) and auxiliary.get("modelId") and
             re.fullmatch(r"[0-9a-f]{40}", auxiliary.get("modelRevision", "")),
             auxiliary_key + " identity is not pinned")
        shared_tree = auxiliary.get("weightTreeSha256", "")
        rank_contracts = auxiliary.get("rankContracts")
        if rank_contracts is None:
            need(re.fullmatch(r"[0-9a-f]{64}", shared_tree),
                 auxiliary_key + " weight tree is not pinned")
        else:
            need(auxiliary_key == "auxiliaryModel" and isinstance(rank_contracts, dict),
                 auxiliary_key + " rank contracts are invalid")
            for rank in ("rank0", "rank1"):
                contract = rank_contracts.get(rank)
                need(isinstance(contract, dict) and
                     re.fullmatch(r"[0-9a-f]{64}", contract.get("weightTreeSha256", "")) and
                     isinstance(contract.get("modelBytes"), int) and contract["modelBytes"] > 0 and
                     isinstance(contract.get("weightFiles"), int) and contract["weightFiles"] > 0 and
                     isinstance(contract.get("weightBytes"), int) and contract["weightBytes"] > 0,
                     auxiliary_key + " " + rank + " contract is incomplete")
    print(json.dumps({
        "profile": profile_name,
        "engine": profile["engine"],
        "modelId": profile["modelId"],
        "modelRevision": profile["modelRevision"],
        "weightTreeSha256": profile["weightTreeSha256"],
        "registrySha256": digest(path),
        "status": profile.get("status", "unknown"),
        "directArguments": len(args),
    }, sort_keys=True))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        fail("usage: deuces-direct-recipe.py REGISTRY PROFILE direct")
    check(sys.argv[1], sys.argv[2], sys.argv[3])
