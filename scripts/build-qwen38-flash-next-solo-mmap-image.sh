#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'Qwen3.8 Solo mmap image build failed: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -ne 0 ]] || die 'run as the normal Spark user, not root'

repo_commit=82ed48d373d8a2c03d142d203f07bce0a6b69125
repo_tree=63611312fe25a96b66c8b42d1b4d694fa319108d
dockerfile_sha256=075504bd5083e63bf80e6db737cfab43033eae7dfab837e64c17c2c94ebca2b1
patch_sha256=2bca73dd0f77e72937cdfc43312c3fc4d217847d4bb126cf3665bd8caa3108c8
test_sha256=8641fe7acff3e3734bd5d539a1438a1a7a70d1ddac8f9e19bd45249754d4ed13
base_image='docker.io/vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8'
output_image=${GB10_QWEN38_SOLO_MMAP_IMAGE:-localhost/gb10sor/qwen38-flash-next-solo-mmap:82ed48d3}
build_timestamp=315532800
expected_image_id=937cf960a699c455ae8588fc2f83293b6bd59b58b7d8815293131db2304ce04d
expected_repo_digest=localhost/gb10sor/qwen38-flash-next-solo-mmap@sha256:e61397b7e3ff32b63da8e6a6be628bc988021c6311dd9efb0c3971d62eab1f38
source_root=${GB10_QWEN38_SOLO_MMAP_SOURCE:-$HOME/.cache/gb10sor/source/qwen3.8-Flash-DGX-82ed48d3}

for command_name in git podman sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

if [[ ! -d $source_root/.git ]]; then
  mkdir -p "$(dirname -- "$source_root")"
  git clone --filter=blob:none https://github.com/blazux/qwen3.8-Flash-DGX.git "$source_root"
fi

git -C "$source_root" fetch --depth=1 origin "$repo_commit"
git -C "$source_root" checkout --detach "$repo_commit"
[[ $(git -C "$source_root" rev-parse HEAD) == "$repo_commit" ]] || die 'source commit changed'
[[ $(git -C "$source_root" rev-parse 'HEAD^{tree}') == "$repo_tree" ]] || die 'source tree changed'
[[ -z $(git -C "$source_root" status --porcelain) ]] || die 'source checkout is dirty'

printf '%s  %s\n' "$dockerfile_sha256" "$source_root/Dockerfile" | sha256sum -c -
printf '%s  %s\n' "$patch_sha256" "$source_root/src/vllm_ple_mmap.py" | sha256sum -c -
printf '%s  %s\n' "$test_sha256" "$source_root/src/test_ple_mmap_cpu.py" | sha256sum -c -

podman pull "$base_image"
podman build --pull=never --network=none --no-cache \
  --timestamp="$build_timestamp" -t "$output_image" "$source_root"
podman run --rm --pull=never --network=none --read-only \
  --security-opt no-new-privileges --cap-drop all \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  -v "$source_root/src:/probe:ro" --entrypoint python3 \
  "$output_image" /probe/test_ple_mmap_cpu.py

observed_image_id=$(podman image inspect "$output_image" --format '{{.Id}}')
[[ $observed_image_id == "$expected_image_id" ]] || \
  die "derived image ID changed: expected $expected_image_id, observed $observed_image_id"
podman image inspect "$output_image" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
  | grep -Fx "$expected_repo_digest" >/dev/null || \
  die "derived image digest changed or is absent: $expected_repo_digest"

podman image inspect "$output_image" --format \
  'image_id={{.Id}} architecture={{.Architecture}} repo_digests={{json .RepoDigests}}'
