#!/usr/bin/env bash
set -Eeuo pipefail

# One-command coordinator for the eight-Spark switched model boundary. It does
# not change NixOS, download checkpoints, activate Ray, or expose the API
# beyond rank 0 loopback. The selected private inventory identifies the exact
# eight nodes, their two fabric rails, and the local-NVMe checkpoint path on
# each node.

die() {
  printf 'Eights-switch launcher failed: %s\n' "$*" >&2
  exit 1
}

mode="${1:-acceptance}"
profile="${GB10_MODEL_PROFILE:-}"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
evidence_root="${GB10_PRIVATE_EVIDENCE_ROOT:-$HOME/.local/state/gb10sor/private-evidence}"
config_file="${GB10_EIGHTS_SWITCH_CONFIG:-$HOME/.config/gb10sor/eights-switch.env}"

# The coordinator can spend many minutes verifying a large read-only model
# tree. Reject incomplete source staging before that expensive preflight.
for required_source in \
  scripts/eights-vllm-acceptance.sh \
  scripts/cluster-weight-hash-shared.sh \
  tests/model-openai-smoke.py \
  tests/hermes-openai-smoke.py \
  tests/model-openai-stress.py
do
  [[ -r "$repo_root/$required_source" ]] || die "required source is unreadable: $required_source"
done

[[ -r "$config_file" ]] || die "private switched-eights config is unreadable: $config_file"
# shellcheck disable=SC1090
source "$config_file"

case "$mode" in
  acceptance) export GB10_CLUSTER_QUALIFY_AND_SERVE=0 ;;
  qualify-and-serve) export GB10_CLUSTER_QUALIFY_AND_SERVE=1 ;;
  *) die 'mode must be acceptance or qualify-and-serve' ;;
esac

[[ -n "$profile" ]] || die 'GB10_MODEL_PROFILE is not set; use a eights-switch-* Nix shell'
[[ "$evidence_root" == /* && "$evidence_root" != / ]] || die 'private evidence root must be a safe absolute path'

case "$profile" in
  nemotron-ultra-eights-vllm022)
    inventory="${EIGHTS_NEMOTRON_ULTRA_INVENTORY_FILE:-}"
    default_tp=4
    default_pp=2
    default_enforce_eager=1
    ;;
  glm53-nvfp4-eights-vllm028-bounded16k)
    inventory="${EIGHTS_GLM53_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    default_enforce_eager=1
    ;;
  glm53-nvfp4-eights-sglang0519-bounded16k)
    inventory="${EIGHTS_GLM53_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    default_enforce_eager=1
    ;;
  inkling-full-eights-sglang0519)
    inventory="${EIGHTS_INKLING_FULL_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    default_enforce_eager=1
    ;;
  inkling-full-eights-vllm-pagedkv-candidate-v1)
    inventory="${EIGHTS_INKLING_FULL_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    # This pinned candidate uses compilation mode 0 and FULL_DECODE_ONLY
    # graphs; eager is a separate diagnostic, not the published candidate.
    default_enforce_eager=0
    ;;
  inkling-full-eights-vllm-pagedkv-nospec-candidate-v1)
    inventory="${EIGHTS_INKLING_FULL_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    default_enforce_eager=0
    ;;
  inkling-full-eights-vllm-stop-candidate-v1)
    inventory="${EIGHTS_INKLING_FULL_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    default_enforce_eager=0
    ;;
  kimi-k3-eights-custom)
    inventory="${EIGHTS_KIMI_K3_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    default_enforce_eager=1
    ;;
  deepseek-v41-flash-eights-vllm-boot10-candidate300k)
    inventory="${EIGHTS_DEEPSEEK_V41_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    # The inherited Boot-10 lane requires its exact CUDA-graph capture set.
    # Keep eager mode available as an explicit diagnostic override only.
    default_enforce_eager=0
    ;;
  nvidia-deepseek-v41-flash-nvfp4-eights-sglang-da64c5c-candidate16k)
    inventory="${EIGHTS_NVIDIA_DEEPSEEK_V41_INVENTORY_FILE:-}"
    default_tp=8
    default_pp=1
    default_enforce_eager=1
    ;;
  *)
    die "profile is not enabled for the switched-Eights boundary: $profile"
    ;;
esac

[[ "$inventory" == /* && "$inventory" != / && -r "$inventory" ]] || \
  die "the private inventory for $profile must be a readable safe absolute path"

for name in \
  EIGHTS_SSH_IDENTITY_FILE EIGHTS_SSH_KNOWN_HOSTS_FILE \
  EIGHTS_NCCL_IB_HCA EIGHTS_NCCL_IB_GID_INDEX EIGHTS_MTU \
  EIGHTS_VLLM_MASTER_PORT EIGHTS_VLLM_STARTUP_TIMEOUT_SECONDS \
  EIGHTS_VLLM_REQUEST_TIMEOUT_SECONDS EIGHTS_VLLM_ENFORCE_EAGER \
  EIGHTS_SERVE_MAX_SECONDS EIGHTS_SSH_CONNECT_TIMEOUT_SECONDS \
  EIGHTS_SSH_ATTEMPTS EIGHTS_WEIGHT_HASH_TIMEOUT_SECONDS \
  EIGHTS_TENSOR_PARALLEL_SIZE EIGHTS_PIPELINE_PARALLEL_SIZE \
  EIGHTS_STORAGE_MODE EIGHTS_SHARED_STORE_SOURCE \
  EIGHTS_HOST_BINDINGS_FILE
do
  # shellcheck disable=SC2163
  [[ -z "${!name:-}" ]] || export "$name"
done

[[ -n "${EIGHTS_SSH_IDENTITY_FILE:-}" && -f "$EIGHTS_SSH_IDENTITY_FILE" ]] || \
  die 'EIGHTS_SSH_IDENTITY_FILE must identify a readable dedicated key'
[[ -n "${EIGHTS_SSH_KNOWN_HOSTS_FILE:-}" && -f "$EIGHTS_SSH_KNOWN_HOSTS_FILE" ]] || \
  die 'EIGHTS_SSH_KNOWN_HOSTS_FILE must identify a readable pinned host-key file'
[[ -n "${EIGHTS_HOST_BINDINGS_FILE:-}" && -f "$EIGHTS_HOST_BINDINGS_FILE" ]] || \
  die 'EIGHTS_HOST_BINDINGS_FILE must identify a readable reviewed host binding'

export GB10_CLUSTER_INVENTORY_FILE="$inventory"
export GB10_CLUSTER_MODEL_PROFILE="$profile"
export GB10_CLUSTER_MODEL_PROFILE_REGISTRY="${EIGHTS_MODEL_PROFILE_REGISTRY:-${GB10_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}}"
[[ -r "$GB10_CLUSTER_MODEL_PROFILE_REGISTRY" ]] || die 'model profile registry is unreadable'
# Catch immutable-image and CUDA metadata omissions before eight-host fabric
# checks and the potentially long checkpoint-tree integrity read.
jq -e --arg profile "$profile" '
  .profiles[$profile] as $p |
  ($p.image | type == "string" and test("@sha256:[0-9a-f]{64}$")) and
  ($p.runtimeImageRef | type == "string" and
    (test("^sha256:[0-9a-f]{64}$") or test("@sha256:[0-9a-f]{64}$"))) and
  ($p.containerCudaVersion | type == "string" and test("^[0-9]+[.][0-9]+([.][0-9]+([.][0-9]+)?)?$"))
' "$GB10_CLUSTER_MODEL_PROFILE_REGISTRY" >/dev/null || \
  die 'profile must pin image, immutable runtime reference and container CUDA version'
export GB10_CLUSTER_SSH_IDENTITY_FILE="${EIGHTS_SSH_IDENTITY_FILE:-}"
export GB10_CLUSTER_SSH_KNOWN_HOSTS_FILE="${EIGHTS_SSH_KNOWN_HOSTS_FILE:-}"
export GB10_CLUSTER_NCCL_IB_HCA="${EIGHTS_NCCL_IB_HCA:-mlx5_1:1,mlx5_3:1}"
export GB10_CLUSTER_NCCL_IB_GID_INDEX="${EIGHTS_NCCL_IB_GID_INDEX:-3}"
export GB10_CLUSTER_MTU="${EIGHTS_MTU:-9000}"
export GB10_CLUSTER_VLLM_MASTER_PORT="${EIGHTS_VLLM_MASTER_PORT:-29601}"
export GB10_CLUSTER_VLLM_STARTUP_TIMEOUT_SECONDS="${EIGHTS_VLLM_STARTUP_TIMEOUT_SECONDS:-3600}"
export GB10_CLUSTER_VLLM_REQUEST_TIMEOUT_SECONDS="${EIGHTS_VLLM_REQUEST_TIMEOUT_SECONDS:-900}"
export GB10_CLUSTER_VLLM_ENFORCE_EAGER="${EIGHTS_VLLM_ENFORCE_EAGER:-$default_enforce_eager}"
export GB10_CLUSTER_SERVE_MAX_SECONDS="${EIGHTS_SERVE_MAX_SECONDS:-0}"
export GB10_CLUSTER_SSH_CONNECT_TIMEOUT_SECONDS="${EIGHTS_SSH_CONNECT_TIMEOUT_SECONDS:-45}"
export GB10_CLUSTER_SSH_ATTEMPTS="${EIGHTS_SSH_ATTEMPTS:-4}"
export GB10_CLUSTER_WEIGHT_HASH_TIMEOUT_SECONDS="${EIGHTS_WEIGHT_HASH_TIMEOUT_SECONDS:-7200}"
export GB10_CLUSTER_TENSOR_PARALLEL_SIZE="${EIGHTS_TENSOR_PARALLEL_SIZE:-$default_tp}"
export GB10_CLUSTER_PIPELINE_PARALLEL_SIZE="${EIGHTS_PIPELINE_PARALLEL_SIZE:-$default_pp}"
export GB10_CLUSTER_STORAGE_MODE="${EIGHTS_STORAGE_MODE:-local-nvme}"
export GB10_CLUSTER_SHARED_STORE_SOURCE="${EIGHTS_SHARED_STORE_SOURCE:-}"

run_id=$(date -u +%Y%m%dT%H%M%SZ)
export GB10_CLUSTER_EVIDENCE_DIR="${GB10_CLUSTER_EVIDENCE_DIR:-$evidence_root/eights-switch-$profile-$run_id}"

ssh_options=(
  -o BatchMode=yes -o "ConnectTimeout=${EIGHTS_SSH_CONNECT_TIMEOUT_SECONDS:-45}"
  -o ConnectionAttempts=3 -o IdentitiesOnly=yes
  -o ServerAliveInterval=10 -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$EIGHTS_SSH_KNOWN_HOSTS_FILE"
  -i "$EIGHTS_SSH_IDENTITY_FILE"
)
hosts=()
while IFS= read -r host; do
  [[ "$host" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "unsafe host in private inventory: $host"
  hosts+=("$host")
done < <(jq -r '.nodes[].host' "$inventory")
(( ${#hosts[@]} == 8 )) || die 'private Eights inventory must contain exactly eight hosts'

jq -e '.nodes | length == 8 and ([.[].host] | unique | length == 8)' \
  "$inventory" >/dev/null || die 'private Eights inventory must have eight distinct hosts'

# Keep coordinator receipts beside the model evidence: the inner harness
# requires its own evidence directory to be empty when it begins.
coordinator_evidence="${GB10_CLUSTER_EVIDENCE_DIR}-coordinator"
[[ "$coordinator_evidence" == /* && ! -e "$coordinator_evidence" && ! -L "$coordinator_evidence" ]] || \
  die 'coordinator evidence path must be a new absolute path'
mkdir -p -- "$(dirname "$coordinator_evidence")"
mkdir -m 700 -- "$coordinator_evidence"
jq -e . "$EIGHTS_HOST_BINDINGS_FILE" >"$coordinator_evidence/host-bindings.json" || \
  die 'Eights host binding is not valid JSON'
EIGHTS_HOST_BINDINGS_FILE="$coordinator_evidence/host-bindings.json"
if [[ "${EIGHTS_ALLOW_DECLARED_RAY_OFF:-0}" == 1 ]]; then
  [[ -r "${EIGHTS_RAY_OFF_ATTESTATIONS:-}" ]] || die "Explicit Ray-off mode requires a readable private attestation"
  jq -e . "$EIGHTS_RAY_OFF_ATTESTATIONS" >"$coordinator_evidence/ray-off-attestations.json" || die "Invalid Ray-off attestation JSON"
  # Freeze this proof's reviewed identities; cleanup must not accept an edited
  # source attestation after a model run has already started.
  EIGHTS_RAY_OFF_ATTESTATIONS="$coordinator_evidence/ray-off-attestations.json"
fi

# Bind the command to the exact reviewed machines, closures, ranks, roles and
# Eights profile before inspecting fabric or changing Ray. Similar-looking
# addressing from another topology must fail closed.
jq -e '.nodes | length == 8 and ([.[].host] | unique | length == 8) and
  ([.[].hostname] | unique | length == 8) and ([.[].rank] | sort == [0,1,2,3,4,5,6,7])' \
  "$EIGHTS_HOST_BINDINGS_FILE" >/dev/null || die 'Eights host binding must contain eight distinct reviewed ranks'
for index in "${!hosts[@]}"; do
  host=${hosts[$index]}
  binding=$(jq -ce --arg host "$host" '[.nodes[] | select(.host == $host)] | select(length == 1) | .[0]' \
    "$EIGHTS_HOST_BINDINGS_FILE") || die "missing unique host binding for $host"
  expected_hostname=$(jq -er '.hostname' <<<"$binding")
  expected_closure=$(jq -er '.systemClosure' <<<"$binding")
  expected_role=$(jq -er '.role' <<<"$binding")
  expected_rank=$(jq -er '.rank' <<<"$binding")
  [[ "$expected_hostname" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'unsafe expected hostname'
  [[ "$expected_closure" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-[A-Za-z0-9._-]+$ ]] || die 'unsafe expected system closure'
  [[ "$expected_role" == head || "$expected_role" == worker ]] || die 'unsafe expected Eights role'
  [[ "$expected_rank" == "$index" ]] || die "host binding rank mismatch for $host"
  (( index == 0 )) && [[ "$expected_role" == head ]] || {
    (( index != 0 )) && [[ "$expected_role" == worker ]] || die "host binding role mismatch for $host"
  }
  # Reviewed binding values are intentionally expanded by the coordinator.
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "$host" \
    "set -e
     test \"\$(hostname)\" = '$expected_hostname'
     test \"\$(readlink -f /run/current-system)\" = '$expected_closure'
     test \"\$(cat /sys/module/nvidia/version)\" = 595.84
     jq -e --arg name '$expected_hostname' --arg role '$expected_role' --arg host '$host' \
       '.profile == \"eight\" and .nodeName == \$name and .role == \$role and .fabricIp == \$host and .clusterNodeCount == 8' \
       /etc/gb10-cluster/cluster-profile.json >/dev/null" \
    >"$coordinator_evidence/rank$index-host-binding.txt" || \
    die "rank$index is not the exact reviewed prepared Eights host; no Ray service was changed"
done

# Both logical rails may share the switch's layer-2 domain. Default Linux ARP
# replies can advertise the wrong interface's MAC, which head-only pings miss.
# Inspect the declared profile and every directed pair without repairing it.
fabric_interfaces=("$(jq -r '.railAInterface' "$inventory")" "$(jq -r '.railBInterface' "$inventory")")
[[ "${fabric_interfaces[0]}" != "${fabric_interfaces[1]}" ]] || die 'fabric interfaces must be distinct'
for interface in "${fabric_interfaces[@]}"; do
  [[ "$interface" =~ ^[A-Za-z0-9_-]+$ ]] || die 'unsafe fabric interface'
done
fabric_addresses_a=()
fabric_addresses_b=()
for index in "${!hosts[@]}"; do
  for rail in A B; do
    cidr=$(jq -r ".nodes[$index].rail$rail" "$inventory")
    [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die 'unsafe fabric IPv4 CIDR'
    if [[ "$rail" == A ]]; then fabric_addresses_a+=("${cidr%/*}"); else fabric_addresses_b+=("${cidr%/*}"); fi
  done
done
for index in "${!hosts[@]}"; do
  for interface in "${fabric_interfaces[@]}"; do
    # The reviewed interface name is intentionally expanded by the coordinator.
    # shellcheck disable=SC2029
    ssh "${ssh_options[@]}" "${hosts[$index]}" \
      "test \"\$(sysctl -n 'net.ipv4.conf.$interface.arp_ignore')\" = 1 &&
       test \"\$(sysctl -n 'net.ipv4.conf.$interface.arp_announce')\" = 2 &&
       test \"\$(cat '/sys/class/net/$interface/mtu')\" = 9000 &&
       printf '%s arp_ignore=1 arp_announce=2 mtu=9000\\n' '$interface'" \
      >>"$coordinator_evidence/rank$index-fabric-profile.txt" || \
      die "rank$index fabric ARP/MTU profile is not ready; no Ray service was changed"
  done
done
for index in "${!hosts[@]}"; do
  for peer in "${!hosts[@]}"; do
    [[ "$index" != "$peer" ]] || continue
    for rail_index in 0 1; do
      interface=${fabric_interfaces[$rail_index]}
      if [[ "$rail_index" == 0 ]]; then
        source_address=${fabric_addresses_a[$index]}; destination=${fabric_addresses_a[$peer]}
      else
        source_address=${fabric_addresses_b[$index]}; destination=${fabric_addresses_b[$peer]}
      fi
      # Reviewed route values are intentionally expanded by the coordinator.
      # shellcheck disable=SC2029
      ssh "${ssh_options[@]}" "${hosts[$index]}" \
        "set -e
         ip -j -4 route get '$destination' from '$source_address' | jq -e \
           'length == 1 and .[0].dev == \"$interface\" and (.[0] | has(\"gateway\") | not)'
         ping -n -I '$interface' -c 2 -W 3 -M do -s 8972 '$destination'" \
        >"$coordinator_evidence/rank$index-peer$peer-rail$rail_index.txt" || \
        die "rank$index cannot reach rank$peer over rail$rail_index; no Ray service was changed"
    done
  done
done

declared_ray_off() {
  local host=$1 attestation name closure
  [[ "${EIGHTS_ALLOW_DECLARED_RAY_OFF:-0}" == 1 && -r "${EIGHTS_RAY_OFF_ATTESTATIONS:-}" ]] || return 1
  attestation=$(jq -ce --arg host "$host" '[.nodes[] | select(.host == $host)] | select(length == 1) | .[0]' "$EIGHTS_RAY_OFF_ATTESTATIONS") || return 1
  name=$(jq -er '.hostname' <<<"$attestation") || return 1
  closure=$(jq -er '.closure' <<<"$attestation") || return 1
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ && "$closure" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-[A-Za-z0-9._-]+$ ]] || return 1
  # Attested identity values are intentionally expanded by the coordinator.
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "$host" \
    "set -e
     test \"\$(hostname)\" = '$name'
     test \"\$(readlink -f /run/current-system)\" = '$closure'
     jq -e --arg name '$name' --arg host '$host' '.profile == \"off\" and .role == \"off\" and .nodeName == \$name and .fabricIp == \$host' /etc/gb10-cluster/cluster-profile.json >/dev/null
     for process in raylet gcs_server; do
       if pgrep -x \"\$process\" >/dev/null; then exit 1; else test \"\$?\" -eq 1; fi
     done" || return 1
}

ray_state() {
  local host=$1 output status
  if output=$(ssh "${ssh_options[@]}" "$host" \
    'systemctl show ray-cluster.service --property=LoadState --value && systemctl show ray-cluster.service --property=ActiveState --value'); then
    case "$output" in
      $'loaded\nactive') printf 'active\n' ;;
      $'loaded\ninactive') printf 'inactive\n' ;;
      $'not-found\ninactive')
        declared_ray_off "$host" || { printf 'Missing Ray unit lacks an exact declared-off attestation on %s.\n' "$host" >&2; return 1; }
        printf 'absent-off\n'
        ;;
      *) printf 'Unstable or missing Ray service on %s: %s\n' "$host" "$output" >&2; return 1 ;;
    esac
  else
    status=$?
    printf 'Cannot inspect Ray service on %s (SSH exit %s).\n' "$host" "$status" >&2
    return "$status"
  fi
}

# Observe every host before stopping any service. A transport failure must
# never be interpreted as an inactive Ray baseline.
ray_before=()
ray_touched=()
printf 'host\tstate\n' >"$coordinator_evidence/ray-before.tsv"
for host in "${hosts[@]}"; do
  state=$(ray_state "$host") || die "Ray preflight failed on $host; no service was changed"
  ray_before+=("$state")
  ray_touched+=(no)
  printf '%s\t%s\n' "$host" "$state" >>"$coordinator_evidence/ray-before.tsv"
done

for index in "${!hosts[@]}"; do
  [[ "${ray_before[$index]}" == active ]] || \
    die "Eights requires active Ray on all eight reviewed ranks before model launch"
done

ray_cluster_snapshot() {
  local output=$1 attempts=${2:-1} attempt
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if ssh "${ssh_options[@]}" "${hosts[0]}" \
      "/run/current-system/sw/bin/python - <<'PY'
import json
import ray
ray.init(address='auto')
nodes = [node for node in ray.nodes() if node.get('Alive')]
resources = ray.cluster_resources()
result = {
    'alive_nodes': len(nodes),
    'CPU': resources.get('CPU'),
    'GPU': resources.get('GPU'),
    'nodes': sorted(node['NodeManagerAddress'] for node in nodes),
}
ray.shutdown()
assert result['alive_nodes'] == 8, result
assert result['CPU'] == 160.0, result
assert result['GPU'] == 8.0, result
print(json.dumps(result, sort_keys=True))
PY" >"$output" 2>"$output.stderr"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ray_cluster_snapshot "$coordinator_evidence/ray-cluster-before.json" 3 || \
  die 'Ray services are active but the reviewed 8-node/160-CPU/8-GPU cluster is not converged'

restored=0
restore_status=0
restore_ray() {
  local index observed
  (( restored == 0 )) || return "$restore_status"
  restored=1
  for index in "${!hosts[@]}"; do
    if [[ "${ray_touched[$index]}" == yes ]]; then
      if ! ssh "${ssh_options[@]}" "${hosts[$index]}" \
        'sudo -n systemctl start ray-cluster.service'; then
        restore_status=1
      fi
    fi
  done
  printf 'host\tstate\n' >"$coordinator_evidence/ray-after.tsv"
  for index in "${!hosts[@]}"; do
    if observed=$(ray_state "${hosts[$index]}"); then
      [[ "$observed" == "${ray_before[$index]}" ]] || restore_status=1
    else
      observed=unverified
      restore_status=1
    fi
    printf '%s\t%s\n' "${hosts[$index]}" "$observed" >>"$coordinator_evidence/ray-after.tsv"
  done
  if (( restore_status == 0 )); then
    ray_cluster_snapshot "$coordinator_evidence/ray-cluster-after.json" 30 || restore_status=1
  fi
  return "$restore_status"
}
on_exit() {
  local model_status=$? exit_status restore_result=pass
  trap - EXIT
  exit_status=$model_status
  if ! restore_ray; then
    restore_result=fail
    (( exit_status != 0 )) || exit_status=1
  fi
  jq -n --arg rayRestoration "$restore_result" --argjson modelExit "$model_status" \
    --argjson exitStatus "$exit_status" \
    '{result:(if $exitStatus == 0 then "pass" else "fail" end),
      modelExit:$modelExit,rayRestoration:$rayRestoration,exitStatus:$exitStatus}' \
    >"$coordinator_evidence/result.json" || exit_status=1
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for index in "${!hosts[@]}"; do
  if [[ "${ray_before[$index]}" == active ]]; then
    # Mark before the request: SSH could drop after the remote stop succeeded.
    ray_touched[index]=yes
    ssh "${ssh_options[@]}" "${hosts[$index]}" 'sudo -n systemctl stop ray-cluster.service'
  fi
done

"$repo_root/scripts/eights-vllm-acceptance.sh"
