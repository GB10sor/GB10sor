#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'model profile failed: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/model-profile.sh show|stage-runtime|bootstrap|preflight|acceptance|qualify-and-serve|benchmark-only|qualify-benchmark-and-stop|serve|stop

Run this inside a model-specific shell, for example:
  nix develop path:.#model-muse-glimmer --command ./scripts/model-profile.sh preflight

No checkpoint is downloaded. `stage-runtime` pulls only a missing immutable
container digest. `bootstrap` builds a missing reviewed local runtime when an
exact profile-specific recipe exists, stages the runtime, and performs the
checkpoint preflight. `qualify-and-serve` then runs the full acceptance gate
before starting a loopback-only service. Acceptance mounts the selected model
root read-only with networking disabled. Set
GB10_MODEL_ROOT to override the local-NVMe checkpoint tree. It defaults to
$HOME/.local/share/gb10sor/models.
EOF
  exit 2
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
registry=${GB10_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}
profile=${GB10_MODEL_PROFILE:-}
action=${1:-}

[[ $action == show || $action == stage-runtime || $action == bootstrap || $action == preflight || $action == acceptance || $action == qualify-and-serve || $action == benchmark-only || $action == qualify-benchmark-and-stop || $action == serve || $action == stop ]] || usage
[[ -n $profile ]] || die 'GB10_MODEL_PROFILE is unset; enter a model-* Nix shell'
[[ -r $registry ]] || die "model profile registry is unreadable: $registry"
jq -e --arg profile "$profile" '.profiles[$profile] != null' "$registry" >/dev/null || \
  die "unknown model profile: $profile"

profile_json=$(jq -c --arg profile "$profile" '.profiles[$profile]' "$registry")
title=$(jq -r '.title' <<<"$profile_json")
model_id=$(jq -r '.modelId' <<<"$profile_json")
model_path=$(jq -r '.modelPath' <<<"$profile_json")
model_root=${GB10_MODEL_ROOT:-$HOME/.local/share/gb10sor/models}
case "$model_path" in
  /mnt/models/*) model_relative=${model_path#/mnt/models/} ;;
  *) die "profile model path is outside the public model-root contract: $model_path" ;;
esac
selected_model_path="$model_root/$model_relative"
model_revision=$(jq -r '.modelRevision' <<<"$profile_json")
expected_bytes=$(jq -r '.modelBytes' <<<"$profile_json")
engine=$(jq -r '.engine' <<<"$profile_json")
engine_version=$(jq -r '.engineVersion' <<<"$profile_json")
image=$(jq -r '.image // empty' <<<"$profile_json")
expected_arch=$(jq -r '.imageArchitecture // empty' <<<"$profile_json")
client_image=$(jq -r '.clientImage // empty' <<<"$profile_json")
expected_client_arch=$(jq -r '.clientImageArchitecture // empty' <<<"$profile_json")
profile_status=$(jq -r '.status' <<<"$profile_json")
container="gb10-model-${profile}-${UID:-0}"
whitehat_network="gb10-mythos-internal-${UID:-0}"

source "$repo_root/scripts/container-engine.sh"

show_profile() {
  jq --arg profile "$profile" '{profile: $profile} + .' <<<"$profile_json"
}

stage_runtime() {
  require_commands grep jq
  [[ $EUID -ne 0 ]] || die 'run as the normal Spark user, not root'
  [[ -n $image && -n $expected_arch ]] || die 'runnable profile lacks an immutable image and architecture'

  local selected_engine reference observed_arch observed_client_arch image_id
  local -a references
  observed_client_arch=
  selected_engine=$(gb10_select_container_engine) || \
    die 'no already-usable rootless Podman or Docker engine with NVIDIA CDI'
  references=( "$image" )
  [[ -z $client_image ]] || references+=( "$client_image" )

  for reference in "${references[@]}"; do
    [[ $reference =~ @sha256:[0-9a-f]{64}$ ]] || \
      die "runtime reference is not digest pinned: $reference"
    if ! "$selected_engine" image inspect "$reference" >/dev/null 2>&1; then
      [[ $reference != localhost/* ]] || \
        die "locally built digest is absent; use its reviewed build recipe: $reference"
      "$selected_engine" pull --platform linux/arm64 "$reference"
    fi
  done

  observed_arch=$("$selected_engine" image inspect --format '{{.Architecture}}' "$image")
  case "$observed_arch:$expected_arch" in
    arm64:arm64|aarch64:arm64|arm64:aarch64|aarch64:aarch64) ;;
    *) die "image architecture mismatch: expected $expected_arch, observed $observed_arch" ;;
  esac
  if [[ -n $client_image ]]; then
    [[ -n $expected_client_arch ]] || die 'client image lacks a declared architecture'
    observed_client_arch=$("$selected_engine" image inspect --format '{{.Architecture}}' "$client_image")
    case "$observed_client_arch:$expected_client_arch" in
      arm64:arm64|aarch64:arm64|arm64:aarch64|aarch64:aarch64) ;;
      *) die "client image architecture mismatch: expected $expected_client_arch, observed $observed_client_arch" ;;
    esac
  fi
  image_id=$("$selected_engine" image inspect --format '{{.Id}}' "$image")
  jq -n \
    --arg status pass --arg profile "$profile" --arg engine "$selected_engine" \
    --arg image "$image" --arg imageId "$image_id" --arg architecture "$observed_arch" \
    --arg clientImage "$client_image" --arg clientArchitecture "$observed_client_arch" \
    '{status:$status,profile:$profile,containerEngine:$engine,image:$image,imageId:$imageId,architecture:$architecture,clientImage:(if $clientImage == "" then null else {image:$clientImage,architecture:$clientArchitecture} end),checkpointDownloaded:false}'
}

build_reviewed_local_runtime() {
  [[ $image == localhost/* ]] || return 0

  local selected_engine
  selected_engine=$(gb10_select_container_engine) || \
    die 'no already-usable rootless Podman or Docker engine with NVIDIA CDI'
  "$selected_engine" image inspect "$image" >/dev/null 2>&1 && return 0

  case "$profile" in
    qwen38-flash-next-solo-mmap)
      [[ $selected_engine == podman ]] || \
        die 'the reviewed Qwen3.8 Solo mmap image recipe currently requires rootless Podman'
      "$repo_root/scripts/build-qwen38-flash-next-solo-mmap-image.sh"
      ;;
    qwen38-flash-next-nvidia-solo-vllm)
      [[ $selected_engine == podman ]] || \
        die 'the reviewed NVIDIA Qwen3.8 Solo image recipe currently requires rootless Podman'
      "$repo_root/scripts/build-qwen38-flash-next-nvidia-solo-image.sh"
      ;;
    nvidia-qwen38-flash-next-solo-trtllm-rc26)
      [[ $selected_engine == podman ]] || \
        die 'the reviewed TensorRT-LLM Qwen3.8 Solo image recipe currently requires rootless Podman'
      "$repo_root/scripts/build-trtllm-rc26-qwen38-mixed-precision-image.sh"
      ;;
    *)
      die "locally built digest is absent and this profile has no automatic reviewed build recipe: $image"
      ;;
  esac

  "$selected_engine" image inspect "$image" >/dev/null 2>&1 || \
    die "reviewed runtime build did not produce the registered immutable digest: $image"
}

bootstrap_profile() {
  build_reviewed_local_runtime
  stage_runtime
  model_preflight
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
  done
}

canonical_model_path() {
  local canonical_root canonical_model
  canonical_root=$(realpath -e "$model_root") || die "model root is unavailable: $model_root"
  canonical_model=$(realpath -e "$selected_model_path") || die "model path is unavailable: $selected_model_path"
  case "$canonical_model/" in
    "$canonical_root/"*) ;;
    *) die "model path resolves outside the selected model root: $canonical_model" ;;
  esac
  printf '%s\n' "$canonical_model"
}

canonical_auxiliary_path() {
  local auxiliary_json auxiliary_path auxiliary_relative canonical_root canonical_auxiliary
  auxiliary_json=$(jq -c '.auxiliaryModel // null' <<<"$profile_json")
  [[ $auxiliary_json != null ]] || return 0
  auxiliary_path=$(jq -r '.modelPath' <<<"$auxiliary_json")
  case "$auxiliary_path" in
    /mnt/models/*) auxiliary_relative=${auxiliary_path#/mnt/models/} ;;
    *) die "auxiliary model path is outside the public model-root contract: $auxiliary_path" ;;
  esac
  canonical_root=$(realpath -e "$model_root") || die "model root is unavailable: $model_root"
  canonical_auxiliary=$(realpath -e "$model_root/$auxiliary_relative") || \
    die "auxiliary model path is unavailable: $model_root/$auxiliary_relative"
  case "$canonical_auxiliary/" in
    "$canonical_root/"*) ;;
    *) die "auxiliary model resolves outside the selected model root: $canonical_auxiliary" ;;
  esac
  printf '%s\n' "$canonical_auxiliary"
}

append_auxiliary_mount() {
  local destination_name=$1
  local -n destination=$destination_name
  local auxiliary_json auxiliary_path container_path
  auxiliary_json=$(jq -c '.auxiliaryModel // null' <<<"$profile_json")
  [[ $auxiliary_json != null ]] || return 0
  auxiliary_path=$(canonical_auxiliary_path)
  container_path=$(jq -r '.containerPath // "/draft"' <<<"$auxiliary_json")
  [[ $container_path == /* && $container_path != *..* ]] || \
    die "unsafe auxiliary container path: $container_path"
  destination+=(-v "$auxiliary_path:$container_path:ro")
}

metadata_revision_count() {
  local canonical_model=$1
  local count=0
  if [[ -d $canonical_model/.cache/huggingface/download ]]; then
    count=$(
      find "$canonical_model/.cache/huggingface/download" -type f -name '*.metadata' -exec sed -n '1p' {} + 2>/dev/null \
        | grep -Fxc "$model_revision" || true
    )
  fi
  if [[ -f $canonical_model/.hf_revision ]] && grep -Fqx "$model_revision" "$canonical_model/.hf_revision"; then
    (( count += 1 ))
  fi
  printf '%s\n' "$count"
}

auxiliary_model_preflight() {
  local auxiliary_json auxiliary_path auxiliary_relative canonical_root canonical_auxiliary
  local revision observed_bytes revision_count weight_count weight_bytes expected_count
  local expected_weight_bytes expected_tree observed_tree mount_source mount_options
  auxiliary_json=$(jq -c '.auxiliaryModel // null' <<<"$profile_json")
  if [[ $auxiliary_json == null ]]; then
    printf 'null\n'
    return 0
  fi

  auxiliary_path=$(jq -r '.modelPath' <<<"$auxiliary_json")
  case "$auxiliary_path" in
    /mnt/models/*) auxiliary_relative=${auxiliary_path#/mnt/models/} ;;
    *) die "auxiliary model path is outside the public model-root contract: $auxiliary_path" ;;
  esac
  canonical_root=$(realpath -e "$model_root") || die "model root is unavailable: $model_root"
  canonical_auxiliary=$(realpath -e "$model_root/$auxiliary_relative") || \
    die "auxiliary model path is unavailable: $model_root/$auxiliary_relative"
  case "$canonical_auxiliary/" in
    "$canonical_root/"*) ;;
    *) die "auxiliary model resolves outside the selected model root: $canonical_auxiliary" ;;
  esac
  [[ -r $canonical_auxiliary/config.json ]] || \
    die "auxiliary model config is unreadable: $canonical_auxiliary/config.json"

  observed_bytes=$(du -sb --apparent-size "$canonical_auxiliary" | awk '{print $1}')
  jq -e --argjson observed "$observed_bytes" \
    '(.modelBytesAllowed // [.modelBytes]) | index($observed) != null' \
    <<<"$auxiliary_json" >/dev/null || \
    die "auxiliary model size changed: observed $observed_bytes"

  revision=$(jq -r '.modelRevision' <<<"$auxiliary_json")
  revision_count=0
  if [[ -f $canonical_auxiliary/.hf_revision ]] && \
     grep -Fqx "$revision" "$canonical_auxiliary/.hf_revision"; then
    revision_count=1
  fi
  if [[ -d $canonical_auxiliary/.cache/huggingface/download ]]; then
    revision_count=$((revision_count + $(
      find "$canonical_auxiliary/.cache/huggingface/download" -type f -name '*.metadata' \
        -exec sed -n '1p' {} + 2>/dev/null | grep -Fxc "$revision" || true
    )))
  fi
  (( revision_count > 0 )) || \
    die "auxiliary model lacks the pinned revision marker: $revision"

  weight_count=$(find "$canonical_auxiliary" -type f \
    \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pth' -o -name '*.pt' \) \
    | wc -l | tr -d ' ')
  weight_bytes=$(find "$canonical_auxiliary" -type f \
    \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pth' -o -name '*.pt' \) \
    -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')
  expected_count=$(jq -r '.weightFiles' <<<"$auxiliary_json")
  expected_weight_bytes=$(jq -r '.weightBytes' <<<"$auxiliary_json")
  [[ $weight_count == "$expected_count" ]] || \
    die "auxiliary model weight count changed: expected $expected_count, observed $weight_count"
  [[ $weight_bytes == "$expected_weight_bytes" ]] || \
    die "auxiliary model weight bytes changed: expected $expected_weight_bytes, observed $weight_bytes"
  expected_tree=$(jq -r '.weightTreeSha256' <<<"$auxiliary_json")
  observed_tree=$(
    cd -- "$canonical_auxiliary"
    find . -type f \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pth' -o -name '*.pt' \) -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
  )
  [[ $observed_tree == "$expected_tree" ]] || die 'auxiliary model weight-tree SHA-256 changed'

  mount_source=unknown
  mount_options=unknown
  if command -v findmnt >/dev/null 2>&1; then
    mount_source=$(findmnt -T "$canonical_auxiliary" -n -o SOURCE 2>/dev/null | tail -n 1 || printf unknown)
    mount_options=$(findmnt -T "$canonical_auxiliary" -n -o OPTIONS 2>/dev/null | tail -n 1 || printf unknown)
  fi
  jq -n --arg modelPath "$canonical_auxiliary" --arg revision "$revision" \
    --argjson modelBytes "$observed_bytes" --argjson weightFiles "$weight_count" \
    --argjson weightBytes "$weight_bytes" --arg weightTreeSha256 "$observed_tree" \
    --arg mountSource "$mount_source" --arg mountOptions "$mount_options" \
    '{modelPath:$modelPath,modelRevision:$revision,modelBytes:$modelBytes,weightFiles:$weightFiles,weightBytes:$weightBytes,weightTreeSha256:$weightTreeSha256,storage:{source:$mountSource,options:$mountOptions}}'
}

model_preflight() {
  require_commands du find grep jq nvidia-smi realpath sed sha256sum sort stat xargs
  [[ $EUID -ne 0 ]] || die 'run as the normal Spark user, not root'
  [[ -r $selected_model_path/config.json ]] || die "model config is unreadable: $selected_model_path/config.json"

  local canonical_model observed_bytes revision_count weight_count weight_bytes mount_source mount_options
  local declared_weight_count verified_weight_digests relative_weight expected_weight_bytes expected_weight_sha
  local weight_file observed_weight_bytes observed_weight_sha
  local expected_weight_count expected_weight_bytes_total declared_weight_tree observed_weight_tree auxiliary_result
  canonical_model=$(canonical_model_path)
  observed_bytes=$(du -sb --apparent-size "$canonical_model" | awk '{print $1}')
  jq -e --argjson observed "$observed_bytes" \
    '(.modelBytesAllowed // [.modelBytes]) | index($observed) != null' \
    <<<"$profile_json" >/dev/null || \
    die "model size changed: expected one of $(jq -c '.modelBytesAllowed // [.modelBytes]' <<<"$profile_json"), observed $observed_bytes"

  revision_count=$(metadata_revision_count "$canonical_model")
  (( revision_count > 0 )) || \
    die "no Hugging Face metadata records the pinned revision $model_revision"

  weight_count=$(find "$canonical_model" -type f \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pth' -o -name '*.pt' \) | wc -l | tr -d ' ')
  (( weight_count > 0 )) || die 'no model weights were found'
  weight_bytes=$(find "$canonical_model" -type f \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pth' -o -name '*.pt' \) -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')
  expected_weight_count=$(jq -r '.weightFiles // empty' <<<"$profile_json")
  expected_weight_bytes_total=$(jq -r '.weightBytes // empty' <<<"$profile_json")
  [[ -z $expected_weight_count || $weight_count == "$expected_weight_count" ]] || \
    die "model weight count changed: expected $expected_weight_count, observed $weight_count"
  [[ -z $expected_weight_bytes_total || $weight_bytes == "$expected_weight_bytes_total" ]] || \
    die "model weight bytes changed: expected $expected_weight_bytes_total, observed $weight_bytes"

  declared_weight_count=$(jq -r '.weights // [] | length' <<<"$profile_json")
  verified_weight_digests=0
  while IFS=$'\t' read -r relative_weight expected_weight_bytes expected_weight_sha; do
    case "$relative_weight" in
      ''|/*|../*|*/../*|*/..) die "unsafe declared weight path: $relative_weight" ;;
    esac
    weight_file=$(realpath -e "$canonical_model/$relative_weight") || \
      die "declared weight file is unavailable: $relative_weight"
    case "$weight_file/" in
      "$canonical_model/"*) ;;
      *) die "declared weight resolves outside the model directory: $relative_weight" ;;
    esac
    observed_weight_bytes=$(stat -c %s "$weight_file")
    [[ $observed_weight_bytes == "$expected_weight_bytes" ]] || \
      die "weight size changed for $relative_weight: expected $expected_weight_bytes, observed $observed_weight_bytes"
    observed_weight_sha=$(sha256sum "$weight_file" | awk '{print $1}')
    [[ $observed_weight_sha == "$expected_weight_sha" ]] || \
      die "weight SHA-256 changed for $relative_weight"
    (( verified_weight_digests += 1 ))
  done < <(jq -r '(.weights // [])[] | [.path, (.bytes | tostring), .sha256] | @tsv' <<<"$profile_json")
  [[ $verified_weight_digests == "$declared_weight_count" ]] || \
    die 'not every declared weight digest was verified'

  declared_weight_tree=$(jq -r '.weightTreeSha256 // empty' <<<"$profile_json")
  if [[ -n $declared_weight_tree ]]; then
    observed_weight_tree=$(
      cd -- "$canonical_model"
      find . -type f \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pth' -o -name '*.pt' \) -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum \
        | sha256sum \
        | awk '{print $1}'
    )
    [[ $observed_weight_tree == "$declared_weight_tree" ]] || \
      die 'model weight-tree SHA-256 changed'
    verified_weight_digests=$weight_count
  fi

  mount_source=unknown
  mount_options=unknown
  if command -v findmnt >/dev/null 2>&1; then
    mount_source=$(findmnt -T "$canonical_model" -n -o SOURCE 2>/dev/null | tail -n 1 || printf unknown)
    mount_options=$(findmnt -T "$canonical_model" -n -o OPTIONS 2>/dev/null | tail -n 1 || printf unknown)
  fi

  nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader,nounits \
    >"${TMPDIR:-/tmp}/gb10-model-gpu-${UID:-0}.txt"
  [[ $(wc -l <"${TMPDIR:-/tmp}/gb10-model-gpu-${UID:-0}.txt" | tr -d ' ') == 1 ]] || \
    die 'expected exactly one visible GPU'
  grep -Eq ',[[:space:]]*12\.1,' "${TMPDIR:-/tmp}/gb10-model-gpu-${UID:-0}.txt" || \
    die 'the visible GPU is not GB10 compute capability 12.1'
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
    >"${TMPDIR:-/tmp}/gb10-model-active-gpu-${UID:-0}.csv" 2>/dev/null || true
  [[ ! -s "${TMPDIR:-/tmp}/gb10-model-active-gpu-${UID:-0}.csv" ]] || \
    die 'an existing GPU compute workload would make process attribution ambiguous'

  if [[ $profile_status == blocked-* ]]; then
    jq -n \
      --arg profile "$profile" --arg title "$title" --arg status "$profile_status" \
      --arg reason "$(jq -r '.blockedReason // "profile is blocked"' <<<"$profile_json")" \
      --arg modelPath "$canonical_model" --arg revision "$model_revision" \
      --argjson bytes "$observed_bytes" \
      '{profile:$profile,title:$title,status:$status,blockedReason:$reason,modelPath:$modelPath,modelRevision:$revision,modelBytes:$bytes}'
    return 3
  fi

  [[ -n $image && -n $expected_arch ]] || die 'runnable profile lacks an immutable image and architecture'
  local container_engine observed_arch image_id
  container_engine=$(gb10_select_container_engine) || die 'no already-usable rootless Podman or Docker engine with NVIDIA CDI'
  "$container_engine" image inspect "$image" >/dev/null 2>&1 || \
    die "digest-pinned image is absent; preflight never pulls it: $image"
  observed_arch=$("$container_engine" image inspect --format '{{.Architecture}}' "$image")
  case "$observed_arch:$expected_arch" in
    arm64:arm64|aarch64:arm64|arm64:aarch64|aarch64:aarch64) ;;
    *) die "image architecture mismatch: expected $expected_arch, observed $observed_arch" ;;
  esac
  image_id=$("$container_engine" image inspect --format '{{.Id}}' "$image")

  if [[ $engine == sglang-omni ]]; then
    local expected_revision expected_source_tree expected_base observed_revision observed_source_tree observed_base
    local image_source_tree
    expected_revision=$(jq -r '.runtimeSourceRevision' <<<"$profile_json")
    expected_source_tree=$(jq -r '.runtimeSourceTreeSha256' <<<"$profile_json")
    expected_base=$(jq -r '.baseImage' <<<"$profile_json")
    observed_revision=$("$container_engine" image inspect --format '{{index .Labels "org.opencontainers.image.revision"}}' "$image")
    observed_source_tree=$("$container_engine" image inspect --format '{{index .Labels "ai.gb10sor.source-tree-sha256"}}' "$image")
    observed_base=$("$container_engine" image inspect --format '{{index .Labels "ai.gb10sor.base-image"}}' "$image")
    [[ $observed_revision == "$expected_revision" ]] || die 'SGLang-Omni image revision label changed'
    [[ $observed_source_tree == "$expected_source_tree" ]] || die 'SGLang-Omni image source-tree label changed'
    [[ $observed_base == "$expected_base" ]] || die 'SGLang-Omni image base label changed'
    image_source_tree=$(
      "$container_engine" run --rm --pull=never --network none \
        --read-only --security-opt no-new-privileges --cap-drop all \
        --entrypoint /bin/bash "$image" -lc \
        'cd /opt/sglang-omni-source && find . -type f ! -path "./.git/*" -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk "{print \$1}"'
    )
    [[ $image_source_tree == "$expected_source_tree" ]] || die 'SGLang-Omni source embedded in the image changed'
  fi

  auxiliary_result=$(auxiliary_model_preflight)

  jq -n \
    --arg profile "$profile" --arg title "$title" --arg status "$profile_status" \
    --arg engine "$engine" --arg engineVersion "$engine_version" \
    --arg modelId "$model_id" --arg modelPath "$canonical_model" --arg revision "$model_revision" \
    --argjson modelBytes "$observed_bytes" --argjson weightFiles "$weight_count" --argjson weightBytes "$weight_bytes" \
    --argjson verifiedWeightDigests "$verified_weight_digests" \
    --arg mountSource "$mount_source" --arg mountOptions "$mount_options" \
    --arg containerEngine "$container_engine" --arg image "$image" --arg imageId "$image_id" --arg imageArchitecture "$observed_arch" \
    --argjson auxiliaryModel "$auxiliary_result" \
    --arg gpu "$(<"${TMPDIR:-/tmp}/gb10-model-gpu-${UID:-0}.txt")" \
    '{profile:$profile,title:$title,status:$status,engine:$engine,engineVersion:$engineVersion,modelId:$modelId,modelPath:$modelPath,modelRevision:$revision,modelBytes:$modelBytes,weightFiles:$weightFiles,weightBytes:$weightBytes,verifiedWeightDigests:$verifiedWeightDigests,auxiliaryModel:$auxiliaryModel,storage:{source:$mountSource,options:$mountOptions},container:{engine:$containerEngine,image:$image,imageId:$imageId,architecture:$imageArchitecture},gpu:$gpu}'
}

container_is_running() {
  local selected_engine=$1
  [[ $("$selected_engine" inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true) == true ]]
}

remove_own_container() {
  local selected_engine=$1
  remove_named_container "$selected_engine" "$container"
}

ensure_whitehat_network() {
  local selected_engine=$1
  [[ $profile == medismera-qwen38-mythos-solo-sglang ]] || return 0
  [[ $selected_engine == podman ]] || die 'Mythos requires rootless Podman for its isolated benchmark network'
  if podman network exists "$whitehat_network"; then
    die "the Mythos internal network already exists; inspect its owner before retrying: $whitehat_network"
  fi
  podman network create --internal --driver bridge \
    --label "ai.gb10sor.profile=$profile" "$whitehat_network" >/dev/null
  if [[ $(podman network inspect --format '{{.Internal}}' "$whitehat_network") != true ]]; then
    podman network rm "$whitehat_network" >/dev/null || true
    die 'Mythos network was not created as internal'
  fi
}

remove_whitehat_network() {
  local selected_engine=$1 observed_label
  [[ $profile == medismera-qwen38-mythos-solo-sglang ]] || return 0
  [[ $selected_engine == podman ]] || return 0
  podman network exists "$whitehat_network" || return 0
  observed_label=$(podman network inspect --format '{{index .Labels "ai.gb10sor.profile"}}' "$whitehat_network")
  [[ $observed_label == "$profile" ]] || die 'refusing to remove a Mythos network with a different owner label'
  podman network rm "$whitehat_network" >/dev/null
}

cleanup_owned_service() {
  local selected_engine=$1
  remove_own_container "$selected_engine"
  remove_whitehat_network "$selected_engine"
}

remove_named_container() {
  local selected_engine=$1 container_name=$2
  if gb10_container_exists "$selected_engine" "$container_name"; then
    timeout --kill-after=5 30 "$selected_engine" stop --time 10 "$container_name" >/dev/null 2>&1 || true
    gb10_remove_container "$selected_engine" "$container_name"
  fi
}

evidence_manifest() {
  local evidence_dir=$1
  (
    cd -- "$evidence_dir"
    find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS
  )
}

common_run_args() {
  local destination_name=$1
  local -n destination=$destination_name
  local canonical_model=$2 client_path=$3 container_client=$4 network_mode=$5
  destination=(
    --name "$container"
    --pull=never
    --device nvidia.com/gpu=all
    --network "$network_mode"
    --read-only
    --security-opt no-new-privileges
    --cap-drop all
    --pids-limit 8192
    --shm-size 16g
    --ulimit memlock=-1
    --ulimit stack=67108864
    --tmpfs /tmp:rw,nosuid,nodev,size=8g
    --tmpfs /root/.cache:rw,nosuid,nodev,size=4g
    --tmpfs /root/.config:rw,nosuid,nodev,size=64m
    --tmpfs /root/.local:rw,nosuid,nodev,size=1g
    --tmpfs /root/.triton:rw,nosuid,nodev,size=4g
    -e HF_HOME=/root/.cache/huggingface
    -e HF_HUB_OFFLINE=1
    -e HF_HUB_DISABLE_TELEMETRY=1
    -e TRANSFORMERS_OFFLINE=1
    -e PIP_NO_INDEX=1
    -e DO_NOT_TRACK=1
    -e VLLM_NO_USAGE_STATS=1
    -v "$canonical_model:/model:ro"
    -v "$client_path:$container_client:ro"
    -v "$repo_root/tests/hermes-openai-smoke.py:/opt/gb10/hermes-openai-smoke.py:ro"
    -v "$repo_root/tests/model-openai-stress.py:/opt/gb10/model-openai-stress.py:ro"
  )
  append_auxiliary_mount "$destination_name"
}

atlas_run_args() {
  local destination_name=$1
  local -n destination=$destination_name
  local canonical_model=$2 container_name=$3 network_mode=$4
  destination=(
    --name "$container_name"
    --pull=never
    --device nvidia.com/gpu=all
    --network "$network_mode"
    --ipc=host
    --read-only
    --security-opt no-new-privileges
    --cap-drop all
    --pids-limit 8192
    --ulimit memlock=-1
    --ulimit stack=67108864
    --tmpfs /tmp:rw,nosuid,nodev,size=8g
    --tmpfs /root/.cache:rw,nosuid,nodev,size=4g
    --tmpfs /root/.config:rw,nosuid,nodev,size=64m
    -e HF_HUB_OFFLINE=1
    -e HF_HUB_DISABLE_TELEMETRY=1
    -e TRANSFORMERS_OFFLINE=1
    -e DO_NOT_TRACK=1
    -v "$canonical_model:/model:ro"
  )
  local item
  local -a environment_args
  mapfile -t environment_args < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")
  for item in "${environment_args[@]}"; do
    destination+=(-e "$item")
  done
  append_auxiliary_mount "$destination_name"
}

atlas_client() {
  local selected_engine=$1 client_path=$2 container_client=$3
  shift 3
  local item
  local -a client_environment_args=() client_run_args=()
  mapfile -t client_environment_args < <(
    jq -r '.acceptance.clientEnvironment // {} | to_entries[] | "\(.key)=\(.value)"' \
      <<<"$profile_json"
  )
  for item in "${client_environment_args[@]}"; do
    [[ $item == GB10_* ]] || die 'Atlas acceptance client environment must use the GB10_ namespace'
    client_run_args+=(-e "$item")
  done
  timeout --kill-after=5 360 "$selected_engine" run --rm --pull=never \
    --network "container:$container" \
    --read-only --security-opt no-new-privileges --cap-drop all \
    -e DO_NOT_TRACK=1 \
    "${client_run_args[@]}" \
    -v "$client_path:$container_client:ro" \
    --entrypoint python3 "$client_image" "$container_client" "$@"
}

cleanup_atlas_acceptance() {
  local selected_engine=$1 check_container=$2 evidence_dir=$3
  "$selected_engine" logs "$container" >"$evidence_dir/server.log" 2>&1 || true
  remove_named_container "$selected_engine" "$container"
  remove_named_container "$selected_engine" "$check_container"
}

accept_atlas_server() {
  local selected_engine=$1 canonical_model=$2 evidence_dir=$3
  [[ -n $client_image && -n $expected_client_arch ]] || \
    die 'Atlas acceptance requires a digest-pinned client image and architecture'
  "$selected_engine" image inspect "$client_image" >"$evidence_dir/client-image-inspect.json" 2>/dev/null || \
    die "digest-pinned Atlas client image is absent: $client_image"
  local observed_client_arch
  observed_client_arch=$("$selected_engine" image inspect --format '{{.Architecture}}' "$client_image")
  case "$observed_client_arch:$expected_client_arch" in
    arm64:arm64|aarch64:arm64|arm64:aarch64|aarch64:aarch64) ;;
    *) die "Atlas client image architecture mismatch: expected $expected_client_arch, observed $observed_client_arch" ;;
  esac

  local check_container="${container}-kernel-check" cleanup_command item ready started startup_timeout
  local -a check_args run_args model_args
  mapfile -t model_args < <(jq -r '.arguments[]' <<<"$profile_json")
  atlas_run_args check_args "$canonical_model" "$check_container" none
  atlas_run_args run_args "$canonical_model" "$container" none
  remove_named_container "$selected_engine" "$check_container"
  remove_own_container "$selected_engine"
  printf -v cleanup_command 'cleanup_atlas_acceptance %q %q %q' \
    "$selected_engine" "$check_container" "$evidence_dir"
  trap "$cleanup_command" EXIT INT TERM

  timeout --kill-after=10 1200 "$selected_engine" run --rm "${check_args[@]}" "$image" \
    "${model_args[@]}" --check-kernels \
    >"$evidence_dir/kernel-check.log" 2>"$evidence_dir/kernel-check.stderr"
  grep -aE '^\{"atlas_kernel_check":' "$evidence_dir/kernel-check.log" \
    | tail -n 1 >"$evidence_dir/kernel-check.json"
  local expected_kernel_model expected_kernel_arch
  expected_kernel_model=$(jq -r '.atlasKernelAudit.model // "qwen3.8-27b"' <<<"$profile_json")
  expected_kernel_arch=$(jq -r '.atlasKernelAudit.arch // "sm_121"' <<<"$profile_json")
  jq -e --arg model "$expected_kernel_model" --arg arch "$expected_kernel_arch" '
    .atlas_kernel_check.ok == true
    and .atlas_kernel_check.unresolved == 0
    and ($model == "" or .atlas_kernel_check.model == $model)
    and .atlas_kernel_check.arch == $arch
  ' "$evidence_dir/kernel-check.json" >/dev/null || \
    die 'Atlas kernel audit did not resolve every required profile kernel'
  gb10_container_exists "$selected_engine" "$check_container" && \
    die 'Atlas kernel-check container remained after the bounded audit'

  "$selected_engine" run -d "${run_args[@]}" "$image" "${model_args[@]}" \
    >"$evidence_dir/container-id.txt"
  "$selected_engine" inspect "$container" >"$evidence_dir/container-inspect.json"
  startup_timeout=${GB10_MODEL_STARTUP_TIMEOUT_SECONDS:-1200}
  [[ $startup_timeout =~ ^[1-9][0-9]*$ ]] && (( startup_timeout <= 2400 )) || \
    die 'GB10_MODEL_STARTUP_TIMEOUT_SECONDS must be 1..2400'
  started=$SECONDS
  ready=0
  while (( SECONDS - started < startup_timeout )); do
    if ! container_is_running "$selected_engine"; then
      break
    fi
    if atlas_client "$selected_engine" "$repo_root/tests/model-openai-smoke.py" \
      /opt/gb10/model-openai-smoke.py ready "$model_id" \
      >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
      ready=1
      break
    fi
    sleep 5
  done
  "$selected_engine" logs "$container" >"$evidence_dir/server.log" 2>&1 || true
  (( ready == 1 )) || die "Atlas server did not become ready; see $evidence_dir/server.log"
  local required_log_pattern
  while IFS= read -r required_log_pattern; do
    [[ -z $required_log_pattern ]] || \
      grep -aF "$required_log_pattern" "$evidence_dir/server.log" >/dev/null || \
      die "Atlas server log lacks required profile evidence: $required_log_pattern"
  done < <(jq -r '.requiredLogPatterns // ["Falling back to runtime BF16→NVFP4 quantization."] | .[]' <<<"$profile_json")

  "$selected_engine" exec "$container" spark --version >"$evidence_dir/runtime-version.txt"
  local expected_runtime_output
  expected_runtime_output=$(jq -r '.runtimeVersionOutput // "spark 1.0.0-beta-preview"' <<<"$profile_json")
  grep -Fx "$expected_runtime_output" "$evidence_dir/runtime-version.txt" >/dev/null || \
    die "Atlas runtime version changed from $expected_runtime_output"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
    >"$evidence_dir/gpu-process-sample.csv"
  [[ -s $evidence_dir/gpu-process-sample.csv ]] || die 'the ready Atlas server had no sampled GPU process'

  atlas_client "$selected_engine" "$repo_root/tests/model-openai-smoke.py" \
    /opt/gb10/model-openai-smoke.py completion "$model_id" \
    >"$evidence_dir/response.json" 2>"$evidence_dir/completion.stderr"
  jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' \
    "$evidence_dir/response.json" >/dev/null || die 'Atlas completion response failed semantic checks'
  if jq -e '.acceptance.streaming // false' <<<"$profile_json" >/dev/null; then
    atlas_client "$selected_engine" "$repo_root/tests/model-openai-smoke.py" \
      /opt/gb10/model-openai-smoke.py stream "$model_id" \
      >"$evidence_dir/streaming-response.json" 2>"$evidence_dir/streaming.stderr"
    jq -e '.status == "pass" and .done == true and .chunks > 0' \
      "$evidence_dir/streaming-response.json" >/dev/null || die 'Atlas streaming gate failed'
  fi
  if jq -e '.acceptance.structuredOutputs // false' <<<"$profile_json" >/dev/null; then
    atlas_client "$selected_engine" "$repo_root/tests/model-openai-smoke.py" \
      /opt/gb10/model-openai-smoke.py structured "$model_id" \
      >"$evidence_dir/structured-response.json" 2>"$evidence_dir/structured.stderr"
    jq -e '.status == "pass" and .parsed == {"status":"GB10_OK","count":10}' \
      "$evidence_dir/structured-response.json" >/dev/null || die 'Atlas structured-output gate failed'
  fi
  if jq -e '.acceptance.imageInput // false' <<<"$profile_json" >/dev/null; then
    atlas_client "$selected_engine" "$repo_root/tests/model-openai-smoke.py" \
      /opt/gb10/model-openai-smoke.py multimodal "$model_id" \
      >"$evidence_dir/multimodal-response.json" 2>"$evidence_dir/multimodal.stderr"
    jq -e '.status == "pass" and .modality == "image+text"' \
      "$evidence_dir/multimodal-response.json" >/dev/null || die 'Atlas multimodal gate failed'
  fi
  local stress_tokens stress_concurrency
  stress_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
  stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")
  if (( stress_tokens > 0 )); then
    atlas_client "$selected_engine" "$repo_root/tests/model-openai-stress.py" \
      /opt/gb10/model-openai-stress.py all "$model_id" "$stress_tokens" "$stress_concurrency" \
      >"$evidence_dir/stress.json" 2>"$evidence_dir/stress.stderr"
    jq -e --argjson minimum "$stress_tokens" --argjson concurrency "$stress_concurrency" '
      .status == "pass" and .longContext.minimumPromptTokens == $minimum
      and .longContext.observedPromptTokens >= $minimum
      and .concurrency.requests == $concurrency
      and (.concurrency.results | length) == $concurrency
    ' "$evidence_dir/stress.json" >/dev/null || die 'Atlas stress gate failed'
  fi
  if jq -e '.acceptance.hermes // true' <<<"$profile_json" >/dev/null; then
    atlas_client "$selected_engine" "$repo_root/tests/hermes-openai-smoke.py" \
      /opt/gb10/hermes-openai-smoke.py "$model_id" \
      >"$evidence_dir/hermes-response.json" 2>"$evidence_dir/hermes.stderr"
    jq -e '
      .status == "pass"
      and .models_gate == "pass"
      and .chat_gate == "pass"
      and .tool_call_gate == "pass"
      and .tool_result_gate == "pass"
    ' "$evidence_dir/hermes-response.json" >/dev/null || \
      die 'Atlas Hermes compatibility response failed semantic checks'
  fi

  cleanup_atlas_acceptance "$selected_engine" "$check_container" "$evidence_dir"
  trap - EXIT INT TERM
}

accept_privacy_filter() {
  local selected_engine=$1 canonical_model=$2 evidence_dir=$3
  local cleanup_command
  local -a run_args
  common_run_args run_args "$canonical_model" "$repo_root/tests/privacy-filter-smoke.py" /opt/gb10/privacy-filter-smoke.py none
  remove_own_container "$selected_engine"
  printf -v cleanup_command 'remove_own_container %q' "$selected_engine"
  trap "$cleanup_command" EXIT INT TERM

  "$selected_engine" create "${run_args[@]}" --entrypoint python3 "$image" \
    /opt/gb10/privacy-filter-smoke.py /model >"$evidence_dir/container-id.txt"
  "$selected_engine" inspect "$container" >"$evidence_dir/container-inspect.json"
  "$selected_engine" start "$container" >/dev/null

  local sample_deadline=$((SECONDS + 120)) sampled=0
  while container_is_running "$selected_engine" && (( SECONDS < sample_deadline )); do
    if nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
      >"$evidence_dir/gpu-process-sample.csv" 2>/dev/null && [[ -s $evidence_dir/gpu-process-sample.csv ]]; then
      sampled=1
      break
    fi
    sleep 1
  done
  (( sampled == 1 )) || printf 'No compute PID was sampled before the bounded process exited.\n' >"$evidence_dir/gpu-process-sample.txt"

  local exit_code wait_status timeout_seconds
  timeout_seconds=${GB10_PRIVACY_FILTER_TIMEOUT_SECONDS:-900}
  [[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] && (( timeout_seconds <= 1800 )) || \
    die 'GB10_PRIVACY_FILTER_TIMEOUT_SECONDS must be 1..1800'
  set +e
  exit_code=$(timeout --kill-after=5 "$timeout_seconds" "$selected_engine" wait "$container")
  wait_status=$?
  set -e
  [[ $wait_status == 0 ]] || die "privacy-filter exceeded its ${timeout_seconds}s process boundary; see $evidence_dir"
  "$selected_engine" logs "$container" >"$evidence_dir/response.json" 2>"$evidence_dir/server.stderr"
  [[ $exit_code == 0 ]] || die "privacy-filter container exited $exit_code; see $evidence_dir"
  jq -e '.status == "pass" and .finite_checksum == true and .non_o_token_count > 0' "$evidence_dir/response.json" >/dev/null || \
    die "privacy-filter response failed semantic checks; see $evidence_dir"
}

accept_openai_server() {
  local selected_engine=$1 canonical_model=$2 evidence_dir=$3
  local cleanup_command
  local -a run_args model_args environment_args
  common_run_args run_args "$canonical_model" "$repo_root/tests/model-openai-smoke.py" /opt/gb10/model-openai-smoke.py none
  mapfile -t model_args < <(jq -r '.arguments[]' <<<"$profile_json")
  mapfile -t environment_args < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")
  local item
  for item in "${environment_args[@]}"; do
    run_args+=(-e "$item")
  done
  remove_own_container "$selected_engine"
  printf -v cleanup_command 'remove_own_container %q' "$selected_engine"
  trap "$cleanup_command" EXIT INT TERM
  "$selected_engine" run -d "${run_args[@]}" --entrypoint vllm "$image" \
    serve /model --host 127.0.0.1 --port 8000 "${model_args[@]}" >"$evidence_dir/container-id.txt"
  "$selected_engine" inspect "$container" >"$evidence_dir/container-inspect.json"

  local startup_timeout=${GB10_MODEL_STARTUP_TIMEOUT_SECONDS:-1200}
  [[ $startup_timeout =~ ^[1-9][0-9]*$ ]] && (( startup_timeout <= 2400 )) || \
    die 'GB10_MODEL_STARTUP_TIMEOUT_SECONDS must be 1..2400'
  local started=$SECONDS ready=0
  while (( SECONDS - started < startup_timeout )); do
    if ! container_is_running "$selected_engine"; then
      break
    fi
    if timeout --kill-after=5 45 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py ready "$model_id" >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
      ready=1
      break
    fi
    sleep 5
  done
  "$selected_engine" logs "$container" >"$evidence_dir/server.log" 2>&1 || true
  (( ready == 1 )) || die "model server did not become ready; see $evidence_dir/server.log"

  "$selected_engine" exec "$container" python3 -c \
    'import json,torch,transformers,vllm; print(json.dumps({"torch":torch.__version__,"torch_cuda":torch.version.cuda,"transformers":transformers.__version__,"vllm":vllm.__version__,"cuda_available":torch.cuda.is_available(),"device":torch.cuda.get_device_name(0) if torch.cuda.is_available() else None},sort_keys=True))' \
    >"$evidence_dir/runtime-metadata.json"
  jq -e --arg expected "$engine_version" '.vllm == $expected' \
    "$evidence_dir/runtime-metadata.json" >/dev/null || \
    die "live vLLM version does not match the pinned profile version: $engine_version"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
    >"$evidence_dir/gpu-process-sample.csv"
  [[ -s $evidence_dir/gpu-process-sample.csv ]] || die 'the ready server had no sampled GPU compute process'
  timeout --kill-after=5 180 "$selected_engine" exec "$container" \
    python3 /opt/gb10/model-openai-smoke.py completion "$model_id" >"$evidence_dir/response.json" 2>"$evidence_dir/completion.stderr"
  jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' "$evidence_dir/response.json" >/dev/null || \
    die 'completion response failed semantic checks'
  if jq -e '.acceptance.streaming // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py stream "$model_id" \
      >"$evidence_dir/streaming-response.json" 2>"$evidence_dir/streaming.stderr"
    jq -e '.status == "pass" and .done == true and .chunks > 0' \
      "$evidence_dir/streaming-response.json" >/dev/null || die 'streaming gate failed'
  fi
  if jq -e '.acceptance.structuredOutputs // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py structured "$model_id" \
      >"$evidence_dir/structured-response.json" 2>"$evidence_dir/structured.stderr"
    jq -e '.status == "pass" and .parsed == {"status":"GB10_OK","count":10}' \
      "$evidence_dir/structured-response.json" >/dev/null || die 'structured-output gate failed'
  fi
  if jq -e '.acceptance.imageInput // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 600 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py multimodal "$model_id" \
      >"$evidence_dir/multimodal-response.json" 2>"$evidence_dir/multimodal.stderr"
    jq -e '.status == "pass" and .modality == "image+text"' \
      "$evidence_dir/multimodal-response.json" >/dev/null || die 'multimodal gate failed'
  fi
  local stress_tokens stress_concurrency
  stress_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
  stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")
  if (( stress_tokens > 0 )); then
    timeout --kill-after=10 1800 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-stress.py all "$model_id" "$stress_tokens" "$stress_concurrency" \
      >"$evidence_dir/stress.json" 2>"$evidence_dir/stress.stderr"
    jq -e --argjson minimum "$stress_tokens" --argjson concurrency "$stress_concurrency" '
      .status == "pass" and .longContext.minimumPromptTokens == $minimum
      and .longContext.observedPromptTokens >= $minimum
      and .concurrency.requests == $concurrency
      and (.concurrency.results | length) == $concurrency
    ' "$evidence_dir/stress.json" >/dev/null || die 'stress gate failed'
  fi
  if jq -e '.acceptance.hermes // true' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/hermes-openai-smoke.py "$model_id" >"$evidence_dir/hermes-response.json" 2>"$evidence_dir/hermes.stderr"
    jq -e '
      .status == "pass"
      and .models_gate == "pass"
      and .chat_gate == "pass"
      and .tool_call_gate == "pass"
      and .tool_result_gate == "pass"
    ' "$evidence_dir/hermes-response.json" >/dev/null || \
      die 'Hermes compatibility response failed semantic checks'
  fi
}

accept_trtllm_server() {
  local selected_engine=$1 canonical_model=$2 evidence_dir=$3
  local cleanup_command item
  local -a run_args model_args environment_args
  common_run_args run_args "$canonical_model" "$repo_root/tests/model-openai-smoke.py" /opt/gb10/model-openai-smoke.py none
  mapfile -t model_args < <(jq -r '.arguments[]' <<<"$profile_json")
  mapfile -t environment_args < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")
  for item in "${environment_args[@]}"; do
    run_args+=(-e "$item")
  done
  remove_own_container "$selected_engine"
  printf -v cleanup_command 'remove_own_container %q' "$selected_engine"
  trap "$cleanup_command" EXIT INT TERM
  "$selected_engine" run -d "${run_args[@]}" --entrypoint trtllm-serve "$image" \
    serve /model --host 127.0.0.1 --port 8000 "${model_args[@]}" >"$evidence_dir/container-id.txt"
  "$selected_engine" inspect "$container" >"$evidence_dir/container-inspect.json"

  local startup_timeout=${GB10_MODEL_STARTUP_TIMEOUT_SECONDS:-2400}
  [[ $startup_timeout =~ ^[1-9][0-9]*$ ]] && (( startup_timeout <= 3600 )) || \
    die 'GB10_MODEL_STARTUP_TIMEOUT_SECONDS must be 1..3600 for TensorRT-LLM'
  local started=$SECONDS ready=0
  while (( SECONDS - started < startup_timeout )); do
    if ! container_is_running "$selected_engine"; then
      break
    fi
    if timeout --kill-after=5 45 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py ready "$model_id" >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
      ready=1
      break
    fi
    sleep 5
  done
  "$selected_engine" logs "$container" >"$evidence_dir/server.log" 2>&1 || true
  (( ready == 1 )) || die "TensorRT-LLM server did not become ready; see $evidence_dir/server.log"

  "$selected_engine" exec "$container" python3 -c \
    'import importlib.metadata as m,json,torch; print(json.dumps({"tensorrt_llm":m.version("tensorrt-llm"),"torch":torch.__version__,"torch_cuda":torch.version.cuda,"cuda_available":torch.cuda.is_available(),"device":torch.cuda.get_device_name(0) if torch.cuda.is_available() else None},sort_keys=True))' \
    >"$evidence_dir/runtime-metadata.json"
  jq -e --arg expected "$engine_version" '.tensorrt_llm == $expected and .cuda_available == true' \
    "$evidence_dir/runtime-metadata.json" >/dev/null || \
    die "live TensorRT-LLM version or CUDA state does not match the pinned profile: $engine_version"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
    >"$evidence_dir/gpu-process-sample.csv"
  [[ -s $evidence_dir/gpu-process-sample.csv ]] || die 'the ready TensorRT-LLM server had no sampled GPU compute process'
  timeout --kill-after=5 300 "$selected_engine" exec "$container" \
    python3 /opt/gb10/model-openai-smoke.py completion "$model_id" >"$evidence_dir/response.json" 2>"$evidence_dir/completion.stderr"
  jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' "$evidence_dir/response.json" >/dev/null || \
    die 'TensorRT-LLM completion response failed semantic checks'
  if jq -e '.acceptance.streaming // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py stream "$model_id" \
      >"$evidence_dir/streaming-response.json" 2>"$evidence_dir/streaming.stderr"
    jq -e '.status == "pass" and .done == true and .chunks > 0' \
      "$evidence_dir/streaming-response.json" >/dev/null || die 'TensorRT-LLM streaming gate failed'
  fi
  if jq -e '.acceptance.structuredOutputs // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py structured "$model_id" \
      >"$evidence_dir/structured-response.json" 2>"$evidence_dir/structured.stderr"
    jq -e '.status == "pass" and .parsed == {"status":"GB10_OK","count":10}' \
      "$evidence_dir/structured-response.json" >/dev/null || die 'TensorRT-LLM structured-output gate failed'
  fi
  local stress_tokens stress_concurrency
  stress_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
  stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")
  if (( stress_tokens > 0 )); then
    timeout --kill-after=10 1800 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-stress.py all "$model_id" "$stress_tokens" "$stress_concurrency" \
      >"$evidence_dir/stress.json" 2>"$evidence_dir/stress.stderr"
    jq -e --argjson minimum "$stress_tokens" --argjson concurrency "$stress_concurrency" '
      .status == "pass" and .longContext.minimumPromptTokens == $minimum
      and .longContext.observedPromptTokens >= $minimum
      and .concurrency.requests == $concurrency
      and (.concurrency.results | length) == $concurrency
    ' "$evidence_dir/stress.json" >/dev/null || die 'TensorRT-LLM stress gate failed'
  fi
  if jq -e '.acceptance.hermes // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/hermes-openai-smoke.py "$model_id" >"$evidence_dir/hermes-response.json" 2>"$evidence_dir/hermes.stderr"
    jq -e '.status == "pass" and .models_gate == "pass" and .chat_gate == "pass" and .tool_call_gate == "pass" and .tool_result_gate == "pass"' \
      "$evidence_dir/hermes-response.json" >/dev/null || die 'TensorRT-LLM Hermes compatibility response failed semantic checks'
  fi
}

accept_sglang_server() {
  local selected_engine=$1 canonical_model=$2 evidence_dir=$3
  local cleanup_command item
  local -a run_args model_args environment_args
  common_run_args run_args "$canonical_model" "$repo_root/tests/model-openai-smoke.py" /opt/gb10/model-openai-smoke.py none
  mapfile -t model_args < <(jq -r '.arguments[]' <<<"$profile_json")
  mapfile -t environment_args < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")
  for item in "${environment_args[@]}"; do
    run_args+=(-e "$item")
  done

  remove_own_container "$selected_engine"
  printf -v cleanup_command 'remove_own_container %q' "$selected_engine"
  trap "$cleanup_command" EXIT INT TERM
  "$selected_engine" run -d "${run_args[@]}" --entrypoint sglang "$image" \
    serve --model-path /model --host 127.0.0.1 --port 8000 "${model_args[@]}" \
    >"$evidence_dir/container-id.txt"
  "$selected_engine" inspect "$container" >"$evidence_dir/container-inspect.json"

  local startup_timeout=${GB10_MODEL_STARTUP_TIMEOUT_SECONDS:-1200}
  [[ $startup_timeout =~ ^[1-9][0-9]*$ ]] && (( startup_timeout <= 2400 )) || \
    die 'GB10_MODEL_STARTUP_TIMEOUT_SECONDS must be 1..2400'
  local started=$SECONDS ready=0
  while (( SECONDS - started < startup_timeout )); do
    if ! container_is_running "$selected_engine"; then
      break
    fi
    if timeout --kill-after=5 45 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py ready "$model_id" >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
      ready=1
      break
    fi
    sleep 5
  done
  "$selected_engine" logs "$container" >"$evidence_dir/server.log" 2>&1 || true
  (( ready == 1 )) || die "SGLang server did not become ready; see $evidence_dir/server.log"

  "$selected_engine" exec "$container" python3 -c \
    'import json,sglang,torch,transformers; print(json.dumps({"sglang":sglang.__version__,"torch":torch.__version__,"torch_cuda":torch.version.cuda,"transformers":transformers.__version__,"cuda_available":torch.cuda.is_available(),"device":torch.cuda.get_device_name(0) if torch.cuda.is_available() else None},sort_keys=True))' \
    >"$evidence_dir/runtime-metadata.json"
  jq -e --arg expected "$engine_version" '.sglang == $expected and .cuda_available == true' \
    "$evidence_dir/runtime-metadata.json" >/dev/null || \
    die "live SGLang version or CUDA state does not match the pinned profile: $engine_version"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
    >"$evidence_dir/gpu-process-sample.csv"
  [[ -s $evidence_dir/gpu-process-sample.csv ]] || die 'the ready SGLang server had no sampled GPU compute process'
  timeout --kill-after=5 180 "$selected_engine" exec "$container" \
    python3 /opt/gb10/model-openai-smoke.py completion "$model_id" >"$evidence_dir/response.json" 2>"$evidence_dir/completion.stderr"
  jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' "$evidence_dir/response.json" >/dev/null || \
    die 'SGLang completion response failed semantic checks'
  if jq -e '.acceptance.streaming // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py stream "$model_id" \
      >"$evidence_dir/streaming-response.json" 2>"$evidence_dir/streaming.stderr"
    jq -e '.status == "pass" and .done == true and .chunks > 0' \
      "$evidence_dir/streaming-response.json" >/dev/null || die 'SGLang streaming gate failed'
  fi
  if jq -e '.acceptance.structuredOutputs // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py structured "$model_id" \
      >"$evidence_dir/structured-response.json" 2>"$evidence_dir/structured.stderr"
    jq -e '.status == "pass" and .parsed == {"status":"GB10_OK","count":10}' \
      "$evidence_dir/structured-response.json" >/dev/null || die 'SGLang structured-output gate failed'
  fi
  if jq -e '.acceptance.reasoningParsing // false' <<<"$profile_json" >/dev/null; then
    timeout --kill-after=5 360 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py reasoning "$model_id" \
      >"$evidence_dir/reasoning-response.json" 2>"$evidence_dir/reasoning.stderr"
    jq -e '.status == "pass" and .reasoningCharacters > 0 and .answerContains42 == true' \
      "$evidence_dir/reasoning-response.json" >/dev/null || die 'SGLang reasoning-parser gate failed'
  fi
  timeout --kill-after=5 360 "$selected_engine" exec "$container" \
    python3 /opt/gb10/hermes-openai-smoke.py "$model_id" >"$evidence_dir/hermes-response.json" 2>"$evidence_dir/hermes.stderr"
  jq -e '
    .status == "pass"
    and .models_gate == "pass"
    and .chat_gate == "pass"
    and .tool_call_gate == "pass"
    and .tool_result_gate == "pass"
  ' "$evidence_dir/hermes-response.json" >/dev/null || \
    die 'SGLang Hermes compatibility response failed semantic checks'
  timeout --kill-after=5 360 "$selected_engine" exec "$container" \
    python3 /opt/gb10/model-openai-smoke.py multimodal "$model_id" \
    >"$evidence_dir/multimodal-response.json" 2>"$evidence_dir/multimodal.stderr"
  jq -e '.status == "pass" and .modality == "image+text"' \
    "$evidence_dir/multimodal-response.json" >/dev/null || \
    die 'SGLang multimodal response failed semantic checks'
  local stress_tokens stress_concurrency
  stress_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
  stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")
  if (( stress_tokens > 0 )); then
    timeout --kill-after=10 1800 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-stress.py all "$model_id" "$stress_tokens" "$stress_concurrency" \
      >"$evidence_dir/stress.json" 2>"$evidence_dir/stress.stderr"
    jq -e --argjson minimum "$stress_tokens" --argjson concurrency "$stress_concurrency" '
      .status == "pass" and .longContext.minimumPromptTokens == $minimum
      and .longContext.observedPromptTokens >= $minimum
      and .concurrency.requests == $concurrency
      and (.concurrency.results | length) == $concurrency
    ' "$evidence_dir/stress.json" >/dev/null || die 'SGLang stress gate failed'
  fi
}

accept_sglang_omni_music3() {
  local selected_engine=$1 canonical_model=$2 evidence_dir=$3
  local cleanup_command item first_audio_sha second_audio_sha
  local -a run_args model_args environment_args
  common_run_args run_args "$canonical_model" "$repo_root/tests/music3-smoke.py" /opt/gb10/music3-smoke.py none
  run_args+=(-v "$repo_root/scripts/sglang-omni-model-shadow.sh:/opt/gb10/sglang-omni-model-shadow.sh:ro")
  mapfile -t model_args < <(jq -r '.arguments[]' <<<"$profile_json")
  mapfile -t environment_args < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")
  for item in "${environment_args[@]}"; do
    run_args+=(-e "$item")
  done

  remove_own_container "$selected_engine"
  printf -v cleanup_command 'remove_own_container %q' "$selected_engine"
  trap "$cleanup_command" EXIT INT TERM
  "$selected_engine" run -d "${run_args[@]}" --entrypoint /bin/bash "$image" \
    /opt/gb10/sglang-omni-model-shadow.sh --model-name "$model_id" --host 127.0.0.1 --port 8000 \
    "${model_args[@]}" >"$evidence_dir/container-id.txt"
  "$selected_engine" inspect "$container" >"$evidence_dir/container-inspect.json"

  local startup_timeout=${GB10_MODEL_STARTUP_TIMEOUT_SECONDS:-2400}
  [[ $startup_timeout =~ ^[1-9][0-9]*$ ]] && (( startup_timeout <= 3600 )) || \
    die 'GB10_MODEL_STARTUP_TIMEOUT_SECONDS must be 1..3600'
  local started=$SECONDS ready=0
  while (( SECONDS - started < startup_timeout )); do
    if ! container_is_running "$selected_engine"; then
      break
    fi
    if timeout --kill-after=5 45 "$selected_engine" exec "$container" \
      python3 /opt/gb10/music3-smoke.py ready "$model_id" \
      >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
      ready=1
      break
    fi
    sleep 5
  done
  "$selected_engine" logs "$container" >"$evidence_dir/server.log" 2>&1 || true
  (( ready == 1 )) || die "SGLang-Omni Music3 server did not become ready; see $evidence_dir/server.log"

  "$selected_engine" exec "$container" python3 -c \
    'import json,sglang,sglang_omni,torch,transformers; print(json.dumps({"sglang":sglang.__version__,"sglang_omni":sglang_omni.__version__,"torch":torch.__version__,"torch_cuda":torch.version.cuda,"transformers":transformers.__version__,"cuda_available":torch.cuda.is_available(),"device":torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,"capability":torch.cuda.get_device_capability(0) if torch.cuda.is_available() else None},sort_keys=True))' \
    >"$evidence_dir/runtime-metadata.json"
  jq -e --arg expected "$engine_version" '
    .sglang_omni == $expected and .sglang == "0.5.16" and
    .torch == "2.11.0+cu130" and .transformers == "5.12.1" and
    .cuda_available == true and .capability == [12,1]
  ' "$evidence_dir/runtime-metadata.json" >/dev/null || \
    die 'live SGLang-Omni, CUDA, or GB10 runtime metadata does not match the pinned profile'
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
    >"$evidence_dir/gpu-process-sample.csv"
  [[ -s $evidence_dir/gpu-process-sample.csv ]] || die 'the ready Music3 server had no sampled GPU compute process'

  timeout --kill-after=10 1800 "$selected_engine" exec "$container" \
    python3 /opt/gb10/music3-smoke.py generate "$model_id" \
    >"$evidence_dir/music3-response-1.json" 2>"$evidence_dir/music3-response-1.stderr"
  timeout --kill-after=10 1800 "$selected_engine" exec "$container" \
    python3 /opt/gb10/music3-smoke.py generate "$model_id" \
    >"$evidence_dir/music3-response-2.json" 2>"$evidence_dir/music3-response-2.stderr"
  jq -e '.status == "pass" and .channels == 2 and .sample_rate == 32000 and .sample_width_bytes == 2 and .frames > 0' \
    "$evidence_dir/music3-response-1.json" "$evidence_dir/music3-response-2.json" >/dev/null || \
    die 'Music3 WAV acceptance failed'
  first_audio_sha=$(jq -r '.sha256' "$evidence_dir/music3-response-1.json")
  second_audio_sha=$(jq -r '.sha256' "$evidence_dir/music3-response-2.json")
  [[ $first_audio_sha == "$second_audio_sha" ]] || die 'Music3 repeated seeded output was not deterministic'
  "$selected_engine" logs "$container" >"$evidence_dir/server.log" 2>&1 || true
}

run_acceptance() {
  require_commands date find jq nvidia-smi sha256sum timeout xargs
  local evidence_root evidence_dir canonical_model selected_engine started_at elapsed source_manifest_sha
  evidence_root=${GB10_MODEL_EVIDENCE_ROOT:-$HOME/gb10sor-private-evidence/model-qualification}
  umask 077
  evidence_dir="$evidence_root/$(date -u +%Y-%m-%d)/$profile/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$evidence_dir"
  chmod 700 "$evidence_dir"
  if [[ $engine == sglang-omni ]]; then
    local runtime_engine
    runtime_engine=$(gb10_select_container_engine) || die 'container engine unavailable for the ARM64 runtime build'
    if ! "$runtime_engine" image inspect "$image" >/dev/null 2>&1; then
      "$repo_root/scripts/build-sglang-omni-arm64-image.sh" >"$evidence_dir/runtime-build.txt"
    fi
  fi
  model_preflight >"$evidence_dir/preflight.json"
  canonical_model=$(canonical_model_path)
  selected_engine=$(gb10_select_container_engine) || die 'container engine unavailable after preflight'
  "$selected_engine" image inspect "$image" >"$evidence_dir/image-inspect.json"
  nvidia-smi -q >"$evidence_dir/nvidia-smi-before.txt"
  started_at=$SECONDS

  case "$engine" in
    transformers-token-classification)
      accept_privacy_filter "$selected_engine" "$canonical_model" "$evidence_dir"
      ;;
    vllm)
      accept_openai_server "$selected_engine" "$canonical_model" "$evidence_dir"
      ;;
    trtllm)
      accept_trtllm_server "$selected_engine" "$canonical_model" "$evidence_dir"
      ;;
    atlas)
      accept_atlas_server "$selected_engine" "$canonical_model" "$evidence_dir"
      ;;
    sglang)
      accept_sglang_server "$selected_engine" "$canonical_model" "$evidence_dir"
      ;;
    sglang-omni)
      accept_sglang_omni_music3 "$selected_engine" "$canonical_model" "$evidence_dir"
      ;;
    *) die "no acceptance implementation exists for engine: $engine" ;;
  esac

  remove_own_container "$selected_engine"
  trap - EXIT INT TERM
  gb10_container_exists "$selected_engine" "$container" && die 'owned container remained after cleanup'
  sleep 2
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits \
    >"$evidence_dir/gpu-processes-after.csv" 2>/dev/null || true
  [[ ! -s $evidence_dir/gpu-processes-after.csv ]] || die 'GPU compute processes remained after cleanup'
  nvidia-smi -q >"$evidence_dir/nvidia-smi-after.txt"
  elapsed=$((SECONDS - started_at))
  source_manifest_sha=$(sha256sum "$repo_root/ADAPTATION-SHA256SUMS" | awk '{print $1}')
  jq -n \
    --arg status pass --arg profile "$profile" --arg modelId "$model_id" --arg engine "$engine" \
    --arg engineVersion "$engine_version" --arg image "$image" --arg evidenceDir "$evidence_dir" \
    --arg sourceManifestSha256 "$source_manifest_sha" --argjson elapsedSeconds "$elapsed" \
    '{status:$status,profile:$profile,modelId:$modelId,engine:$engine,engineVersion:$engineVersion,image:$image,sourceManifestSha256:$sourceManifestSha256,elapsedSeconds:$elapsedSeconds,network:"none",modelMount:"read-only",cleanup:"pass",evidenceDir:$evidenceDir}' \
    >"$evidence_dir/summary.json"
  evidence_manifest "$evidence_dir"
  printf 'model_acceptance=pass\nprofile=%s\nevidence_dir=%s\nelapsed_seconds=%s\n' \
    "$profile" "$evidence_dir" "$elapsed"
}

serve_profile() {
  require_commands find grep jq nvidia-smi python3 sha256sum sort tail timeout
  [[ $engine == vllm || $engine == trtllm || $engine == atlas || $engine == sglang || $engine == sglang-omni ]] || \
    die "production serving is not implemented for engine: $engine"

  # Recheck the live checkpoint, image, GPU, and immutable registry before
  # trusting earlier evidence. This catches a changed weight file after the
  # last accepted run.
  (cd -- "$repo_root" && sha256sum -c ADAPTATION-SHA256SUMS >/dev/null) || \
    die 'source files do not match the reviewed adaptation manifest'
  model_preflight >/dev/null

  local host_port=${GB10_MODEL_HOST_PORT:-8000}
  [[ $host_port =~ ^[0-9]+$ ]] && (( host_port >= 1024 && host_port <= 65535 )) || \
    die 'GB10_MODEL_HOST_PORT must be 1024..65535'
  python3 - "$host_port" <<'PY' || die "loopback port is already in use: $host_port"
import socket
import sys
with socket.socket() as probe:
    probe.bind(("127.0.0.1", int(sys.argv[1])))
PY

  local evidence_root latest_summary evidence_dir source_manifest_sha declared_weight_count
  evidence_root=${GB10_MODEL_EVIDENCE_ROOT:-$HOME/gb10sor-private-evidence/model-qualification}
  latest_summary=$(find "$evidence_root" -path "*/$profile/*/summary.json" -type f -printf '%T@\t%p\n' 2>/dev/null \
    | sort -n | tail -n 1 | cut -f2- || true)
  [[ -n $latest_summary && -r $latest_summary ]] || \
    die 'no completed acceptance evidence exists for this profile'
  evidence_dir=$(dirname -- "$latest_summary")
  (cd -- "$evidence_dir" && sha256sum -c SHA256SUMS >/dev/null) || \
    die "acceptance evidence checksum failed: $evidence_dir"
  source_manifest_sha=$(sha256sum "$repo_root/ADAPTATION-SHA256SUMS" | awk '{print $1}')
  jq -e \
    --arg profile "$profile" --arg modelId "$model_id" --arg image "$image" \
    --arg sourceManifestSha256 "$source_manifest_sha" \
    '.status == "pass" and .cleanup == "pass" and .profile == $profile and
     .modelId == $modelId and .image == $image and
     .sourceManifestSha256 == $sourceManifestSha256' \
    "$latest_summary" >/dev/null || \
    die 'latest acceptance evidence does not match this exact source, model, and image'
  declared_weight_count=$(jq -r '
    if (.weightTreeSha256 // "") != "" then .weightFiles
    else (.weights // [] | length)
    end
  ' <<<"$profile_json")
  jq -e --argjson count "$declared_weight_count" \
    '.verifiedWeightDigests == $count' "$evidence_dir/preflight.json" >/dev/null || \
    die 'acceptance evidence does not contain the expected weight-digest result'

  local canonical_model selected_engine item ready started cleanup_command network_mode
  local -a run_args model_args environment_args
  canonical_model=$(canonical_model_path)
  selected_engine=$(gb10_select_container_engine) || die 'no usable container engine'
  network_mode=bridge
  if [[ $profile == medismera-qwen38-mythos-solo-sglang ]]; then
    ensure_whitehat_network "$selected_engine"
    network_mode=$whitehat_network
  fi
  printf -v cleanup_command 'cleanup_owned_service %q' "$selected_engine"
  trap "$cleanup_command" EXIT INT TERM
  mapfile -t model_args < <(jq -r '.arguments[]' <<<"$profile_json")
  if [[ $engine == atlas ]]; then
    # Atlas acceptance shares the container network namespace, where binding
    # loopback is correct. Production serving uses a rootless bridge with a
    # host-loopback-only published port, so Atlas must listen on the container
    # interface for that port forward to work. Refuse an unexpected argument
    # shape instead of silently broadening the endpoint.
    atlas_bind_rewritten=0
    for ((item = 0; item < ${#model_args[@]}; item++)); do
      if [[ ${model_args[$item]} == --bind ]]; then
        (( item + 1 < ${#model_args[@]} )) || die 'Atlas --bind is missing its value'
        [[ ${model_args[$((item + 1))]} == 127.0.0.1 ]] || \
          die 'Atlas production bridge requires the reviewed loopback bind declaration'
        model_args[$((item + 1))]=0.0.0.0
        atlas_bind_rewritten=1
        break
      fi
    done
    (( atlas_bind_rewritten == 1 )) || die 'Atlas production bridge requires an explicit --bind declaration'
    atlas_run_args run_args "$canonical_model" "$container" bridge
    run_args+=(--publish "127.0.0.1:${host_port}:8000")
  else
    if [[ $engine == sglang-omni ]]; then
      common_run_args run_args "$canonical_model" "$repo_root/tests/music3-smoke.py" /opt/gb10/music3-smoke.py bridge
      run_args+=(-v "$repo_root/scripts/sglang-omni-model-shadow.sh:/opt/gb10/sglang-omni-model-shadow.sh:ro")
    else
      common_run_args run_args "$canonical_model" "$repo_root/tests/model-openai-smoke.py" /opt/gb10/model-openai-smoke.py "$network_mode"
    fi
    run_args+=(--publish "127.0.0.1:${host_port}:8000")
    mapfile -t environment_args < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")
    for item in "${environment_args[@]}"; do
      run_args+=(-e "$item")
    done
  fi

  remove_own_container "$selected_engine"
  if [[ $engine == atlas ]]; then
    "$selected_engine" run -d "${run_args[@]}" "$image" "${model_args[@]}" >/dev/null
  elif [[ $engine == sglang ]]; then
    "$selected_engine" run -d "${run_args[@]}" --entrypoint sglang "$image" \
      serve --model-path /model --host 0.0.0.0 --port 8000 "${model_args[@]}" >/dev/null
  elif [[ $engine == trtllm ]]; then
    "$selected_engine" run -d "${run_args[@]}" --entrypoint trtllm-serve "$image" \
      serve /model --host 0.0.0.0 --port 8000 "${model_args[@]}" >/dev/null
  elif [[ $engine == sglang-omni ]]; then
    "$selected_engine" run -d "${run_args[@]}" --entrypoint /bin/bash "$image" \
      /opt/gb10/sglang-omni-model-shadow.sh --model-name "$model_id" --host 0.0.0.0 --port 8000 "${model_args[@]}" >/dev/null
  else
    "$selected_engine" run -d "${run_args[@]}" --entrypoint vllm "$image" \
      serve /model --host 0.0.0.0 --port 8000 "${model_args[@]}" >/dev/null
  fi
  local serve_startup_timeout=1200
  [[ $engine == sglang-omni ]] && serve_startup_timeout=2400
  started=$SECONDS
  ready=0
  while (( SECONDS - started < serve_startup_timeout )); do
    if ! container_is_running "$selected_engine"; then
      break
    fi
    if [[ $engine == atlas ]]; then
      if timeout --kill-after=5 45 python3 "$repo_root/tests/model-openai-smoke.py" ready "$model_id" \
        >/dev/null 2>&1; then
        ready=1
        break
      fi
    elif [[ $engine == sglang-omni ]] && timeout --kill-after=5 45 "$selected_engine" exec "$container" \
      python3 /opt/gb10/music3-smoke.py ready "$model_id" >/dev/null 2>&1; then
      ready=1
      break
    elif timeout --kill-after=5 45 "$selected_engine" exec "$container" \
      python3 /opt/gb10/model-openai-smoke.py ready "$model_id" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 5
  done
  (( ready == 1 )) || {
    "$selected_engine" logs "$container" >&2 || true
    die 'production model server did not become ready'
  }
  "$selected_engine" port "$container" 8000/tcp | grep -Fx "127.0.0.1:${host_port}" >/dev/null || \
    die 'production port is not restricted to the requested loopback address'
  trap - EXIT INT TERM
  printf 'model_serve=pass\nprofile=%s\nendpoint=http://127.0.0.1:%s/v1\ncontainer=%s\n' \
    "$profile" "$host_port" "$container"
}

stop_profile() {
  local selected_engine
  selected_engine=$(gb10_select_container_engine) || die 'no usable container engine'
  cleanup_owned_service "$selected_engine"
  if gb10_container_exists "$selected_engine" "$container"; then
    die "profile container remains after cleanup: $container"
  fi
  printf 'profile_container_absent=%s\n' "$container"
}

qualify_and_serve_profile() {
  # Repeat the cheap preflight inside acceptance and serve. Each phase then
  # fails closed if the checkpoint, runtime, source, or evidence changes.
  bootstrap_profile
  run_acceptance
  serve_profile
}

benchmark_profile() {
  local recipe_relative benchmark_profile_relative output_root output nodes tensor_parallel pipeline_parallel host_count
  local benchmark_compatibility blocked_reason
  benchmark_compatibility=$(jq -r '.benchmark.compatibility // "missing"' <<<"$profile_json")
  blocked_reason=$(jq -r '.benchmark.blockedReason // "deployment qualification is incomplete"' <<<"$profile_json")
  case "$benchmark_compatibility" in
    untested|validated|ready|qualified|qualified-*) ;;
    blocked) die "benchmark is blocked for this profile: $blocked_reason" ;;
    *) die "profile lacks a recognized benchmark compatibility state: $benchmark_compatibility" ;;
  esac
  recipe_relative=$(jq -r '.benchmark.recipe // empty' <<<"$profile_json")
  benchmark_profile_relative=$(jq -r '.benchmark.profile // empty' <<<"$profile_json")
  [[ -n $recipe_relative && $recipe_relative != /* && $recipe_relative != *..* ]] || \
    die 'profile lacks a safe benchmark recipe'
  [[ -n $benchmark_profile_relative && $benchmark_profile_relative != /* && $benchmark_profile_relative != *..* ]] || \
    die 'profile lacks a safe benchmark profile'
  [[ -r $repo_root/$recipe_relative ]] || die "benchmark recipe is unreadable: $recipe_relative"
  [[ -r $repo_root/$benchmark_profile_relative ]] || die "benchmark profile is unreadable: $benchmark_profile_relative"
  output_root=${GB10_MODEL_BENCHMARK_ROOT:-$HOME/gb10sor-private-evidence/model-benchmarks}
  output=${GB10_MODEL_BENCHMARK_OUTPUT:-$output_root/$profile/$(date -u +%Y%m%dT%H%M%SZ).yaml}
  [[ $output == /* ]] || die 'benchmark output path must be absolute'
  nodes=$(jq -r '.benchmark.nodes // 1' <<<"$profile_json")
  tensor_parallel=$(jq -r '.benchmark.tensorParallel // 1' <<<"$profile_json")
  pipeline_parallel=$(jq -r '.benchmark.pipelineParallel // 1' <<<"$profile_json")
  [[ $nodes =~ ^[1-8]$ && $tensor_parallel =~ ^[1-8]$ && $pipeline_parallel =~ ^[1-8]$ ]] || \
    die 'profile benchmark node/TP/PP values must each be 1..8'
  (( tensor_parallel * pipeline_parallel == nodes )) || \
    die 'profile benchmark TP x PP does not equal its node count'
  if (( nodes > 1 )); then
    [[ -n ${GB10_BENCHMARK_HOSTS:-} ]] || die 'multi-node benchmark requires explicit GB10_BENCHMARK_HOSTS'
    host_count=$(awk -F, '{print NF}' <<<"$GB10_BENCHMARK_HOSTS")
    (( host_count == nodes )) || die "benchmark requires exactly $nodes hosts, observed $host_count"
  fi
  GB10_BENCHMARK_PROFILE="$repo_root/$benchmark_profile_relative" \
    GB10_BENCHMARK_TP="$tensor_parallel" GB10_BENCHMARK_PP="$pipeline_parallel" \
    GB10_BENCHMARK_TOKENIZER="$(canonical_model_path)" \
    "$repo_root/scripts/spark-arena-adapter.sh" benchmark "$repo_root/$recipe_relative" "$output"
  printf 'model_benchmark=pass\nprofile=%s\nevidence=%s\n' "$profile" "$output"
}

qualify_benchmark_and_stop_profile() {
  local selected_engine cleanup_command
  bootstrap_profile
  run_acceptance
  serve_profile
  selected_engine=$(gb10_select_container_engine) || die 'no usable container engine'
  printf -v cleanup_command 'cleanup_owned_service %q' "$selected_engine"
  trap "$cleanup_command" EXIT INT TERM
  benchmark_profile
  cleanup_owned_service "$selected_engine"
  gb10_container_exists "$selected_engine" "$container" && \
    die "profile container remains after benchmark cleanup: $container"
  trap - EXIT INT TERM
  printf 'benchmark_cleanup=pass\nprofile=%s\n' "$profile"
}

case "$action" in
  show) show_profile ;;
  stage-runtime) stage_runtime ;;
  bootstrap) bootstrap_profile ;;
  preflight) model_preflight ;;
  acceptance) run_acceptance ;;
  qualify-and-serve) qualify_and_serve_profile ;;
  benchmark-only) benchmark_profile ;;
  qualify-benchmark-and-stop) qualify_benchmark_and_stop_profile ;;
  serve) serve_profile ;;
  stop) stop_profile ;;
esac
