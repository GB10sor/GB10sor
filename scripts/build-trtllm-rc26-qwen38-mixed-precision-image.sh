#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'TensorRT-LLM Qwen3.8 mixed-precision image build failed: %s\n' "$*" >&2
  exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$repo_root/scripts/container-engine.sh"

base_image='nvcr.io/nvidia/tensorrt-llm/release@sha256:a6a9de9351d0ae122e852d2ddeee816302a90f6e528d64f06c8d5e6a2fbc9ad3'
upstream_fix=e1e6bcca3b7c
patch_id=qwen38-modelopt-ple-fp8-e1e6bcca3b7c
image_tag="localhost/gb10sor/trtllm-rc26-qwen38:${patch_id}"
expected_image_id=3cb0892819860f8eaf6c20738e555fa8a9053a423858cfa80d865c7edf6b7749
expected_repo_digest=localhost/gb10sor/trtllm-rc26-qwen38@sha256:3347bc226861d586ba8a0e7cdcceeaf6c7610ad4f4a690bdd900af0c1a1164b8
context_dir="$repo_root/containers/trtllm-rc26-qwen38-mixed-precision"

[[ $(uname -m) == aarch64 ]] || die 'this image must be built and probed natively on a Spark'
container_engine=$(gb10_select_container_engine) || die 'no usable rootless Podman or Docker engine'

"$container_engine" image inspect "$base_image" >/dev/null 2>&1 || \
  die 'the exact rc26 base image must already be staged locally'

env -u SOURCE_DATE_EPOCH "$container_engine" build \
  --network=none \
  --pull=never \
  --timestamp 1788918864 \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "TRTLLM_UPSTREAM_FIX=$upstream_fix" \
  -f "$context_dir/Containerfile" \
  -t "$image_tag" \
  "$context_dir"

observed_architecture=$("$container_engine" image inspect --format '{{.Architecture}}' "$image_tag")
observed_revision=$("$container_engine" image inspect --format '{{index .Labels "org.opencontainers.image.revision"}}' "$image_tag")
observed_base=$("$container_engine" image inspect --format '{{index .Labels "ai.gb10sor.base-image"}}' "$image_tag")
observed_patch=$("$container_engine" image inspect --format '{{index .Labels "ai.gb10sor.patch-id"}}' "$image_tag")
observed_image_id=$("$container_engine" image inspect --format '{{.Id}}' "$image_tag")
[[ $observed_architecture == arm64 || $observed_architecture == aarch64 ]] || die 'built image architecture changed'
[[ $observed_revision == "$upstream_fix" ]] || die 'upstream revision label changed'
[[ $observed_base == "$base_image" ]] || die 'base-image label changed'
[[ $observed_patch == "$patch_id" ]] || die 'patch label changed'
[[ $observed_image_id == "$expected_image_id" ]] || \
  die "derived image ID changed: expected $expected_image_id, observed $observed_image_id"
"$container_engine" image inspect "$image_tag" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
  | grep -Fx "$expected_repo_digest" >/dev/null || \
  die "derived image digest changed or is absent: $expected_repo_digest"

"$container_engine" run --rm --pull=never --network none \
  --read-only --security-opt no-new-privileges --cap-drop all \
  --device nvidia.com/gpu=all \
  --tmpfs /root/.cache:rw,nosuid,nodev,size=2g \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  --entrypoint python3 "$image_tag" -c '
from types import SimpleNamespace
from tensorrt_llm._torch.modules.qwen4_exp.ple import _uses_scaled_fp8_ngram_table
name = "model.language_model.layers.2.ple.ple_embedding.ngram_embedding"
config = SimpleNamespace(quantization_config={
    "quantized_layers": {name: {"quant_algo": "FP8"}}
})
assert _uses_scaled_fp8_ngram_table(config) is True
import tensorrt_llm
print(f"tensorrt_llm={tensorrt_llm.__version__} mixed_precision_ple_probe=pass")
'

printf 'trtllm_qwen38_mixed_precision_build=pass\nimage=%s\nimage_id=%s\nbase_image=%s\nupstream_fix=%s\npatch_id=%s\n' \
  "$image_tag" "$observed_image_id" "$base_image" "$upstream_fix" "$patch_id"
