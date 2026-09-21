#!/usr/bin/env bash
set -Eeuo pipefail

# Fail-closed two-node SGLang acceptance over an already-qualified persistent
# switched fabric. Checkpoints and the immutable ARM64 image must already be
# present on both nodes; this script never downloads or changes NixOS state.

die() {
  printf 'Deuces SGLang acceptance failed: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "missing required environment variable: $name"
}

profile_allows_topology() {
  local selected_topology=$1
  [[ "$selected_topology" == direct || "$selected_topology" == switch ]] || return 1
  jq -e --arg topology "$selected_topology" '
    if has("allowedTopologies") then
      .allowedTopologies | type=="array" and length>0 and
        all(.[]; .=="direct" or .=="switch") and
        (length == (unique|length)) and (index($topology)!=null)
    else true end' >/dev/null
}

arguments_for_topology() {
  local selected_topology=$1
  [[ "$selected_topology" == direct || "$selected_topology" == switch ]] || return 1
  jq -ce --arg topology "$selected_topology" '
    def argv:
      type == "array" and all(.[];
        type == "string" and length > 0 and
        (explode | all(. != 0 and . != 10 and . != 13)));
    def safe_argv:
      argv and
      ([.[] | select(startswith("--")) | split("=")[0]] |
        length == (unique | length)) and
      all(.[]; (split("=")[0]) as $flag |
        ["--tp", "--tp-size", "--tensor-parallel-size", "--nnodes",
         "--node-rank", "--dist-init-addr", "--host", "--port"] |
        index($flag) == null);
    def topologies:
      type == "object" and (keys | all(. == "direct" or . == "switch"));
    .arguments as $base |
    (if has("topologyArguments") then .topologyArguments else {} end) as $extra |
    (if has("topologyArgumentSets") then .topologyArgumentSets else {} end) as $sets |
    if ($base | safe_argv) and ($extra | topologies) and
       ($sets | topologies) and ($extra | all(.[]; safe_argv)) and
       ($sets | all(.[]; safe_argv and length > 0)) and
       ($sets | keys | all(. as $key | $extra | has($key) | not)) and
       ($extra | all(.[]; ($base + .) | safe_argv))
    then if ($sets | has($topology)) then $sets[$topology]
         else $base + ($extra[$topology] // []) end
    else error("invalid topology-specific argument contract") end |
    if safe_argv then . else error("profile overrides coordinator transport") end
  '
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
profile="${DEUCES_MODEL_PROFILE:-deepseek-v4-dspark-sglang}"
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
master_port="${DEUCES_SGLANG_MASTER_PORT:-29511}"
startup_timeout="${DEUCES_SGLANG_STARTUP_TIMEOUT_SECONDS:-1800}"
request_timeout="${DEUCES_SGLANG_REQUEST_TIMEOUT_SECONDS:-600}"
qualify_and_serve="${DEUCES_QUALIFY_AND_SERVE:-0}"
serve_max_seconds="${DEUCES_SERVE_MAX_SECONDS:-0}"
target_mtu="${DEUCES_MTU:-9000}"
nccl_ib_hca="${DEUCES_NCCL_IB_HCA:-mlx5_1:1,mlx5_3:1}"
nccl_ib_gid_index="${DEUCES_NCCL_IB_GID_INDEX:-3}"
nccl_socket_ifname="${DEUCES_NCCL_SOCKET_IFNAME:-$rail_a_interface,$rail_b_interface}"
ipc_mode="${DEUCES_SGLANG_IPC_MODE:-private}"
disable_custom_all_reduce="${DEUCES_SGLANG_DISABLE_CUSTOM_ALL_REDUCE:-0}"
start_order="${DEUCES_SGLANG_START_ORDER:-head-first}"
tp_socket_ifname="${DEUCES_TP_SOCKET_IFNAME:-}"
nccl_cumem_enable="${DEUCES_NCCL_CUMEM_ENABLE:-}"
nccl_nvls_enable="${DEUCES_NCCL_NVLS_ENABLE:-}"
nccl_cross_nic="${DEUCES_NCCL_CROSS_NIC:-}"
nccl_net_plugin="${DEUCES_NCCL_NET_PLUGIN:-}"
nccl_ib_disable="${DEUCES_NCCL_IB_DISABLE:-}"
nccl_net="${DEUCES_NCCL_NET:-}"
nccl_autodetect="${DEUCES_SGLANG_NCCL_AUTODETECT:-0}"
run_id="gb10sor-sglang-$(date -u +%Y%m%dT%H%M%SZ)-$$"
left_container="${run_id}-rank0"
right_container="${run_id}-rank1"
left_test="/tmp/${run_id}-model-openai-smoke.py"
left_hermes_test="/tmp/${run_id}-hermes-openai-smoke.py"
left_stress_test="/tmp/${run_id}-model-openai-stress.py"

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
profile_allows_topology "$topology" <<<"$profile_json" || \
  die 'profile does not allow the requested topology'
selected_arguments_json=$(arguments_for_topology "$topology" <<<"$profile_json") || \
  die 'invalid profile arguments for the selected topology'
engine=$(jq -r '.engine' <<<"$profile_json")
[[ "$engine" == sglang ]] || \
  die "profile $profile does not use SGLang"
model_id=$(jq -r '.modelId' <<<"$profile_json")
model_revision=$(jq -r '.modelRevision' <<<"$profile_json")
profile_image=$(jq -r '.image' <<<"$profile_json")
image="${DEUCES_SGLANG_IMAGE:-$profile_image}"
expected_image_id="${DEUCES_SGLANG_EXPECTED_IMAGE_ID:-}"
expected_layers_sha256="${DEUCES_SGLANG_EXPECTED_LAYERS_SHA256:-}"
engine_version=$(jq -r '.engineVersion' <<<"$profile_json")
engine_source_revision=$(jq -r '.engineSourceRevision // empty' <<<"$profile_json")
expected_torch_cuda=$(jq -r '.torchCudaVersion // empty' <<<"$profile_json")
expected_container_cuda=$(jq -r '.containerCudaVersion // empty' <<<"$profile_json")
expected_weight_count=$(jq -r '.weightFiles // empty' <<<"$profile_json")
expected_weight_bytes=$(jq -r '.weightBytes // empty' <<<"$profile_json")
expected_weight_tree=$(jq -r '.weightTreeSha256 // empty' <<<"$profile_json")
chat_template_relative_path=$(jq -r '.chatTemplate.relativePath // empty' <<<"$profile_json")
expected_chat_template_sha256=$(jq -r '.chatTemplate.sha256 // empty' <<<"$profile_json")
draft_model_id=$(jq -r '.speculative.modelId // empty' <<<"$profile_json")
draft_model_revision=$(jq -r '.speculative.modelRevision // empty' <<<"$profile_json")
draft_expected_weight_count=$(jq -r '.speculative.weightFiles // empty' <<<"$profile_json")
draft_expected_weight_bytes=$(jq -r '.speculative.weightBytes // empty' <<<"$profile_json")
draft_expected_weight_tree=$(jq -r '.speculative.weightTreeSha256 // empty' <<<"$profile_json")
accept_hermes=$(jq -r 'if (.acceptance | type) == "object" and (.acceptance | has("hermes")) then .acceptance.hermes else true end' <<<"$profile_json")
accept_streaming=$(jq -r '.acceptance.streaming // false' <<<"$profile_json")
accept_structured=$(jq -r '.acceptance.structuredOutputs // false' <<<"$profile_json")
accept_image=$(jq -r '.acceptance.imageInput // false' <<<"$profile_json")
accept_audio=$(jq -r '.acceptance.audioInput // false' <<<"$profile_json")
stress_minimum_prompt_tokens=$(jq -r '.acceptance.stress.minimumPromptTokens // 0' <<<"$profile_json")
stress_concurrency=$(jq -r '.acceptance.stress.concurrency // 0' <<<"$profile_json")
container_memory=$(jq -r '.container.memory // empty' <<<"$profile_json")
container_memory_swap=$(jq -r '.container.memorySwap // empty' <<<"$profile_json")

[[ "$profile_image" =~ @sha256:[0-9a-f]{64}$ ]] || die 'SGLang profile image must be digest pinned'
if [[ "$image" != "$profile_image" ]]; then
  [[ "$image" =~ ^localhost/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ ]] || \
    die 'a SGLang runtime override must be a localhost tag'
  [[ "$expected_image_id" =~ ^[0-9a-f]{64}$ && "$expected_layers_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die 'a local SGLang runtime tag requires exact image-ID and rootfs-layer hashes'
fi
[[ "$engine_source_revision" =~ ^[0-9a-f]{40}$ ]] || \
  die 'SGLang profile requires an exact engine source revision'
[[ -n "$expected_torch_cuda" && -n "$expected_container_cuda" ]] || \
  die 'SGLang profile requires explicit CUDA contracts'
[[ -n "$expected_weight_count" && -n "$expected_weight_bytes" && -n "$expected_weight_tree" ]] || \
  die 'SGLang profile requires a complete checkpoint contract'
if [[ -n "$chat_template_relative_path" || -n "$expected_chat_template_sha256" ]]; then
  [[ "$chat_template_relative_path" =~ ^[A-Za-z0-9._/-]+$ && "$chat_template_relative_path" != /* ]] || \
    die 'chat-template path must be a safe relative path'
  [[ "$expected_chat_template_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    die 'chat-template SHA-256 is invalid'
fi
left_draft_model_dir=''
right_draft_model_dir=''
if [[ -n "$draft_model_id" ]]; then
  require_env DEUCES_LEFT_DRAFT_MODEL_DIR
  require_env DEUCES_RIGHT_DRAFT_MODEL_DIR
  left_draft_model_dir="$DEUCES_LEFT_DRAFT_MODEL_DIR"
  right_draft_model_dir="$DEUCES_RIGHT_DRAFT_MODEL_DIR"
  [[ "$draft_model_revision" =~ ^[0-9a-f]{40}$ ]] || \
    die 'speculative draft requires an exact model revision'
  [[ -n "$draft_expected_weight_count" && -n "$draft_expected_weight_bytes" && -n "$draft_expected_weight_tree" ]] || \
    die 'speculative draft requires a complete checkpoint contract'
fi
for value in "$accept_hermes" "$accept_streaming" "$accept_structured" "$accept_image" "$accept_audio"; do
  [[ "$value" == true || "$value" == false ]] || die 'acceptance gates must be booleans'
done
[[ "$stress_minimum_prompt_tokens" =~ ^[0-9]+$ && "$stress_minimum_prompt_tokens" -le 65536 ]] || \
  die 'stress minimumPromptTokens must be 0..65536'
[[ "$stress_concurrency" =~ ^[0-9]+$ && "$stress_concurrency" -le 32 ]] || \
  die 'stress concurrency must be 0..32'
if (( stress_minimum_prompt_tokens > 0 || stress_concurrency > 0 )); then
  (( stress_minimum_prompt_tokens >= 1024 && stress_concurrency >= 1 )) || \
    die 'stress minimumPromptTokens and concurrency must both be enabled'
fi
if [[ -n "$container_memory" || -n "$container_memory_swap" ]]; then
  [[ "$container_memory" =~ ^[1-9][0-9]*[mMgG]$ ]] || die 'container memory limit is invalid'
  [[ "$container_memory_swap" =~ ^[1-9][0-9]*[mMgG]$ ]] || die 'container memory+swap limit is invalid'
fi
for value in "$left_model_dir" "$right_model_dir" "$left_draft_model_dir" "$right_draft_model_dir"; do
  [[ -z "$value" ]] && continue
  [[ "$value" =~ ^/[A-Za-z0-9._/@+-]+$ && "$value" != / ]] || \
    die "unsafe model path: $value"
done
fabric_interface_names=("$rail_a_interface")
if [[ "$interface_count" == 2 ]]; then
  fabric_interface_names+=("$rail_b_interface")
fi
for value in "${fabric_interface_names[@]}"; do
  [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "unsafe interface name: $value"
done
fabric_addresses=("$DEUCES_LEFT_RAIL_A" "$DEUCES_RIGHT_RAIL_A")
if [[ "$interface_count" == 2 ]]; then
  fabric_addresses+=("$DEUCES_LEFT_RAIL_B" "$DEUCES_RIGHT_RAIL_B")
fi
for value in "${fabric_addresses[@]}"; do
  [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || \
    die "fabric address is not an IPv4 CIDR: $value"
done
[[ "$master_port" =~ ^[0-9]+$ && "$master_port" -ge 1024 && "$master_port" -le 65535 ]] || \
  die 'DEUCES_SGLANG_MASTER_PORT must be 1024..65535'
[[ "$startup_timeout" =~ ^[1-9][0-9]*$ && "$startup_timeout" -le 3600 ]] || \
  die 'DEUCES_SGLANG_STARTUP_TIMEOUT_SECONDS must be 1..3600'
[[ "$request_timeout" =~ ^[1-9][0-9]*$ && "$request_timeout" -le 900 ]] || \
  die 'DEUCES_SGLANG_REQUEST_TIMEOUT_SECONDS must be 1..900'
[[ "$target_mtu" == 9000 ]] || die 'the reviewed switched profile requires MTU 9000'
[[ "$topology" == switch || "$topology" == direct ]] || \
  die 'DEUCES_TOPOLOGY must be switch or direct'
[[ "$nccl_ib_hca" =~ ^mlx5_[0-9]+:[0-9]+(,mlx5_[0-9]+:[0-9]+)*$ ]] || \
  die 'DEUCES_NCCL_IB_HCA must be a comma-separated mlx5_N:P list'
[[ "$nccl_socket_ifname" =~ ^[A-Za-z0-9_.:-]+(,[A-Za-z0-9_.:-]+)*$ ]] || \
  die 'DEUCES_NCCL_SOCKET_IFNAME must be a comma-separated interface list'
[[ "$ipc_mode" == private || "$ipc_mode" == host ]] || \
  die 'DEUCES_SGLANG_IPC_MODE must be private or host'
[[ "$disable_custom_all_reduce" == 0 || "$disable_custom_all_reduce" == 1 ]] || \
  die 'DEUCES_SGLANG_DISABLE_CUSTOM_ALL_REDUCE must be 0 or 1'
[[ "$nccl_autodetect" == 0 || "$nccl_autodetect" == 1 ]] || \
  die 'DEUCES_SGLANG_NCCL_AUTODETECT must be 0 or 1'
[[ "$start_order" == head-first || "$start_order" == worker-first ]] || \
  die 'DEUCES_SGLANG_START_ORDER must be head-first or worker-first'
if [[ -n "$tp_socket_ifname" ]]; then
  [[ "$tp_socket_ifname" =~ ^[A-Za-z0-9_.:-]+$ ]] || \
    die 'DEUCES_TP_SOCKET_IFNAME must be one interface name'
fi
for value in "$nccl_cumem_enable" "$nccl_nvls_enable" "$nccl_cross_nic" "$nccl_ib_disable"; do
  [[ -z "$value" || "$value" == 0 || "$value" == 1 ]] || \
    die 'optional NCCL diagnostic toggles must be 0 or 1'
done
[[ -z "$nccl_net_plugin" || "$nccl_net_plugin" == none ]] || \
  die 'DEUCES_NCCL_NET_PLUGIN currently permits only the reviewed value none'
[[ -z "$nccl_net" || "$nccl_net" == IB || "$nccl_net" == Socket ]] || \
  die 'DEUCES_NCCL_NET must be IB or Socket when set'
[[ "$nccl_ib_gid_index" =~ ^[0-9]+$ && "$nccl_ib_gid_index" -le 255 ]] || \
  die 'DEUCES_NCCL_IB_GID_INDEX must be 0..255'

if [[ -e "$evidence_dir" ]]; then
  [[ -d "$evidence_dir" && ! -L "$evidence_dir" ]] || \
    die "evidence path is not a non-symlink directory: $evidence_dir"
  [[ -z $(find "$evidence_dir" -mindepth 1 -print -quit) ]] || \
    die "evidence directory must be empty: $evidence_dir"
else
  mkdir -p -- "$evidence_dir"
fi
evidence_dir=$(cd "$evidence_dir" && pwd -P)

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ConnectionAttempts=3
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=6
)
scp_options=( -q -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=3 -o ServerAliveInterval=5 -o ServerAliveCountMax=6 )
if [[ -n "${DEUCES_SSH_IDENTITY_FILE:-}" ]]; then
  [[ -f "$DEUCES_SSH_IDENTITY_FILE" ]] || die 'SSH identity file is unreadable'
  ssh_options+=( -o IdentitiesOnly=yes -i "$DEUCES_SSH_IDENTITY_FILE" )
  scp_options+=( -o IdentitiesOnly=yes -i "$DEUCES_SSH_IDENTITY_FILE" )
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

gpu_inventory() {
  remote "$1" \
    "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits | LC_ALL=C sort"
}

container_inventory() {
  remote "$1" \
    "podman ps -a --no-trunc --format '{{.ID}} {{.Image}} {{.Status}}' | LC_ALL=C sort"
}

firewall_inventory() {
  remote "$1" 'sudo -n iptables -S'
}

fabric_inventory() {
  local interfaces="'$rail_a_interface'"
  [[ "$interface_count" == 1 ]] || interfaces+=" '$rail_b_interface'"
  remote "$1" "for interface in $interfaces; do
    ip -o -4 address show dev \"\$interface\"
    printf '%s mtu=' \"\$interface\"
    cat \"/sys/class/net/\$interface/mtu\"
    rdma link show | grep -F \"netdev \$interface\"
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
    hash_slot_add auxiliary rank0 "$left_host" "$left_auxiliary_model_dir" "$auxiliary_expected_tree" || return 1
    hash_slot_add auxiliary rank1 "$right_host" "$right_auxiliary_model_dir" "$auxiliary_expected_tree" || return 1
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
  local index hash_copy=scp
  [[ "${owned_enabled:-0}" != 1 ]] || hash_copy=owned_bounded_scp
  for ((index=0; index<${#hash_hosts[@]}; index++)); do
    hash_prepared[$index]=attempted
    printf '%s\tsetup-attempted\n' "$index" >>"$evidence_dir/weight-hash-setup.tsv" || return 1
    remote "${hash_hosts[$index]}" \
      "set -eu; umask 077; mkdir '${hash_states[$index]}'; printf '%s\\n' '${hash_tokens[$index]}' >'${hash_states[$index]}/owner'" || return 1
    "$hash_copy" "${scp_options[@]}" "$hash_helper" "${hash_hosts[$index]}:${hash_states[$index]}/hash.sh" || return 1
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
  local index failed=0 archive="$evidence_dir/weight-hash-state" hash_copy=scp stop_prefix=''
  if [[ "${owned_enabled:-0}" == 1 ]]; then
    hash_copy=owned_bounded_scp
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
    if "$hash_copy" "${scp_options[@]}" -r "${hash_hosts[$index]}:${hash_states[$index]}" "$archive/" \
      >"$evidence_dir/weight-hash-$index-archive.txt" 2>&1; then owned_hash_archive[$index]=0; else failed=1; fi
  done
  return "$failed"
}
# END bounded per-slot weight lifecycle.

# Explicit opt-in only; unlimited legacy serving is not lifecycle-qualified.
source "$repo_root/scripts/deuces-owned-adapter.sh"

firewall_hosts=()
firewall_rules=()

capture_final_container_state() {
  local host="$1" container="$2" label="$3"
  remote "$host" "podman inspect '$container'" \
    >"$evidence_dir/$label-final-inspect.json" \
    2>"$evidence_dir/$label-final-inspect.stderr" || true
  remote "$host" "podman logs '$container'" \
    >"$evidence_dir/$label-final.log" \
    2>"$evidence_dir/$label-final.stderr" || true
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
  capture_final_container_state "$left_host" "$left_container" rank0
  capture_final_container_state "$right_host" "$right_container" rank1
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
  remote "$left_host" "rm -f '$left_test' '$left_hermes_test' '$left_stress_test'" >/dev/null 2>&1 || true
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

preflight_node() {
  local host="$1" model_dir="$2" label="$3" rail_a="$4" rail_b="${5:-}"
  local observed_bytes observed_count observed_weight_bytes observed_tree revision_count
  local fstype gpu image_json image_id image_arch image_digest image_layers image_revision
  local observed_chat_template_sha256=''

  if [[ "$label" == rank0 ]]; then
    require_exact_deuces_profile "$host" "$DEUCES_LEFT_NODE" "$left_address"
  else
    require_exact_deuces_profile "$host" "$DEUCES_RIGHT_NODE" "$right_address"
  fi
  remote "$host" "ip -o -4 address show dev '$rail_a_interface' | awk '{print \$4}' | grep -Fqx '$rail_a'"
  local interfaces="'$rail_a_interface'"
  if [[ "$interface_count" == 2 ]]; then
    remote "$host" "ip -o -4 address show dev '$rail_b_interface' | awk '{print \$4}' | grep -Fqx '$rail_b'"
    interfaces+=" '$rail_b_interface'"
  fi
  remote "$host" "for interface in $interfaces; do
    test \"\$(cat /sys/class/net/\$interface/operstate)\" = up
    test \"\$(cat /sys/class/net/\$interface/mtu)\" = '$target_mtu'
    ethtool \"\$interface\" | grep -F 'Speed: 200000Mb/s'
    ethtool --show-fec \"\$interface\" | grep -F 'Active FEC encoding: RS'
    rdma link show | grep -F \"netdev \$interface\" | grep -F 'state ACTIVE' | grep -F 'physical_state LINK_UP'
  done" >"$evidence_dir/$label-fabric-gate.txt"

  remote "$host" \
    "test -r '$model_dir/config.json'; test -n \"\$(find '$model_dir' -type f -name '*.safetensors' -print -quit)\""
  fstype=$(remote "$host" "findmnt -T '$model_dir' -n -o FSTYPE | tail -n 1")
  case "$fstype" in
    *nfs*|*cifs*|*smb*|*fuse.sshfs*) die "$label checkpoint is not local" ;;
  esac
  observed_bytes=$(remote "$host" "du -sb --apparent-size '$model_dir' | awk '{print \$1}'")
  jq -e --argjson observed "$observed_bytes" \
    '(.modelBytesAllowed // [.modelBytes]) | index($observed) != null' \
    <<<"$profile_json" >/dev/null || die "$label model byte size changed"
  revision_count=$(remote "$host" \
    "count=0; resolved=\$(readlink -f '$model_dir'); case \"\${resolved##*/}\" in *.rev-'$model_revision') count=1 ;; esac; for marker in '$model_dir/.hf_revision' '$model_dir/.gb10sor-revision'; do if test -f \"\$marker\" && grep -Fqx '$model_revision' \"\$marker\"; then count=1; fi; done; if test -d '$model_dir/.cache/huggingface/download'; then extra=\$(find '$model_dir/.cache/huggingface/download' -type f -name '*.metadata' -exec sed -n '1p' {} + 2>/dev/null | grep -Fxc '$model_revision' || true); count=\$((count + extra)); fi; printf '%s\\n' \"\$count\"")
  [[ "$revision_count" -gt 0 ]] || die "$label checkpoint lacks the pinned revision marker"
  observed_count=$(remote "$host" "find '$model_dir' -type f -name '*.safetensors' | wc -l | tr -d ' '")
  [[ "$observed_count" == "$expected_weight_count" ]] || die "$label weight-file count changed"
  observed_weight_bytes=$(remote "$host" \
    "find '$model_dir' -type f -name '*.safetensors' -printf '%s\\n' | awk '{sum += \$1} END {print sum + 0}'")
  [[ "$observed_weight_bytes" == "$expected_weight_bytes" ]] || die "$label weight byte total changed"
  observed_tree=$(hash_slot_run target "$label" "$host" "$model_dir" "$expected_weight_tree")
  [[ "$observed_tree" == "$expected_weight_tree" ]] || die "$label weight-tree SHA-256 changed"
  if [[ -n "$chat_template_relative_path" ]]; then
    observed_chat_template_sha256=$(remote "$host" \
      "test -f '$model_dir/$chat_template_relative_path'; sha256sum '$model_dir/$chat_template_relative_path' | awk '{print \$1}'")
    [[ "$observed_chat_template_sha256" == "$expected_chat_template_sha256" ]] || \
      die "$label chat-template SHA-256 changed"
  fi
  gpu=$(remote "$host" 'nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader,nounits')
  [[ $(wc -l <<<"$gpu" | tr -d ' ') == 1 && "$gpu" == *12.1* ]] || \
    die "$label does not expose exactly one GB10-class GPU"
  [[ -z $(gpu_inventory "$host") ]] || die "$label already has a GPU workload"

  image_json=$(remote "$host" "podman image inspect '$image'")
  image_id=$(jq -er '.[0].Id' <<<"$image_json" | sed 's/^sha256://')
  image_arch=$(jq -er '.[0].Architecture' <<<"$image_json")
  image_digest=$(jq -er '.[0].Digest' <<<"$image_json")
  image_revision=$(jq -er '.[0].Labels["org.opencontainers.image.revision"]' <<<"$image_json")
  image_layers=$(jq -c '.[0].RootFS.Layers' <<<"$image_json" | sha256sum | awk '{print $1}')
  [[ "$image_id" =~ ^[0-9a-f]{64}$ && "$image_arch" == arm64 ]] || die "$label image identity failed"
  if [[ "$image" == "$profile_image" ]]; then
    [[ "$image_digest" == "${image##*@}" ]] || die "$label image digest changed"
  else
    [[ "$image_id" == "$expected_image_id" && "$image_layers" == "$expected_layers_sha256" ]] || \
      die "$label local image identity or rootfs layers changed"
  fi
  [[ "$image_revision" == "$engine_source_revision" ]] || die "$label image source revision changed"

  jq -n --arg label "$label" --arg storage "$fstype" --arg gpu "$gpu" \
    --arg imageId "$image_id" --arg imageDigest "$image_digest" \
    --arg imageLayersSha256 "$image_layers" --arg imageRevision "$image_revision" \
    --arg modelRevision "$model_revision" --arg weightTreeSha256 "$observed_tree" \
    --arg chatTemplateRelativePath "$chat_template_relative_path" \
    --arg chatTemplateSha256 "$observed_chat_template_sha256" \
    --argjson modelBytes "$observed_bytes" --argjson weightFiles "$observed_count" \
    --argjson weightBytes "$observed_weight_bytes" \
    '{label:$label,storage:$storage,gpu:$gpu,imageId:$imageId,imageDigest:$imageDigest,
      imageLayersSha256:$imageLayersSha256,imageRevision:$imageRevision,
      modelRevision:$modelRevision,modelBytes:$modelBytes,weightFiles:$weightFiles,
      weightBytes:$weightBytes,weightTreeSha256:$weightTreeSha256,
      chatTemplateRelativePath:$chatTemplateRelativePath,
      chatTemplateSha256:$chatTemplateSha256}' \
    >"$evidence_dir/$label-preflight.json"
}

preflight_draft_node() {
  local host="$1" model_dir="$2" label="$3"
  local fstype observed_count observed_weight_bytes observed_tree revision_count

  remote "$host" \
    "test -r '$model_dir/config.json'; test -n \"\$(find '$model_dir' -type f -name '*.safetensors' -print -quit)\""
  fstype=$(remote "$host" "findmnt -T '$model_dir' -n -o FSTYPE | tail -n 1")
  case "$fstype" in
    *nfs*|*cifs*|*smb*|*fuse.sshfs*) die "$label speculative draft is not local" ;;
  esac
  revision_count=$(remote "$host" \
    "count=0; resolved=\$(readlink -f '$model_dir'); case \"\${resolved##*/}\" in *.rev-'$draft_model_revision') count=1 ;; esac; for marker in '$model_dir/.hf_revision' '$model_dir/.gb10sor-revision'; do if test -f \"\$marker\" && grep -Fqx '$draft_model_revision' \"\$marker\"; then count=1; fi; done; printf '%s\n' \"\$count\"")
  [[ "$revision_count" -gt 0 ]] || die "$label speculative draft lacks the pinned revision marker"
  observed_count=$(remote "$host" "find '$model_dir' -type f -name '*.safetensors' | wc -l | tr -d ' '")
  [[ "$observed_count" == "$draft_expected_weight_count" ]] || \
    die "$label speculative draft weight-file count changed"
  observed_weight_bytes=$(remote "$host" \
    "find '$model_dir' -type f -name '*.safetensors' -printf '%s\n' | awk '{sum += \$1} END {print sum + 0}'")
  [[ "$observed_weight_bytes" == "$draft_expected_weight_bytes" ]] || \
    die "$label speculative draft weight byte total changed"
  observed_tree=$(hash_slot_run draft "$label" "$host" "$model_dir" "$draft_expected_weight_tree")
  [[ "$observed_tree" == "$draft_expected_weight_tree" ]] || \
    die "$label speculative draft weight-tree SHA-256 changed"
  jq -n --arg label "$label" --arg storage "$fstype" \
    --arg modelId "$draft_model_id" --arg modelRevision "$draft_model_revision" \
    --arg weightTreeSha256 "$observed_tree" --argjson weightFiles "$observed_count" \
    --argjson weightBytes "$observed_weight_bytes" \
    '{label:$label,storage:$storage,modelId:$modelId,modelRevision:$modelRevision,
      weightFiles:$weightFiles,weightBytes:$weightBytes,weightTreeSha256:$weightTreeSha256}' \
    >"$evidence_dir/$label-draft-preflight.json"
}

for host in "$left_host" "$right_host"; do
  remote "$host" 'sudo -n true'
  firewall_inventory "$host" >"$evidence_dir/$host-firewall-before.txt"
  gpu_inventory "$host" >"$evidence_dir/$host-gpu-before.txt"
  container_inventory "$host" >"$evidence_dir/$host-containers-before.txt"
  fabric_inventory "$host" >"$evidence_dir/$host-fabric-before.txt"
done

profile_args=()
while IFS= read -r argument; do profile_args+=( "$argument" ); done \
  < <(jq -r '.[]' <<<"$selected_arguments_json")
for argument in "${profile_args[@]}"; do
  case "$argument" in
    --tp|--tensor-parallel-size|--nnodes|--node-rank|--dist-init-addr|--host|--port)
      die "profile contains a conflicting Deuces transport flag: $argument" ;;
  esac
done
if [[ "$disable_custom_all_reduce" == 1 ]]; then
  profile_args+=( --disable-custom-all-reduce )
fi
effective_arguments_json=$(printf '%s\n' "${profile_args[@]}" | jq -Rsc 'split("\n")[:-1]')
jq -n --arg topology "$topology" --arg profile "$profile" \
  --argjson baseArguments "$(jq -c '.arguments' <<<"$profile_json")" \
  --argjson selectedArguments "$selected_arguments_json" \
  --argjson effectiveArguments "$effective_arguments_json" \
  '{topology:$topology,profile:$profile,baseArguments:$baseArguments,
    selectedArguments:$selectedArguments,effectiveArguments:$effectiveArguments}' \
  > "$evidence_dir/selected-arguments.json"
profile_environment_args=()
while IFS= read -r assignment; do
  name=${assignment%%=*}
  value=${assignment#*=}
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "unsafe profile environment key: $name"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "multiline profile environment: $name"
  profile_environment_args+=( -e "$name=$value" )
done < <(jq -r '(.environment // {}) | to_entries[] | "\(.key)=\(.value)"' <<<"$profile_json")

common_args=(
  --pull=never --network host
  --device nvidia.com/gpu=all --device /dev/infiniband:/dev/infiniband
  --ulimit memlock=-1:-1 --ulimit stack=67108864:67108864
  --pids-limit 8192 --cap-drop=all --security-opt=no-new-privileges --read-only
  --tmpfs /tmp:rw,nosuid,nodev,size=8g
  --tmpfs /root/.cache:rw,nosuid,nodev,size=12g
  --tmpfs /root/.config:rw,nosuid,nodev,size=64m
  --tmpfs /root/.tilelang:rw,nosuid,nodev,size=8g
  --tmpfs /root/.triton:rw,nosuid,nodev,size=4g
  -e HF_HUB_OFFLINE=1 -e HF_HUB_DISABLE_TELEMETRY=1
  -e TRANSFORMERS_OFFLINE=1 -e PIP_NO_INDEX=1 -e DO_NOT_TRACK=1
  -e "GB10SOR_OPENAI_TIMEOUT_SECONDS=$request_timeout"
  -e NCCL_DEBUG=INFO -e NCCL_DEBUG_SUBSYS=INIT,NET,COLL
  -e "GLOO_SOCKET_IFNAME=$rail_a_interface"
  --entrypoint python3
)
if [[ "$nccl_autodetect" == 0 ]]; then
  common_args+=(
    -e NCCL_IB_DISABLE=0
    -e "NCCL_IB_HCA=$nccl_ib_hca"
    -e "NCCL_IB_GID_INDEX=$nccl_ib_gid_index"
    -e "NCCL_SOCKET_IFNAME=$nccl_socket_ifname"
  )
fi
if [[ "$ipc_mode" == host ]]; then
  # The publisher's verified multi-node DGX Spark container boundary requires
  # host IPC and IPC_LOCK. Keep this opt-in because private IPC is the safer
  # default for profiles that do not need the expanded boundary.
  common_args+=( --ipc host --cap-add IPC_LOCK )
else
  common_args+=( --ipc private --shm-size 16g )
fi
if [[ -n "$container_memory" ]]; then
  common_args+=( --memory "$container_memory" --memory-swap "$container_memory_swap" )
fi
if (( ${#profile_environment_args[@]} > 0 )); then
  common_args+=( "${profile_environment_args[@]}" )
fi
[[ -n "$tp_socket_ifname" ]] && common_args+=( -e "TP_SOCKET_IFNAME=$tp_socket_ifname" )
[[ -n "$nccl_cumem_enable" ]] && common_args+=( -e "NCCL_CUMEM_ENABLE=$nccl_cumem_enable" )
[[ -n "$nccl_nvls_enable" ]] && common_args+=( -e "NCCL_NVLS_ENABLE=$nccl_nvls_enable" )
[[ -n "$nccl_cross_nic" ]] && common_args+=( -e "NCCL_CROSS_NIC=$nccl_cross_nic" )
[[ -n "$nccl_net_plugin" ]] && common_args+=( -e "NCCL_NET_PLUGIN=$nccl_net_plugin" )
[[ -n "$nccl_ib_disable" ]] && common_args+=( -e "NCCL_IB_DISABLE=$nccl_ib_disable" )
[[ -n "$nccl_net" ]] && common_args+=( -e "NCCL_NET=$nccl_net" )

quote_command() {
  local destination="$1"
  shift
  printf -v "$destination" '%q ' "$@"
}

left_mounts=( -v "$left_model_dir:/model:ro" )
right_mounts=( -v "$right_model_dir:/model:ro" )
if [[ -n "$draft_model_id" ]]; then
  left_mounts+=( -v "$left_draft_model_dir:/draft-model:ro" )
  right_mounts+=( -v "$right_draft_model_dir:/draft-model:ro" )
fi

left_command=(
  podman run -d --name "$left_container" "${common_args[@]}"
  -e "SGLANG_HOST_IP=$left_address"
  "${left_mounts[@]}"
  -v "$left_test:/opt/gb10/model-openai-smoke.py:ro"
  -v "$left_hermes_test:/opt/gb10/hermes-openai-smoke.py:ro"
  -v "$left_stress_test:/opt/gb10/model-openai-stress.py:ro"
  "$image" -m sglang.launch_server
  --model-path /model --host 127.0.0.1 --port 8000
  --tp 2 --nnodes 2 --node-rank 0 --dist-init-addr "$left_address:$master_port"
  "${profile_args[@]}"
)
right_command=(
  podman run -d --name "$right_container" "${common_args[@]}"
  -e "SGLANG_HOST_IP=$right_address"
  "${right_mounts[@]}"
  "$image" -m sglang.launch_server
  --model-path /model --host 127.0.0.1 --port 8000
  --tp 2 --nnodes 2 --node-rank 1 --dist-init-addr "$left_address:$master_port"
  "${profile_args[@]}"
)
quote_command left_quoted "${left_command[@]}"
quote_command right_quoted "${right_command[@]}"

owned_budget_preflight || die 'unsafe finite owned qualification budget'
hash_slots_init || die 'bounded weight-hash slot preparation failed'
if [[ "$owned_enabled" == 1 ]]; then
  owned_slots_declare || die 'owned declaration/preflight failed'
  owned_parent_ack || die 'missing, failed or stale parent declaration acknowledgement'
  hash_slots_prepare || die 'declared hash staging failed'
fi
preflight_node "$left_host" "$left_model_dir" rank0 "$DEUCES_LEFT_RAIL_A" "${DEUCES_LEFT_RAIL_B:-}" &
left_preflight_pid=$!
preflight_pids+=( "$left_preflight_pid" )
preflight_node "$right_host" "$right_model_dir" rank1 "$DEUCES_RIGHT_RAIL_A" "${DEUCES_RIGHT_RAIL_B:-}" &
right_preflight_pid=$!
preflight_pids+=( "$right_preflight_pid" )
left_preflight_status=0
right_preflight_status=0
wait "$left_preflight_pid" || left_preflight_status=$?
wait "$right_preflight_pid" || right_preflight_status=$?
(( left_preflight_status == 0 && right_preflight_status == 0 )) || die 'one or both preflights failed'
preflight_pids=()
jq -e -n --slurpfile rank0 "$evidence_dir/rank0-preflight.json" \
  --slurpfile rank1 "$evidence_dir/rank1-preflight.json" \
  '$rank0[0].modelRevision == $rank1[0].modelRevision and
   $rank0[0].weightFiles == $rank1[0].weightFiles and
   $rank0[0].weightBytes == $rank1[0].weightBytes and
   $rank0[0].weightTreeSha256 == $rank1[0].weightTreeSha256 and
   $rank0[0].chatTemplateSha256 == $rank1[0].chatTemplateSha256 and
   $rank0[0].imageId == $rank1[0].imageId and
   $rank0[0].imageLayersSha256 == $rank1[0].imageLayersSha256' >/dev/null
if [[ -n "$draft_model_id" ]]; then
  preflight_draft_node "$left_host" "$left_draft_model_dir" rank0
  preflight_draft_node "$right_host" "$right_draft_model_dir" rank1
  jq -e -n --slurpfile rank0 "$evidence_dir/rank0-draft-preflight.json" \
    --slurpfile rank1 "$evidence_dir/rank1-draft-preflight.json" \
    '$rank0[0].modelRevision == $rank1[0].modelRevision and
     $rank0[0].weightBytes == $rank1[0].weightBytes and
     $rank0[0].weightTreeSha256 == $rank1[0].weightTreeSha256' >/dev/null
fi

remote "$left_host" "ping -I '$rail_a_interface' -M do -s 8972 -c 3 -W 2 '$right_address'" \
  >"$evidence_dir/rail-a-ping.txt"
if [[ "$interface_count" == 2 ]]; then
  remote "$left_host" "ping -I '$rail_b_interface' -M do -s 8972 -c 3 -W 2 '${DEUCES_RIGHT_RAIL_B%/*}'" \
    >"$evidence_dir/rail-b-ping.txt"
fi

scp "${scp_options[@]}" "$repo_root/tests/model-openai-smoke.py" "$left_host:$left_test"
scp "${scp_options[@]}" "$repo_root/tests/hermes-openai-smoke.py" "$left_host:$left_hermes_test"
scp "${scp_options[@]}" "$repo_root/tests/model-openai-stress.py" "$left_host:$left_stress_test"
add_peer_tcp_rule "$left_host" "$rail_a_interface" "${DEUCES_RIGHT_RAIL_A%/*}"
add_peer_tcp_rule "$right_host" "$rail_a_interface" "${DEUCES_LEFT_RAIL_A%/*}"
if [[ "$interface_count" == 2 ]]; then
  add_peer_tcp_rule "$left_host" "$rail_b_interface" "${DEUCES_RIGHT_RAIL_B%/*}"
  add_peer_tcp_rule "$right_host" "$rail_b_interface" "${DEUCES_LEFT_RAIL_B%/*}"
fi


if [[ "$owned_enabled" == 1 ]]; then
  owned_slots_launch || die 'owned container preparation/start failed'
else
if [[ "$start_order" == worker-first ]]; then
  remote "$right_host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $right_quoted" \
    >"$evidence_dir/rank1-container-id.txt"
  sleep 2
  remote "$left_host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $left_quoted" \
    >"$evidence_dir/rank0-container-id.txt"
else
  remote "$left_host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $left_quoted" \
    >"$evidence_dir/rank0-container-id.txt"
  sleep 2
  remote "$right_host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $right_quoted" \
    >"$evidence_dir/rank1-container-id.txt"
fi
fi

podman_exec() {
  local host="$1" container="$2"
  shift 2
  if [[ "$owned_enabled" == 1 ]]; then owned_exec "$host" "$container" "$@"; return $?; fi
  local quoted
  printf -v quoted '%q ' podman exec "$container" "$@"
  remote "$host" "sudo -n prlimit --pid \$\$ --memlock=unlimited; $quoted"
}

ready=0
started=$SECONDS
while (( SECONDS - started < startup_timeout )); do
  left_running=$(container_running "$left_host" "$left_container")
  right_running=$(container_running "$right_host" "$right_container")
  if [[ "$left_running" != true || "$right_running" != true ]]; then break; fi
  if podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py ready "$model_id" \
    >"$evidence_dir/models.json" 2>"$evidence_dir/readiness.stderr"; then
    ready=1
    break
  fi
  sleep 5
done
container_logs "$left_host" "$left_container" >"$evidence_dir/rank0.log" 2>&1 || true
container_logs "$right_host" "$right_container" >"$evidence_dir/rank1.log" 2>&1 || true
(( ready == 1 )) || die 'the two-node SGLang endpoint did not become ready'

for tuple in "$left_host:$left_container:rank0" "$right_host:$right_container:rank1"; do
  host=${tuple%%:*}
  remainder=${tuple#*:}
  container=${remainder%%:*}
  label=${tuple##*:}
  [[ $(container_running "$host" "$container") == true ]] || \
    die "$label container stopped before acceptance"
  gpu_inventory "$host" >"$evidence_dir/$label-gpu-live.txt"
  [[ -s "$evidence_dir/$label-gpu-live.txt" ]] || die "$label had no live GPU process"
  podman_exec "$host" "$container" python3 -c \
    'import json,os,torch,sglang; print(json.dumps({"sglang":sglang.__version__,"torch":torch.__version__,"torchCuda":torch.version.cuda,"containerCuda":os.environ.get("CUDA_VERSION"),"capability":list(torch.cuda.get_device_capability())}))' \
    >"$evidence_dir/$label-runtime.json"
  jq -e --arg version "$engine_version" --arg torchCuda "$expected_torch_cuda" \
    --arg containerCuda "$expected_container_cuda" \
    '.sglang == $version and .torchCuda == $torchCuda and
     .containerCuda == $containerCuda and .capability == [12,1]' \
    "$evidence_dir/$label-runtime.json" >/dev/null
done

podman_exec "$left_host" "$left_container" \
  python3 /opt/gb10/model-openai-smoke.py completion "$model_id" \
  >"$evidence_dir/completion.json" 2>"$evidence_dir/completion.stderr"
jq -e '.status == "pass" and .attempts == 2 and (.responses | length == 2)' \
  "$evidence_dir/completion.json" >/dev/null
if [[ "$accept_hermes" == true ]]; then
  podman_exec "$left_host" "$left_container" python3 /opt/gb10/hermes-openai-smoke.py "$model_id" \
    >"$evidence_dir/hermes.json" 2>"$evidence_dir/hermes.stderr"
  jq -e '.status == "pass" and .models_gate == "pass" and .chat_gate == "pass" and
    .tool_call_gate == "pass" and .tool_result_gate == "pass"' "$evidence_dir/hermes.json" >/dev/null
fi
if [[ "$accept_streaming" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py stream "$model_id" \
    >"$evidence_dir/streaming.json" 2>"$evidence_dir/streaming.stderr"
  jq -e '.status == "pass" and .content == "GB10_STREAM_OK" and .done == true' \
    "$evidence_dir/streaming.json" >/dev/null
fi
if [[ "$accept_structured" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py structured "$model_id" \
    >"$evidence_dir/structured.json" 2>"$evidence_dir/structured.stderr"
  jq -e '.status == "pass" and .parsed == {status:"GB10_OK",count:10}' \
    "$evidence_dir/structured.json" >/dev/null
fi
if [[ "$accept_image" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py multimodal "$model_id" \
    >"$evidence_dir/image.json" 2>"$evidence_dir/image.stderr"
  jq -e '.status == "pass" and .modality == "image+text"' \
    "$evidence_dir/image.json" >/dev/null
fi
if [[ "$accept_audio" == true ]]; then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-smoke.py audio "$model_id" \
    >"$evidence_dir/audio.json" 2>"$evidence_dir/audio.stderr"
  jq -e '.status == "pass" and .modality == "audio+text"' \
    "$evidence_dir/audio.json" >/dev/null
fi
if (( stress_minimum_prompt_tokens > 0 )); then
  podman_exec "$left_host" "$left_container" \
    python3 /opt/gb10/model-openai-stress.py all "$model_id" "$stress_minimum_prompt_tokens" \
      "$stress_concurrency" \
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
    --arg engine sglang --arg endpoint 'http://127.0.0.1:8000/v1' \
    --argjson maxSeconds "$serve_max_seconds" \
    '{result:$result,profile:$profile,model:$model,engine:$engine,
      endpoint:$endpoint,loopbackOnly:true,qualifiedBeforeServe:true,
      maxSeconds:(if $maxSeconds == 0 then null else $maxSeconds end)}' \
    | tee "$evidence_dir/live-service.json"
  printf 'deuces_sglang_qualified_service=ready\n'
  printf 'Qualified API is live on rank 0 loopback; press Ctrl-C to stop and clean up.\n'
  serve_started=$SECONDS
  while :; do
    left_running=$(container_running "$left_host" "$left_container")
    right_running=$(container_running "$right_host" "$right_container")
    [[ "$left_running" == true && "$right_running" == true ]] || \
      die 'a qualified SGLang service container stopped unexpectedly'
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

jq -n --arg result pass --arg topologyMode "$topology" --arg interfaceCount "$interface_count" --arg profile "$profile" --arg model "$model_id" \
  --arg revision "$model_revision" --arg engineVersion "$engine_version" \
  --arg engineSourceRevision "$engine_source_revision" --arg image "$profile_image" \
  --arg runtimeImageRef "$image" \
  --arg imageId "$(jq -r '.imageId' "$evidence_dir/rank0-preflight.json")" \
  --arg rootfsLayersSha256 "$(jq -r '.imageLayersSha256' "$evidence_dir/rank0-preflight.json")" \
  --arg weightTreeSha256 "$expected_weight_tree" --arg ncclIbHca "$nccl_ib_hca" \
  --arg chatTemplateRelativePath "$chat_template_relative_path" \
  --arg chatTemplateSha256 "$expected_chat_template_sha256" \
  --arg ncclSocketIfname "$nccl_socket_ifname" \
  --arg tpSocketIfname "$tp_socket_ifname" \
  --arg ncclCumemEnable "$nccl_cumem_enable" \
  --arg ncclNvlsEnable "$nccl_nvls_enable" \
  --arg ncclCrossNic "$nccl_cross_nic" \
  --arg ncclNetPlugin "$nccl_net_plugin" \
  --arg ncclIbDisable "$nccl_ib_disable" \
  --arg ncclNet "$nccl_net" \
  --arg startOrder "$start_order" \
  --arg ipcMode "$ipc_mode" \
  --arg containerMemory "$container_memory" \
  --arg containerMemorySwap "$container_memory_swap" \
  --arg ncclAutodetect "$nccl_autodetect" \
  --argjson effectiveArguments "$effective_arguments_json" \
  --arg ncclIbGidIndex "$nccl_ib_gid_index" \
  --argjson profileArguments "$(jq -c '.arguments' <<<"$profile_json")" \
  --argjson hermes "$accept_hermes" --argjson streaming "$accept_streaming" \
  --argjson structuredOutputs "$accept_structured" \
  --argjson imageInput "$accept_image" --argjson audioInput "$accept_audio" \
  --argjson stressMinimumPromptTokens "$stress_minimum_prompt_tokens" \
  --argjson stressConcurrency "$stress_concurrency" \
  --argjson rank0 "$(<"$evidence_dir/rank0-runtime.json")" \
  --argjson rank1 "$(<"$evidence_dir/rank1-runtime.json")" \
  '{result:$result,profile:$profile,model:$model,modelRevision:$revision,
    weightTreeSha256:$weightTreeSha256,
    chatTemplate:{relativePath:$chatTemplateRelativePath,sha256:$chatTemplateSha256},
    engine:"sglang",engineVersion:$engineVersion,
    engineSourceRevision:$engineSourceRevision,image:$image,runtimeImageRef:$runtimeImageRef,imageId:$imageId,
    rootfsLayersSha256:$rootfsLayersSha256,
    topology:{nodes:2,gpus:2,tensorParallelSize:2,mode:$topologyMode,
      transport:(if $topologyMode == "direct" then
        (if $interfaceCount == "1" then "direct-QSFP56-single-cable-single-logical-interface" else "direct-QSFP56-single-cable-two-logical-interfaces" end)
        else "switched-QSFP-DD" end)},
    preservedProfileArguments:$profileArguments,effectiveArguments:$effectiveArguments,
    runtime:[$rank0,$rank1],
    api:{loopbackOnly:true,repeatedCompletion:true,hermesContract:$hermes,
      streaming:$streaming,structuredOutputs:$structuredOutputs,
      imageInput:$imageInput,audioInput:$audioInput,
      stress:(if $stressMinimumPromptTokens > 0 then
        {unicodeIntegrity:true,minimumPromptTokens:$stressMinimumPromptTokens,
         concurrency:$stressConcurrency} else null end)},
    network:{transport:"NCCL NET/IB",physicalBoundary:(if $topologyMode == "direct" then "one-direct-QSFP56-cable" else "switched-QSFP-DD" end),logicalInterfaces:(if $topologyMode == "direct" then ($interfaceCount | tonumber) else null end),hcas:$ncclIbHca,
      socketInterfaces:$ncclSocketIfname,gidIndex:$ncclIbGidIndex},
    diagnostics:{startOrder:$startOrder,tpSocketIfname:$tpSocketIfname,
      ncclCumemEnable:$ncclCumemEnable,ncclNvlsEnable:$ncclNvlsEnable,
      ncclCrossNic:$ncclCrossNic,ncclNetPlugin:$ncclNetPlugin,
      ncclIbDisable:$ncclIbDisable,ncclNet:$ncclNet},
    containerIsolation:{ipc:$ipcMode,capabilities:(if $ipcMode == "host" then ["IPC_LOCK"] else [] end),
      memory:$containerMemory,memorySwap:$containerMemorySwap},
    ncclAutodetect:($ncclAutodetect == "1"),
    storage:"identical-pinned-checkpoint-on-each-local-NVMe",
    cleanup:"temporary-firewall-containers-files-and-GPU-process-state-restored"}' \
  | tee "$evidence_dir/summary.json"

printf 'deuces_sglang_acceptance=pass\n'
