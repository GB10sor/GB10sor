#!/usr/bin/env bash
set -Eeuo pipefail

# Fail-closed 2/3/4/8-node vLLM or SGLang acceptance over an already-qualified persistent
# switched fabric. The inventory, checkpoints, and immutable ARM64 image must
# already be present. This script never downloads a model or changes NixOS.

die() {
  printf 'Cluster vLLM acceptance failed: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name=$1
  [[ -n "${!name:-}" ]] || die "missing required environment variable: $name"
}

require_env GB10_CLUSTER_INVENTORY_FILE
require_env GB10_CLUSTER_EVIDENCE_DIR

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
inventory=$GB10_CLUSTER_INVENTORY_FILE
evidence_dir=$GB10_CLUSTER_EVIDENCE_DIR
profile_registry="${GB10_CLUSTER_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}"
profile="${GB10_CLUSTER_MODEL_PROFILE:-}"
master_port="${GB10_CLUSTER_VLLM_MASTER_PORT:-29601}"
startup_timeout="${GB10_CLUSTER_VLLM_STARTUP_TIMEOUT_SECONDS:-3600}"
request_timeout="${GB10_CLUSTER_VLLM_REQUEST_TIMEOUT_SECONDS:-900}"
target_mtu="${GB10_CLUSTER_MTU:-9000}"
nccl_ib_hca="${GB10_CLUSTER_NCCL_IB_HCA:-mlx5_1:1,mlx5_3:1}"
nccl_ib_gid_index="${GB10_CLUSTER_NCCL_IB_GID_INDEX:-3}"
enforce_eager="${GB10_CLUSTER_VLLM_ENFORCE_EAGER:-1}"
qualify_and_serve="${GB10_CLUSTER_QUALIFY_AND_SERVE:-0}"
serve_max_seconds="${GB10_CLUSTER_SERVE_MAX_SECONDS:-0}"
ssh_connect_timeout="${GB10_CLUSTER_SSH_CONNECT_TIMEOUT_SECONDS:-45}"
ssh_attempts="${GB10_CLUSTER_SSH_ATTEMPTS:-4}"
weight_hash_timeout="${GB10_CLUSTER_WEIGHT_HASH_TIMEOUT_SECONDS:-1800}"
storage_mode="${GB10_CLUSTER_STORAGE_MODE:-local-nvme}"
shared_store_source="${GB10_CLUSTER_SHARED_STORE_SOURCE:-}"

[[ -r "$inventory" && -r "$profile_registry" ]] || die 'inventory or profile registry is unreadable'
jq -e '.nodes | type == "array" and (length == 2 or length == 3 or length == 4 or length == 8)' \
  "$inventory" >/dev/null || die 'inventory must contain exactly 2, 3, 4, or 8 nodes'
node_count=$(jq -r '.nodes | length' "$inventory")
declared_topology=$(jq -r '.topology' "$inventory")
case "$node_count:$declared_topology" in
  2:deuces|3:trips|4:quads|8:eight) ;;
  *) die 'inventory topology does not match node count' ;;
esac
[[ -n "$profile" ]] || die 'GB10_CLUSTER_MODEL_PROFILE is required'
jq -e --arg profile "$profile" '.profiles[$profile].engine == "vllm" or .profiles[$profile].engine == "sglang"' \
  "$profile_registry" >/dev/null || die "unknown or unsupported model-engine profile: $profile"
profile_json=$(jq -c --arg profile "$profile" '.profiles[$profile]' "$profile_registry")
engine=$(jq -r '.engine' <<<"$profile_json")
profile_startup_timeout=$(jq -r '.startupTimeoutSeconds // 0' <<<"$profile_json")
[[ "$profile_startup_timeout" =~ ^[0-9]+$ && "$profile_startup_timeout" -le 7200 ]] || \
  die 'profile startup timeout must be 0..7200 seconds'
if (( profile_startup_timeout > startup_timeout )); then
  startup_timeout=$profile_startup_timeout
fi
container_ipc=$(jq -r '.container.ipc // "private"' <<<"$profile_json")
container_shm_size=$(jq -r '.container.shmSize // "16g"' <<<"$profile_json")
container_memory=$(jq -r '.container.memory // empty' <<<"$profile_json")
container_nofile=$(jq -r '.container.nofile // empty' <<<"$profile_json")
container_oom_score_adj=$(jq -r '.container.oomScoreAdj // empty' <<<"$profile_json")
container_cap_ipc_lock=$(jq -r '.container.capIpcLock // false' <<<"$profile_json")
container_cap_dac_override=$(jq -r '.container.capDacOverride // false' <<<"$profile_json")
container_preserve_image_root_cache=$(jq -r '.container.preserveImageRootCache // false' <<<"$profile_json")
container_runtime=$(jq -r '.container.runtime // "rootless-podman"' <<<"$profile_json")
container_security_mode=$(jq -r '.container.securityMode // "hardened"' <<<"$profile_json")
container_rootful_graph_root=$(jq -r '.container.rootful.graphRoot // empty' <<<"$profile_json")
container_rootful_run_root=$(jq -r '.container.rootful.runRoot // empty' <<<"$profile_json")
container_rootful_image_store=$(jq -r '.container.rootful.imageStore // empty' <<<"$profile_json")
container_docker_client=$(jq -r '.container.docker.clientPath // empty' <<<"$profile_json")
container_docker_sockets_json=$(jq -c '.container.docker.sockets // []' <<<"$profile_json")
host_drop_page_cache=$(jq -r '.hostPrelaunch.dropPageCache // false' <<<"$profile_json")
host_minimum_mem_available_gib=$(jq -r '.hostPrelaunch.minimumMemAvailableGiB // 0' <<<"$profile_json")
container_disable_custom_all_reduce=$(jq -r '
  if ((.container // {}) | has("disableCustomAllReduce"))
  then .container.disableCustomAllReduce
  else true
  end
' <<<"$profile_json")
container_cache_host_path=$(jq -r '.container.cacheHostPath // empty' <<<"$profile_json")
container_read_only_mounts_json=$(jq -c '.container.readOnlyMounts // []' <<<"$profile_json")
[[ "$container_ipc" == private || "$container_ipc" == host ]] || \
  die 'profile container IPC mode must be private or host'
[[ "$container_shm_size" =~ ^[1-9][0-9]*[gGmM]$ ]] || \
  die 'profile container shared-memory size is invalid'
[[ -z "$container_memory" || "$container_memory" =~ ^[1-9][0-9]*[gGmM]$ ]] || \
  die 'profile container memory limit is invalid'
[[ -z "$container_nofile" || "$container_nofile" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] || \
  die 'profile container nofile limit must be SOFT:HARD'
[[ -z "$container_oom_score_adj" || "$container_oom_score_adj" =~ ^-?[0-9]+$ ]] || \
  die 'profile container oomScoreAdj must be an integer'
[[ -z "$container_oom_score_adj" || ( "$container_oom_score_adj" -ge -1000 && "$container_oom_score_adj" -le 1000 ) ]] || \
  die 'profile container oomScoreAdj must be -1000..1000'
[[ "$container_cap_ipc_lock" == true || "$container_cap_ipc_lock" == false ]] || \
  die 'profile container capIpcLock must be boolean'
[[ "$container_cap_dac_override" == true || "$container_cap_dac_override" == false ]] || \
  die 'profile container capDacOverride must be boolean'
[[ "$container_preserve_image_root_cache" == true || "$container_preserve_image_root_cache" == false ]] || \
  die 'profile container preserveImageRootCache must be boolean'
[[ "$host_drop_page_cache" == true || "$host_drop_page_cache" == false ]] || \
  die 'profile hostPrelaunch.dropPageCache must be boolean'
[[ "$host_minimum_mem_available_gib" =~ ^[0-9]+$ && "$host_minimum_mem_available_gib" -le 1024 ]] || \
  die 'profile hostPrelaunch.minimumMemAvailableGiB must be 0..1024'
[[ "$host_drop_page_cache" == true || "$host_minimum_mem_available_gib" == 0 ]] || \
  die 'profile minimum host memory requires dropPageCache'
case "$container_runtime" in
  rootless-podman)
    [[ -z "$container_rootful_graph_root$container_rootful_run_root$container_rootful_image_store" ]] || \
      die 'rootless-podman profile must not define rootful storage paths'
    [[ "$container_cap_dac_override" == false ]] || \
      die 'rootless-podman profile must not enable capDacOverride'
    ;;
  rootful-podman)
    if [[ -n "$container_rootful_graph_root$container_rootful_run_root$container_rootful_image_store" ]]; then
      [[ "$container_rootful_graph_root" =~ ^/var/tmp/gb10sor-rootful-runtime/[A-Za-z0-9._/-]+$ &&
         "$container_rootful_graph_root" != *..* && "$container_rootful_graph_root" != */ ]] || \
        die 'rootful graphRoot must be a scoped path under /var/tmp/gb10sor-rootful-runtime'
      [[ "$container_rootful_run_root" =~ ^/run/gb10sor-rootful-runtime/[A-Za-z0-9._/-]+$ &&
         "$container_rootful_run_root" != *..* && "$container_rootful_run_root" != */ ]] || \
        die 'rootful runRoot must be a scoped path under /run/gb10sor-rootful-runtime'
      [[ "$container_rootful_image_store" =~ ^/home/[A-Za-z0-9._-]+/[.]local/share/containers/storage$ ]] || \
        die 'rootful imageStore must name one existing user Podman image store'
    fi
    ;;
  rootful-docker)
    [[ -z "$container_rootful_graph_root$container_rootful_run_root$container_rootful_image_store" ]] || \
      die 'rootful-docker profile must not define Podman storage paths'
    [[ "$container_docker_client" =~ ^/nix/store/[a-z0-9]{32}-docker-[A-Za-z0-9.+_-]+/bin/docker$ ]] || \
      die 'rootful-docker profile requires an exact Nix-store Docker client path'
    ;;
  *) die 'profile container runtime must be rootless-podman, rootful-podman, or rootful-docker' ;;
esac
case "$container_security_mode" in
  hardened) ;;
  publisher-compatible-rootful)
    [[ "$container_runtime" == rootful-podman || "$container_runtime" == rootful-docker ]] || \
      die 'publisher-compatible security mode requires an explicit rootful runtime'
    [[ "$container_preserve_image_root_cache" == true ]] || \
      die 'publisher-compatible security mode requires preserveImageRootCache'
    [[ "$container_cap_dac_override" == false ]] || \
      die 'publisher-compatible security mode uses the default rootful capability set'
    ;;
  *) die 'profile container securityMode must be hardened or publisher-compatible-rootful' ;;
esac
if [[ "$host_drop_page_cache" == true ]]; then
  [[ "$container_runtime" == rootful-podman || "$container_runtime" == rootful-docker ]] || \
    die 'host page-cache drop is restricted to an explicit rootful profile'
  (( host_minimum_mem_available_gib > 0 )) || \
    die 'host page-cache drop requires a positive minimumMemAvailableGiB'
fi
[[ "$container_disable_custom_all_reduce" == true || "$container_disable_custom_all_reduce" == false ]] || \
  die 'profile container disableCustomAllReduce must be boolean'
if [[ -n "$container_cache_host_path" ]]; then
  [[ "$container_cache_host_path" =~ ^/var/tmp/gb10sor-runtime-cache/[A-Za-z0-9._/-]+$ &&
     "$container_cache_host_path" != *..* && "$container_cache_host_path" != */ ]] || \
    die 'profile container cacheHostPath must be a scoped path under /var/tmp/gb10sor-runtime-cache'
fi
jq -e '
  type == "array" and length <= 32 and
  all(.[];
    type == "object" and
    (.sourcePath | type == "string" and test("^/var/tmp/gb10sor-runtime-patches/[A-Za-z0-9._/-]+$") and (contains("..") | not)) and
    (.containerPath | type == "string" and
      (test("^/usr/local/lib/python3[.]12/dist-packages/vllm/[A-Za-z0-9._/-]+$") or
       test("^/sgl-workspace/sglang/python/sglang/[A-Za-z0-9._/-]+$")) and
      (contains("..") | not)) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
  ([.[].containerPath] | length == (unique | length))
' <<<"$container_read_only_mounts_json" >/dev/null || \
  die 'profile container readOnlyMounts are invalid'

tp_size="${GB10_CLUSTER_TENSOR_PARALLEL_SIZE:-$node_count}"
pp_size="${GB10_CLUSTER_PIPELINE_PARALLEL_SIZE:-1}"
[[ "$tp_size" =~ ^[1-9][0-9]*$ && "$pp_size" =~ ^[1-9][0-9]*$ ]] || \
  die 'tensor and pipeline parallel sizes must be positive integers'
(( tp_size * pp_size == node_count )) || \
  die 'tensor parallel size times pipeline parallel size must equal node count'
[[ "$master_port" =~ ^[0-9]+$ && "$master_port" -ge 1024 && "$master_port" -le 65535 ]] || \
  die 'GB10_CLUSTER_VLLM_MASTER_PORT must be 1024..65535'
[[ "$startup_timeout" =~ ^[1-9][0-9]*$ && "$startup_timeout" -le 7200 ]] || \
  die 'GB10_CLUSTER_VLLM_STARTUP_TIMEOUT_SECONDS must be 1..7200'
[[ "$request_timeout" =~ ^[1-9][0-9]*$ && "$request_timeout" -le 1800 ]] || \
  die 'GB10_CLUSTER_VLLM_REQUEST_TIMEOUT_SECONDS must be 1..1800'
[[ "$target_mtu" == 9000 ]] || die 'the reviewed switched profile requires MTU 9000'
[[ "$nccl_ib_hca" =~ ^mlx5_[0-9]+:[0-9]+(,mlx5_[0-9]+:[0-9]+)*$ ]] || \
  die 'GB10_CLUSTER_NCCL_IB_HCA must be a comma-separated mlx5_N:P list'
effective_nccl_ib_hca=$(jq -r --arg fallback "$nccl_ib_hca" '.environment.NCCL_IB_HCA // $fallback' <<<"$profile_json")
[[ "$effective_nccl_ib_hca" =~ ^mlx5_[0-9]+:[0-9]+(,mlx5_[0-9]+:[0-9]+)*$ ]] || \
  die 'effective NCCL_IB_HCA must be a comma-separated mlx5_N:P list'
[[ "$nccl_ib_gid_index" =~ ^[0-9]+$ && "$nccl_ib_gid_index" -le 255 ]] || \
  die 'GB10_CLUSTER_NCCL_IB_GID_INDEX must be 0..255'
[[ "$enforce_eager" == 0 || "$enforce_eager" == 1 ]] || \
  die 'GB10_CLUSTER_VLLM_ENFORCE_EAGER must be 0 or 1'
[[ "$qualify_and_serve" == 0 || "$qualify_and_serve" == 1 ]] || \
  die 'GB10_CLUSTER_QUALIFY_AND_SERVE must be 0 or 1'
[[ "$serve_max_seconds" =~ ^[0-9]+$ && "$serve_max_seconds" -le 604800 ]] || \
  die 'GB10_CLUSTER_SERVE_MAX_SECONDS must be 0..604800'
[[ "$ssh_connect_timeout" =~ ^[1-9][0-9]*$ && "$ssh_connect_timeout" -le 120 ]] || \
  die 'GB10_CLUSTER_SSH_CONNECT_TIMEOUT_SECONDS must be 1..120'
[[ "$ssh_attempts" =~ ^[1-9][0-9]*$ && "$ssh_attempts" -le 10 ]] || \
  die 'GB10_CLUSTER_SSH_ATTEMPTS must be 1..10'
if ! [[ "$weight_hash_timeout" =~ ^[0-9]+$ ]] ||
   ! (( weight_hash_timeout >= 60 && weight_hash_timeout <= 7200 )); then
  die 'GB10_CLUSTER_WEIGHT_HASH_TIMEOUT_SECONDS must be 60..7200'
fi
case "$storage_mode" in
  local-nvme)
    [[ -z "$shared_store_source" ]] || die 'shared-store source must be empty in local-NVMe mode'
    ;;
  read-only-shared)
    [[ -n "$shared_store_source" && "$shared_store_source" != *[[:space:]]* ]] || \
      die 'read-only shared mode requires an exact, whitespace-free shared-store source'
    ;;
  *) die 'GB10_CLUSTER_STORAGE_MODE must be local-nvme or read-only-shared' ;;
esac

rail_a_interface=$(jq -r '.railAInterface' "$inventory")
rail_b_interface=$(jq -r '.railBInterface' "$inventory")
for interface in "$rail_a_interface" "$rail_b_interface"; do
  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "unsafe interface name: $interface"
done

hosts=()
rail_a_cidrs=()
rail_b_cidrs=()
rail_a_addresses=()
rail_b_addresses=()
model_dirs=()
node_local_dirs=()
node_local_marker_hashes=()
containers=()
container_command_texts=()
docker_sockets=()
container_read_only_mount_sources=()
container_read_only_mount_targets=()
container_read_only_mount_hashes=()
while IFS=$'\t' read -r source_path container_path source_hash; do
  [[ -n "$source_path" ]] || continue
  container_read_only_mount_sources+=( "$source_path" )
  container_read_only_mount_targets+=( "$container_path" )
  container_read_only_mount_hashes+=( "$source_hash" )
done < <(jq -r '.[] | [.sourcePath,.containerPath,.sha256] | @tsv' <<<"$container_read_only_mounts_json")
node_local_mount_container=$(jq -r '.nodeLocalReadOnlyMount.containerPath // empty' <<<"$profile_json")
node_local_mount_marker=$(jq -r '.nodeLocalReadOnlyMount.marker // empty' <<<"$profile_json")
if [[ -n "$node_local_mount_container" || -n "$node_local_mount_marker" ]]; then
  [[ "$node_local_mount_container" =~ ^/[A-Za-z0-9._/-]+$ && "$node_local_mount_container" != / ]] || \
    die 'profile node-local container path is unsafe'
  [[ "$node_local_mount_marker" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die 'profile node-local marker name is unsafe'
fi
for ((rank = 0; rank < node_count; rank++)); do
  host=$(jq -r ".nodes[$rank].host" "$inventory")
  rail_a=$(jq -r ".nodes[$rank].railA" "$inventory")
  rail_b=$(jq -r ".nodes[$rank].railB" "$inventory")
  model_dir=$(jq -r ".nodes[$rank].modelDir" "$inventory")
  [[ "$host" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "unsafe host: $host"
  for cidr in "$rail_a" "$rail_b"; do
    [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || \
      die "fabric address is not an IPv4 CIDR: $cidr"
  done
  [[ "$model_dir" =~ ^/[A-Za-z0-9._/@+-]+$ && "$model_dir" != / ]] || \
    die "unsafe model path: $model_dir"
  if [[ -n "$node_local_mount_container" ]]; then
    node_local_dir=$(jq -r ".nodes[$rank].nodeLocalReadOnlyDir // empty" "$inventory")
    node_local_marker_hash=$(jq -r ".nodes[$rank].nodeLocalReadOnlyMarkerSha256 // empty" "$inventory")
    [[ "$node_local_dir" =~ ^/[A-Za-z0-9._/@+-]+$ && "$node_local_dir" != / ]] || \
      die "unsafe node-local read-only path for rank$rank"
    [[ "$node_local_marker_hash" =~ ^[0-9a-f]{64}$ ]] || \
      die "rank$rank node-local marker SHA-256 is missing or invalid"
  else
    node_local_dir=
    node_local_marker_hash=
  fi
  hosts+=( "$host" )
  rail_a_cidrs+=( "$rail_a" )
  rail_b_cidrs+=( "$rail_b" )
  rail_a_addresses+=( "${rail_a%/*}" )
  rail_b_addresses+=( "${rail_b%/*}" )
  model_dirs+=( "$model_dir" )
  node_local_dirs+=( "$node_local_dir" )
  node_local_marker_hashes+=( "$node_local_marker_hash" )
done

if [[ "$container_runtime" == rootful-docker ]]; then
  jq -e --argjson nodes "$node_count" '
    type == "array" and length == $nodes and
    all(.[]; type == "string" and
      (test("^/var/run/docker[.]sock$") or
       test("^/run/gb10sor-docker-runtime/[A-Za-z0-9._/-]+/docker[.]sock$")) and
      (contains("..") | not))
  ' <<<"$container_docker_sockets_json" >/dev/null || \
    die 'rootful-docker sockets must provide one reviewed absolute socket per rank'
  while IFS= read -r socket; do docker_sockets+=( "$socket" ); done \
    < <(jq -r '.[]' <<<"$container_docker_sockets_json")
fi

set_container_command_for_rank() {
  local rank=$1
  case "$container_runtime" in
    rootless-podman)
      container_command=(podman)
      container_command_text=podman
      ;;
    rootful-podman)
      if [[ -n "$container_rootful_graph_root$container_rootful_run_root$container_rootful_image_store" ]]; then
        container_command=(sudo -n podman --root "$container_rootful_graph_root" --runroot "$container_rootful_run_root" --imagestore "$container_rootful_image_store")
        container_command_text="sudo -n podman --root $container_rootful_graph_root --runroot $container_rootful_run_root --imagestore $container_rootful_image_store"
      else
        container_command=(sudo -n podman)
        container_command_text='sudo -n podman'
      fi
      ;;
    rootful-docker)
      container_command=(sudo -n env "DOCKER_HOST=unix://${docker_sockets[$rank]}" "$container_docker_client")
      printf -v container_command_text 'sudo -n env %q %q' \
        "DOCKER_HOST=unix://${docker_sockets[$rank]}" "$container_docker_client"
      ;;
  esac
  container_command_texts[$rank]=$container_command_text
}
for ((rank = 0; rank < node_count; rank++)); do set_container_command_for_rank "$rank"; done

# Keep site-specific fabric addresses in the private inventory.  The public
# model profile defines engine behavior, while the coordinator derives the
# reviewed /24 range used to constrain NCCL from the selected hosts.
rail_a_prefix="${rail_a_addresses[0]%.*}"
for ((rank = 0; rank < node_count; rank++)); do
  [[ "${rail_a_cidrs[$rank]##*/}" == 24 ]] || \
    die 'the reviewed NCCL fabric range requires /24 rail-A addresses'
  [[ "${rail_a_addresses[$rank]%.*}" == "$rail_a_prefix" ]] || \
    die 'all rail-A addresses must share one private-inventory /24'
done
rail_a_network="$rail_a_prefix.0/24"

model_id=$(jq -r '.modelId' <<<"$profile_json")
model_revision=$(jq -r '.modelRevision' <<<"$profile_json")
allowed_revisions_json=$(jq -c '.modelRevisionsAllowed // [.modelRevision]' <<<"$profile_json")
expected_weight_count=$(jq -r '.weightFiles' <<<"$profile_json")
expected_weight_bytes=$(jq -r '.weightBytes' <<<"$profile_json")
expected_weight_tree=$(jq -r '.weightTreeSha256' <<<"$profile_json")
revision_manifest=$(jq -r '.modelRevisionManifest.path // empty' <<<"$profile_json")
revision_manifest_sha=$(jq -r '.modelRevisionManifest.sha256 // empty' <<<"$profile_json")
if [[ -n "$revision_manifest" || -n "$revision_manifest_sha" ]]; then
  [[ "$revision_manifest" =~ ^model-assets/[A-Za-z0-9._/-]+[.]json$ &&
     "$revision_manifest" != *..* && "$revision_manifest_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die 'model revision manifest path or hash is invalid'
  [[ -f "$repo_root/$revision_manifest" && ! -L "$repo_root/$revision_manifest" ]] ||
    die 'model revision manifest is missing'
  [[ $(sha256sum "$repo_root/$revision_manifest" | awk '{print $1}') == "$revision_manifest_sha" ]] ||
    die 'model revision manifest hash changed'
  jq -e --arg id "$model_id" --arg rev "$model_revision" \
    '.modelId == $id and .revision == $rev and
     ([.files | keys[] | select(endswith(".safetensors"))] | length == 48)' \
    "$repo_root/$revision_manifest" >/dev/null || die 'model revision manifest identity changed'
  manifest_tree=$(jq -r '
    .files | to_entries | map(select(.key | endswith(".safetensors"))) |
    sort_by(.key) | .[] | .value.sha256 + "  ./" + .key
  ' "$repo_root/$revision_manifest" | sha256sum | awk '{print $1}')
  [[ "$manifest_tree" == "$expected_weight_tree" ]] ||
    die 'model revision manifest does not match the expected weight tree'
fi
image=$(jq -r '.image' <<<"$profile_json")
runtime_image_ref=$(jq -r '.runtimeImageRef // .image' <<<"$profile_json")
runtime_image_refs_json=$(jq -c '.runtimeImageRefs // []' <<<"$profile_json")
container_entrypoint=$(jq -r '.containerEntrypoint // "vllm"' <<<"$profile_json")
expected_image_id=$(jq -r '.imageId // empty' <<<"$profile_json")
allowed_image_ids_json=$(jq -c '.imageIdsAllowed // (if .imageId then [.imageId] else [] end)' <<<"$profile_json")
expected_rootfs_layers=$(jq -r '.rootfsLayersSha256 // empty' <<<"$profile_json")
expected_image_config=$(jq -r '.imageConfigSha256 // empty' <<<"$profile_json")
engine_version=$(jq -r '.engineVersion' <<<"$profile_json")
engine_source_revision=$(jq -r '.engineSourceRevision // empty' <<<"$profile_json")
expected_torch_cuda=$(jq -r '.torchCudaVersion' <<<"$profile_json")
expected_container_cuda=$(jq -r '.containerCudaVersion' <<<"$profile_json")
expected_flashinfer=$(jq -r '.flashinferVersion // empty' <<<"$profile_json")
accept_hermes=$(jq -r 'if (.acceptance | type) == "object" and (.acceptance | has("hermes")) then .acceptance.hermes else true end' <<<"$profile_json")
accept_streaming=$(jq -r '.acceptance.streaming // false' <<<"$profile_json")
accept_structured=$(jq -r '.acceptance.structuredOutputs // false' <<<"$profile_json")
accept_output_integrity=$(jq -r '.acceptance.outputIntegrity // false' <<<"$profile_json")
accept_reasoning=$(jq -r '.acceptance.reasoningParsing // false' <<<"$profile_json")
accept_image=$(jq -r '.acceptance.imageInput // false' <<<"$profile_json")
accept_audio=$(jq -r '.acceptance.audioInput // false' <<<"$profile_json")
stress_minimum_prompt_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")

[[ "$model_revision" =~ ^[0-9a-f]{40}$ ]] || die 'profile requires an exact model revision'
jq -e --arg primary "$model_revision" '
  type == "array" and length > 0 and
  all(.[]; type == "string" and test("^[0-9a-f]{40}$")) and
  (length == (unique | length)) and
  index($primary) != null
' <<<"$allowed_revisions_json" >/dev/null || \
  die 'profile allowed revisions must be unique exact commits and include modelRevision'
[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || die 'profile image must be digest pinned'
[[ "$runtime_image_ref" =~ ^sha256:[0-9a-f]{64}$ || "$runtime_image_ref" =~ @sha256:[0-9a-f]{64}$ ]] || \
  die 'profile runtime image must be an immutable digest or image ID'
runtime_image_refs=()
if [[ $(jq -r 'length' <<<"$runtime_image_refs_json") == 0 ]]; then
  for ((rank = 0; rank < node_count; rank++)); do runtime_image_refs+=( "$runtime_image_ref" ); done
else
  jq -e --argjson nodes "$node_count" '
    type == "array" and length == $nodes and
    all(.[]; type == "string" and
      (test("^sha256:[0-9a-f]{64}$") or test("@sha256:[0-9a-f]{64}$")))
  ' <<<"$runtime_image_refs_json" >/dev/null || \
    die 'profile runtimeImageRefs must contain one immutable reference per rank'
  while IFS= read -r ref; do runtime_image_refs+=( "$ref" ); done \
    < <(jq -r '.[]' <<<"$runtime_image_refs_json")
fi
[[ "$container_entrypoint" =~ ^/?[A-Za-z0-9._/-]+$ && "$container_entrypoint" != */../* ]] || \
  die 'profile container entrypoint is unsafe'
[[ -z "$expected_image_id" || "$expected_image_id" =~ ^[0-9a-f]{64}$ ]] || \
  die 'profile expected image ID is invalid'
jq -e '
  type == "array" and (length == (unique | length)) and
  all(.[]; type == "string" and test("^[0-9a-f]{64}$"))
' <<<"$allowed_image_ids_json" >/dev/null || die 'profile allowed image IDs are invalid'
[[ -z "$expected_image_id" || $(jq -r --arg id "$expected_image_id" 'index($id) != null' <<<"$allowed_image_ids_json") == true ]] || \
  die 'profile allowed image IDs must include imageId'
[[ -z "$expected_rootfs_layers" || "$expected_rootfs_layers" =~ ^[0-9a-f]{64}$ ]] || \
  die 'profile expected rootfs-layer SHA-256 is invalid'
[[ -z "$expected_image_config" || "$expected_image_config" =~ ^[0-9a-f]{64}$ ]] || \
  die 'profile expected image-config SHA-256 is invalid'
[[ "$container_runtime" != rootful-docker || -n "$expected_image_config" ]] || \
  die 'rootful-docker profile requires an exact normalized image-config SHA-256'
[[ ( -z "$expected_image_id" && -z "$expected_rootfs_layers" ) || \
   ( -n "$expected_image_id" && -n "$expected_rootfs_layers" ) ]] || \
  die 'profile image ID and rootfs-layer SHA-256 must be specified together'
[[ "$expected_weight_count" =~ ^[1-9][0-9]*$ && "$expected_weight_bytes" =~ ^[1-9][0-9]*$ ]] || \
  die 'profile weight contract is incomplete'
[[ "$expected_weight_tree" =~ ^[0-9a-f]{64}$ ]] || die 'profile weight-tree SHA-256 is invalid'
for value in \
  "$accept_hermes" "$accept_streaming" "$accept_structured" \
  "$accept_output_integrity" "$accept_image" "$accept_audio"
do
  [[ "$value" == true || "$value" == false ]] || die 'profile acceptance gates must be booleans'
done
[[ "$stress_minimum_prompt_tokens" =~ ^[0-9]+$ && "$stress_minimum_prompt_tokens" -le 65536 ]] || \
  die 'stress minimumPromptTokens must be 0..65536'
[[ "$stress_concurrency" =~ ^[0-9]+$ && "$stress_concurrency" -le 32 ]] || \
  die 'stress concurrency must be 0..32'
if (( stress_minimum_prompt_tokens > 0 || stress_concurrency > 0 )); then
  (( stress_minimum_prompt_tokens >= 1024 && stress_concurrency >= 1 )) || \
    die 'stress minimumPromptTokens and concurrency must both be enabled'
fi

if [[ -e "$evidence_dir" ]]; then
  [[ -d "$evidence_dir" && ! -L "$evidence_dir" ]] || die 'evidence path must be a non-symlink directory'
  [[ -z $(find "$evidence_dir" -mindepth 1 -print -quit) ]] || die 'evidence directory must be empty'
else
  mkdir -p -- "$evidence_dir"
fi
evidence_dir=$(cd "$evidence_dir" && pwd -P)

ssh_options=(
  -o BatchMode=yes
  -o "ConnectTimeout=$ssh_connect_timeout"
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)
scp_options=( -q -o BatchMode=yes -o "ConnectTimeout=$ssh_connect_timeout" )
if [[ -n "${GB10_CLUSTER_SSH_IDENTITY_FILE:-}" ]]; then
  [[ -f "$GB10_CLUSTER_SSH_IDENTITY_FILE" ]] || die 'SSH identity file is unreadable'
  ssh_options+=( -o IdentitiesOnly=yes -i "$GB10_CLUSTER_SSH_IDENTITY_FILE" )
  scp_options+=( -o IdentitiesOnly=yes -i "$GB10_CLUSTER_SSH_IDENTITY_FILE" )
fi
if [[ -n "${GB10_CLUSTER_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  [[ -f "$GB10_CLUSTER_SSH_KNOWN_HOSTS_FILE" ]] || die 'SSH known-hosts file is unreadable'
  ssh_options+=( -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$GB10_CLUSTER_SSH_KNOWN_HOSTS_FILE" )
  scp_options+=( -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$GB10_CLUSTER_SSH_KNOWN_HOSTS_FILE" )
fi

remote() {
  local host=$1 attempt status
  shift
  for ((attempt = 1; attempt <= ssh_attempts; attempt++)); do
    # The command arguments are deliberately supplied by the local harness.
    # shellcheck disable=SC2029
    if ssh "${ssh_options[@]}" "$host" "$@"; then
      return 0
    else
      status=$?
    fi
    # OpenSSH reserves 255 for a transport/session failure. Remote command
    # failures are semantic failures and must remain fail-closed without retry.
    (( status == 255 && attempt < ssh_attempts )) || return "$status"
    sleep 3
  done
  return 255
}

# systemd automounts can briefly report only the synthetic `autofs` layer even
# after a path lookup has started the real NFS mount.  Resolve the first real
# backing filesystem with a short, bounded retry so a healthy cold automount
# is not misclassified, while still failing closed on the source and `ro`
# checks below.
remote_mount_info() {
  local host=$1 path=$2
  remote "$host" "for attempt in 1 2 3 4 5 6 7 8 9 10; do
    test -r '$path/config.json' || exit 1
    line=\$(findmnt -T '$path' -rn -o FSTYPE,SOURCE,OPTIONS | awk '\$1 != \"autofs\" { print; exit }')
    if test -n \"\$line\"; then printf '%s\\n' \"\$line\"; exit 0; fi
    sleep 1
  done
  exit 1"
}

firewall_inventory() {
  remote "$1" 'sudo -n iptables -S'
}

gpu_inventory() {
  remote "$1" \
    'nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits | LC_ALL=C sort'
}

container_inventory() {
  local rank=$1 host=${hosts[$1]}
  set_container_command_for_rank "$rank"
  remote "$host" \
    "$container_command_text ps -a --no-trunc --format '{{.ID}} {{.Image}} {{.Status}}' | LC_ALL=C sort"
}

runtime_cache_inventory() {
  local rank=$1 host=${hosts[$1]}
  [[ -n "$container_cache_host_path" ]] || return 0
  if [[ "$container_runtime" == rootful-podman || "$container_runtime" == rootful-docker ]]; then
    remote "$host" "set -eu
      cache='$container_cache_host_path'
      if test -e \"\$cache\"; then
        test -d \"\$cache\" && test ! -L \"\$cache\"
      else
        sudo -n install -d -m 0700 -o root -g root \"\$cache\"
      fi
      sudo -n chown root:root \"\$cache\"
      sudo -n chmod 0700 \"\$cache\"
      sudo -n install -d -m 0700 -o root -g root \"\$cache/xdg\" \"\$cache/xdg/torch\" \"\$cache/xdg/torch/kernels\"
      test \"\$(stat -c %u \"\$cache\")\" = 0
      test \"\$(stat -c %a \"\$cache\")\" = 700
      printf 'path=%s owner_uid=%s mode=%s files=%s bytes=%s\\n' \
        \"\$cache\" \"\$(stat -c %u \"\$cache\")\" \"\$(stat -c %a \"\$cache\")\" \
        \"\$(sudo -n find \"\$cache\" -xdev -type f | wc -l | tr -d ' ')\" \
        \"\$(sudo -n du -sb --apparent-size \"\$cache\" | awk '{print \$1}')\""
    return
  fi
  remote "$host" "set -eu
    cache='$container_cache_host_path'
    if test -e \"\$cache\"; then
      test -d \"\$cache\" && test ! -L \"\$cache\"
    else
      install -d -m 0700 \"\$cache\"
    fi
    test \"\$(stat -c %u \"\$cache\")\" = \"\$(id -u)\"
    test \"\$(stat -c %a \"\$cache\")\" = 700
    # Some vLLM images do not create the parents of TORCH_KERNELS_CACHE_PATH.
    # Create the reviewed path before the read-only container starts so a
    # first-run kernel remains available to the next literal command.
    install -d -m 0700 \"\$cache/xdg\" \"\$cache/xdg/torch\" \"\$cache/xdg/torch/kernels\"
    printf 'path=%s owner_uid=%s mode=%s files=%s bytes=%s\\n' \
      \"\$cache\" \"\$(stat -c %u \"\$cache\")\" \"\$(stat -c %a \"\$cache\")\" \
      \"\$(find \"\$cache\" -xdev -type f | wc -l | tr -d ' ')\" \
      \"\$(du -sb --apparent-size \"\$cache\" | awk '{print \$1}')\""
}

host_prelaunch_gate() {
  local rank=$1 host=${hosts[$1]}
  [[ "$host_drop_page_cache" == true ]] || return 0
  remote "$host" "set -eu
    sync
    printf '3\\n' | sudo -n tee /proc/sys/vm/drop_caches >/dev/null
    available_kib=\$(awk '\$1 == \"MemAvailable:\" { print \$2; exit }' /proc/meminfo)
    minimum_kib=$((host_minimum_mem_available_gib * 1024 * 1024))
    test -n \"\$available_kib\"
    printf 'drop_page_cache=pass mem_available_kib=%s minimum_kib=%s\\n' \
      \"\$available_kib\" \"\$minimum_kib\"
    test \"\$available_kib\" -ge \"\$minimum_kib\""
}

fabric_inventory() {
  remote "$1" "for interface in '$rail_a_interface' '$rail_b_interface'; do
    printf '%s mtu=' \"\$interface\"
    cat \"/sys/class/net/\$interface/mtu\"
    ip -o -4 address show dev \"\$interface\" | LC_ALL=C sort
  done"
}

ib_counter_inventory() {
  local host=$1 requested_hcas=${effective_nccl_ib_hca//,/ }
  remote "$host" "for hca in $requested_hcas; do
    device=\${hca%%:*}
    port=\${hca#*:}
    counter=/sys/class/infiniband/\$device/ports/\$port/counters/port_xmit_data
    test -r \"\$counter\"
    value=\$(cat \"\$counter\")
    case \$value in ''|*[!0-9]*) exit 1 ;; esac
    printf '%s %s\\n' \"\$hca\" \"\$value\"
  done"
}

container_exec() {
  local rank=$1 host=${hosts[$1]} container=$2
  shift 2
  local quoted
  set_container_command_for_rank "$rank"
  printf -v quoted '%q ' "${container_command[@]}" exec "$container" "$@"
  remote "$host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $quoted"
}

run_id="gb10sor-vllm-${declared_topology}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
hash_helper="$repo_root/scripts/cluster-weight-hash-shared.sh"
[[ -f "$hash_helper" ]] || die 'bounded weight-hash helper missing'
hash_helper_sha=$(sha256sum "$hash_helper" | awk '{print $1}')
hash_token=$(printf '%s\n' "$run_id" "$evidence_dir" "$hash_helper_sha" | sha256sum | awk '{print $1}')
hash_states=() hash_units=() hash_prepared=()
head_test="/tmp/${run_id}-model-openai-smoke.py"
head_hermes_test="/tmp/${run_id}-hermes-openai-smoke.py"
head_stress_test="/tmp/${run_id}-model-openai-stress.py"
head_reasoning_test="/tmp/${run_id}-deepseek-v41-reasoning-openai-smoke.py"
for ((rank = 0; rank < node_count; rank++)); do
  containers+=( "$run_id-rank$rank" )
  hash_states+=( "/tmp/$run_id-weights-rank$rank" )
  hash_units+=( "$run_id-weights-rank$rank" )
  hash_prepared+=( no )
done
jq -n --arg runId "$run_id" --arg token "$hash_token" --arg helperSha "$hash_helper_sha" \
  --argjson nodes "$(for ((rank=0; rank<node_count; rank++)); do
    jq -n --arg host "${hosts[$rank]}" --arg state "${hash_states[$rank]}" --arg unit "${hash_units[$rank]}" \
      '{host:$host,state:$state,unit:$unit}'
  done | jq -s .)" \
  '{runId:$runId,token:$token,helperSha:$helperSha,nodes:$nodes}' >"$evidence_dir/weight-hash-ownership.json"

firewall_hosts=()
firewall_rules=()

capture_container() {
  local rank=$1 host=${hosts[$1]} container=${containers[$1]}
  set_container_command_for_rank "$rank"
  if remote "$host" "$container_command_text inspect '$container' >/dev/null 2>&1"; then
    remote "$host" "$container_command_text inspect '$container'" \
      >"$evidence_dir/rank$rank-final-inspect.json" \
      2>"$evidence_dir/rank$rank-final-inspect.stderr" || true
    remote "$host" "$container_command_text logs '$container'" \
      >"$evidence_dir/rank$rank.log" \
      2>"$evidence_dir/rank$rank-log.stderr" || true
  fi
}

cleanup() (
  local cleanup_failed=0
  set +e
  for ((rank = 0; rank < node_count; rank++)); do
    [[ "${hash_prepared[$rank]}" == yes ]] || continue
    remote "${hosts[$rank]}" \
      "bash '${hash_states[$rank]}/hash.sh' stop '${hash_states[$rank]}' '${hash_units[$rank]}' '$hash_token'" \
      >"$evidence_dir/rank$rank-weight-hash-cleanup.txt" 2>&1 || cleanup_failed=1
    scp "${scp_options[@]}" -r "${hosts[$rank]}:${hash_states[$rank]}" \
      "$evidence_dir/rank$rank-weight-hash-state" >/dev/null 2>&1 || cleanup_failed=1
  done
  for ((rank = 0; rank < node_count; rank++)); do capture_container "$rank"; done
  for ((rank = 0; rank < node_count; rank++)); do
    remove_container_with_retries "$rank" "${containers[$rank]}" || cleanup_failed=1
  done
  for ((index = ${#firewall_rules[@]} - 1; index >= 0; index--)); do
    remote "${firewall_hosts[$index]}" \
      "sudo -n iptables -D nixos-fw ${firewall_rules[$index]}" >/dev/null 2>&1 || true
  done
  remote "${hosts[0]}" "rm -f '$head_test' '$head_hermes_test' '$head_stress_test' '$head_reasoning_test'" >/dev/null 2>&1 || true
  exit "$cleanup_failed"
)
remove_container_with_retries() {
  local rank=$1 host=${hosts[$1]} container=$2 attempt
  set_container_command_for_rank "$rank"
  # Large distributed workers can remain in container teardown for well over
  # the old eight-second window after TERM.  Keep the target exact, but allow
  # the runtime up to five minutes to finish releasing hundreds of GiB of
  # mappings before declaring cleanup failure.
  for attempt in $(seq 1 60); do
    if remote "$host" \
      "$container_command_text rm -f '$container' >/dev/null 2>&1 || true; ! $container_command_text inspect '$container' >/dev/null 2>&1"; then
      return 0
    fi
    sleep 5
  done
  printf 'Cleanup failed to remove exact container %s after five minutes.\n' "$container" >&2
  return 1
}
on_exit() {
  local exit_status=$?
  trap - EXIT
  if ! cleanup && (( exit_status == 0 )); then
    exit_status=1
  fi
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A local-NVMe deployment must hash every independent copy. A reviewed
# read-only shared export has only one underlying copy, so rank 0 hashes it
# once while every rank still verifies the exact source, read-only mount,
# revision marker, file count, and byte count. This avoids reading the same
# 350-750 GB checkpoint from the NAS eight times without weakening identity.
hash_node_count=$node_count
[[ "$storage_mode" == read-only-shared ]] && hash_node_count=1

# Provision every ownership record that can actually start a hash. No unit
# starts here. Collision/error prevents model work; private receipts stay.
for ((rank = 0; rank < hash_node_count; rank++)); do
  state=${hash_states[$rank]}
  remote "${hosts[$rank]}" "umask 077; mkdir '$state' && printf '%s\\n' '$hash_token' > '$state/owner'"
  scp "${scp_options[@]}" "$hash_helper" "${hosts[$rank]}:$state/hash.sh"
  remote "${hosts[$rank]}" "printf '%s  hash.sh\\n' '$hash_helper_sha' > '$state/helper.sha256'; cd '$state'; sha256sum --strict -c helper.sha256"
  hash_prepared[rank]=yes
done

shared_observed_tree=
if [[ "$storage_mode" == read-only-shared ]]; then
  shared_model_dir=${model_dirs[0]}
  read -r shared_fstype shared_mount_source shared_mount_options < <(
    remote_mount_info "${hosts[0]}" "$shared_model_dir"
  )
  case "$shared_fstype" in nfs|nfs4) ;; *) die 'rank0 checkpoint is not on the declared NFS store' ;; esac
  [[ "$shared_mount_source" == "$shared_store_source" ]] || die 'rank0 shared-store source changed before hash'
  case ",$shared_mount_options," in *,ro,*) ;; *) die 'rank0 shared checkpoint mount is not read-only before hash' ;; esac
  shared_observed_tree=$(remote "${hosts[0]}" \
    "bash '${hash_states[0]}/hash.sh' start '${hash_states[0]}' '${hash_units[0]}' '$hash_token' '$shared_model_dir' '$expected_weight_tree' '$weight_hash_timeout' '$storage_mode' '$shared_store_source'")
  [[ "$shared_observed_tree" == "$expected_weight_tree" ]] || die 'shared weight-tree SHA-256 changed'
  printf '%s\n' "$shared_observed_tree" >"$evidence_dir/shared-weight-tree.sha256"
fi

add_peer_rule() {
  local host=$1 interface=$2 peer=$3
  local rule="-i '$interface' -s '$peer' -p tcp -m comment --comment '$run_id' -j nixos-fw-accept"
  remote "$host" "sudo -n iptables -I nixos-fw 1 $rule"
  firewall_hosts+=( "$host" )
  firewall_rules+=( "$rule" )
}

preflight_node() {
  local rank=$1 host=${hosts[$1]} model_dir=${model_dirs[$1]}
  local rank_runtime_image_ref=${runtime_image_refs[$1]}
  local node_local_dir=${node_local_dirs[$1]} node_local_marker_hash=${node_local_marker_hashes[$1]}
  local rail_a=${rail_a_cidrs[$1]} rail_b=${rail_b_cidrs[$1]}
  local observed_bytes observed_count observed_weight_bytes observed_tree observed_revisions observed_revision candidate
  local fstype mount_source mount_options gpu image_json image_id image_arch image_digest image_layers image_config driver
  trap 'status=$?; printf "preflight_failed rank=%s lines=%s status=%s command=%q\n" "$rank" "${BASH_LINENO[*]}" "$status" "$BASH_COMMAND" >&2' ERR
  set_container_command_for_rank "$rank"

  remote "$host" 'sudo -n true'
  remote "$host" 'systemctl is-active --quiet cluster-fabric-profile.service'
  remote "$host" '! systemctl is-active --quiet ray-cluster.service'
  remote "$host" "for tuple in '$rail_a_interface:$rail_a' '$rail_b_interface:$rail_b'; do
    interface=\${tuple%%:*}; cidr=\${tuple#*:}
    test \"\$(cat /sys/class/net/\$interface/operstate)\" = up
    test \"\$(cat /sys/class/net/\$interface/mtu)\" = '$target_mtu'
    ip -o -4 address show dev \"\$interface\" | awk '{print \$4}' | grep -Fqx \"\$cidr\"
    ethtool \"\$interface\" | grep -F 'Speed: 200000Mb/s'
    ethtool --show-fec \"\$interface\" | grep -F 'Active FEC encoding: RS'
    rdma link show | grep -F \"netdev \$interface\" | grep -F 'state ACTIVE' | grep -F 'physical_state LINK_UP'
  done" >"$evidence_dir/rank$rank-fabric-gate.txt"

  remote "$host" "test -r '$model_dir/config.json'; test -n \"\$(find '$model_dir' -type f -name '*.safetensors' -print -quit)\""
  read -r fstype mount_source mount_options < <(remote_mount_info "$host" "$model_dir")
  case "$storage_mode" in
    local-nvme)
      case "$fstype" in *nfs*|*cifs*|*smb*|*fuse.sshfs*) die "rank$rank checkpoint is not local" ;; esac
      ;;
    read-only-shared)
      case "$fstype" in nfs|nfs4) ;; *) die "rank$rank checkpoint is not on the declared NFS store" ;; esac
      [[ "$mount_source" == "$shared_store_source" ]] || die "rank$rank shared-store source changed"
      case ",$mount_options," in *,ro,*) ;; *) die "rank$rank shared checkpoint mount is not read-only" ;; esac
      ;;
  esac
  observed_bytes=$(remote "$host" "du -sb --apparent-size '$model_dir' | awk '{print \$1}'")
  jq -e --argjson observed "$observed_bytes" \
    '(.modelBytesAllowed // [.modelBytes]) | index($observed) != null' \
    <<<"$profile_json" >/dev/null || die "rank$rank model byte size changed"
  observed_revisions=$(remote "$host" \
    "for marker in '$model_dir/.hf_revision' '$model_dir/.gb10sor-revision'; do test ! -f \"\$marker\" || sed -n '1p' \"\$marker\"; done; if test -d '$model_dir/.cache/huggingface/download'; then find '$model_dir/.cache/huggingface/download' -type f -name '*.metadata' -exec sed -n '1p' {} + 2>/dev/null; fi" \
    | LC_ALL=C sort -u)
  observed_revision=
  while IFS= read -r candidate; do
    [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || continue
    if jq -e --arg candidate "$candidate" 'index($candidate) != null' \
      <<<"$allowed_revisions_json" >/dev/null; then
      observed_revision=$candidate
      break
    fi
  done <<<"$observed_revisions"
  # Some immutable NAS snapshots omit Hugging Face's mutable download cache.
  # A hash-pinned publisher manifest supplies the revision only when its 48
  # weight hashes produce the exact tree that is independently rehashed below.
  if [[ -z "$observed_revision" && -n "$revision_manifest" ]]; then
    observed_revision=$model_revision
  fi
  [[ -n "$observed_revision" ]] || die "rank$rank checkpoint lacks a reviewed revision marker"
  observed_count=$(remote "$host" "find '$model_dir' -type f -name '*.safetensors' | wc -l | tr -d ' '")
  [[ "$observed_count" == "$expected_weight_count" ]] || die "rank$rank weight-file count changed"
  observed_weight_bytes=$(remote "$host" \
    "find '$model_dir' -type f -name '*.safetensors' -printf '%s\\n' | awk '{sum += \$1} END {print sum + 0}'")
  [[ "$observed_weight_bytes" == "$expected_weight_bytes" ]] || die "rank$rank weight bytes changed"
  if [[ "$storage_mode" == read-only-shared ]]; then
    observed_tree=$shared_observed_tree
  else
    observed_tree=$(remote "$host" \
      "bash '${hash_states[$rank]}/hash.sh' start '${hash_states[$rank]}' '${hash_units[$rank]}' '$hash_token' '$model_dir' '$expected_weight_tree' '$weight_hash_timeout' '$storage_mode' '$shared_store_source'")
  fi
  [[ "$observed_tree" == "$expected_weight_tree" ]] || die "rank$rank weight-tree SHA-256 changed"
  if [[ -n "$node_local_mount_container" ]]; then
    local local_fstype local_source resolved_dir observed_marker_hash
    read -r local_fstype local_source < <(remote "$host" "test -d '$node_local_dir' && test ! -L '$node_local_dir' && test -r '$node_local_dir/$node_local_mount_marker' && findmnt -T '$node_local_dir' -rn -o FSTYPE,SOURCE | awk '\$1 != \"autofs\" { print; exit }'")
    case "$local_fstype" in *nfs*|*cifs*|*smb*|*fuse.sshfs*|'') die "rank$rank auxiliary data is not on local storage" ;; esac
    [[ "$local_source" == /dev/nvme* && "$local_fstype" =~ ^(ext4|xfs|btrfs)$ ]] || \
      die "rank$rank auxiliary data must reside on this Spark's NVMe disk"
    resolved_dir=$(remote "$host" "realpath -e '$node_local_dir'")
    [[ "$resolved_dir" == "$node_local_dir" ]] || \
      die "rank$rank auxiliary directory must not resolve through a symlink"
    remote "$host" "test -z \"\$(find '$node_local_dir' -type l -print -quit)\" && test -z \"\$(findmnt -R '$node_local_dir' -rn -o TARGET)\"" || \
      die "rank$rank auxiliary directory contains a symlink or nested mount"
    observed_marker_hash=$(remote "$host" "sha256sum '$node_local_dir/$node_local_mount_marker' | awk '{print \$1}'")
    [[ "$observed_marker_hash" == "$node_local_marker_hash" ]] || \
      die "rank$rank node-local marker SHA-256 changed"
    if [[ "$node_local_mount_container" == /engram-local && "$node_count" == 4 ]]; then
      # The sparse files have the full tensor's apparent size even if local
      # rows were never written.  Check the exact TP4 range and every byte's
      # allocated extent on this Spark's own NVMe before any rank starts.
      ssh "${ssh_options[@]}" "$host" "python3 - '$node_local_dir' '$rank'" \
        <"$repo_root/scripts/verify-deepseek-v41-engram-local.py" \
        >"$evidence_dir/rank$rank-engram-complete.json" || \
        die "rank$rank local Engram rows are incomplete"
    fi
    jq -n --argjson rank "$rank" --arg host "$host" --arg path "$node_local_dir" \
      --arg containerPath "$node_local_mount_container" --arg marker "$node_local_mount_marker" \
      --arg markerSha256 "$observed_marker_hash" --arg storage "$local_fstype" \
      '{rank:$rank,host:$host,path:$path,containerPath:$containerPath,marker:$marker,
        markerSha256:$markerSha256,storage:$storage,readOnlyAtRuntime:true}' \
      >"$evidence_dir/rank$rank-node-local-mount.json"
  fi
  for index in "${!container_read_only_mount_sources[@]}"; do
    local patch_source=${container_read_only_mount_sources[$index]}
    local patch_target=${container_read_only_mount_targets[$index]}
    local patch_hash=${container_read_only_mount_hashes[$index]}
    local observed_patch_hash
    observed_patch_hash=$(remote "$host" "test -f '$patch_source' && test ! -L '$patch_source'; sha256sum '$patch_source' | awk '{print \$1}'")
    [[ "$observed_patch_hash" == "$patch_hash" ]] || \
      die "rank$rank read-only runtime patch changed: $patch_target"
  done
  gpu=$(remote "$host" 'nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader,nounits')
  [[ $(wc -l <<<"$gpu" | tr -d ' ') == 1 && "$gpu" == *12.1* ]] || die "rank$rank is not one GB10 GPU"
  [[ -z $(gpu_inventory "$host") ]] || die "rank$rank already has a GPU workload"
  driver=$(remote "$host" 'nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits')
  image_json=$(remote "$host" "$container_command_text image inspect '$rank_runtime_image_ref'")
  image_id=$(jq -er '.[0].Id' <<<"$image_json" | sed 's/^sha256://')
  image_arch=$(jq -er '.[0].Architecture' <<<"$image_json")
  image_digest=$(jq -r '.[0].Digest // empty' <<<"$image_json")
  image_layers=$(jq -c '.[0].RootFS.Layers' <<<"$image_json" | sha256sum | awk '{print $1}')
  image_config=$(jq -cS '.[0].Config' <<<"$image_json" | sha256sum | awk '{print $1}')
  [[ "$image_id" =~ ^[0-9a-f]{64}$ && "$image_arch" == arm64 ]] || die "rank$rank image identity failed"
  if [[ -n "$expected_image_id" ]]; then
    jq -e --arg id "$image_id" 'index($id) != null' <<<"$allowed_image_ids_json" >/dev/null || \
      die "rank$rank image ID is not in the reviewed cross-runtime set"
    [[ "$image_layers" == "$expected_rootfs_layers" ]] || die "rank$rank rootfs layers changed"
    [[ -z "$expected_image_config" || "$image_config" == "$expected_image_config" ]] || \
      die "rank$rank normalized image config changed"
  else
    [[ "$image_digest" == "${image##*@}" ]] || die "rank$rank image manifest changed"
  fi

  jq -n --argjson rank "$rank" --arg host "$host" --arg storage "$fstype" \
    --arg storageMode "$storage_mode" --arg storageSource "$mount_source" \
    --arg storageOptions "$mount_options" \
    --arg gpu "$gpu" --arg driver "$driver" --arg imageId "$image_id" \
    --arg imageDigest "$image_digest" --arg layers "$image_layers" --arg imageConfig "$image_config" \
    --arg revision "$observed_revision" --arg tree "$observed_tree" \
    --argjson bytes "$observed_bytes" --argjson files "$observed_count" \
    --argjson weightBytes "$observed_weight_bytes" \
    '{rank:$rank,host:$host,storage:$storage,storageMode:$storageMode,
      storageSource:$storageSource,storageOptions:$storageOptions,
      gpu:$gpu,driverVersion:$driver,
      imageId:$imageId,imageDigest:$imageDigest,rootfsLayersSha256:$layers,imageConfigSha256:$imageConfig,
      modelRevision:$revision,modelBytes:$bytes,weightFiles:$files,
      weightBytes:$weightBytes,weightTreeSha256:$tree}' \
    >"$evidence_dir/rank$rank-preflight.json"
  trap - ERR
}

preflight_pids=()
for ((rank = 0; rank < node_count; rank++)); do
  firewall_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-firewall-before.txt"
  gpu_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-gpu-before.txt"
  container_inventory "$rank" >"$evidence_dir/rank$rank-containers-before.txt"
  fabric_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-fabric-before.txt"
  preflight_node "$rank" 2>"$evidence_dir/rank$rank-preflight.stderr" &
  preflight_pids+=( "$!" )
done
preflight_failed=0
for pid in "${preflight_pids[@]}"; do wait "$pid" || preflight_failed=1; done
(( preflight_failed == 0 )) || die 'one or more node preflights failed'
runtime_nccl_debug=$(jq -r '.environment.NCCL_DEBUG // "INFO"' <<<"$profile_json")
if [[ "$runtime_nccl_debug" == WARN ]]; then
  for ((rank = 0; rank < node_count; rank++)); do
    ib_counter_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-ib-before.tsv"
  done
fi
observed_revision_count=$(jq -s '[.[].modelRevision] | unique | length' "$evidence_dir"/rank*-preflight.json)
[[ "$observed_revision_count" == 1 ]] || die 'node preflights observed different checkpoint revisions'

reference_image=$(jq -r '.imageConfigSha256 + ":" + .rootfsLayersSha256' "$evidence_dir/rank0-preflight.json")
reference_checkpoint=$(jq -r '.modelRevision + ":" + .weightTreeSha256' "$evidence_dir/rank0-preflight.json")
for ((rank = 1; rank < node_count; rank++)); do
  [[ $(jq -r '.imageConfigSha256 + ":" + .rootfsLayersSha256' "$evidence_dir/rank$rank-preflight.json") == "$reference_image" ]] || \
    die "rank$rank image identity differs"
  [[ $(jq -r '.modelRevision + ":" + .weightTreeSha256' "$evidence_dir/rank$rank-preflight.json") == "$reference_checkpoint" ]] || \
    die "rank$rank checkpoint identity differs"
done

if [[ -n "$container_cache_host_path" ]]; then
  for ((rank = 0; rank < node_count; rank++)); do
    runtime_cache_inventory "$rank" >"$evidence_dir/rank$rank-runtime-cache-before.txt"
  done
fi

scp "${scp_options[@]}" "$repo_root/tests/model-openai-smoke.py" "${hosts[0]}:$head_test"
scp "${scp_options[@]}" "$repo_root/tests/hermes-openai-smoke.py" "${hosts[0]}:$head_hermes_test"
scp "${scp_options[@]}" "$repo_root/tests/model-openai-stress.py" "${hosts[0]}:$head_stress_test"
if [[ "$accept_reasoning" == true ]]; then
  scp "${scp_options[@]}" "$repo_root/tests/deepseek-v41-reasoning-openai-smoke.py" "${hosts[0]}:$head_reasoning_test"
fi

for ((rank = 0; rank < node_count; rank++)); do
  for ((peer = 0; peer < node_count; peer++)); do
    (( rank == peer )) && continue
    add_peer_rule "${hosts[$rank]}" "$rail_a_interface" "${rail_a_addresses[$peer]}"
    add_peer_rule "${hosts[$rank]}" "$rail_b_interface" "${rail_b_addresses[$peer]}"
  done
done
for ((peer = 1; peer < node_count; peer++)); do
  remote "${hosts[0]}" \
    "ping -I '$rail_a_interface' -M do -s 8972 -c 3 -W 2 '${rail_a_addresses[$peer]}'" \
    >"$evidence_dir/rank0-rank$peer-rail-a-ping.txt"
  remote "${hosts[0]}" \
    "ping -I '$rail_b_interface' -M do -s 8972 -c 3 -W 2 '${rail_b_addresses[$peer]}'" \
    >"$evidence_dir/rank0-rank$peer-rail-b-ping.txt"
done

# Some publisher-proven large-model recipes require the page cache to be
# released only after the complete checkpoint seal and immediately before
# rank launch. This is opt-in, rootful-only, independently evidenced on every
# host, and fails closed when the declared available-memory floor is not met.
if [[ "$host_drop_page_cache" == true ]]; then
  for ((rank = 0; rank < node_count; rank++)); do
    host_prelaunch_gate "$rank" >"$evidence_dir/rank$rank-host-prelaunch.txt"
  done
fi

profile_args=()
while IFS= read -r argument; do profile_args+=( "$argument" ); done \
  < <(jq -r '.arguments[]' <<<"$profile_json")
for argument in "${profile_args[@]}"; do
  case "$argument" in
    --tp|--tp-size|--tensor-parallel-size|--pipeline-parallel-size|--distributed-executor-backend|--nnodes|--node-rank|--dist-init-addr|--master-addr|--master-port|--headless|--host|--port)
      die "profile contains a conflicting cluster transport flag: $argument" ;;
  esac
done
profile_environment_args=()
while IFS= read -r assignment; do
  name=${assignment%%=*}; value=${assignment#*=}
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "unsafe profile environment key: $name"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "multiline profile environment: $name"
  profile_environment_args+=( -e "$name=$value" )
done < <(jq -r '(.environment // {}) | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")

# Kimi-K3 resolves its compiler/runtime cache under /cache. Keep that cache
# writable, isolated, and ephemeral for every profile while the checkpoint
# itself remains read-only.
common_args=(
  --pull=never --network host --ipc "$container_ipc"
  --device nvidia.com/gpu=all --device /dev/infiniband:/dev/infiniband
  --ulimit memlock=-1:-1 --ulimit stack=67108864:67108864
  -e HF_HUB_OFFLINE=1 -e HF_HUB_DISABLE_TELEMETRY=1 -e TRANSFORMERS_OFFLINE=1
  -e PIP_NO_INDEX=1 -e DO_NOT_TRACK=1
  -e "GB10SOR_OPENAI_TIMEOUT_SECONDS=$request_timeout"
  -e NCCL_DEBUG=INFO -e "NCCL_DEBUG_SUBSYS=INIT,NET,COLL" -e NCCL_IB_DISABLE=0
  -e "NCCL_IB_HCA=$nccl_ib_hca" -e "NCCL_IB_GID_INDEX=$nccl_ib_gid_index"
  -e "NCCL_IB_ADDR_RANGE=$rail_a_network"
  -e "NCCL_SOCKET_IFNAME=$rail_a_interface,$rail_b_interface"
  -e "GLOO_SOCKET_IFNAME=$rail_a_interface"
)
if [[ "$container_security_mode" == hardened ]]; then
  common_args+=(
    --pids-limit 8192 --cap-drop=all --security-opt=no-new-privileges --read-only
    --tmpfs "/tmp:rw,nosuid,nodev,size=8g"
    --tmpfs "/root/.config:rw,nosuid,nodev,size=64m"
    --tmpfs "/root/.tilelang:rw,nosuid,nodev,size=8g"
    --tmpfs "/root/.triton:rw,nosuid,nodev,size=4g"
  )
fi
for index in "${!container_read_only_mount_sources[@]}"; do
  common_args+=( -v "${container_read_only_mount_sources[$index]}:${container_read_only_mount_targets[$index]}:ro" )
done
if [[ -n "$container_cache_host_path" ]]; then
  common_args+=( -v "$container_cache_host_path:/cache:rw" )
else
  common_args+=( --tmpfs "/cache:rw,nosuid,nodev,size=12g" )
fi
if [[ "$container_preserve_image_root_cache" != true ]]; then
  common_args+=( --tmpfs "/root/.cache:rw,nosuid,nodev,size=12g" )
fi
if [[ "$container_ipc" == private ]]; then
  common_args+=( --shm-size "$container_shm_size" )
fi
[[ -n "$container_memory" ]] && common_args+=( --memory "$container_memory" --memory-swap "$container_memory" )
[[ -n "$container_nofile" ]] && common_args+=( --ulimit "nofile=$container_nofile" )
[[ -n "$container_oom_score_adj" ]] && common_args+=( --oom-score-adj "$container_oom_score_adj" )
[[ "$container_cap_ipc_lock" == true ]] && common_args+=( --cap-add IPC_LOCK )
[[ "$container_cap_dac_override" == true ]] && common_args+=( --cap-add DAC_OVERRIDE )
(( ${#profile_environment_args[@]} > 0 )) && common_args+=( "${profile_environment_args[@]}" )

if [[ "$engine" == vllm ]]; then
  if [[ "$container_preserve_image_root_cache" == true && "$container_security_mode" == hardened ]]; then
    if [[ "$container_runtime" == rootful-podman || "$container_runtime" == rootful-docker ]]; then
      cache_copy='cp -R'
    else
      cache_copy='cp -a'
    fi
    cache_bootstrap="set -eu; mkdir -p /cache/.cache; $cache_copy /root/.cache/flashinfer /cache/.cache/; exec $container_entrypoint \"\$@\""
    common_args+=( -e VLLM_NO_USAGE_STATS=1 --entrypoint /bin/sh )
    runtime_prefix=( -lc "$cache_bootstrap" gb10sor-cache-bootstrap )
  else
    common_args+=( -e VLLM_NO_USAGE_STATS=1 --entrypoint "$container_entrypoint" )
    runtime_prefix=()
  fi
  transport_args=(
    "${runtime_prefix[@]}"
    serve /model --host 127.0.0.1 --port 8000
    --distributed-executor-backend mp --nnodes "$node_count"
    --tensor-parallel-size "$tp_size" --pipeline-parallel-size "$pp_size"
    --master-addr "${rail_a_addresses[0]}" --master-port "$master_port"
    --distributed-timeout-seconds 900
  )
  [[ "$container_disable_custom_all_reduce" == true ]] && transport_args+=( --disable-custom-all-reduce )
  [[ "$enforce_eager" == 1 ]] && transport_args+=( --enforce-eager )
else
  [[ "$pp_size" == 1 ]] || die 'the reviewed SGLang cluster path requires pipeline parallel size 1'
  [[ "$engine_source_revision" =~ ^[0-9a-f]{40}$ ]] || \
    die 'SGLang profile requires an exact engine source revision'
  [[ "$container_entrypoint" == python3 ]] || die 'SGLang profile must use the reviewed python3 entrypoint'
  common_args+=( --entrypoint python3 )
  transport_args=(
    -m sglang.launch_server --model-path /model --host 127.0.0.1 --port 8000
    --tp "$tp_size" --nnodes "$node_count" --dist-init-addr "${rail_a_addresses[0]}:$master_port"
  )
fi

quote_command() {
  local destination=$1
  shift
  printf -v "$destination" '%q ' "$@"
}

launch_rank() {
  local rank=$1 host=${hosts[$1]} container=${containers[$1]} model_dir=${model_dirs[$1]}
  local rank_runtime_image_ref=${runtime_image_refs[$1]}
  local command quoted
  set_container_command_for_rank "$rank"
  command=(
    "${container_command[@]}" run -d --name "$container" "${common_args[@]}"
    -v "$model_dir:/model:ro"
  )
  if [[ -n "$node_local_mount_container" ]]; then
    command+=( -v "${node_local_dirs[$rank]}:$node_local_mount_container:ro" )
  fi
  if (( rank == 0 )); then
    command+=(
      -v "$head_test:/opt/gb10/model-openai-smoke.py:ro"
      -v "$head_hermes_test:/opt/gb10/hermes-openai-smoke.py:ro"
      -v "$head_stress_test:/opt/gb10/model-openai-stress.py:ro"
    )
    if [[ "$accept_reasoning" == true ]]; then
      command+=( -v "$head_reasoning_test:/opt/gb10/deepseek-v41-reasoning-openai-smoke.py:ro" )
    fi
  fi
  if [[ "$engine" == vllm ]]; then
    command+=( -e "VLLM_HOST_IP=${rail_a_addresses[$rank]}" )
  else
    command+=( -e "SGLANG_HOST_IP=${rail_a_addresses[$rank]}" )
  fi
  command+=( "$rank_runtime_image_ref" "${transport_args[@]}" --node-rank "$rank" )
  [[ "$engine" == vllm && "$rank" -gt 0 ]] && command+=( --headless )
  command+=( "${profile_args[@]}" )
  quote_command quoted "${command[@]}"
  remote "$host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $quoted" \
    >"$evidence_dir/rank$rank-container-id.txt"
}

for ((rank = node_count - 1; rank >= 1; rank--)); do launch_rank "$rank"; done
sleep 2
launch_rank 0

ready=0
started=$SECONDS
while (( SECONDS - started < startup_timeout )); do
  all_running=1
  for ((rank = 0; rank < node_count; rank++)); do
    running=$(remote "${hosts[$rank]}" \
      "${container_command_texts[$rank]} inspect '${containers[$rank]}' --format '{{.State.Running}}' 2>/dev/null || true")
    [[ "$running" == true ]] || { all_running=0; break; }
  done
  (( all_running == 1 )) || break
  if container_exec 0 "${containers[0]}" \
    python3 /opt/gb10/model-openai-smoke.py ready "$model_id" \
    >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
    ready=1
    break
  fi
  sleep 5
done
for ((rank = 0; rank < node_count; rank++)); do capture_container "$rank"; done
(( ready == 1 )) || die "the $declared_topology $engine endpoint did not become ready"

runtime_files=()
for ((rank = 0; rank < node_count; rank++)); do
  host=${hosts[$rank]}; container=${containers[$rank]}
  gpu_inventory "$host" >"$evidence_dir/rank$rank-gpu-live.txt"
  [[ -s "$evidence_dir/rank$rank-gpu-live.txt" ]] || die "rank$rank has no live GPU process"
  if [[ "$engine" == vllm ]]; then
    container_exec "$rank" "$container" python3 -c \
      'import importlib.metadata as m,json,os,torch,vllm; print(json.dumps({"engine":"vllm","version":vllm.__version__,"vllm":vllm.__version__,"torch":torch.__version__,"torchCuda":torch.version.cuda,"containerCuda":os.environ.get("CUDA_VERSION"),"flashinfer":m.version("flashinfer-python"),"capability":list(torch.cuda.get_device_capability())}))' \
      >"$evidence_dir/rank$rank-runtime.json"
  else
    container_exec "$rank" "$container" python3 -c \
      'import json,os,torch,sglang; print(json.dumps({"engine":"sglang","version":sglang.__version__,"sglang":sglang.__version__,"torch":torch.__version__,"torchCuda":torch.version.cuda,"containerCuda":os.environ.get("CUDA_VERSION"),"flashinfer":None,"capability":list(torch.cuda.get_device_capability())}))' \
      >"$evidence_dir/rank$rank-runtime.json"
  fi
  jq -e --arg engine "$engine" --arg version "$engine_version" --arg torchCuda "$expected_torch_cuda" \
    --arg containerCuda "$expected_container_cuda" --arg flashinfer "$expected_flashinfer" \
    '.engine == $engine and .version == $version and .torchCuda == $torchCuda and .containerCuda == $containerCuda and
     (($engine == "sglang") or ($flashinfer == "") or .flashinfer == $flashinfer) and .capability == [12,1]' \
    "$evidence_dir/rank$rank-runtime.json" >/dev/null
  runtime_files+=( "$evidence_dir/rank$rank-runtime.json" )
done

head_host=${hosts[0]}; head_container=${containers[0]}
acceptance_failures=()
: >"$evidence_dir/acceptance-gates.tsv"
record_acceptance_gate() {
  local gate=$1 result=$2
  printf '%s\t%s\n' "$gate" "$result" >>"$evidence_dir/acceptance-gates.tsv"
  if [[ "$result" == fail ]]; then acceptance_failures+=( "$gate" ); fi
}
if container_exec 0 "$head_container" python3 /opt/gb10/model-openai-smoke.py completion "$model_id" \
    >"$evidence_dir/completion.json" 2>"$evidence_dir/completion.stderr" && \
   jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' \
    "$evidence_dir/completion.json" >/dev/null; then
  record_acceptance_gate completion pass
else
  record_acceptance_gate completion fail
fi
if [[ "$accept_output_integrity" == true ]]; then
  if container_exec 0 "$head_container" python3 /opt/gb10/model-openai-smoke.py integrity "$model_id" \
      >"$evidence_dir/output-integrity.json" 2>"$evidence_dir/output-integrity.stderr" && \
     jq -e '.status == "pass" and .passes == 2 and .probesPerPass == 4 and (.receipts | length) == 8' \
      "$evidence_dir/output-integrity.json" >/dev/null; then
    record_acceptance_gate output-integrity pass
  else
    record_acceptance_gate output-integrity fail
  fi
fi
if [[ "$accept_hermes" == true ]]; then
  if container_exec 0 "$head_container" python3 /opt/gb10/hermes-openai-smoke.py "$model_id" \
      >"$evidence_dir/hermes.json" 2>"$evidence_dir/hermes.stderr" && \
     jq -e '.status == "pass" and .models_gate == "pass" and .chat_gate == "pass" and .tool_call_gate == "pass" and .tool_result_gate == "pass"' \
      "$evidence_dir/hermes.json" >/dev/null; then
    record_acceptance_gate tool-parsing pass
  else
    record_acceptance_gate tool-parsing fail
  fi
fi
if [[ "$accept_reasoning" == true ]]; then
  if container_exec 0 "$head_container" python3 /opt/gb10/deepseek-v41-reasoning-openai-smoke.py "$model_id" \
      >"$evidence_dir/reasoning.json" 2>"$evidence_dir/reasoning.stderr" && \
     jq -e '.status == "pass" and .reasoningCharacters > 0 and .answerCharacters > 0 and .finishReason == "stop"' \
      "$evidence_dir/reasoning.json" >/dev/null; then
    record_acceptance_gate reasoning pass
  else
    record_acceptance_gate reasoning fail
  fi
fi
if [[ "$accept_streaming" == true ]]; then
  if container_exec 0 "$head_container" python3 /opt/gb10/model-openai-smoke.py stream "$model_id" \
      >"$evidence_dir/streaming.json" 2>"$evidence_dir/streaming.stderr" && \
     jq -e '.status == "pass" and .chunks > 0 and .done == true' "$evidence_dir/streaming.json" >/dev/null; then
    record_acceptance_gate streaming pass
  else
    record_acceptance_gate streaming fail
  fi
fi
if [[ "$accept_structured" == true ]]; then
  if container_exec 0 "$head_container" python3 /opt/gb10/model-openai-smoke.py structured "$model_id" \
      >"$evidence_dir/structured.json" 2>"$evidence_dir/structured.stderr" && \
     jq -e '.status == "pass" and .schema == "gb10_result"' "$evidence_dir/structured.json" >/dev/null; then
    record_acceptance_gate structured-output pass
  else
    record_acceptance_gate structured-output fail
  fi
fi
if [[ "$accept_image" == true ]]; then
  if container_exec 0 "$head_container" python3 /opt/gb10/model-openai-smoke.py multimodal "$model_id" \
      >"$evidence_dir/image.json" 2>"$evidence_dir/image.stderr" && \
     jq -e '.status == "pass" and .modality == "image+text"' "$evidence_dir/image.json" >/dev/null; then
    record_acceptance_gate image-input pass
  else
    record_acceptance_gate image-input fail
  fi
fi
if [[ "$accept_audio" == true ]]; then
  if container_exec 0 "$head_container" python3 /opt/gb10/model-openai-smoke.py audio "$model_id" \
      >"$evidence_dir/audio.json" 2>"$evidence_dir/audio.stderr" && \
     jq -e '.status == "pass" and .modality == "audio+text"' "$evidence_dir/audio.json" >/dev/null; then
    record_acceptance_gate audio-input pass
  else
    record_acceptance_gate audio-input fail
  fi
fi
if (( stress_minimum_prompt_tokens > 0 )); then
  if container_exec 0 "$head_container" \
      python3 /opt/gb10/model-openai-stress.py all "$model_id" \
        "$stress_minimum_prompt_tokens" "$stress_concurrency" \
      >"$evidence_dir/stress.json" 2>"$evidence_dir/stress.stderr" && \
     jq -e --argjson minimum "$stress_minimum_prompt_tokens" --argjson concurrency "$stress_concurrency" \
      '.status == "pass" and .longContext.minimumPromptTokens == $minimum and
       .longContext.observedPromptTokens >= $minimum and
       .concurrency.requests == $concurrency and
       (.concurrency.results | length) == $concurrency' "$evidence_dir/stress.json" >/dev/null; then
    record_acceptance_gate sustained-load pass
  else
    record_acceptance_gate sustained-load fail
  fi
fi
if (( ${#acceptance_failures[@]} > 0 )); then
  die "acceptance gates failed: ${acceptance_failures[*]}"
fi

cat "$evidence_dir"/rank*.log >"$evidence_dir/combined.log"
fabric_transport_pass=true
if ! grep -E 'NET/IB|Using network IB' "$evidence_dir/combined.log" >/dev/null; then
  if [[ "$runtime_nccl_debug" == WARN ]] &&
     [[ $(jq -r '.environment.NCCL_NET // ""' <<<"$profile_json") == IB ]] &&
     [[ $(jq -r --arg fallback "$nccl_ib_hca" '.environment.NCCL_IB_HCA // $fallback' <<<"$profile_json") == "$effective_nccl_ib_hca" ]]; then
    for ((rank = 0; rank < node_count; rank++)); do
      ib_counter_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-ib-after.tsv" || fabric_transport_pass=false
      while read -r hca before; do
        after=$(awk -v h="$hca" '$1 == h {print $2}' "$evidence_dir/rank$rank-ib-after.tsv")
        if ! [[ "$after" =~ ^[0-9]+$ ]] || (( after <= before )); then
          fabric_transport_pass=false
        fi
      done <"$evidence_dir/rank$rank-ib-before.tsv"
    done
  else
    fabric_transport_pass=false
  fi
else
  IFS=, read -r -a requested_hcas <<<"$effective_nccl_ib_hca"
  for requested_hca in "${requested_hcas[@]}"; do
    if ! grep -F "${requested_hca%%:*}" "$evidence_dir/combined.log" >/dev/null; then
      fabric_transport_pass=false
    fi
  done
fi
if [[ "$fabric_transport_pass" == true ]]; then
  record_acceptance_gate fabric-transport pass
else
  record_acceptance_gate fabric-transport fail
  die "fabric transport evidence absent from runtime logs"
fi

if [[ "$qualify_and_serve" == 1 ]]; then
  jq -n --arg result ready --arg topology "$declared_topology" \
    --arg profile "$profile" --arg model "$model_id" --arg engine "$engine" \
    --arg endpoint 'http://127.0.0.1:8000/v1' --argjson maxSeconds "$serve_max_seconds" \
    '{result:$result,topology:$topology,profile:$profile,model:$model,engine:$engine,
      endpoint:$endpoint,loopbackOnly:true,qualifiedBeforeServe:true,
      maxSeconds:(if $maxSeconds == 0 then null else $maxSeconds end)}' \
    >"$evidence_dir/live-service.json"
  # Persist the release receipt before best-effort display. This keeps a
  # disconnected caller from producing SIGPIPE/141 after a successful run.
  cat "$evidence_dir/live-service.json" || true
  printf 'cluster_vllm_qualified_service=ready\n'
  printf 'Qualified API is live on rank 0 loopback; press Ctrl-C to stop and clean up.\n'
  serve_started=$SECONDS
  while :; do
    for ((rank = 0; rank < node_count; rank++)); do
      running=$(remote "${hosts[$rank]}" \
        "${container_command_texts[$rank]} inspect '${containers[$rank]}' --format '{{.State.Running}}' 2>/dev/null || true")
      [[ "$running" == true ]] || die "rank$rank qualified $engine service container stopped unexpectedly"
    done
    container_exec 0 "$head_container" \
      python3 /opt/gb10/model-openai-smoke.py ready "$model_id" \
      >"$evidence_dir/live-health.json" 2>"$evidence_dir/live-health.stderr" || \
      die "qualified $engine endpoint failed its live health check"
    if (( serve_max_seconds > 0 && SECONDS - serve_started >= serve_max_seconds )); then
      printf 'Qualified service duration reached; cleaning up.\n'
      break
    fi
    sleep 10
  done
fi

cleanup
trap - EXIT HUP INT TERM
for ((rank = 0; rank < node_count; rank++)); do
  host=${hosts[$rank]}
  firewall_inventory "$host" >"$evidence_dir/rank$rank-firewall-after.txt"
  gpu_inventory "$host" >"$evidence_dir/rank$rank-gpu-after.txt"
  container_inventory "$rank" >"$evidence_dir/rank$rank-containers-after.txt"
  fabric_inventory "$host" >"$evidence_dir/rank$rank-fabric-after.txt"
  diff -u "$evidence_dir/rank$rank-firewall-before.txt" "$evidence_dir/rank$rank-firewall-after.txt"
  diff -u "$evidence_dir/rank$rank-gpu-before.txt" "$evidence_dir/rank$rank-gpu-after.txt"
  diff -u "$evidence_dir/rank$rank-containers-before.txt" "$evidence_dir/rank$rank-containers-after.txt"
  diff -u "$evidence_dir/rank$rank-fabric-before.txt" "$evidence_dir/rank$rank-fabric-after.txt"
  if [[ -n "$container_cache_host_path" ]]; then
    runtime_cache_inventory "$rank" >"$evidence_dir/rank$rank-runtime-cache-after.txt"
  fi
done

runtime_json=$(jq -s '.' "${runtime_files[@]}")
preflight_json=$(jq -s '.' "$evidence_dir"/rank*-preflight.json)
runtime_image_refs_result=$(printf '%s\n' "${runtime_image_refs[@]}" | jq -R . | jq -s .)
jq -n --arg result pass --arg topology "$declared_topology" --arg profile "$profile" \
  --arg model "$model_id" --arg revision "$model_revision" --arg engine "$engine" --arg engineVersion "$engine_version" \
  --arg image "$image" --arg runtimeImageRef "$runtime_image_ref" --argjson runtimeImageRefs "$runtime_image_refs_result" \
  --arg tree "$expected_weight_tree" --arg hcas "$effective_nccl_ib_hca" \
  --arg flashinferVersion "$expected_flashinfer" \
  --argjson nodes "$node_count" --argjson tp "$tp_size" --argjson pp "$pp_size" \
  --argjson eager "$enforce_eager" --argjson preflight "$preflight_json" \
  --argjson runtime "$runtime_json" --argjson hermes "$accept_hermes" \
  --argjson streaming "$accept_streaming" --argjson structured "$accept_structured" \
  --argjson outputIntegrity "$accept_output_integrity" \
  --argjson imageInput "$accept_image" --argjson audioInput "$accept_audio" \
  --argjson stressMinimumPromptTokens "$stress_minimum_prompt_tokens" \
  --argjson stressConcurrency "$stress_concurrency" \
  --arg runtimeCacheHostPath "$container_cache_host_path" \
  '{result:$result,topology:$topology,profile:$profile,model:$model,modelRevision:$revision,
    weightTreeSha256:$tree,engine:$engine,engineVersion:$engineVersion,
    flashinferVersion:(if $flashinferVersion == "" then null else $flashinferVersion end),
    image:$image,runtimeImageRef:$runtimeImageRef,runtimeImageRefs:$runtimeImageRefs,
    topologyContract:{nodes:$nodes,gpus:$nodes,tensorParallelSize:$tp,pipelineParallelSize:$pp,
      executor:(if $engine == "vllm" then "mp" else "sglang-multinode" end),workerStartOrder:"workers-before-head",
      enforceEager:(if $engine == "vllm" then ($eager == 1) else null end)},
    preflight:$preflight,runtime:$runtime,
    api:{loopbackOnly:true,repeatedCompletion:true,hermesContract:$hermes,
      streaming:$streaming,structuredOutputs:$structured,outputIntegrity:$outputIntegrity,
      imageInput:$imageInput,audioInput:$audioInput,
      stress:{minimumPromptTokens:$stressMinimumPromptTokens,concurrency:$stressConcurrency}},
    runtimeCache:{persistent:($runtimeCacheHostPath != ""),hostPath:(if $runtimeCacheHostPath == "" then null else $runtimeCacheHostPath end),
      ownerOnly:true,checkpointReadOnly:true},
    network:{transport:"NCCL NET/IB",hcas:$hcas,mtu:9000},
    storage:(if $preflight[0].storageMode == "local-nvme"
      then "identical-pinned-checkpoint-on-each-local-NVMe"
      else "identical-pinned-checkpoint-on-reviewed-read-only-shared-store" end),
    checkpointHash:(if $preflight[0].storageMode == "local-nvme"
      then "each independent local copy hashed"
      else "one underlying read-only shared copy hashed; every rank independently verified source, mount mode, revision, file count, and byte count" end),
    cleanup:"temporary-firewall-containers-files-and-GPU-process-state-restored"}' \
  >"$evidence_dir/summary.json"
cat "$evidence_dir/summary.json" || true

[[ "$engine" != vllm ]] || printf 'cluster_vllm_acceptance=pass\n'
printf 'cluster_model_acceptance=pass engine=%s\n' "$engine"
