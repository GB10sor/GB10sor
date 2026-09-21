#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'SGLang-Omni ARM64 build failed: %s\n' "$*" >&2
  exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$repo_root/scripts/container-engine.sh"

source_revision=5207c5dbc45bd7fe8062bc9a222ea6121f990349
source_tree_sha256=895093395dcf7a88574d49e64b594ed007b7d40324e0c42e994fdce53984fd21
source_timestamp=1787675828
base_image=docker.io/lmsysorg/sglang@sha256:d4a984cdeb9846ef0d433d80e8fff55d527fa84f91c0eec2c62d9dea7ab26426
image_tag="localhost/gb10sor/sglang-omni:${source_revision}"
source_dir=${GB10_SGLANG_OMNI_SOURCE:-}

[[ -n $source_dir ]] || die 'GB10_SGLANG_OMNI_SOURCE is unset; enter the model-minimax-music3 Nix shell'
[[ -d $source_dir && -r $source_dir/pyproject.toml ]] || die "source input is unavailable: $source_dir"
[[ $(uname -m) == aarch64 ]] || die 'this runtime must be built natively on an aarch64 Spark'

for command_name in find sha256sum sort xargs; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done

observed_tree_sha256=$(
  cd -- "$source_dir"
  find . -type f ! -path './.git/*' -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | awk '{print $1}'
)
[[ $observed_tree_sha256 == "$source_tree_sha256" ]] || \
  die "source tree changed: expected $source_tree_sha256, observed $observed_tree_sha256"

container_engine=$(gb10_select_container_engine) || die 'no usable rootless Podman or Docker engine'
"$container_engine" image inspect "$base_image" >/dev/null 2>&1 || \
  "$container_engine" pull "$base_image"

env -u SOURCE_DATE_EPOCH "$container_engine" build \
  --network=none \
  --pull=false \
  --timestamp "$source_timestamp" \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "SGLANG_OMNI_COMMIT=$source_revision" \
  --build-arg "SGLANG_OMNI_SOURCE_TREE_SHA256=$source_tree_sha256" \
  -f "$repo_root/containers/sglang-omni-arm64/Dockerfile" \
  -t "$image_tag" \
  "$source_dir"

observed_architecture=$("$container_engine" image inspect --format '{{.Architecture}}' "$image_tag")
[[ $observed_architecture == arm64 || $observed_architecture == aarch64 ]] || \
  die "built image has the wrong architecture: $observed_architecture"
observed_revision=$("$container_engine" image inspect --format '{{index .Labels "org.opencontainers.image.revision"}}' "$image_tag")
observed_base=$("$container_engine" image inspect --format '{{index .Labels "ai.gb10sor.base-image"}}' "$image_tag")
observed_source_tree=$("$container_engine" image inspect --format '{{index .Labels "ai.gb10sor.source-tree-sha256"}}' "$image_tag")
[[ $observed_revision == "$source_revision" ]] || die 'built image revision label is wrong'
[[ $observed_base == "$base_image" ]] || die 'built image base label is wrong'
[[ $observed_source_tree == "$source_tree_sha256" ]] || die 'built image source-tree label is wrong'

"$container_engine" run --rm --pull=never --network none \
  --read-only --security-opt no-new-privileges --cap-drop all \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  --entrypoint python3 "$image_tag" -c \
  'import platform,sglang,sglang_omni,torch,transformers; assert platform.machine() == "aarch64"; assert sglang.__version__ == "0.5.16"; assert sglang_omni.__version__ == "0.1.3"; assert torch.__version__ == "2.11.0+cu130"; assert transformers.__version__ == "5.12.1"'

image_id=$("$container_engine" image inspect --format '{{.Id}}' "$image_tag")
image_digest=$("$container_engine" image inspect --format '{{index .RepoDigests 0}}' "$image_tag")
printf 'sglang_omni_arm64_build=pass\nimage=%s\nimage_id=%s\nimage_digest=%s\nsource_revision=%s\nsource_tree_sha256=%s\nbase_image=%s\n' \
  "$image_tag" "$image_id" "$image_digest" "$source_revision" "$source_tree_sha256" "$base_image"
