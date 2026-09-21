#!/usr/bin/env bash
set -Eeuo pipefail

# Fail-closed 2/4/8-node vLLM or SGLang acceptance over an already-qualified persistent
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

[[ -r "$inventory" && -r "$profile_registry" ]] || die 'inventory or profile registry is unreadable'
jq -e '.nodes | type == "array" and (length == 2 or length == 4 or length == 8)' \
  "$inventory" >/dev/null || die 'inventory must contain exactly 2, 4, or 8 nodes'
node_count=$(jq -r '.nodes | length' "$inventory")
declared_topology=$(jq -r '.topology' "$inventory")
case "$node_count:$declared_topology" in
  2:deuces|4:quads|8:eight) ;;
  *) die 'inventory topology does not match node count' ;;
esac
[[ -n "$profile" ]] || die 'GB10_CLUSTER_MODEL_PROFILE is required'
jq -e --arg profile "$profile" '.profiles[$profile].engine == "vllm" or .profiles[$profile].engine == "sglang"' \
  "$profile_registry" >/dev/null || die "unknown or unsupported model-engine profile: $profile"
profile_json=$(jq -c --arg profile "$profile" '.profiles[$profile]' "$profile_registry")
engine=$(jq -r '.engine' <<<"$profile_json")

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
[[ "$weight_hash_timeout" =~ ^[0-9]+$ ]] && (( weight_hash_timeout >= 60 && weight_hash_timeout <= 7200 )) || \
  die 'GB10_CLUSTER_WEIGHT_HASH_TIMEOUT_SECONDS must be 60..7200'

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
containers=()
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
  hosts+=( "$host" )
  rail_a_cidrs+=( "$rail_a" )
  rail_b_cidrs+=( "$rail_b" )
  rail_a_addresses+=( "${rail_a%/*}" )
  rail_b_addresses+=( "${rail_b%/*}" )
  model_dirs+=( "$model_dir" )
done

model_id=$(jq -r '.modelId' <<<"$profile_json")
model_revision=$(jq -r '.modelRevision' <<<"$profile_json")
model_bytes=$(jq -r '.modelBytes' <<<"$profile_json")
expected_weight_count=$(jq -r '.weightFiles' <<<"$profile_json")
expected_weight_bytes=$(jq -r '.weightBytes' <<<"$profile_json")
expected_weight_tree=$(jq -r '.weightTreeSha256' <<<"$profile_json")
image=$(jq -r '.image' <<<"$profile_json")
runtime_image_ref=$(jq -r '.runtimeImageRef // .image' <<<"$profile_json")
expected_image_id=$(jq -r '.imageId // empty' <<<"$profile_json")
expected_rootfs_layers=$(jq -r '.rootfsLayersSha256 // empty' <<<"$profile_json")
engine_version=$(jq -r '.engineVersion' <<<"$profile_json")
engine_source_revision=$(jq -r '.engineSourceRevision // empty' <<<"$profile_json")
expected_torch_cuda=$(jq -r '.torchCudaVersion' <<<"$profile_json")
expected_container_cuda=$(jq -r '.containerCudaVersion' <<<"$profile_json")
expected_flashinfer=$(jq -r '.flashinferVersion // empty' <<<"$profile_json")
container_entrypoint=$(jq -r '.containerEntrypoint // empty' <<<"$profile_json")
accept_hermes=$(jq -r 'if (.acceptance | type) == "object" and (.acceptance | has("hermes")) then .acceptance.hermes else true end' <<<"$profile_json")
accept_streaming=$(jq -r '.acceptance.streaming // false' <<<"$profile_json")
accept_structured=$(jq -r '.acceptance.structuredOutputs // false' <<<"$profile_json")
accept_image=$(jq -r '.acceptance.imageInput // false' <<<"$profile_json")
accept_audio=$(jq -r '.acceptance.audioInput // false' <<<"$profile_json")
stress_minimum_prompt_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")

[[ "$model_revision" =~ ^[0-9a-f]{40}$ ]] || die 'profile requires an exact model revision'
[[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || die 'profile image must be digest pinned'
[[ "$runtime_image_ref" =~ ^sha256:[0-9a-f]{64}$ || "$runtime_image_ref" =~ @sha256:[0-9a-f]{64}$ ]] || \
  die 'profile runtime image must be an immutable digest or image ID'
[[ -z "$expected_image_id" || "$expected_image_id" =~ ^[0-9a-f]{64}$ ]] || \
  die 'profile expected image ID is invalid'
[[ -z "$expected_rootfs_layers" || "$expected_rootfs_layers" =~ ^[0-9a-f]{64}$ ]] || \
  die 'profile expected rootfs-layer SHA-256 is invalid'
[[ "$container_entrypoint" =~ ^[A-Za-z0-9_./+:-]+$ ]] || \
  die 'profile requires a safe explicit container entrypoint'
[[ ( -z "$expected_image_id" && -z "$expected_rootfs_layers" ) || \
   ( -n "$expected_image_id" && -n "$expected_rootfs_layers" ) ]] || \
  die 'profile image ID and rootfs-layer SHA-256 must be specified together'
[[ "$expected_weight_count" =~ ^[1-9][0-9]*$ && "$expected_weight_bytes" =~ ^[1-9][0-9]*$ ]] || \
  die 'profile weight contract is incomplete'
[[ "$expected_weight_tree" =~ ^[0-9a-f]{64}$ ]] || die 'profile weight-tree SHA-256 is invalid'
for value in "$accept_hermes" "$accept_streaming" "$accept_structured" "$accept_image" "$accept_audio"; do
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

firewall_inventory() {
  remote "$1" 'sudo -n iptables -S'
}

gpu_inventory() {
  remote "$1" \
    'nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits | LC_ALL=C sort'
}

container_inventory() {
  remote "$1" \
    "podman ps -a --no-trunc --format '{{.ID}} {{.Image}} {{.Status}}' | LC_ALL=C sort"
}

fabric_inventory() {
  remote "$1" "for interface in '$rail_a_interface' '$rail_b_interface'; do
    printf '%s mtu=' \"\$interface\"
    cat \"/sys/class/net/\$interface/mtu\"
    ip -o -4 address show dev \"\$interface\" | LC_ALL=C sort
  done"
}

podman_exec() {
  local host=$1 container=$2
  shift 2
  local quoted
  printf -v quoted '%q ' podman exec "$container" "$@"
  remote "$host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $quoted"
}

run_id="gb10sor-vllm-${declared_topology}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
hash_helper="$repo_root/scripts/cluster-weight-hash.sh"
[[ -f "$hash_helper" ]] || die 'bounded weight-hash helper missing'
hash_helper_sha=$(sha256sum "$hash_helper" | awk '{print $1}')
hash_token=$(printf '%s\n' "$run_id" "$evidence_dir" "$hash_helper_sha" | sha256sum | awk '{print $1}')
hash_states=() hash_units=() hash_prepared=()
head_test="/tmp/${run_id}-model-openai-smoke.py"
head_hermes_test="/tmp/${run_id}-hermes-openai-smoke.py"
head_stress_test="/tmp/${run_id}-model-openai-stress.py"
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
  if remote "$host" "podman inspect '$container' >/dev/null 2>&1"; then
    remote "$host" "podman inspect '$container'" \
      >"$evidence_dir/rank$rank-final-inspect.json" \
      2>"$evidence_dir/rank$rank-final-inspect.stderr" || true
    remote "$host" "podman logs '$container'" \
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
    remove_container_with_retries "${hosts[$rank]}" "${containers[$rank]}" || cleanup_failed=1
  done
  for ((index = ${#firewall_rules[@]} - 1; index >= 0; index--)); do
    remote "${firewall_hosts[$index]}" \
      "sudo -n iptables -D nixos-fw ${firewall_rules[$index]}" >/dev/null 2>&1 || true
  done
  remote "${hosts[0]}" "rm -f '$head_test' '$head_hermes_test' '$head_stress_test'" >/dev/null 2>&1 || true
  exit "$cleanup_failed"
)
remove_container_with_retries() {
  local host=$1 container=$2 attempt
  for attempt in 1 2 3 4; do
    if remote "$host" \
      "podman rm -f '$container' >/dev/null 2>&1 || true; ! podman inspect '$container' >/dev/null 2>&1"; then
      return 0
    fi
    sleep 2
  done
  printf 'Cleanup failed to remove exact container %s after four attempts.\n' "$container" >&2
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
trap 'exit 130' INT
trap 'exit 143' TERM

# Provision all ownership records synchronously before launching any preflight.
# No unit starts here. Collision/error prevents model work; private receipts stay.
for ((rank = 0; rank < node_count; rank++)); do
  state=${hash_states[$rank]}
  remote "${hosts[$rank]}" "umask 077; mkdir '$state' && printf '%s\\n' '$hash_token' > '$state/owner'"
  scp "${scp_options[@]}" "$hash_helper" "${hosts[$rank]}:$state/hash.sh"
  remote "${hosts[$rank]}" "printf '%s  hash.sh\\n' '$hash_helper_sha' > '$state/helper.sha256'; cd '$state'; sha256sum --strict -c helper.sha256"
  hash_prepared[$rank]=yes
done

add_peer_rule() {
  local host=$1 interface=$2 peer=$3
  local rule="-i '$interface' -s '$peer' -p tcp -m comment --comment '$run_id' -j nixos-fw-accept"
  remote "$host" "sudo -n iptables -I nixos-fw 1 $rule"
  firewall_hosts+=( "$host" )
  firewall_rules+=( "$rule" )
}

preflight_node() {
  local rank=$1 host=${hosts[$1]} model_dir=${model_dirs[$1]}
  local rail_a=${rail_a_cidrs[$1]} rail_b=${rail_b_cidrs[$1]}
  local observed_bytes observed_count observed_weight_bytes observed_tree revision_count
  local fstype gpu image_json image_id image_arch image_digest image_layers driver

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
  fstype=$(remote "$host" "findmnt -T '$model_dir' -n -o FSTYPE | tail -n 1")
  case "$fstype" in *nfs*|*cifs*|*smb*|*fuse.sshfs*) die "rank$rank checkpoint is not local" ;; esac
  observed_bytes=$(remote "$host" "du -sb --apparent-size '$model_dir' | awk '{print \$1}'")
  jq -e --argjson observed "$observed_bytes" \
    '(.modelBytesAllowed // [.modelBytes]) | index($observed) != null' \
    <<<"$profile_json" >/dev/null || die "rank$rank model byte size changed"
  revision_count=$(remote "$host" \
    "count=0; for marker in '$model_dir/.hf_revision' '$model_dir/.gb10sor-revision'; do if test -f \"\$marker\" && grep -Fqx '$model_revision' \"\$marker\"; then count=1; fi; done; if test -d '$model_dir/.cache/huggingface/download'; then extra=\$(find '$model_dir/.cache/huggingface/download' -type f -name '*.metadata' -exec sed -n '1p' {} + 2>/dev/null | grep -Fxc '$model_revision' || true); count=\$((count + extra)); fi; printf '%s\\n' \"\$count\"")
  [[ "$revision_count" -gt 0 ]] || die "rank$rank checkpoint lacks the pinned revision marker"
  observed_count=$(remote "$host" "find '$model_dir' -type f -name '*.safetensors' | wc -l | tr -d ' '")
  [[ "$observed_count" == "$expected_weight_count" ]] || die "rank$rank weight-file count changed"
  observed_weight_bytes=$(remote "$host" \
    "find '$model_dir' -type f -name '*.safetensors' -printf '%s\\n' | awk '{sum += \$1} END {print sum + 0}'")
  [[ "$observed_weight_bytes" == "$expected_weight_bytes" ]] || die "rank$rank weight bytes changed"
  observed_tree=$(remote "$host" \
    "bash '${hash_states[$rank]}/hash.sh' start '${hash_states[$rank]}' '${hash_units[$rank]}' '$hash_token' '$model_dir' '$expected_weight_tree' '$weight_hash_timeout'")
  [[ "$observed_tree" == "$expected_weight_tree" ]] || die "rank$rank weight-tree SHA-256 changed"
  gpu=$(remote "$host" 'nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader,nounits')
  [[ $(wc -l <<<"$gpu" | tr -d ' ') == 1 && "$gpu" == *12.1* ]] || die "rank$rank is not one GB10 GPU"
  [[ -z $(gpu_inventory "$host") ]] || die "rank$rank already has a GPU workload"
  driver=$(remote "$host" 'nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits')
  image_json=$(remote "$host" "podman image inspect '$runtime_image_ref'")
  image_id=$(jq -er '.[0].Id' <<<"$image_json" | sed 's/^sha256://')
  image_arch=$(jq -er '.[0].Architecture' <<<"$image_json")
  image_digest=$(jq -r '.[0].Digest // empty' <<<"$image_json")
  image_layers=$(jq -c '.[0].RootFS.Layers' <<<"$image_json" | sha256sum | awk '{print $1}')
  [[ "$image_id" =~ ^[0-9a-f]{64}$ && "$image_arch" == arm64 ]] || die "rank$rank image identity failed"
  if [[ -n "$expected_image_id" ]]; then
    [[ "$image_id" == "$expected_image_id" ]] || die "rank$rank image ID changed"
    [[ "$image_layers" == "$expected_rootfs_layers" ]] || die "rank$rank rootfs layers changed"
  else
    [[ "$image_digest" == "${image##*@}" ]] || die "rank$rank image manifest changed"
  fi

  jq -n --argjson rank "$rank" --arg host "$host" --arg storage "$fstype" \
    --arg gpu "$gpu" --arg driver "$driver" --arg imageId "$image_id" \
    --arg imageDigest "$image_digest" --arg layers "$image_layers" \
    --arg revision "$model_revision" --arg tree "$observed_tree" \
    --argjson bytes "$observed_bytes" --argjson files "$observed_count" \
    --argjson weightBytes "$observed_weight_bytes" \
    '{rank:$rank,host:$host,storage:$storage,gpu:$gpu,driverVersion:$driver,
      imageId:$imageId,imageDigest:$imageDigest,rootfsLayersSha256:$layers,
      modelRevision:$revision,modelBytes:$bytes,weightFiles:$files,
      weightBytes:$weightBytes,weightTreeSha256:$tree}' \
    >"$evidence_dir/rank$rank-preflight.json"
}

preflight_pids=()
for ((rank = 0; rank < node_count; rank++)); do
  firewall_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-firewall-before.txt"
  gpu_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-gpu-before.txt"
  container_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-containers-before.txt"
  fabric_inventory "${hosts[$rank]}" >"$evidence_dir/rank$rank-fabric-before.txt"
  preflight_node "$rank" &
  preflight_pids+=( "$!" )
done
preflight_failed=0
for pid in "${preflight_pids[@]}"; do wait "$pid" || preflight_failed=1; done
(( preflight_failed == 0 )) || die 'one or more node preflights failed'

reference_image=$(jq -r '.imageId + ":" + .rootfsLayersSha256' "$evidence_dir/rank0-preflight.json")
reference_checkpoint=$(jq -r '.modelRevision + ":" + .weightTreeSha256' "$evidence_dir/rank0-preflight.json")
for ((rank = 1; rank < node_count; rank++)); do
  [[ $(jq -r '.imageId + ":" + .rootfsLayersSha256' "$evidence_dir/rank$rank-preflight.json") == "$reference_image" ]] || \
    die "rank$rank image identity differs"
  [[ $(jq -r '.modelRevision + ":" + .weightTreeSha256' "$evidence_dir/rank$rank-preflight.json") == "$reference_checkpoint" ]] || \
    die "rank$rank checkpoint identity differs"
done

scp "${scp_options[@]}" "$repo_root/tests/model-openai-smoke.py" "${hosts[0]}:$head_test"
scp "${scp_options[@]}" "$repo_root/tests/hermes-openai-smoke.py" "${hosts[0]}:$head_hermes_test"
scp "${scp_options[@]}" "$repo_root/tests/model-openai-stress.py" "${hosts[0]}:$head_stress_test"

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

common_args=(
  --pull=never --network host --ipc private --shm-size 16g
  --device nvidia.com/gpu=all --device /dev/infiniband:/dev/infiniband
  --ulimit memlock=-1:-1 --ulimit stack=67108864:67108864
  --pids-limit 8192 --cap-drop=all --security-opt=no-new-privileges --read-only
  --tmpfs /tmp:rw,nosuid,nodev,size=8g
  --tmpfs /root/.cache:rw,nosuid,nodev,size=12g
  --tmpfs /root/.config:rw,nosuid,nodev,size=64m
  --tmpfs /root/.tilelang:rw,nosuid,nodev,size=8g
  --tmpfs /root/.triton:rw,nosuid,nodev,size=4g
  -e HF_HUB_OFFLINE=1 -e HF_HUB_DISABLE_TELEMETRY=1 -e TRANSFORMERS_OFFLINE=1
  -e PIP_NO_INDEX=1 -e DO_NOT_TRACK=1
  -e "GB10SOR_OPENAI_TIMEOUT_SECONDS=$request_timeout"
  -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET,COLL -e NCCL_IB_DISABLE=0
  -e "NCCL_IB_HCA=$nccl_ib_hca" -e "NCCL_IB_GID_INDEX=$nccl_ib_gid_index"
  -e "NCCL_SOCKET_IFNAME=$rail_a_interface,$rail_b_interface"
  -e "GLOO_SOCKET_IFNAME=$rail_a_interface"
)
(( ${#profile_environment_args[@]} > 0 )) && common_args+=( "${profile_environment_args[@]}" )

if [[ "$engine" == vllm ]]; then
  common_args+=( -e VLLM_NO_USAGE_STATS=1 --entrypoint "$container_entrypoint" )
  transport_args=(
    serve /model --host 127.0.0.1 --port 8000
    --distributed-executor-backend mp --nnodes "$node_count"
    --tensor-parallel-size "$tp_size" --pipeline-parallel-size "$pp_size"
    --master-addr "${rail_a_addresses[0]}" --master-port "$master_port"
    --distributed-timeout-seconds 900 --disable-custom-all-reduce
  )
  [[ "$enforce_eager" == 1 ]] && transport_args+=( --enforce-eager )
else
  [[ "$pp_size" == 1 ]] || die 'the reviewed SGLang cluster path requires pipeline parallel size 1'
  [[ "$engine_source_revision" =~ ^[0-9a-f]{40}$ ]] || \
    die 'SGLang profile requires an exact engine source revision'
  common_args+=( --entrypoint "$container_entrypoint" )
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
  local command quoted
  command=(
    podman run -d --name "$container" "${common_args[@]}"
    -v "$model_dir:/model:ro"
  )
  if (( rank == 0 )); then
    command+=(
      -v "$head_test:/opt/gb10/model-openai-smoke.py:ro"
      -v "$head_hermes_test:/opt/gb10/hermes-openai-smoke.py:ro"
      -v "$head_stress_test:/opt/gb10/model-openai-stress.py:ro"
    )
  fi
  if [[ "$engine" == vllm ]]; then
    command+=( -e "VLLM_HOST_IP=${rail_a_addresses[$rank]}" )
  else
    command+=( -e "SGLANG_HOST_IP=${rail_a_addresses[$rank]}" )
  fi
  command+=( "$runtime_image_ref" "${transport_args[@]}" --node-rank "$rank" )
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
      "podman inspect '${containers[$rank]}' --format '{{.State.Running}}' 2>/dev/null || true")
    [[ "$running" == true ]] || { all_running=0; break; }
  done
  (( all_running == 1 )) || break
  if podman_exec "${hosts[0]}" "${containers[0]}" \
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
    podman_exec "$host" "$container" python3 -c \
      'import importlib.metadata as m,json,os,torch,vllm; print(json.dumps({"engine":"vllm","version":vllm.__version__,"vllm":vllm.__version__,"torch":torch.__version__,"torchCuda":torch.version.cuda,"containerCuda":os.environ.get("CUDA_VERSION"),"flashinfer":m.version("flashinfer-python"),"capability":list(torch.cuda.get_device_capability())}))' \
      >"$evidence_dir/rank$rank-runtime.json"
  else
    podman_exec "$host" "$container" python3 -c \
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
podman_exec "$head_host" "$head_container" python3 /opt/gb10/model-openai-smoke.py completion "$model_id" \
  >"$evidence_dir/completion.json" 2>"$evidence_dir/completion.stderr"
jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' \
  "$evidence_dir/completion.json" >/dev/null
if [[ "$accept_hermes" == true ]]; then
  podman_exec "$head_host" "$head_container" python3 /opt/gb10/hermes-openai-smoke.py "$model_id" \
    >"$evidence_dir/hermes.json" 2>"$evidence_dir/hermes.stderr"
  jq -e '.status == "pass" and .models_gate == "pass" and .chat_gate == "pass" and .tool_call_gate == "pass" and .tool_result_gate == "pass"' \
    "$evidence_dir/hermes.json" >/dev/null
fi
if [[ "$accept_streaming" == true ]]; then
  podman_exec "$head_host" "$head_container" python3 /opt/gb10/model-openai-smoke.py stream "$model_id" \
    >"$evidence_dir/streaming.json" 2>"$evidence_dir/streaming.stderr"
  jq -e '.status == "pass" and .chunks > 0 and .done == true' "$evidence_dir/streaming.json" >/dev/null
fi
if [[ "$accept_structured" == true ]]; then
  podman_exec "$head_host" "$head_container" python3 /opt/gb10/model-openai-smoke.py structured "$model_id" \
    >"$evidence_dir/structured.json" 2>"$evidence_dir/structured.stderr"
  jq -e '.status == "pass" and .schema == "gb10_result"' "$evidence_dir/structured.json" >/dev/null
fi
if [[ "$accept_image" == true ]]; then
  podman_exec "$head_host" "$head_container" python3 /opt/gb10/model-openai-smoke.py multimodal "$model_id" \
    >"$evidence_dir/image.json" 2>"$evidence_dir/image.stderr"
  jq -e '.status == "pass" and .modality == "image+text"' "$evidence_dir/image.json" >/dev/null
fi
if [[ "$accept_audio" == true ]]; then
  podman_exec "$head_host" "$head_container" python3 /opt/gb10/model-openai-smoke.py audio "$model_id" \
    >"$evidence_dir/audio.json" 2>"$evidence_dir/audio.stderr"
  jq -e '.status == "pass" and .modality == "audio+text"' "$evidence_dir/audio.json" >/dev/null
fi
if (( stress_minimum_prompt_tokens > 0 )); then
  podman_exec "$head_host" "$head_container" \
    python3 /opt/gb10/model-openai-stress.py all "$model_id" \
      "$stress_minimum_prompt_tokens" "$stress_concurrency" \
    >"$evidence_dir/stress.json" 2>"$evidence_dir/stress.stderr"
  jq -e --argjson minimum "$stress_minimum_prompt_tokens" --argjson concurrency "$stress_concurrency" \
    '.status == "pass" and .longContext.minimumPromptTokens == $minimum and
     .longContext.observedPromptTokens >= $minimum and
     .concurrency.requests == $concurrency and
     (.concurrency.results | length) == $concurrency' "$evidence_dir/stress.json" >/dev/null
fi

cat "$evidence_dir"/rank*.log >"$evidence_dir/combined.log"
grep -E 'NET/IB|Using network IB' "$evidence_dir/combined.log" >/dev/null
IFS=, read -r -a requested_hcas <<<"$nccl_ib_hca"
for requested_hca in "${requested_hcas[@]}"; do
  grep -F "${requested_hca%%:*}" "$evidence_dir/combined.log" >/dev/null
done

if [[ "$qualify_and_serve" == 1 ]]; then
  jq -n --arg result ready --arg topology "$declared_topology" \
    --arg profile "$profile" --arg model "$model_id" --arg engine "$engine" \
    --arg endpoint 'http://127.0.0.1:8000/v1' --argjson maxSeconds "$serve_max_seconds" \
    '{result:$result,topology:$topology,profile:$profile,model:$model,engine:$engine,
      endpoint:$endpoint,loopbackOnly:true,qualifiedBeforeServe:true,
      maxSeconds:(if $maxSeconds == 0 then null else $maxSeconds end)}' \
    >"$evidence_dir/live-service.json"
  # Evidence persistence must not depend on the caller continuing to consume
  # stdout. A closed display pipe must never turn a completed qualification
  # into exit 141 or leave a zero-byte receipt.
  cat "$evidence_dir/live-service.json" || true
  printf 'cluster_vllm_qualified_service=ready\n'
  printf 'Qualified API is live on rank 0 loopback; press Ctrl-C to stop and clean up.\n'
  serve_started=$SECONDS
  while :; do
    for ((rank = 0; rank < node_count; rank++)); do
      running=$(remote "${hosts[$rank]}" \
        "podman inspect '${containers[$rank]}' --format '{{.State.Running}}' 2>/dev/null || true")
      [[ "$running" == true ]] || die "rank$rank qualified $engine service container stopped unexpectedly"
    done
    podman_exec "$head_host" "$head_container" \
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
trap - EXIT INT TERM
for ((rank = 0; rank < node_count; rank++)); do
  host=${hosts[$rank]}
  firewall_inventory "$host" >"$evidence_dir/rank$rank-firewall-after.txt"
  gpu_inventory "$host" >"$evidence_dir/rank$rank-gpu-after.txt"
  container_inventory "$host" >"$evidence_dir/rank$rank-containers-after.txt"
  fabric_inventory "$host" >"$evidence_dir/rank$rank-fabric-after.txt"
  diff -u "$evidence_dir/rank$rank-firewall-before.txt" "$evidence_dir/rank$rank-firewall-after.txt"
  diff -u "$evidence_dir/rank$rank-gpu-before.txt" "$evidence_dir/rank$rank-gpu-after.txt"
  diff -u "$evidence_dir/rank$rank-containers-before.txt" "$evidence_dir/rank$rank-containers-after.txt"
  diff -u "$evidence_dir/rank$rank-fabric-before.txt" "$evidence_dir/rank$rank-fabric-after.txt"
done

runtime_json=$(jq -s '.' "${runtime_files[@]}")
preflight_json=$(jq -s '.' "$evidence_dir"/rank*-preflight.json)
jq -n --arg result pass --arg topology "$declared_topology" --arg profile "$profile" \
  --arg model "$model_id" --arg revision "$model_revision" --arg engine "$engine" --arg engineVersion "$engine_version" \
  --arg image "$image" --arg runtimeImageRef "$runtime_image_ref" \
  --arg tree "$expected_weight_tree" --arg hcas "$nccl_ib_hca" \
  --arg flashinferVersion "$expected_flashinfer" \
  --argjson nodes "$node_count" --argjson tp "$tp_size" --argjson pp "$pp_size" \
  --argjson eager "$enforce_eager" --argjson preflight "$preflight_json" \
  --argjson runtime "$runtime_json" --argjson hermes "$accept_hermes" \
  --argjson streaming "$accept_streaming" --argjson structured "$accept_structured" \
  --argjson imageInput "$accept_image" --argjson audioInput "$accept_audio" \
  --argjson stressMinimumPromptTokens "$stress_minimum_prompt_tokens" \
  --argjson stressConcurrency "$stress_concurrency" \
  '{result:$result,topology:$topology,profile:$profile,model:$model,modelRevision:$revision,
    weightTreeSha256:$tree,engine:$engine,engineVersion:$engineVersion,
    flashinferVersion:(if $flashinferVersion == "" then null else $flashinferVersion end),
    image:$image,runtimeImageRef:$runtimeImageRef,
    topologyContract:{nodes:$nodes,gpus:$nodes,tensorParallelSize:$tp,pipelineParallelSize:$pp,
      executor:(if $engine == "vllm" then "mp" else "sglang-multinode" end),workerStartOrder:"workers-before-head",
      enforceEager:(if $engine == "vllm" then ($eager == 1) else null end)},
    preflight:$preflight,runtime:$runtime,
    api:{loopbackOnly:true,repeatedCompletion:true,hermesContract:$hermes,
      streaming:$streaming,structuredOutputs:$structured,imageInput:$imageInput,audioInput:$audioInput,
      stress:{minimumPromptTokens:$stressMinimumPromptTokens,concurrency:$stressConcurrency}},
    network:{transport:"NCCL NET/IB",hcas:$hcas,mtu:9000},
    storage:"identical-pinned-checkpoint-on-each-local-NVMe",
    cleanup:"temporary-firewall-containers-files-and-GPU-process-state-restored"}' \
  >"$evidence_dir/summary.json"
cat "$evidence_dir/summary.json" || true

[[ "$engine" != vllm ]] || printf 'cluster_vllm_acceptance=pass\n'
printf 'cluster_model_acceptance=pass engine=%s\n' "$engine"
