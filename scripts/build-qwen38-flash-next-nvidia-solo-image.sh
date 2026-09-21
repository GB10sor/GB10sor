#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'NVIDIA Qwen3.8 Solo image build failed: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -ne 0 ]] || die 'run as the normal Spark user, not root'

repo_commit=6ad1c8f15cbab1ababd2048e8e5f94094dbfc4a0
repo_tree=152d5ecfb1e524fac6adda1743566d4fbff00bc8
base_image='docker.io/vllm/vllm-openai:nightly-8a728663c1c3eeace834a95f5654fa653cc1998c'
expected_base_digest='sha256:a551e05307cd2e0092139d84db32af9c97e67d2eeeff072d21e429131d8c23f0'
output_image=${GB10_QWEN38_NVIDIA_SOLO_IMAGE:-localhost/gb10sor/qwen38-flash-next-nvidia-solo:6ad1c8f1}
expected_image_id=311207963fa6af58ee0c520e29b59bb3387bb5becca5fdcf864543e21b4a0c93
expected_repo_digest=localhost/gb10sor/qwen38-flash-next-nvidia-solo@sha256:652696cc057dbe24653572b9978eae094b1dfc9d2cabde863cfbf260f64609ac
source_root=${GB10_QWEN38_NVIDIA_SOURCE:-$HOME/.cache/gb10sor/source/Qwen3.8-Flash-Next-NVFP4-DGX-Spark-6ad1c8f1}
containerfile=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/runtime-images/qwen38-flash-next-nvidia-solo/Containerfile

for command_name in git podman sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

if [[ ! -d $source_root/.git ]]; then
  mkdir -p "$(dirname -- "$source_root")"
  git clone --filter=blob:none https://github.com/tonyd2wild/Qwen3.8-Flash-Next-NVFP4-DGX-Spark.git "$source_root"
fi

git -C "$source_root" fetch --depth=1 origin "$repo_commit"
git -C "$source_root" checkout --detach "$repo_commit"
[[ $(git -C "$source_root" rev-parse HEAD) == "$repo_commit" ]] || die 'source commit changed'
[[ $(git -C "$source_root" rev-parse 'HEAD^{tree}') == "$repo_tree" ]] || die 'source tree changed'
[[ -z $(git -C "$source_root" status --porcelain) ]] || die 'source checkout is dirty'

patch_root=$source_root/single-spark-vllm-tp1/patch
while read -r expected relative; do
  printf '%s  %s\n' "$expected" "$patch_root/$relative" | sha256sum -c -
done <<'EOF'
74526607e4239ad95b5bc8e94acfcb8a250ba75f8705acce3cbe752e0cc1f4a9 ple_layer.py
aa03eb1dff0b8739744259cf426bcb7674b1c6a7cc06233c181cac323bb86a00 ple_mmap.py
ce9fc0c589d60703899659a6100594c788d0b1636a33585e301636531a4d85ce model_state.py
1d6b90d3dea98b4c7fa0de86b1ef222e88d5772969fd8fb9b20a705e4c4c5981 mtp_draft_vocab.py
cc8994b653dd4b59d6ba35b6ec10af34017e9944482ec67cad6a32a02c5dd00a upstream-overlays/ops_ple.py
1e928e2994233496e9ef447768e8b63acbedc22e242d4b2fc9f4ed861a1616c3 upstream-overlays/ops_qsa.py
f2fc3fb43f6c6e84e892a995697fb59a85ee8df2ef2959943c96cf0233078da7 upstream-overlays/qsa.py
443b556b984b306c0274c58af8658ef853c664b8beae6deefda41908f789d26d upstream-overlays/platforms_interface.py
eff707e7f42b12a0483f41461aaaf786399e860077b767a76dc236a869c7e303 upstream-overlays/modelopt.py
dcc49535554b5642b1035122e0be13c4f1000c83db9d04a274329fe6254bedb9 compilation.py
EOF

podman pull "$base_image"
observed_base_digest=$(podman image inspect "$base_image" --format '{{index .RepoDigests 0}}')
[[ $observed_base_digest == *@"$expected_base_digest" ]] || \
  die "base image digest changed: expected $expected_base_digest, observed $observed_base_digest"
env -u SOURCE_DATE_EPOCH podman build --pull=never --network=none --no-cache --timestamp=315532800 \
  -f "$containerfile" -t "$output_image" "$source_root"

observed_image_id=$(podman image inspect "$output_image" --format '{{.Id}}')
[[ $observed_image_id == "$expected_image_id" ]] || \
  die "derived image ID changed: expected $expected_image_id, observed $observed_image_id"
podman image inspect "$output_image" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
  | grep -Fx "$expected_repo_digest" >/dev/null || \
  die "derived image digest changed or is absent: $expected_repo_digest"

podman run --rm --pull=never --network=none --read-only \
  --security-opt no-new-privileges --cap-drop all --entrypoint python3 \
  "$output_image" -c 'import vllm; print(vllm.__version__)'
podman image inspect "$output_image" --format \
  'image_id={{.Id}} architecture={{.Architecture}} repo_digests={{json .RepoDigests}}'
