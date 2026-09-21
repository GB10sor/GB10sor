#!/usr/bin/env bash
set -Eeuo pipefail

# One-command coordinator for the independently reviewed four-Spark switched
# large-model boundary. It does
# not change NixOS, download checkpoints, activate Ray, or expose the API
# beyond rank 0 loopback. The selected private inventory identifies the exact
# four nodes, their two fabric rails, and either an independently verified
# local-NVMe path per node or one exact read-only shared checkpoint source.

die() {
  printf 'Quads-switch launcher failed: %s\n' "$*" >&2
  exit 1
}

mode="${1:-acceptance}"
profile="${GB10_MODEL_PROFILE:-}"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
evidence_root="${GB10_PRIVATE_EVIDENCE_ROOT:-$HOME/.local/state/gb10sor/private-evidence}"
config_file="${GB10_QUADS_SWITCH_CONFIG:-$HOME/.config/gb10sor/quads-switch.env}"
expected_node_count=4
expected_topology=quads

[[ -r "$config_file" ]] || die "private switched-topology config is unreadable: $config_file"
# shellcheck disable=SC1090
source "$config_file"

case "$mode" in
  acceptance) export GB10_CLUSTER_QUALIFY_AND_SERVE=0 ;;
  qualify-and-serve) export GB10_CLUSTER_QUALIFY_AND_SERVE=1 ;;
  *) die 'mode must be acceptance or qualify-and-serve' ;;
esac

[[ -n "$profile" ]] || die 'GB10_MODEL_PROFILE is not set; use a quads-switch-* Nix shell'
[[ "$evidence_root" == /* && "$evidence_root" != / ]] || die 'private evidence root must be a safe absolute path'

case "$profile" in
  minimax-m3-nvfp4-quads-v028-bounded16k)
    inventory="${QUADS_MINIMAX_M3_INVENTORY_FILE:-}"
    profile_enforce_eager="${QUADS_VLLM_ENFORCE_EAGER:-1}"
    ;;
  nemotron-ultra-quads-vllm022-bounded16k)
    inventory="${QUADS_NEMOTRON_ULTRA_INVENTORY_FILE:-}"
    profile_enforce_eager="${QUADS_VLLM_ENFORCE_EAGER:-1}"
    ;;
  glm53-nvfp4-quads-vllm028-bounded8k)
    inventory="${QUADS_GLM53_NVFP4_INVENTORY_FILE:-}"
    profile_enforce_eager="${QUADS_VLLM_ENFORCE_EAGER:-1}"
    ;;
  nvidia-glm53-flash-nvfp4-quads-vllm0281-bounded32k)
    inventory="${QUADS_NVIDIA_GLM53_FLASH_INVENTORY_FILE:-}"
    profile_enforce_eager="${QUADS_VLLM_ENFORCE_EAGER:-1}"
    ;;
  deepseek-v41-flash-quads-vllm-boot10-candidate300k|deepseek-v41-flash-whitehat-derived-quads-vllm-boot10-bounded32k)
    inventory="${QUADS_DEEPSEEK_V41_INVENTORY_FILE:-}"
    # The measured Boot-10 lane is a graph-mode recipe.  The shared private
    # Quads config defaults older conservative profiles to eager mode, so keep
    # this model-specific default separate.  An explicit experiment can still
    # opt back into eager mode without changing the publishable command.
    profile_enforce_eager="${QUADS_DEEPSEEK_V41_ENFORCE_EAGER:-0}"
    ;;
  blackfrost-glm53-flash-nvfp4-trips-switch-bounded32k)
    inventory="${TRIPS_BLACKFROST_INVENTORY_FILE:-}"
    profile_enforce_eager=1
    expected_node_count=3
    expected_topology=trips
    ;;
  *)
    die "profile is not enabled for the reviewed switched-topology boundary: $profile"
    ;;
esac

[[ "$profile_enforce_eager" == 0 || "$profile_enforce_eager" == 1 ]] || \
  die 'the selected profile enforce-eager value must be 0 or 1'

case "${QUADS_STORAGE_MODE:-local-nvme}" in
  local-nvme)
    [[ -z "${QUADS_SHARED_STORE_SOURCE:-}" ]] || \
      die 'QUADS_SHARED_STORE_SOURCE must be empty in local-NVMe mode'
    ;;
  read-only-shared)
    [[ -n "${QUADS_SHARED_STORE_SOURCE:-}" && "${QUADS_SHARED_STORE_SOURCE}" != *[[:space:]]* ]] || \
      die 'read-only shared mode requires an exact, whitespace-free QUADS_SHARED_STORE_SOURCE'
    ;;
  *) die 'QUADS_STORAGE_MODE must be local-nvme or read-only-shared' ;;
esac
export GB10_CLUSTER_STORAGE_MODE="${QUADS_STORAGE_MODE:-local-nvme}"
export GB10_CLUSTER_SHARED_STORE_SOURCE="${QUADS_SHARED_STORE_SOURCE:-}"

[[ "$inventory" == /* && "$inventory" != / && -r "$inventory" ]] || \
  die "the private inventory for $profile must be a readable safe absolute path"

for name in \
  QUADS_SSH_IDENTITY_FILE QUADS_SSH_KNOWN_HOSTS_FILE \
  QUADS_NCCL_IB_HCA QUADS_NCCL_IB_GID_INDEX QUADS_MTU \
  QUADS_VLLM_MASTER_PORT QUADS_VLLM_STARTUP_TIMEOUT_SECONDS \
  QUADS_VLLM_REQUEST_TIMEOUT_SECONDS QUADS_VLLM_ENFORCE_EAGER \
  QUADS_SERVE_MAX_SECONDS QUADS_SSH_CONNECT_TIMEOUT_SECONDS \
  QUADS_SSH_ATTEMPTS QUADS_WEIGHT_HASH_TIMEOUT_SECONDS \
  QUADS_STORAGE_MODE QUADS_SHARED_STORE_SOURCE
do
  # shellcheck disable=SC2163
  [[ -z "${!name:-}" ]] || export "$name"
done

[[ -n "${QUADS_SSH_IDENTITY_FILE:-}" && -f "$QUADS_SSH_IDENTITY_FILE" ]] || \
  die 'QUADS_SSH_IDENTITY_FILE must identify a readable dedicated key'
[[ -n "${QUADS_SSH_KNOWN_HOSTS_FILE:-}" && -f "$QUADS_SSH_KNOWN_HOSTS_FILE" ]] || \
  die 'QUADS_SSH_KNOWN_HOSTS_FILE must identify a readable pinned host-key file'

export GB10_CLUSTER_INVENTORY_FILE="$inventory"
export GB10_CLUSTER_MODEL_PROFILE="$profile"
export GB10_CLUSTER_MODEL_PROFILE_REGISTRY="${QUADS_MODEL_PROFILE_REGISTRY:-${GB10_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}}"
export GB10_CLUSTER_SSH_IDENTITY_FILE="${QUADS_SSH_IDENTITY_FILE:-}"
export GB10_CLUSTER_SSH_KNOWN_HOSTS_FILE="${QUADS_SSH_KNOWN_HOSTS_FILE:-}"
export GB10_CLUSTER_NCCL_IB_HCA="${QUADS_NCCL_IB_HCA:-mlx5_1:1,mlx5_3:1}"
export GB10_CLUSTER_NCCL_IB_GID_INDEX="${QUADS_NCCL_IB_GID_INDEX:-3}"
export GB10_CLUSTER_MTU="${QUADS_MTU:-9000}"
export GB10_CLUSTER_VLLM_MASTER_PORT="${QUADS_VLLM_MASTER_PORT:-29601}"
export GB10_CLUSTER_VLLM_STARTUP_TIMEOUT_SECONDS="${QUADS_VLLM_STARTUP_TIMEOUT_SECONDS:-3600}"
export GB10_CLUSTER_VLLM_REQUEST_TIMEOUT_SECONDS="${QUADS_VLLM_REQUEST_TIMEOUT_SECONDS:-900}"
export GB10_CLUSTER_VLLM_ENFORCE_EAGER="$profile_enforce_eager"
export GB10_CLUSTER_SERVE_MAX_SECONDS="${QUADS_SERVE_MAX_SECONDS:-0}"
export GB10_CLUSTER_SSH_CONNECT_TIMEOUT_SECONDS="${QUADS_SSH_CONNECT_TIMEOUT_SECONDS:-45}"
export GB10_CLUSTER_SSH_ATTEMPTS="${QUADS_SSH_ATTEMPTS:-4}"
export GB10_CLUSTER_WEIGHT_HASH_TIMEOUT_SECONDS="${QUADS_WEIGHT_HASH_TIMEOUT_SECONDS:-7200}"

run_id=$(date -u +%Y%m%dT%H%M%SZ)
export GB10_CLUSTER_EVIDENCE_DIR="${GB10_CLUSTER_EVIDENCE_DIR:-$evidence_root/$expected_topology-switch-$profile-$run_id}"

ssh_options=(
  -o BatchMode=yes -o "ConnectTimeout=${QUADS_SSH_CONNECT_TIMEOUT_SECONDS:-45}"
  -o ConnectionAttempts=3 -o IdentitiesOnly=yes
  -o ServerAliveInterval=10 -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$QUADS_SSH_KNOWN_HOSTS_FILE"
  -i "$QUADS_SSH_IDENTITY_FILE"
)
hosts=()
while IFS= read -r host; do
  [[ "$host" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "unsafe host in private inventory: $host"
  hosts+=("$host")
done < <(jq -r '.nodes[].host' "$inventory")
(( ${#hosts[@]} == expected_node_count )) || \
  die "private $expected_topology inventory must contain exactly $expected_node_count hosts"

jq -e --argjson count "$expected_node_count" --arg topology "$expected_topology" \
  '.topology == $topology and (.nodes | length) == $count and ([.nodes[].host] | unique | length) == $count' \
  "$inventory" >/dev/null || \
  die "private $expected_topology inventory must have $expected_node_count distinct hosts"

# Keep coordinator receipts beside the model evidence: the inner harness
# requires its own evidence directory to be empty when it begins.
coordinator_evidence="${GB10_CLUSTER_EVIDENCE_DIR}-coordinator"
[[ "$coordinator_evidence" == /* && ! -e "$coordinator_evidence" && ! -L "$coordinator_evidence" ]] || \
  die 'coordinator evidence path must be a new absolute path'
mkdir -p -- "$(dirname "$coordinator_evidence")"
mkdir -m 700 -- "$coordinator_evidence"
if [[ "${QUADS_ALLOW_DECLARED_RAY_OFF:-0}" == 1 ]]; then
  [[ -r "${QUADS_RAY_OFF_ATTESTATIONS:-}" ]] || die "Explicit Ray-off mode requires a readable private attestation"
  jq -e . "$QUADS_RAY_OFF_ATTESTATIONS" >"$coordinator_evidence/ray-off-attestations.json" || die "Invalid Ray-off attestation JSON"
  # Freeze this proof's reviewed identities; cleanup must not accept an edited
  # source attestation after a model run has already started.
  QUADS_RAY_OFF_ATTESTATIONS="$coordinator_evidence/ray-off-attestations.json"
fi

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
    # Reviewed interface names are intentionally expanded by the coordinator.
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
  [[ "${QUADS_ALLOW_DECLARED_RAY_OFF:-0}" == 1 && -r "${QUADS_RAY_OFF_ATTESTATIONS:-}" ]] || return 1
  attestation=$(jq -ce --arg host "$host" '[.nodes[] | select(.host == $host)] | select(length == 1) | .[0]' "$QUADS_RAY_OFF_ATTESTATIONS") || return 1
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

restored=0
restore_status=0
model_cleanup_status=0
wait_for_model_cleanup() {
  local attempt index host container_id clean
  for attempt in $(seq 1 60); do
    clean=1
    for index in "${!hosts[@]}"; do
      host=${hosts[$index]}
      if [[ -f "${GB10_CLUSTER_EVIDENCE_DIR}/rank${index}-container-id.txt" ]]; then
        container_id=$(<"${GB10_CLUSTER_EVIDENCE_DIR}/rank${index}-container-id.txt")
        [[ "$container_id" =~ ^[0-9a-f]{64}$ ]] || return 1
        if ssh "${ssh_options[@]}" "$host" \
          "podman inspect '$container_id' >/dev/null 2>&1 || sudo -n podman inspect '$container_id' >/dev/null 2>&1 || docker inspect '$container_id' >/dev/null 2>&1"; then
          clean=0
        fi
      fi
      if ! ssh "${ssh_options[@]}" "$host" \
        'gpu_jobs=$(timeout 10 nvidia-smi --query-compute-apps=pid --format=csv,noheader) && test -z "$gpu_jobs"'; then
        clean=0
      fi
    done
    if (( clean == 1 )); then
      printf 'owned containers absent and GPU inventory empty\n' >"$coordinator_evidence/model-cleanup-gate.txt"
      return 0
    fi
    sleep 5
  done
  printf 'owned container or GPU process remains after five minutes\n' >"$coordinator_evidence/model-cleanup-gate.txt"
  return 1
}
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
  # A Ray unit can report active briefly and then enter auto-restart when its
  # session has exhausted numbered log filenames. Observe a stable baseline
  # before recording restoration as passed.
  sleep 20
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
  return "$restore_status"
}
on_exit() {
  local model_status=$? exit_status restore_result=pass
  trap - EXIT HUP INT TERM
  exit_status=$model_status
  if (( model_status == 0 )) && ! jq -e '.result == "pass"' \
    "${GB10_CLUSTER_EVIDENCE_DIR}/summary.json" >/dev/null 2>&1; then
    model_status=1
    exit_status=1
  fi
  if ! wait_for_model_cleanup; then
    model_cleanup_status=1
    restore_result=deferred-until-model-cleanup
    exit_status=1
  elif ! restore_ray; then
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
