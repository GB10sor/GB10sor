#!/usr/bin/env bash
set -Eeuo pipefail

# Fail-closed two-node vLLM model acceptance for an explicitly qualified
# Deuces fabric. Checkpoints must already exist on both local NVMe filesystems
# and the immutable ARM64 image must already be present; this script never
# downloads.

die() {
  printf 'Deuces vLLM acceptance failed: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "missing required environment variable: $name"
}

for name in \
  DEUCES_LEFT_HOST DEUCES_RIGHT_HOST \
  DEUCES_LEFT_NODE DEUCES_RIGHT_NODE \
  DEUCES_CLUSTER_PROFILE_PATH \
  DEUCES_LEFT_RAIL_A DEUCES_RIGHT_RAIL_A \
  DEUCES_PAYLOAD_EVIDENCE_DIR \
  DEUCES_LEFT_MODEL_DIR DEUCES_RIGHT_MODEL_DIR
do
  require_env "$name"
done

interface_count="${DEUCES_DIRECT_INTERFACE_COUNT:-2}"
[[ "$interface_count" == 1 || "$interface_count" == 2 ]] || \
  die 'DEUCES_DIRECT_INTERFACE_COUNT must be 1 or 2'
if [[ "$interface_count" == 2 ]]; then
  require_env DEUCES_LEFT_RAIL_B
  require_env DEUCES_RIGHT_RAIL_B
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
profile_registry="${DEUCES_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}"
profile="${DEUCES_MODEL_PROFILE:-nemotron-lightning}"
cluster_profile_path="$DEUCES_CLUSTER_PROFILE_PATH"
topology="${DEUCES_TOPOLOGY:-switch}"
left_host="$DEUCES_LEFT_HOST"
right_host="$DEUCES_RIGHT_HOST"
left_address="${DEUCES_LEFT_RAIL_A%/*}"
right_address="${DEUCES_RIGHT_RAIL_A%/*}"
rail_a_interface="${DEUCES_RAIL_A_INTERFACE:-enp1s0f1np1}"
rail_b_interface="${DEUCES_RAIL_B_INTERFACE:-enP2p1s0f1np1}"
left_model_dir="$DEUCES_LEFT_MODEL_DIR"
right_model_dir="$DEUCES_RIGHT_MODEL_DIR"
evidence_dir="$DEUCES_PAYLOAD_EVIDENCE_DIR"
master_port="${DEUCES_VLLM_MASTER_PORT:-29501}"
startup_timeout="${DEUCES_VLLM_STARTUP_TIMEOUT_SECONDS:-1500}"
request_timeout="${DEUCES_VLLM_REQUEST_TIMEOUT_SECONDS:-600}"
qualify_and_serve="${DEUCES_QUALIFY_AND_SERVE:-0}"
serve_max_seconds="${DEUCES_SERVE_MAX_SECONDS:-0}"
enforce_eager="${DEUCES_VLLM_ENFORCE_EAGER:-1}"
target_mtu="${DEUCES_MTU:-9000}"
nccl_ib_hca="${DEUCES_NCCL_IB_HCA:-mlx5_1:1,mlx5_3:1}"
nccl_socket_ifname="${DEUCES_NCCL_SOCKET_IFNAME:-$rail_a_interface,$rail_b_interface}"
nccl_ib_gid_index="${DEUCES_NCCL_IB_GID_INDEX:-3}"
run_id="gb10sor-vllm-$(date -u +%Y%m%dT%H%M%SZ)-$$"
left_container="${run_id}-rank0"
right_container="${run_id}-rank1"
left_test="/tmp/${run_id}-model-openai-smoke.py"
left_hermes_test="/tmp/${run_id}-hermes-openai-smoke.py"
left_stress_test="/tmp/${run_id}-model-openai-stress.py"
right_test="/tmp/${run_id}-model-openai-smoke.py"
right_hermes_test="/tmp/${run_id}-hermes-openai-smoke.py"

[[ "$qualify_and_serve" == 0 || "$qualify_and_serve" == 1 ]] || \
  die 'DEUCES_QUALIFY_AND_SERVE must be 0 or 1'
[[ "$serve_max_seconds" =~ ^[0-9]+$ && "$serve_max_seconds" -le 604800 ]] || \
  die 'DEUCES_SERVE_MAX_SECONDS must be 0..604800'

[[ -r "$profile_registry" ]] || die "profile registry is unreadable: $profile_registry"
[[ "$cluster_profile_path" =~ ^/[A-Za-z0-9._/-]+$ && "$cluster_profile_path" != / ]] || \
  die 'DEUCES_CLUSTER_PROFILE_PATH is unsafe'
jq -e --arg profile "$profile" '.profiles[$profile] != null' "$profile_registry" >/dev/null || \
  die "unknown model profile: $profile"
profile_json=$(jq -c --arg profile "$profile" '.profiles[$profile]' "$profile_registry")
if [[ -z "${DEUCES_VLLM_ENFORCE_EAGER+x}" ]]; then
  enforce_eager=$(jq -r 'if (.container.enforceEager // true) then 1 else 0 end' <<<"$profile_json")
fi
container_ipc=$(jq -r '.container.ipc // "private"' <<<"$profile_json")
container_shm_size=$(jq -r '.container.shmSize // "16g"' <<<"$profile_json")
container_cap_ipc_lock=$(jq -r '.container.capIpcLock // false' <<<"$profile_json")
disable_custom_all_reduce=$(jq -r '.container.disableCustomAllReduce // true' <<<"$profile_json")
[[ "$container_ipc" == private || "$container_ipc" == host ]] || \
  die 'container IPC mode must be private or host'
[[ "$container_shm_size" =~ ^[1-9][0-9]*[mg]$ ]] || die 'container SHM size is invalid'
container_shm_count=${container_shm_size%[mg]}
container_shm_unit=${container_shm_size: -1}
if [[ "$container_shm_unit" == g ]]; then
  container_shm_min_bytes=$((container_shm_count * 1024 * 1024 * 1024))
else
  container_shm_min_bytes=$((container_shm_count * 1024 * 1024))
fi
for value in "$container_cap_ipc_lock" "$disable_custom_all_reduce"; do
  [[ "$value" == true || "$value" == false ]] || die 'container capability flags must be booleans'
done
engine=$(jq -r '.engine' <<<"$profile_json")
[[ "$engine" == vllm ]] || die "profile $profile does not use vLLM"
model_id=$(jq -r '.modelId' <<<"$profile_json")
served_model_id=$(jq -r '.servedModelName // .modelId' <<<"$profile_json")
model_revision=$(jq -r '.modelRevision' <<<"$profile_json")
accept_hermes=$(jq -r 'if (.acceptance | type) == "object" and (.acceptance | has("hermes")) then .acceptance.hermes else true end' <<<"$profile_json")
accept_streaming=$(jq -r '.acceptance.streaming // false' <<<"$profile_json")
accept_structured=$(jq -r '.acceptance.structuredOutputs // false' <<<"$profile_json")
accept_image=$(jq -r '.acceptance.imageInput // false' <<<"$profile_json")
accept_audio=$(jq -r '.acceptance.audioInput // false' <<<"$profile_json")
stress_minimum_prompt_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")
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
profile_image=$(jq -r '.image' <<<"$profile_json")
image="${DEUCES_VLLM_IMAGE:-$profile_image}"
expected_image_id="${DEUCES_VLLM_EXPECTED_IMAGE_ID:-}"
expected_layers_sha256="${DEUCES_VLLM_EXPECTED_LAYERS_SHA256:-}"
engine_version=$(jq -r '.engineVersion' <<<"$profile_json")
expected_torch_cuda=$(jq -r '.torchCudaVersion // empty' <<<"$profile_json")
expected_container_cuda=$(jq -r '.containerCudaVersion // empty' <<<"$profile_json")
expected_flashinfer=$(jq -r '.flashinferVersion // empty' <<<"$profile_json")
[[ -n "$expected_torch_cuda" && -n "$expected_container_cuda" ]] || \
  die 'Deuces qualification requires explicit torch and container CUDA contracts'
expected_weight_count=$(jq -r '.weightFiles // empty' <<<"$profile_json")
expected_weight_bytes=$(jq -r '.weightBytes // empty' <<<"$profile_json")
expected_weight_tree=$(jq -r '.weightTreeSha256 // empty' <<<"$profile_json")
[[ -n "$expected_weight_count" && -n "$expected_weight_bytes" && -n "$expected_weight_tree" ]] || \
  die 'Deuces qualification requires a profile with a complete weight-tree contract'
has_auxiliary_model=0
left_auxiliary_model_dir=
right_auxiliary_model_dir=
auxiliary_container_path=
left_auxiliary_expected_tree=
right_auxiliary_expected_tree=
if jq -e '.auxiliaryModel != null' <<<"$profile_json" >/dev/null; then
  has_auxiliary_model=1
  left_auxiliary_expected_tree=$(jq -r \
    '.auxiliaryModel.rankContracts.rank0.weightTreeSha256 // .auxiliaryModel.weightTreeSha256 // empty' \
    <<<"$profile_json")
  right_auxiliary_expected_tree=$(jq -r \
    '.auxiliaryModel.rankContracts.rank1.weightTreeSha256 // .auxiliaryModel.weightTreeSha256 // empty' \
    <<<"$profile_json")
  [[ "$left_auxiliary_expected_tree" =~ ^[0-9a-f]{64}$ && \
     "$right_auxiliary_expected_tree" =~ ^[0-9a-f]{64}$ ]] || \
    die 'auxiliary model rank contracts require exact weight-tree SHA-256 values'
  require_env DEUCES_LEFT_AUXILIARY_MODEL_DIR
  require_env DEUCES_RIGHT_AUXILIARY_MODEL_DIR
  left_auxiliary_model_dir=$DEUCES_LEFT_AUXILIARY_MODEL_DIR
  right_auxiliary_model_dir=$DEUCES_RIGHT_AUXILIARY_MODEL_DIR
  auxiliary_container_path=$(jq -r '.auxiliaryModel.containerPath' <<<"$profile_json")
  [[ "$auxiliary_container_path" =~ ^/[A-Za-z0-9._/@+-]+$ && "$auxiliary_container_path" != / ]] || \
    die 'auxiliary model container path is unsafe'
fi
if [[ "$image" != "$profile_image" ]]; then
  [[ "$expected_image_id" =~ ^[0-9a-f]{64}$ && "$expected_layers_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die 'a local runtime tag requires exact expected image-ID and rootfs-layer hashes'
fi

model_paths=( "$left_model_dir" "$right_model_dir" )
if (( has_auxiliary_model == 1 )); then
  model_paths+=( "$left_auxiliary_model_dir" "$right_auxiliary_model_dir" )
fi
for value in "${model_paths[@]}"; do
  [[ "$value" =~ ^/[A-Za-z0-9._/@+-]+$ && "$value" != / ]] || \
    die "model path is not a safe absolute path: $value"
done
[[ "$master_port" =~ ^[0-9]+$ && "$master_port" -ge 1024 && "$master_port" -le 65535 ]] || \
  die 'DEUCES_VLLM_MASTER_PORT must be 1024..65535'
[[ "$startup_timeout" =~ ^[1-9][0-9]*$ && "$startup_timeout" -le 2400 ]] || \
  die 'DEUCES_VLLM_STARTUP_TIMEOUT_SECONDS must be 1..2400'
[[ "$request_timeout" =~ ^[1-9][0-9]*$ && "$request_timeout" -le 900 ]] || \
  die 'DEUCES_VLLM_REQUEST_TIMEOUT_SECONDS must be 1..900'
[[ "$enforce_eager" == 0 || "$enforce_eager" == 1 ]] || \
  die 'DEUCES_VLLM_ENFORCE_EAGER must be 0 or 1'
[[ "$topology" == switch || "$topology" == direct ]] || \
  die 'DEUCES_TOPOLOGY must be switch or direct'
[[ "$target_mtu" =~ ^[0-9]+$ && "$target_mtu" -ge 1280 && "$target_mtu" -le 9700 ]] || \
  die 'DEUCES_MTU must be 1280..9700'
[[ "$nccl_ib_hca" =~ ^mlx5_[0-9]+:[0-9]+(,mlx5_[0-9]+:[0-9]+)*$ ]] || \
  die 'DEUCES_NCCL_IB_HCA must be a comma-separated mlx5_N:P list'
[[ "$nccl_ib_gid_index" =~ ^[0-9]+$ && "$nccl_ib_gid_index" -le 255 ]] || \
  die 'DEUCES_NCCL_IB_GID_INDEX must be 0..255'
fabric_addresses=("$DEUCES_LEFT_RAIL_A" "$DEUCES_RIGHT_RAIL_A")
if [[ "$interface_count" == 2 ]]; then
  fabric_addresses+=("$DEUCES_LEFT_RAIL_B" "$DEUCES_RIGHT_RAIL_B")
fi
for value in "${fabric_addresses[@]}"; do
  [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || \
    die "fabric address is not an IPv4 CIDR: $value"
done
fabric_interface_names=("$rail_a_interface")
if [[ "$interface_count" == 2 ]]; then
  fabric_interface_names+=("$rail_b_interface")
fi
for value in "${fabric_interface_names[@]}"; do
  [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "unsafe interface name: $value"
done

mkdir -p "$evidence_dir"

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ConnectionAttempts=3
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=6
)
scp_options=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ConnectionAttempts=3
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=6
)
if [[ -n "${DEUCES_SSH_IDENTITY_FILE:-}" ]]; then
  [[ -f "$DEUCES_SSH_IDENTITY_FILE" ]] || \
    die "DEUCES_SSH_IDENTITY_FILE is not a readable file: $DEUCES_SSH_IDENTITY_FILE"
  ssh_options+=(
    -o IdentitiesOnly=yes
    -i "$DEUCES_SSH_IDENTITY_FILE"
  )
  scp_options+=(
    -o IdentitiesOnly=yes
    -i "$DEUCES_SSH_IDENTITY_FILE"
  )
fi
if [[ -n "${DEUCES_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  [[ -f "$DEUCES_SSH_KNOWN_HOSTS_FILE" ]] || \
    die "DEUCES_SSH_KNOWN_HOSTS_FILE is not a readable file: $DEUCES_SSH_KNOWN_HOSTS_FILE"
  ssh_options+=(
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$DEUCES_SSH_KNOWN_HOSTS_FILE"
  )
  scp_options+=(
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$DEUCES_SSH_KNOWN_HOSTS_FILE"
  )
fi

remote() {
  local host="$1"
  shift
  if [[ -n "${DEUCES_LEFT_NODE:-}" && "$(hostname -s)" == "$DEUCES_LEFT_NODE" && "$host" == "$DEUCES_LEFT_HOST" ]]; then
    [[ $# == 1 ]] || return 2
    /run/current-system/sw/bin/bash --noprofile --norc -euo pipefail -c "$1"
    return
  fi
  ssh "${ssh_options[@]}" "$host" "$@"
}

copy_to_host() {
  local host="$1" source="$2" destination="$3"
  if [[ -n "${DEUCES_LEFT_NODE:-}" && "$(hostname -s)" == "$DEUCES_LEFT_NODE" && "$host" == "$DEUCES_LEFT_HOST" ]]; then
    cp -- "$source" "$destination"
  else
    scp "${scp_options[@]}" "$source" "$host:$destination"
  fi
}

copy_from_host_recursive() {
  local host="$1" source="$2" destination="$3"
  if [[ -n "${DEUCES_LEFT_NODE:-}" && "$(hostname -s)" == "$DEUCES_LEFT_NODE" && "$host" == "$DEUCES_LEFT_HOST" ]]; then
    cp -a -- "$source" "$destination/"
  else
    scp "${scp_options[@]}" -r "$host:$source" "$destination/"
  fi
}

# The SSH client's status is only the final remote command's status unless the
# remote script explicitly fails fast. Use a new Bash process so caller-side
# conditionals cannot disable errexit inside these safety gates.
remote_profile_gate() {
  local host=$1 script=$2 quoted
  printf -v quoted '%q' "$script"
  remote "$host" "/run/current-system/sw/bin/bash --noprofile --norc -euo pipefail -c $quoted"
}

require_exact_deuces_profile() {
  local host="$1" expected_node="$2" expected_fabric_ip="$3"

  if [[ "$topology" == switch ]]; then
    remote_profile_gate "$host" "
      test -r '$cluster_profile_path'
      jq -e \
        --arg node '$expected_node' \
        --arg fabric '$expected_fabric_ip' \
        --arg head '$left_address' \
        --arg left '$left_address' \
        --arg right '$right_address' \
        '.clusterMode == \"deuces-switch\"
         and .profile == \"off\"
         and .role == \"off\"
         and .nodeName == \$node
         and .fabricIp == \$fabric
         and .headIp == \$head
         and .clusterNodeCount == 2
         and .clusterFabricHosts == [\$left, \$right]' \
        '$cluster_profile_path' >/dev/null
      systemctl is-active --quiet cluster-fabric-profile.service
      systemctl is-active --quiet cluster-fabric-qualification.service
      if systemctl is-active --quiet ray-cluster.service; then exit 1; fi
      for interface in enp1s0f0np0 enP2p1s0f0np0; do
        ip -j link show dev \"\$interface\" | jq -e '.[0].flags | index(\"UP\") == null' >/dev/null
        addresses=\$(ip -o -4 address show dev \"\$interface\")
        routes=\$(ip route show dev \"\$interface\")
        test -z \"\$addresses\"
        test -z \"\$routes\"
      done
    "
  else
    local direct_interfaces="'$rail_a_interface'"
    [[ "$interface_count" == 1 ]] || direct_interfaces+=" '$rail_b_interface'"
    remote_profile_gate "$host" "
      if systemctl is-active --quiet cluster-fabric-profile.service; then exit 1; fi
      if systemctl is-active --quiet cluster-fabric-qualification.service; then exit 1; fi
      if systemctl is-active --quiet ray-cluster.service; then exit 1; fi
      for interface in enp1s0f1np1 enP2p1s0f1np1; do
        ip -j link show dev \"\$interface\" | jq -e '.[0].flags | index(\"UP\") == null' >/dev/null
        addresses=\$(ip -o -4 address show dev \"\$interface\")
        routes=\$(ip route show dev \"\$interface\")
        test -z \"\$addresses\"
        test -z \"\$routes\"
      done
      for interface in $direct_interfaces; do
        test \"\$(cat /sys/class/net/\$interface/operstate)\" = up
        test \"\$(cat /sys/class/net/\$interface/mtu)\" = '$target_mtu'
        ethtool \"\$interface\" | grep -F 'Speed: 200000Mb/s'
        ethtool --show-fec \"\$interface\" | grep -F 'Active FEC encoding: RS'
        rdma link show | grep -F \"netdev \$interface\" | grep -F 'state ACTIVE' | grep -F 'physical_state LINK_UP'
      done
    "
  fi
}

remote_auxiliary_model_preflight() {
  local host="$1" model_dir="$2" label="$3"
  local auxiliary_json revision expected_bytes expected_count expected_weight_bytes expected_tree
  local observed_bytes observed_count observed_weight_bytes observed_tree revision_count fstype mount_source resolved_dir

  auxiliary_json=$(jq -c --arg label "$label" \
    '.auxiliaryModel as $base | ($base.rankContracts[$label] // {}) as $rank | $base + $rank' \
    <<<"$profile_json")
  revision=$(jq -r '.modelRevision' <<<"$auxiliary_json")
  expected_bytes=$(jq -r '.modelBytes' <<<"$auxiliary_json")
  expected_count=$(jq -r '.weightFiles' <<<"$auxiliary_json")
  expected_weight_bytes=$(jq -r '.weightBytes' <<<"$auxiliary_json")
  expected_tree=$(jq -r '.weightTreeSha256' <<<"$auxiliary_json")
  # jq's `//` treats both null and false as absent.  Preserve an explicit false
  # for intentionally sparse rank-local auxiliary trees; default only when the
  # property itself is missing.
  if [[ $(jq -r 'if has("requiresConfig") then .requiresConfig else true end' <<<"$auxiliary_json") == true ]]; then
    remote "$host" "test -r '$model_dir/config.json'"
  fi
  remote "$host" \
    "test -n \"\$(find '$model_dir' -type f -name '*.safetensors' -print -quit)\""
  read -r fstype mount_source < <(remote "$host" "findmnt -T '$model_dir' -rn -o FSTYPE,SOURCE | awk '\$1 != \"autofs\" { print; exit }'")
  case "$fstype" in
    *nfs*|*cifs*|*smb*|*fuse.sshfs*|'') die "$label auxiliary checkpoint is not on local storage" ;;
  esac
  if [[ "$auxiliary_container_path" == /engram-src ]]; then
    [[ "$mount_source" == /dev/nvme* && "$fstype" =~ ^(ext4|xfs|btrfs)$ ]] || \
      die "$label Engram source must reside on this Spark's NVMe disk"
    resolved_dir=$(remote "$host" "realpath -e '$model_dir'")
    [[ "$resolved_dir" == "$model_dir" ]] || \
      die "$label Engram directory must not resolve through a symlink"
    remote "$host" "test -z \"\$(find '$model_dir' -type l -print -quit)\" && test -z \"\$(findmnt -R '$model_dir' -rn -o TARGET)\"" || \
      die "$label Engram directory contains a symlink or nested mount"
  fi
  observed_bytes=$(remote "$host" "du -sb --apparent-size '$model_dir' | awk '{print \$1}'")
  jq -e --argjson observed "$observed_bytes" \
    '(.modelBytesAllowed // [.modelBytes]) | index($observed) != null' \
    <<<"$auxiliary_json" >/dev/null || die "$label auxiliary model byte size changed"
  revision_count=$(remote "$host" \
    "count=0; if test -f '$model_dir/.hf_revision' && grep -Fqx '$revision' '$model_dir/.hf_revision'; then count=1; fi; if test -d '$model_dir/.cache/huggingface/download'; then extra=\$(find '$model_dir/.cache/huggingface/download' -type f -name '*.metadata' -exec sed -n '1p' {} + 2>/dev/null | grep -Fxc '$revision' || true); count=\$((count + extra)); fi; printf '%s\\n' \"\$count\"")
  [[ "$revision_count" -gt 0 ]] || die "$label auxiliary checkpoint lacks the pinned revision marker"
  observed_count=$(remote "$host" "find '$model_dir' -type f -name '*.safetensors' | wc -l | tr -d ' '")
  [[ "$observed_count" == "$expected_count" ]] || die "$label auxiliary weight-file count changed"
  observed_weight_bytes=$(remote "$host" \
    "find '$model_dir' -type f -name '*.safetensors' -printf '%s\\n' | awk '{sum += \$1} END {print sum + 0}'")
  [[ "$observed_weight_bytes" == "$expected_weight_bytes" ]] || \
    die "$label auxiliary weight byte total changed"
  observed_tree=$(hash_slot_run auxiliary "$label" "$host" "$model_dir" "$expected_tree")
  [[ "$observed_tree" == "$expected_tree" ]] || die "$label auxiliary weight-tree SHA-256 changed"
  jq -n --arg label "$label" --arg storage "$fstype" --arg revision "$revision" \
    --arg weightTreeSha256 "$observed_tree" --argjson modelBytes "$observed_bytes" \
    --argjson weightFiles "$observed_count" --argjson weightBytes "$observed_weight_bytes" \
    '{label:$label,storage:$storage,modelRevision:$revision,modelBytes:$modelBytes,
      weightFiles:$weightFiles,weightBytes:$weightBytes,weightTreeSha256:$weightTreeSha256}' \
    >"$evidence_dir/$label-auxiliary-preflight.json"
}

podman_exec() {
  local host="$1" container="$2"
  shift 2
  if [[ "$owned_enabled" == 1 ]]; then owned_exec "$host" "$container" "$@"; return $?; fi
  local quoted
  printf -v quoted '%q ' podman exec "$container" "$@"
  remote "$host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $quoted"
}

firewall_inventory() {
  remote "$1" "sudo -n iptables -S"
}

gpu_inventory() {
  remote "$1" \
    "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits | LC_ALL=C sort"
}

container_inventory() {
  remote "$1" \
    "podman ps -a --no-trunc --format '{{.ID}} {{.Image}} {{.Status}}' | LC_ALL=C sort"
}

fabric_inventory() {
  local interfaces="'$rail_a_interface'"
  [[ "$interface_count" == 1 ]] || interfaces+=" '$rail_b_interface'"
  remote "$1" "for interface in $interfaces; do
    printf '%s mtu=' \"\$interface\"
    cat \"/sys/class/net/\$interface/mtu\"
    printf ' arp_ignore='
    sysctl -n \"net.ipv4.conf.\$interface.arp_ignore\"
    printf ' arp_announce='
    sysctl -n \"net.ipv4.conf.\$interface.arp_announce\"
    ip -o -4 address show dev \"\$interface\" | LC_ALL=C sort
  done"
}

# BEGIN bounded per-slot weight lifecycle (kept identical in both engines).
hash_hosts=() hash_kinds=() hash_ranks=() hash_models=() hash_expected=()
hash_states=() hash_units=() hash_tokens=() hash_prepared=()
preflight_pids=()

hash_slot_add() {
  local kind=$1 rank=$2 host=$3 model=$4 expected=$5 unit token
  [[ "$kind" == target || "$kind" == auxiliary || "$kind" == draft ]] || return 1
  [[ "$rank" == rank0 || "$rank" == rank1 ]] || return 1
  [[ "$model" =~ ^/[A-Za-z0-9._/@+-]+$ && "$expected" =~ ^[a-f0-9]{64}$ ]] || return 1
  unit="gb10sor-vllm-deuces-${run_id#gb10sor-}-$kind-weights-$rank"
  [[ "$unit" =~ ^gb10sor-vllm-[a-zA-Z0-9-]+-weights-rank[01]$ ]] || return 1
  token=$(printf '%s\n' "$run_id" "$host" "$kind" "$rank" "$model" "$expected" "$hash_helper_sha" | sha256sum | awk '{print $1}') || return 1
  hash_hosts+=("$host"); hash_kinds+=("$kind"); hash_ranks+=("$rank")
  hash_models+=("$model"); hash_expected+=("$expected")
  hash_states+=("/tmp/$unit"); hash_units+=("$unit"); hash_tokens+=("$token")
  hash_prepared+=(no)
}

hash_slots_init() {
  hash_helper="$repo_root/scripts/cluster-weight-hash.sh"
  [[ -f "$hash_helper" ]] || return 1
  hash_helper_sha=$(sha256sum "$hash_helper" | awk '{print $1}') || return 1
  hash_timeout="${GB10_CLUSTER_WEIGHT_HASH_TIMEOUT_SECONDS:-1800}"
  [[ "$hash_timeout" =~ ^[0-9]+$ ]] && (( hash_timeout >= 60 && hash_timeout <= 7200 )) || return 1
  hash_slot_add target rank0 "$left_host" "$left_model_dir" "$expected_weight_tree" || return 1
  hash_slot_add target rank1 "$right_host" "$right_model_dir" "$expected_weight_tree" || return 1
  if [[ "${has_auxiliary_model:-0}" == 1 ]]; then
    hash_slot_add auxiliary rank0 "$left_host" "$left_auxiliary_model_dir" "$left_auxiliary_expected_tree" || return 1
    hash_slot_add auxiliary rank1 "$right_host" "$right_auxiliary_model_dir" "$right_auxiliary_expected_tree" || return 1
  fi
  if [[ -n "${draft_model_id:-}" ]]; then
    hash_slot_add draft rank0 "$left_host" "$left_draft_model_dir" "$draft_expected_weight_tree" || return 1
    hash_slot_add draft rank1 "$right_host" "$right_draft_model_dir" "$draft_expected_weight_tree" || return 1
  fi
  readonly -a hash_hosts hash_kinds hash_ranks hash_models hash_expected hash_states hash_units hash_tokens
  readonly hash_helper hash_helper_sha hash_timeout
  local index
  # Complete durable ownership manifest precedes every remote mutation. Tokens
  # bind immutable host/kind/rank/path/tree/helper identity; no model is read here.
  [[ ! -e "$evidence_dir/weight-hash-ownership.tsv" ]] || return 1
  for ((index=0; index<${#hash_hosts[@]}; index++)); do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${hash_hosts[$index]}" "${hash_kinds[$index]}" "${hash_ranks[$index]}" \
      "${hash_models[$index]}" "${hash_expected[$index]}" "${hash_states[$index]}" \
      "${hash_units[$index]}" "${hash_tokens[$index]}" "$hash_helper_sha" \
      >>"$evidence_dir/weight-hash-ownership.tsv" || return 1
  done
  if [[ "${owned_enabled:-0}" != 1 ]]; then hash_slots_prepare; fi
}

hash_slots_prepare() {
  local index
  for ((index=0; index<${#hash_hosts[@]}; index++)); do
    hash_prepared[$index]=attempted
    printf '%s\tsetup-attempted\n' "$index" >>"$evidence_dir/weight-hash-setup.tsv" || return 1
    remote "${hash_hosts[$index]}" \
      "set -eu; umask 077; mkdir '${hash_states[$index]}'; printf '%s\\n' '${hash_tokens[$index]}' >'${hash_states[$index]}/owner'" || return 1
    if [[ "${owned_enabled:-0}" == 1 ]]; then
      owned_bounded_scp "${scp_options[@]}" "$hash_helper" \
        "${hash_hosts[$index]}:${hash_states[$index]}/hash.sh" || return 1
    else
      copy_to_host "${hash_hosts[$index]}" "$hash_helper" \
        "${hash_states[$index]}/hash.sh" || return 1
    fi
    remote "${hash_hosts[$index]}" \
      "set -eu; printf '%s  hash.sh\\n' '$hash_helper_sha' >'${hash_states[$index]}/helper.sha256'; cd '${hash_states[$index]}'; sha256sum --strict -c helper.sha256" || return 1
    hash_prepared[$index]=yes
    printf '%s\tprepared\n' "$index" >>"$evidence_dir/weight-hash-setup.tsv" || return 1
  done
}

hash_slot_run() {
  local kind=$1 rank=$2 host=$3 model=$4 expected=$5 index
  for ((index=0; index<${#hash_hosts[@]}; index++)); do
    [[ "${hash_prepared[$index]}" == yes ]] || return 1
  done
  for ((index=0; index<${#hash_hosts[@]}; index++)); do
    [[ "${hash_kinds[$index]}" == "$kind" && "${hash_ranks[$index]}" == "$rank" ]] || continue
    [[ "${hash_hosts[$index]}" == "$host" && "${hash_models[$index]}" == "$model" && "${hash_expected[$index]}" == "$expected" ]] || return 1
    remote "$host" \
      "bash '${hash_states[$index]}/hash.sh' start '${hash_states[$index]}' '${hash_units[$index]}' '${hash_tokens[$index]}' '$model' '$expected' '$hash_timeout'"
    return $?
  done
  return 1
}

hash_slots_cleanup() {
  local index failed=0 archive="$evidence_dir/weight-hash-state" stop_prefix=''
  if [[ "${owned_enabled:-0}" == 1 ]]; then
    stop_prefix="/run/current-system/sw/bin/timeout --signal=TERM --kill-after=15 120 "
  fi
  mkdir -p "$archive" || return 1
  for ((index=0; index<${#hash_hosts[@]}; index++)); do
    [[ "${hash_prepared[$index]}" != no ]] || continue
    # An attempted setup with no sealed helper is uncertain, not proof of an
    # empty unit. Preserve its failure and state; never erase or guess ownership.
    owned_hash_cleanup[$index]=1; owned_hash_archive[$index]=1
    if remote "${hash_hosts[$index]}" \
      "${stop_prefix}bash '${hash_states[$index]}/hash.sh' stop '${hash_states[$index]}' '${hash_units[$index]}' '${hash_tokens[$index]}'" \
      >"$evidence_dir/weight-hash-$index-cleanup.txt" 2>&1; then owned_hash_cleanup[$index]=0; else failed=1; fi
    if [[ "${owned_enabled:-0}" == 1 ]]; then
      owned_bounded_scp "${scp_options[@]}" -r \
        "${hash_hosts[$index]}:${hash_states[$index]}" "$archive/" \
        >"$evidence_dir/weight-hash-$index-archive.txt" 2>&1
    else
      copy_from_host_recursive "${hash_hosts[$index]}" "${hash_states[$index]}" "$archive" \
        >"$evidence_dir/weight-hash-$index-archive.txt" 2>&1
    fi
    if (( $? == 0 )); then owned_hash_archive[$index]=0; else failed=1; fi
  done
  return "$failed"
}
# END bounded per-slot weight lifecycle.

# Explicit opt-in only; unlimited legacy serving is not lifecycle-qualified.
source "$repo_root/scripts/deuces-owned-adapter.sh"

firewall_hosts=()
firewall_rules=()
fabric_hosts=()
fabric_interfaces=()
fabric_cidrs=()
fabric_added=()
fabric_mtus=()
fabric_arp_ignores=()
fabric_arp_announces=()

configure_fabric_address() {
  local host="$1" interface="$2" cidr="$3"
  local mtu arp_ignore arp_announce index expected

  if [[ "$topology" == direct ]]; then
    # The direct wrapper owns addresses, MTU, ARP and their restoration. This
    # engine only observes its exact declared rail; never acquire duplicate
    # ownership, repair a mismatch, or interpret a failed query as absence.
    [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ && "$cidr" =~ ^[0-9.]+/[0-9]+$ &&
       "$target_mtu" =~ ^[0-9]+$ ]] || return 2
    if [[ "$host" == "$left_host" ]]; then
      if [[ "$interface" == "$rail_a_interface" ]]; then expected=$DEUCES_LEFT_RAIL_A
      elif [[ "$interface_count" == 2 && "$interface" == "$rail_b_interface" ]]; then expected=$DEUCES_LEFT_RAIL_B
      else return 2; fi
    elif [[ "$host" == "$right_host" ]]; then
      if [[ "$interface" == "$rail_a_interface" ]]; then expected=$DEUCES_RIGHT_RAIL_A
      elif [[ "$interface_count" == 2 && "$interface" == "$rail_b_interface" ]]; then expected=$DEUCES_RIGHT_RAIL_B
      else return 2; fi
    else return 2; fi
    [[ "$cidr" == "$expected" ]] || return 2
    remote_profile_gate "$host" "
      state=\$(cat '/sys/class/net/$interface/operstate')
      test \"\$state\" = up
      mtu=\$(cat '/sys/class/net/$interface/mtu')
      test \"\$mtu\" = '$target_mtu'
      ignore=\$(sysctl -n 'net.ipv4.conf.$interface.arp_ignore')
      test \"\$ignore\" = 1
      announce=\$(sysctl -n 'net.ipv4.conf.$interface.arp_announce')
      test \"\$announce\" = 2
      addresses=\$(ip -o -4 address show dev '$interface')
      test \"\$(printf '%s\\n' \"\$addresses\" | awk '{print \$4}')\" = '$cidr'
      physical=\$(ethtool '$interface')
      printf '%s\\n' \"\$physical\" | grep -F 'Speed: 200000Mb/s'
      printf '%s\\n' \"\$physical\" | grep -F 'Link detected: yes'
      links=\$(rdma link show)
      printf '%s\\n' \"\$links\" | grep -E 'netdev $interface( |$)' | grep -F 'state ACTIVE' | grep -F 'physical_state LINK_UP'
    " >"$evidence_dir/${host}-${interface}-direct-observed.txt" 2>&1 || return $?
    return 0
  fi

  remote "$host" \
    "test \"\$(cat '/sys/class/net/$interface/operstate')\" = up
     ethtool '$interface' | grep -F 'Speed: 200000Mb/s'
     ethtool '$interface' | grep -F 'Link detected: yes'
     rdma link show | grep -F 'netdev $interface' | grep -F 'state ACTIVE' | grep -F 'physical_state LINK_UP'" \
    >"$evidence_dir/${host}-${interface}-physical.txt"
  mtu=$(remote "$host" "cat '/sys/class/net/$interface/mtu'")
  arp_ignore=$(remote "$host" "sysctl -n 'net.ipv4.conf.$interface.arp_ignore'")
  arp_announce=$(remote "$host" "sysctl -n 'net.ipv4.conf.$interface.arp_announce'")
  index=${#fabric_hosts[@]}
  fabric_hosts+=("$host")
  fabric_interfaces+=("$interface")
  fabric_cidrs+=("$cidr")
  fabric_added+=(0)
  fabric_mtus+=("$mtu")
  fabric_arp_ignores+=("$arp_ignore")
  fabric_arp_announces+=("$arp_announce")
  if ! remote "$host" "ip -o -4 address show dev '$interface' | awk '{print \$4}' | grep -Fqx '$cidr'"; then
    remote "$host" "sudo -n ip address add '$cidr' dev '$interface'"
    fabric_added[$index]=1
  fi
  remote "$host" \
    "sudo -n ip link set '$interface' mtu '$target_mtu'
     sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_ignore=1'
     sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_announce=2'"
}

add_peer_tcp_rule() {
  local host="$1" interface="$2" peer="$3"
  local rule expected index
  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ && "$peer" =~ ^[0-9.]+$ &&
     "$run_id" =~ ^gb10sor-(vllm|sglang)-[A-Za-z0-9-]+$ ]] || return 2
  if [[ "$host" == "$left_host" ]]; then
    if [[ "$interface" == "$rail_a_interface" ]]; then expected=${DEUCES_RIGHT_RAIL_A%/*}
    elif [[ "$interface_count" == 2 && "$interface" == "$rail_b_interface" ]]; then expected=${DEUCES_RIGHT_RAIL_B%/*}
    else return 2; fi
  elif [[ "$host" == "$right_host" ]]; then
    if [[ "$interface" == "$rail_a_interface" ]]; then expected=${DEUCES_LEFT_RAIL_A%/*}
    elif [[ "$interface_count" == 2 && "$interface" == "$rail_b_interface" ]]; then expected=${DEUCES_LEFT_RAIL_B%/*}
    else return 2; fi
  else return 2; fi
  [[ "$peer" == "$expected" ]] || return 2
  [[ "${GB10_DEUCES_PARENT_FIREWALL:-0}" == 0 || "${GB10_DEUCES_PARENT_FIREWALL:-0}" == 1 ]] || return 2
  if [[ "${GB10_DEUCES_PARENT_FIREWALL:-0}" == 1 ]]; then
    [[ "${owned_enabled:-0}" == 1 && "${DEUCES_TOPOLOGY:-switch}" == direct && "$interface_count" == 1 &&
       "${GB10_DEUCES_NETWORK_OWNER:-}" =~ ^[a-f0-9]{64}$ ]] || return 2
    local comment="gb10sor-direct-model-$GB10_DEUCES_NETWORK_OWNER"
    rule="-i '$interface' -s '$peer' -p tcp -m comment --comment '$comment' -j nixos-fw-accept"
    # Outer owns insertion/removal. The child verifies the exact peer/interface
    # rule and unique comment only; it never registers or adopts the rule.
    remote_profile_gate "$host" "set -euo pipefail
      rules=\$(sudo -n iptables -w 5 -S nixos-fw)
      test \"\$(printf '%s\\n' \"\$rules\" | grep -F -c -- '$comment')\" = 1
      sudo -n iptables -w 5 -C nixos-fw $rule" || return 1
    printf '%s\t%s\t%s\t%s\n' "$host" "$interface" "$peer" "$comment" >>"$evidence_dir/firewall-parent-observation.tsv"
    return 0
  fi
  rule="-i '$interface' -s '$peer' -p tcp -m comment --comment '$run_id' -j nixos-fw-accept"
  # Never adopt a pre-existing rule or interpret a query failure as absence.
  remote_profile_gate "$host" "sudo -n iptables -w 5 -S nixos-fw >/dev/null
    if sudo -n iptables -w 5 -C nixos-fw $rule; then exit 1
    else status=\$?; test \"\$status\" = 1; fi" || return 1
  index=${#firewall_hosts[@]}
  firewall_hosts+=("$host")
  firewall_rules+=("$rule")
  # Register before the first mutation, including a potentially lost reply.
  printf '%s\t%s\t%s\n' "$index" "$host" "$rule" >>"$evidence_dir/firewall-ownership.tsv" || return 1
  remote_profile_gate "$host" "sudo -n iptables -w 5 -I nixos-fw 1 $rule
    sudo -n iptables -w 5 -C nixos-fw $rule" \
    >"$evidence_dir/firewall-$index-insert.txt" 2>&1
}

remove_peer_tcp_rule() {
  local index=$1 host rule
  [[ "$index" =~ ^[0-9]+$ ]] && (( index < ${#firewall_hosts[@]} )) || return 2
  host=${firewall_hosts[$index]}; rule=${firewall_rules[$index]}
  # The exact in-memory ownership tuple must also be in the pre-insert record.
  grep -Fqx "$(printf '%s\t%s\t%s' "$index" "$host" "$rule")" "$evidence_dir/firewall-ownership.tsv" || return 1
  remote_profile_gate "$host" "sudo -n iptables -w 5 -S nixos-fw >/dev/null
    if sudo -n iptables -w 5 -C nixos-fw $rule; then
      sudo -n iptables -w 5 -D nixos-fw $rule
    else status=\$?; test \"\$status\" = 1; fi
    sudo -n iptables -w 5 -S nixos-fw >/dev/null
    if sudo -n iptables -w 5 -C nixos-fw $rule; then exit 1
    else status=\$?; test \"\$status\" = 1; fi" \
    >"$evidence_dir/firewall-$index-remove.txt" 2>&1
}

cleanup_peer_tcp_rules() {
  local index failed=0 status
  for ((index=${#firewall_hosts[@]}-1; index>=0; index--)); do
    status=0
    remove_peer_tcp_rule "$index" || status=$?
    printf '%s\t%s\n' "$index" "$status" >>"$evidence_dir/firewall-cleanup.tsv" || failed=1
    (( status == 0 )) || failed=1
  done
  return "$failed"
}

remove_container_with_retries() {
  local host="$1" container="$2" attempt
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

cleanup() (
  local index cleanup_failed=0
  set +e
  if [[ "$owned_enabled" == 1 ]]; then
    owned_slots_cleanup || cleanup_failed=1
    hash_slots_cleanup || cleanup_failed=1
    owned_resources_finish || cleanup_failed=1
  else
  hash_slots_cleanup || cleanup_failed=1
  # Preserve the final container state and logs before removal. This is
  # especially important for startup failures: without these files, the
  # cleanup trap could erase the only direct explanation for a worker exit.
  if remote "$left_host" "podman inspect '$left_container' >/dev/null 2>&1"; then
    remote "$left_host" "podman inspect '$left_container'" \
      >"$evidence_dir/rank0-final-inspect.json" 2>"$evidence_dir/rank0-final-inspect.stderr" || true
    remote "$left_host" "podman logs '$left_container'" \
      >"$evidence_dir/rank0.log" 2>"$evidence_dir/rank0-log.stderr" || true
  fi
  if remote "$right_host" "podman inspect '$right_container' >/dev/null 2>&1"; then
    remote "$right_host" "podman inspect '$right_container'" \
      >"$evidence_dir/rank1-final-inspect.json" 2>"$evidence_dir/rank1-final-inspect.stderr" || true
    remote "$right_host" "podman logs '$right_container'" \
      >"$evidence_dir/rank1.log" 2>"$evidence_dir/rank1-log.stderr" || true
  fi
  remove_container_with_retries "$left_host" "$left_container" || cleanup_failed=1
  remove_container_with_retries "$right_host" "$right_container" || cleanup_failed=1
  fi
  if (( cleanup_failed )); then
    printf 'Uncertain owned hash/container cleanup; retaining network state for outer recovery.\n' >&2
    exit 1
  fi
  if ! cleanup_peer_tcp_rules; then
    printf 'Exact engine firewall cleanup uncertain; retaining network state.\n' >&2
    exit 1
  fi
  for ((index = ${#fabric_hosts[@]} - 1; index >= 0; index--)); do
    if [[ "${fabric_added[$index]}" == 1 ]]; then
      remote "${fabric_hosts[$index]}" \
        "sudo -n ip address delete '${fabric_cidrs[$index]}' dev '${fabric_interfaces[$index]}'" \
        >/dev/null 2>&1 || true
    fi
    remote "${fabric_hosts[$index]}" \
      "sudo -n ip link set '${fabric_interfaces[$index]}' mtu '${fabric_mtus[$index]}'
       sudo -n sysctl -qw 'net.ipv4.conf.${fabric_interfaces[$index]}.arp_ignore=${fabric_arp_ignores[$index]}'
       sudo -n sysctl -qw 'net.ipv4.conf.${fabric_interfaces[$index]}.arp_announce=${fabric_arp_announces[$index]}'" \
      >/dev/null 2>&1 || true
  done
  remote "$left_host" "rm -f '$left_test' '$left_hermes_test' '$left_stress_test'" >/dev/null 2>&1 || true
  remote "$right_host" "rm -f '$right_test' '$right_hermes_test'" >/dev/null 2>&1 || true
  exit "$cleanup_failed"
)
on_exit() {
  local exit_status=$? cleanup_status=0 index
  trap - EXIT
  cleanup || cleanup_status=$?
  if (( cleanup_status == 0 )); then
    # wait must run in the owning parent, not cleanup's subshell. No PID/PGID
    # signals: remote hash control groups have already been stopped exactly.
    for ((index=0; index<${#preflight_pids[@]}; index++)); do
      wait "${preflight_pids[$index]}" >/dev/null 2>&1 || true
    done
  elif (( exit_status == 0 )); then
    exit_status=1
  fi
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

remote_model_preflight() {
  local host="$1" model_dir="$2" label="$3"
  local observed_bytes observed_weight_count observed_weight_bytes observed_weight_tree
  local fstype gpu driver_version image_id image_arch image_digest layers_sha256 revision_count

  if [[ "$label" == rank0 ]]; then
    require_exact_deuces_profile "$host" "$DEUCES_LEFT_NODE" "$left_address"
  else
    require_exact_deuces_profile "$host" "$DEUCES_RIGHT_NODE" "$right_address"
  fi

  if [[ "$container_ipc" == host ]]; then
    remote "$host" "test \"\$(df -B1 --output=size /dev/shm | tail -n 1 | tr -d ' ')\" -ge '$container_shm_min_bytes'" || \
      die "$label host /dev/shm is smaller than the profile minimum"
  fi

  remote "$host" \
    "test -r '$model_dir/config.json'; test -n \"\$(find '$model_dir' -type f -name '*.safetensors' -print -quit)\""
  fstype=$(remote "$host" "findmnt -T '$model_dir' -n -o FSTYPE | tail -n 1")
  case "$fstype" in
    *nfs*|*cifs*|*smb*|*fuse.sshfs*) die "$label checkpoint is not on local storage" ;;
  esac
  observed_bytes=$(remote "$host" "du -sb --apparent-size '$model_dir' | awk '{print \$1}'")
  jq -e --argjson observed "$observed_bytes" \
    '(.modelBytesAllowed // [.modelBytes]) | index($observed) != null' \
    <<<"$profile_json" >/dev/null || die "$label model byte size changed"
  revision_count=$(remote "$host" \
    "count=0; if test -f '$model_dir/.hf_revision' && grep -Fqx '$model_revision' '$model_dir/.hf_revision'; then count=1; fi; if test -d '$model_dir/.cache/huggingface/download'; then extra=\$(find '$model_dir/.cache/huggingface/download' -type f -name '*.metadata' -exec sed -n '1p' {} + 2>/dev/null | grep -Fxc '$model_revision' || true); count=\$((count + extra)); fi; printf '%s\\n' \"\$count\"")
  [[ "$revision_count" -gt 0 ]] || die "$label checkpoint lacks the pinned revision marker"
  observed_weight_count=$(remote "$host" \
    "find '$model_dir' -type f -name '*.safetensors' | wc -l | tr -d ' '")
  [[ "$observed_weight_count" == "$expected_weight_count" ]] || \
    die "$label weight-file count changed"
  observed_weight_bytes=$(remote "$host" \
    "find '$model_dir' -type f -name '*.safetensors' -printf '%s\\n' | awk '{sum += \$1} END {print sum + 0}'")
  [[ "$observed_weight_bytes" == "$expected_weight_bytes" ]] || \
    die "$label weight byte total changed"
  observed_weight_tree=$(hash_slot_run target "$label" "$host" "$model_dir" "$expected_weight_tree")
  [[ "$observed_weight_tree" == "$expected_weight_tree" ]] || \
    die "$label weight-tree SHA-256 changed"
  gpu=$(remote "$host" \
    "nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader,nounits")
  [[ $(wc -l <<<"$gpu" | tr -d ' ') == 1 && "$gpu" == *12.1* ]] || \
    die "$label does not expose exactly one GB10-class GPU"
  [[ -z "$(gpu_inventory "$host")" ]] || die "$label already has a GPU workload"
  driver_version=$(remote "$host" \
    "nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits")
  image_id=$(remote "$host" "podman image inspect '$image' --format '{{.Id}}'")
  image_arch=$(remote "$host" "podman image inspect '$image' --format '{{.Architecture}}'")
  image_digest=$(remote "$host" "podman image inspect '$image' --format '{{.Digest}}'")
  layers_sha256=$(remote "$host" \
    "podman image inspect '$image' --format '{{json .RootFS.Layers}}' | sha256sum | awk '{print \$1}'")
  [[ "$image_id" =~ ^[0-9a-f]{64}$ && "$image_arch" == arm64 && "$image_digest" == sha256:* ]] || \
    die "$label immutable ARM64 image identity check failed"
  if [[ -n "$expected_image_id" ]]; then
    [[ "$image_id" == "$expected_image_id" && "$layers_sha256" == "$expected_layers_sha256" ]] || \
      die "$label local runtime tag does not match the approved image identity"
  fi

  jq -n \
    --arg label "$label" --arg fstype "$fstype" --arg gpu "$gpu" \
    --arg driverVersion "$driver_version" \
    --arg imageId "$image_id" --arg imageArchitecture "$image_arch" \
    --arg imageDigest "$image_digest" --arg layersSha256 "$layers_sha256" \
    --arg revision "$model_revision" \
    --arg weightTree "$observed_weight_tree" --argjson bytes "$observed_bytes" \
    --argjson weightFiles "$observed_weight_count" --argjson weightBytes "$observed_weight_bytes" \
    '{label:$label,storage:$fstype,gpu:$gpu,driverVersion:$driverVersion,imageId:$imageId,imageArchitecture:$imageArchitecture,imageDigest:$imageDigest,rootfsLayersSha256:$layersSha256,modelRevision:$revision,modelBytes:$bytes,weightFiles:$weightFiles,weightBytes:$weightBytes,weightTreeSha256:$weightTree}' \
    >"$evidence_dir/$label-preflight.json"
}

for host in "$left_host" "$right_host"; do
  remote "$host" "sudo -n true"
  firewall_inventory "$host" >"$evidence_dir/$host-firewall-before.txt"
  gpu_inventory "$host" >"$evidence_dir/$host-gpu-before.txt"
  container_inventory "$host" >"$evidence_dir/$host-containers-before.txt"
  fabric_inventory "$host" >"$evidence_dir/$host-fabric-before.txt"
done

profile_args=()
while IFS= read -r argument; do
  profile_args+=("$argument")
done < <(jq -r '.arguments[]' <<<"$profile_json")
if (( ${#profile_args[@]} > 0 )); then
  for argument in "${profile_args[@]}"; do
    case "$argument" in
      --tensor-parallel-size|--pipeline-parallel-size|--distributed-executor-backend|--nnodes|--node-rank|--master-addr|--master-port|--headless)
        die "profile contains a conflicting Deuces transport flag: $argument"
        ;;
    esac
  done
fi
if [[ "$enforce_eager" == 1 ]] && printf '%s\n' "${profile_args[@]}" | \
   grep -Eq '^(-cc\.|--compilation-config$)'; then
  die 'profile requires CUDA-graph compilation; rerun with DEUCES_VLLM_ENFORCE_EAGER=0'
fi
profile_environment_args=()
while IFS= read -r assignment; do
  name=${assignment%%=*}
  value=${assignment#*=}
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || \
    die "profile contains an unsafe environment variable name: $name"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || \
    die "profile contains a multiline environment variable: $name"
  profile_environment_args+=( -e "$name=$value" )
done < <(jq -r '
  (.environment // {}) | to_entries[] | "\(.key)=\(.value)"
' <<<"$profile_json")

common_args=(
  --pull=never
  --network host
  --ipc "$container_ipc"
  --device nvidia.com/gpu=all
  --device /dev/infiniband:/dev/infiniband
  --ulimit memlock=-1:-1
  --ulimit stack=67108864:67108864
  --pids-limit 8192
  --cap-drop=all
  --security-opt=no-new-privileges
  --read-only
  --tmpfs /tmp:rw,nosuid,nodev,size=8g
  --tmpfs /root/.cache:rw,nosuid,nodev,size=8g
  --tmpfs /root/.config:rw,nosuid,nodev,size=64m
  --tmpfs /root/.tilelang:rw,nosuid,nodev,size=8g
  --tmpfs /root/.triton:rw,nosuid,nodev,size=4g
  -e HF_HUB_OFFLINE=1
  -e HF_HUB_DISABLE_TELEMETRY=1
  -e TRANSFORMERS_OFFLINE=1
  -e PIP_NO_INDEX=1
  -e DO_NOT_TRACK=1
  -e VLLM_NO_USAGE_STATS=1
  -e "GB10SOR_OPENAI_TIMEOUT_SECONDS=$request_timeout"
  -e NCCL_DEBUG=INFO
  -e NCCL_DEBUG_SUBSYS=INIT,NET,COLL
  -e NCCL_IB_DISABLE=0
  -e "NCCL_IB_HCA=$nccl_ib_hca"
  -e "NCCL_IB_GID_INDEX=$nccl_ib_gid_index"
  -e "NCCL_SOCKET_IFNAME=$nccl_socket_ifname"
  -e "GLOO_SOCKET_IFNAME=$rail_a_interface"
  --entrypoint vllm
)
if [[ "$container_ipc" != host ]]; then
  # Podman rejects --shm-size together with --ipc=host.  In host IPC mode the
  # preflight above verifies the host tmpfs capacity instead.
  common_args+=( --shm-size "$container_shm_size" )
fi
if [[ "$container_cap_ipc_lock" == true ]]; then
  common_args+=( --cap-add=IPC_LOCK )
fi
if (( ${#profile_environment_args[@]} > 0 )); then
  common_args+=( "${profile_environment_args[@]}" )
fi

transport_args=(
  serve /model
  --host 127.0.0.1
  --port 8000
  --distributed-executor-backend mp
  --nnodes 2
  --tensor-parallel-size 2
  --master-addr "$left_address"
  --master-port "$master_port"
  --distributed-timeout-seconds 300
)
if [[ "$disable_custom_all_reduce" == true ]]; then
  transport_args+=( --disable-custom-all-reduce )
fi
if [[ "$enforce_eager" == 1 ]]; then
  # The default preserves the proven fallback used by older GB10 vLLM images.
  # Current recipes that explicitly require CUDA graphs must opt out and are
  # still subjected to the same endpoint, GPU, transport, and cleanup gates.
  transport_args+=( --enforce-eager )
fi

quote_command() {
  local destination=$1
  shift
  printf -v "$destination" '%q ' "$@"
}

left_command=(
  podman run -d --name "$left_container"
  "${common_args[@]}"
  -e "VLLM_HOST_IP=$left_address"
  -v "$left_model_dir:/model:ro"
)
if (( has_auxiliary_model == 1 )); then
  left_command+=( -v "$left_auxiliary_model_dir:$auxiliary_container_path:ro" )
fi
left_command+=(
  -v "$left_test:/opt/gb10/model-openai-smoke.py:ro"
  -v "$left_hermes_test:/opt/gb10/hermes-openai-smoke.py:ro"
  -v "$left_stress_test:/opt/gb10/model-openai-stress.py:ro"
  "$image"
  "${transport_args[@]}"
  --node-rank 0
)
if (( ${#profile_args[@]} > 0 )); then
  left_command+=( "${profile_args[@]}" )
fi
right_command=(
  podman run -d --name "$right_container"
  "${common_args[@]}"
  -e "VLLM_HOST_IP=$right_address"
  -v "$right_model_dir:/model:ro"
)
if (( has_auxiliary_model == 1 )); then
  right_command+=( -v "$right_auxiliary_model_dir:$auxiliary_container_path:ro" )
fi
right_command+=(
  -v "$right_test:/opt/gb10/model-openai-smoke.py:ro"
  -v "$right_hermes_test:/opt/gb10/hermes-openai-smoke.py:ro"
  "$image"
  "${transport_args[@]}"
  --node-rank 1
  --headless
)
if (( ${#profile_args[@]} > 0 )); then
  right_command+=( "${profile_args[@]}" )
fi
quote_command left_quoted "${left_command[@]}"
quote_command right_quoted "${right_command[@]}"

owned_budget_preflight || die 'unsafe finite owned qualification budget'
hash_slots_init || die 'bounded weight-hash slot preparation failed'
if [[ "$owned_enabled" == 1 ]]; then
  owned_slots_declare || die 'owned declaration/preflight failed'
  owned_parent_ack || die 'missing, failed or stale parent declaration acknowledgement'
  hash_slots_prepare || die 'declared hash staging failed'
fi
remote_model_preflight "$left_host" "$left_model_dir" rank0 &
left_preflight_pid=$!
preflight_pids+=("$left_preflight_pid")
remote_model_preflight "$right_host" "$right_model_dir" rank1 &
right_preflight_pid=$!
preflight_pids+=("$right_preflight_pid")
left_preflight_status=0
right_preflight_status=0
wait "$left_preflight_pid" || left_preflight_status=$?
wait "$right_preflight_pid" || right_preflight_status=$?
(( left_preflight_status == 0 && right_preflight_status == 0 )) || \
  die 'one or both model preflights failed'
preflight_pids=()
jq -e -n \
  --slurpfile rank0 "$evidence_dir/rank0-preflight.json" \
  --slurpfile rank1 "$evidence_dir/rank1-preflight.json" \
  '$rank0[0].modelRevision == $rank1[0].modelRevision and
   $rank0[0].modelBytes == $rank1[0].modelBytes and
   $rank0[0].weightTreeSha256 == $rank1[0].weightTreeSha256 and
   $rank0[0].driverVersion == $rank1[0].driverVersion and
   $rank0[0].imageId == $rank1[0].imageId and
   $rank0[0].rootfsLayersSha256 == $rank1[0].rootfsLayersSha256' >/dev/null
if (( has_auxiliary_model == 1 )); then
  remote_auxiliary_model_preflight "$left_host" "$left_auxiliary_model_dir" rank0 &
  left_auxiliary_preflight_pid=$!
  preflight_pids+=("$left_auxiliary_preflight_pid")
  remote_auxiliary_model_preflight "$right_host" "$right_auxiliary_model_dir" rank1 &
  right_auxiliary_preflight_pid=$!
  preflight_pids+=("$right_auxiliary_preflight_pid")
  left_auxiliary_preflight_status=0
  right_auxiliary_preflight_status=0
  wait "$left_auxiliary_preflight_pid" || left_auxiliary_preflight_status=$?
  wait "$right_auxiliary_preflight_pid" || right_auxiliary_preflight_status=$?
  (( left_auxiliary_preflight_status == 0 && right_auxiliary_preflight_status == 0 )) || \
    die 'one or both auxiliary model preflights failed'
  preflight_pids=()
  if jq -e '.auxiliaryModel.rankContracts != null' <<<"$profile_json" >/dev/null; then
    jq -e -n \
      --slurpfile rank0 "$evidence_dir/rank0-auxiliary-preflight.json" \
      --slurpfile rank1 "$evidence_dir/rank1-auxiliary-preflight.json" \
      '$rank0[0].modelRevision == $rank1[0].modelRevision' >/dev/null
  else
    jq -e -n \
      --slurpfile rank0 "$evidence_dir/rank0-auxiliary-preflight.json" \
      --slurpfile rank1 "$evidence_dir/rank1-auxiliary-preflight.json" \
      '$rank0[0].modelRevision == $rank1[0].modelRevision and
       $rank0[0].modelBytes == $rank1[0].modelBytes and
       $rank0[0].weightTreeSha256 == $rank1[0].weightTreeSha256' >/dev/null
  fi
fi

copy_to_host "$left_host" "$repo_root/tests/model-openai-smoke.py" "$left_test"
copy_to_host "$left_host" "$repo_root/tests/hermes-openai-smoke.py" "$left_hermes_test"
copy_to_host "$left_host" "$repo_root/tests/model-openai-stress.py" "$left_stress_test"
copy_to_host "$right_host" "$repo_root/tests/model-openai-smoke.py" "$right_test"
copy_to_host "$right_host" "$repo_root/tests/hermes-openai-smoke.py" "$right_hermes_test"

configure_fabric_address "$left_host" "$rail_a_interface" "$DEUCES_LEFT_RAIL_A"
configure_fabric_address "$right_host" "$rail_a_interface" "$DEUCES_RIGHT_RAIL_A"
if [[ "$interface_count" == 2 ]]; then
  configure_fabric_address "$left_host" "$rail_b_interface" "$DEUCES_LEFT_RAIL_B"
  configure_fabric_address "$right_host" "$rail_b_interface" "$DEUCES_RIGHT_RAIL_B"
fi

remote "$left_host" \
  "ping -I '$rail_a_interface' -M do -s '$((target_mtu - 28))' -c 3 -W 2 '$right_address'" \
  >"$evidence_dir/rail-a-ping.txt"
if [[ "$interface_count" == 2 ]]; then
  remote "$left_host" \
    "ping -I '$rail_b_interface' -M do -s '$((target_mtu - 28))' -c 3 -W 2 '${DEUCES_RIGHT_RAIL_B%/*}'" \
    >"$evidence_dir/rail-b-ping.txt"
fi

add_peer_tcp_rule "$left_host" "$rail_a_interface" "${DEUCES_RIGHT_RAIL_A%/*}"
add_peer_tcp_rule "$right_host" "$rail_a_interface" "${DEUCES_LEFT_RAIL_A%/*}"
if [[ "$interface_count" == 2 ]]; then
  add_peer_tcp_rule "$left_host" "$rail_b_interface" "${DEUCES_RIGHT_RAIL_B%/*}"
  add_peer_tcp_rule "$right_host" "$rail_b_interface" "${DEUCES_LEFT_RAIL_B%/*}"
fi



if [[ "$owned_enabled" == 1 ]]; then
  owned_slots_launch || die 'owned container preparation/start failed'
else
remote "$left_host" \
  "sudo -n prlimit --pid \$\$ --memlock=unlimited; $left_quoted" \
  >"$evidence_dir/rank0-container-id.txt"
sleep 2
remote "$right_host" \
  "sudo -n prlimit --pid \$\$ --memlock=unlimited; $right_quoted" \
  >"$evidence_dir/rank1-container-id.txt"
fi

ready=0
started=$SECONDS
while (( SECONDS - started < startup_timeout )); do
  left_running=$(container_running "$left_host" "$left_container")
  right_running=$(container_running "$right_host" "$right_container")
  if [[ "$left_running" != true || "$right_running" != true ]]; then
    break
  fi
  if podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py ready "$served_model_id" \
    >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
    ready=1
    break
  fi
  sleep 5
done

container_logs "$left_host" "$left_container" >"$evidence_dir/rank0.log" 2>&1 || true
container_logs "$right_host" "$right_container" >"$evidence_dir/rank1.log" 2>&1 || true
(( ready == 1 )) || die 'the two-node vLLM endpoint did not become ready'

for tuple in "$left_host:$left_container:rank0" "$right_host:$right_container:rank1"; do
  host=${tuple%%:*}
  remainder=${tuple#*:}
  container=${remainder%%:*}
  label=${tuple##*:}
  [[ $(container_running "$host" "$container") == true ]] || \
    die "$label container stopped before acceptance"
  gpu_inventory "$host" >"$evidence_dir/$label-gpu-live.txt"
  [[ -s "$evidence_dir/$label-gpu-live.txt" ]] || die "$label had no live GPU process"
  podman_exec "$host" "$container" \
    python3 -c 'import importlib.metadata as m,json,os,torch,vllm; print(json.dumps({"vllm":vllm.__version__,"torch":torch.__version__,"torchCuda":torch.version.cuda,"containerCuda":os.environ.get("CUDA_VERSION"),"flashinfer":m.version("flashinfer-python"),"capability":list(torch.cuda.get_device_capability())}))' \
    >"$evidence_dir/$label-runtime.json"
  jq -e --arg version "$engine_version" --arg torchCuda "$expected_torch_cuda" \
    --arg containerCuda "$expected_container_cuda" --arg flashinfer "$expected_flashinfer" \
    '.vllm == $version and .torchCuda == $torchCuda and
     .containerCuda == $containerCuda and
     (($flashinfer == "") or .flashinfer == $flashinfer) and .capability == [12,1]' \
    "$evidence_dir/$label-runtime.json" >/dev/null
done

podman_exec "$left_host" "$left_container" \
  python3 /opt/gb10/model-openai-smoke.py completion "$served_model_id" \
  >"$evidence_dir/completion.json" 2>"$evidence_dir/completion.stderr"
jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' \
  "$evidence_dir/completion.json" >/dev/null
if [[ "$accept_hermes" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/hermes-openai-smoke.py "$served_model_id" \
    >"$evidence_dir/hermes.json" 2>"$evidence_dir/hermes.stderr"
  jq -e '
    .status == "pass" and .models_gate == "pass" and .chat_gate == "pass" and
    .tool_call_gate == "pass" and .tool_result_gate == "pass"
  ' "$evidence_dir/hermes.json" >/dev/null
fi
if [[ "$accept_streaming" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py stream "$served_model_id" \
    >"$evidence_dir/streaming.json" 2>"$evidence_dir/streaming.stderr"
  jq -e '.status == "pass" and .chunks > 0 and .done == true' \
    "$evidence_dir/streaming.json" >/dev/null
fi
if [[ "$accept_structured" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py structured "$served_model_id" \
    >"$evidence_dir/structured.json" 2>"$evidence_dir/structured.stderr"
  jq -e '.status == "pass" and .schema == "gb10_result" and .parsed == {status:"GB10_OK",count:10}' \
    "$evidence_dir/structured.json" >/dev/null
fi
if [[ "$accept_image" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py multimodal "$served_model_id" \
    >"$evidence_dir/image.json" 2>"$evidence_dir/image.stderr"
  jq -e '.status == "pass" and .modality == "image+text"' "$evidence_dir/image.json" >/dev/null
fi
if [[ "$accept_audio" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py audio "$served_model_id" \
    >"$evidence_dir/audio.json" 2>"$evidence_dir/audio.stderr"
  jq -e '.status == "pass" and .modality == "audio+text"' "$evidence_dir/audio.json" >/dev/null
fi
if (( stress_minimum_prompt_tokens > 0 )); then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-stress.py all "$served_model_id" \
      "$stress_minimum_prompt_tokens" "$stress_concurrency" \
    >"$evidence_dir/stress.json" 2>"$evidence_dir/stress.stderr"
  jq -e --argjson minimum "$stress_minimum_prompt_tokens" --argjson concurrency "$stress_concurrency" \
    '.status == "pass" and .longContext.minimumPromptTokens == $minimum and
     .longContext.observedPromptTokens >= $minimum and
     .concurrency.requests == $concurrency and
     (.concurrency.results | length) == $concurrency' "$evidence_dir/stress.json" >/dev/null
fi

cat "$evidence_dir/rank0.log" "$evidence_dir/rank1.log" >"$evidence_dir/combined.log"
grep -E 'NET/IB|Using network IB' "$evidence_dir/combined.log" >/dev/null
IFS=, read -r -a requested_hcas <<<"$nccl_ib_hca"
for requested_hca in "${requested_hcas[@]}"; do
  grep -F "${requested_hca%%:*}" "$evidence_dir/combined.log" >/dev/null
done

if [[ "$qualify_and_serve" == 1 ]]; then
  jq -n --arg result ready --arg profile "$profile" --arg model "$model_id" \
    --arg servedModel "$served_model_id" \
    --arg engine vllm --arg endpoint 'http://127.0.0.1:8000/v1' \
    --argjson maxSeconds "$serve_max_seconds" \
    '{result:$result,profile:$profile,model:$model,servedModel:$servedModel,engine:$engine,
      endpoint:$endpoint,loopbackOnly:true,qualifiedBeforeServe:true,
      maxSeconds:(if $maxSeconds == 0 then null else $maxSeconds end)}' \
    | tee "$evidence_dir/live-service.json"
  printf 'deuces_vllm_qualified_service=ready\n'
  printf 'Qualified API is live on rank 0 loopback; press Ctrl-C to stop and clean up.\n'
  serve_started=$SECONDS
  while :; do
    left_running=$(container_running "$left_host" "$left_container")
    right_running=$(container_running "$right_host" "$right_container")
    [[ "$left_running" == true && "$right_running" == true ]] || \
      die 'a qualified vLLM service container stopped unexpectedly'
    if (( serve_max_seconds > 0 && SECONDS - serve_started >= serve_max_seconds )); then
      printf 'Qualified service duration reached; cleaning up.\n'
      break
    fi
    sleep 10
  done
fi

cleanup
trap - EXIT INT TERM

for host in "$left_host" "$right_host"; do
  firewall_inventory "$host" >"$evidence_dir/$host-firewall-after.txt"
  gpu_inventory "$host" >"$evidence_dir/$host-gpu-after.txt"
  container_inventory "$host" >"$evidence_dir/$host-containers-after.txt"
  fabric_inventory "$host" >"$evidence_dir/$host-fabric-after.txt"
  diff -u "$evidence_dir/$host-firewall-before.txt" "$evidence_dir/$host-firewall-after.txt"
  diff -u "$evidence_dir/$host-gpu-before.txt" "$evidence_dir/$host-gpu-after.txt"
  diff -u "$evidence_dir/$host-containers-before.txt" "$evidence_dir/$host-containers-after.txt"
  diff -u "$evidence_dir/$host-fabric-before.txt" "$evidence_dir/$host-fabric-after.txt"
done

auxiliary_summary=null
if (( has_auxiliary_model == 1 )); then
  auxiliary_summary=$(jq -n \
    --slurpfile rank0 "$evidence_dir/rank0-auxiliary-preflight.json" \
    --slurpfile rank1 "$evidence_dir/rank1-auxiliary-preflight.json" \
    '{rank0:$rank0[0],rank1:$rank1[0]}')
fi

jq -n \
  --arg result pass \
  --arg topologyMode "$topology" \
  --arg interfaceCount "$interface_count" \
  --arg profile "$profile" \
  --arg model "$model_id" \
  --arg servedModel "$served_model_id" \
  --arg revision "$model_revision" \
  --arg engineVersion "$engine_version" \
  --arg torchCudaVersion "$expected_torch_cuda" \
  --arg containerCudaVersion "$expected_container_cuda" \
  --arg flashinferVersion "$expected_flashinfer" \
  --arg hostDriverVersion "$(jq -r '.driverVersion' "$evidence_dir/rank0-preflight.json")" \
  --arg image "$profile_image" \
  --arg ncclIbHca "$nccl_ib_hca" \
  --arg ncclIbGidIndex "$nccl_ib_gid_index" \
  --arg enforceEager "$enforce_eager" \
  --arg disableCustomAllReduce "$disable_custom_all_reduce" \
  --arg containerIpc "$container_ipc" \
  --arg containerShmSize "$container_shm_size" \
  --arg runtimeImageRef "$image" \
  --arg imageId "$(jq -r '.imageId' "$evidence_dir/rank0-preflight.json")" \
  --arg rootfsLayersSha256 "$(jq -r '.rootfsLayersSha256' "$evidence_dir/rank0-preflight.json")" \
  --arg weightTreeSha256 "$expected_weight_tree" \
  --argjson profileArguments "$(jq -c '.arguments' <<<"$profile_json")" \
  --argjson profileEnvironment "$(jq -c '.environment // {}' <<<"$profile_json")" \
  --argjson auxiliaryModel "$auxiliary_summary" \
  --argjson hermes "$accept_hermes" \
  --argjson streaming "$accept_streaming" \
  --argjson structuredOutputs "$accept_structured" \
  --argjson imageInput "$accept_image" \
  --argjson audioInput "$accept_audio" \
  --argjson stressMinimumPromptTokens "$stress_minimum_prompt_tokens" \
  --argjson stressConcurrency "$stress_concurrency" \
  --argjson rank0 "$(<"$evidence_dir/rank0-runtime.json")" \
  --argjson rank1 "$(<"$evidence_dir/rank1-runtime.json")" \
  '{
    result: $result,
    profile: $profile,
    model: $model,
    servedModel: $servedModel,
    modelRevision: $revision,
    weightTreeSha256: $weightTreeSha256,
    engine: "vllm",
    engineVersion: $engineVersion,
    torchCudaVersion: $torchCudaVersion,
    containerCudaVersion: $containerCudaVersion,
    flashinferVersion: (if $flashinferVersion == "" then null else $flashinferVersion end),
    hostDriverVersion: $hostDriverVersion,
    image: $image,
    runtimeImageRef: $runtimeImageRef,
    imageId: $imageId,
    rootfsLayersSha256: $rootfsLayersSha256,
    topology: {nodes:2,gpus:2,tensorParallelSize:2,executor:"mp",mode:$topologyMode,
      transport:(if $topologyMode == "direct" then
        (if $interfaceCount == "1" then "direct-QSFP56-single-cable-single-logical-interface" else "direct-QSFP56-single-cable-two-logical-interfaces" end)
        else "switched-QSFP-DD" end)},
    preservedProfileArguments: $profileArguments,
    preservedProfileEnvironment: $profileEnvironment,
    auxiliaryModel: $auxiliaryModel,
    topologySafetyFlags: (["headless-worker"] +
      (if $disableCustomAllReduce == "true" then ["disable-custom-all-reduce"] else [] end) +
      (if $enforceEager == "1" then ["enforce-eager"] else [] end)),
    eagerMode: ($enforceEager == "1"),
    containerIpc: $containerIpc,
    containerShmSize: $containerShmSize,
    runtime: [$rank0,$rank1],
    api: {
      loopbackOnly:true,
      repeatedCompletion:true,
      hermesContract:$hermes,
      streaming:$streaming,
      structuredOutputs:$structuredOutputs,
      imageInput:$imageInput,
      audioInput:$audioInput,
      stress:(if $stressMinimumPromptTokens > 0 then
        {unicodeIntegrity:true,minimumPromptTokens:$stressMinimumPromptTokens,
         concurrency:$stressConcurrency} else null end)
    },
    network: {transport:"NCCL NET/IB",physicalBoundary:(if $topologyMode == "direct" then "one-direct-QSFP56-cable" else "switched-QSFP-DD" end),logicalInterfaces:(if $topologyMode == "direct" then ($interfaceCount | tonumber) else null end),hcas:$ncclIbHca,gidIndex:$ncclIbGidIndex},
    storage: "identical-pinned-checkpoint-on-each-local-NVMe",
    cleanup: "temporary-test-firewall-containers-files-and-GPU-process-state-restored"
  }' | tee "$evidence_dir/summary.json"

printf 'deuces_vllm_acceptance=pass\n'
