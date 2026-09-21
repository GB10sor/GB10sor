#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'Deuces-direct launcher failed: %s\n' "$*" >&2
  exit 1
}

mode="${1:-acceptance}"
profile="${GB10_MODEL_PROFILE:-}"
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
evidence_root="${GB10_PRIVATE_EVIDENCE_ROOT:-$HOME/.local/state/gb10sor/private-evidence}"
# Candidate mode retains the temporary-profile guard/cleanup path. Normal
# qualify-and-serve uses the durable owned controller for every explicitly
# reviewed direct profile.
candidate_mode=0
if [[ "$mode" == candidate-qualify-and-serve ]]; then
  candidate_mode=1
  mode=qualify-and-serve
  case "$profile" in
    qwen38-flash-next-direct-bounded|qwen38-flash-next-nvidia-vllm|deepseek-v4-sglang-target-only|deepseek-v4-nvidia-anemll-vllm|deepseek-v4-flash-0731-nvidia-vllm|deepseek-v4-flash-0731-nvidia-v028|deepseek-v41-flash-exl3-29bpw|inkling-small-nvfp4-sglang-dspark|glm53-flash-nvfp4-sglang-dflash2|glm53-flash-nvfp4-sglang-target-only)
      ;;
    *) die 'candidate direct mode is not enabled for this model profile' ;;
  esac
  printf 'DEUCES_DIRECT_STATUS=candidate; owned Laguna controller was not used\n' >&2
fi
# The literal serving command owns its finite controller and generates fresh
# plans from machine provisioning. Acceptance retains its legacy entrypoint.
if [[ "$mode" == qualify-and-serve && "$candidate_mode" == 0 && "${GB10_DEUCES_FRONTEND_CHILD:-0}" != 1 ]]; then
  case "$profile" in
    laguna-s21-nvfp4|qwen38-flash-next-direct-bounded|qwen38-flash-next-nvidia-vllm|deepseek-v4-sglang-target-only|deepseek-v4-nvidia-anemll-vllm|deepseek-v4-flash-0731-nvidia-vllm|deepseek-v4-flash-0731-nvidia-v028|deepseek-v41-flash-exl3-29bpw|inkling-small-nvfp4-sglang-dspark|glm53-flash-nvfp4-sglang-dflash2|glm53-flash-nvfp4-sglang-target-only) ;;
    *) die 'durable single-command mode is not enabled for this model profile' ;;
  esac
  [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-1}" == 1 ]] || die 'qualify-and-serve requires the owned lifecycle'
  exec "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I -B "$repo_root/scripts/deuces-direct-frontend.py" run \
    "${GB10_DEUCES_DIRECT_PROVISION:-$HOME/.config/gb10sor/deuces-direct.json}"
fi
frontend_child=0
if [[ "${GB10_DEUCES_FRONTEND_CHILD:-0}" == 1 ]]; then
  [[ "$mode" == qualify-and-serve && "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]] || die 'invalid internal frontend mode'
  "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I -B "$repo_root/scripts/deuces-direct-frontend.py" verify-child \
    "${GB10_DEUCES_FRONTEND_PROOF:?}" "${DEUCES_LINK_SERVER_PLAN:?}" "${DEUCES_LINK_SERVER_PLAN_SHA256:?}" "${GB10_DEUCES_PREDECLARED_RUN_ID:?}"
  frontend_child=1
fi
if [[ "$candidate_mode" == 1 ]]; then
  [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 0 ]] || die 'candidate direct mode requires the temporary cleanup lifecycle'
  [[ "${GB10_DEUCES_PRECONFIGURED_DIRECT:-0}" == 0 ]] || die 'candidate direct mode cannot adopt persistent direct profiles'
  [[ "${GB10_DEUCES_LINK_ONLY:-0}" == 0 ]] || die 'candidate direct mode cannot run link-only ownership'
fi
[[ "${GB10_DEUCES_LINK_ONLY:-0}" == 0 || ( "${GB10_DEUCES_LINK_ONLY:-}" == 1 && "$frontend_child" == 1 ) ]] || \
  die 'link-only qualification requires the sealed owned frontend'
config_file="${GB10_DEUCES_DIRECT_CONFIG:-$HOME/.config/gb10sor/deuces-direct.env}"
[[ -r "$config_file" ]] || die "private direct-pair config is unreadable: $config_file"
# shellcheck disable=SC1090
source "$config_file"

# The engine coordinator is a child process. Export only its reviewed private
# runtime overrides; shell-local values loaded above would otherwise disappear
# and silently fall back to a registry image that may not have a local name.
for name in \
  DEUCES_SSH_IDENTITY_FILE DEUCES_SSH_KNOWN_HOSTS_FILE \
  DEUCES_SGLANG_IMAGE DEUCES_SGLANG_EXPECTED_IMAGE_ID \
  DEUCES_SGLANG_EXPECTED_LAYERS_SHA256 \
  DEUCES_VLLM_IMAGE DEUCES_VLLM_EXPECTED_IMAGE_ID \
  DEUCES_VLLM_EXPECTED_LAYERS_SHA256 \
  DEUCES_VLLM_ENFORCE_EAGER \
  DEUCES_SERVE_MAX_SECONDS \
  DEUCES_SGLANG_STARTUP_TIMEOUT_SECONDS DEUCES_SGLANG_REQUEST_TIMEOUT_SECONDS \
  DEUCES_VLLM_STARTUP_TIMEOUT_SECONDS DEUCES_VLLM_REQUEST_TIMEOUT_SECONDS
do
  [[ -z "${!name:-}" ]] || export "$name"
done

# Validate the exact immutable model contract before any direct interface is
# raised or temporary profile is created. This is read-only and local-only.
recipe_registry="${GB10_MODEL_PROFILE_REGISTRY:-$repo_root/model-profiles.json}"
[[ -r "$recipe_registry" ]] || die "model profile registry is unreadable: $recipe_registry"
"${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I -B "$repo_root/scripts/deuces-direct-recipe.py" \
  "$recipe_registry" "$profile" direct

# Explicit environment overrides make it possible to reuse the reviewed SSH
# and storage settings from a switched-pair config while selecting a different
# physical pair for a bounded direct-cable qualification run.
for name in \
  LEFT_HOST RIGHT_HOST LEFT_NODE RIGHT_NODE \
  LEFT_RAIL_A RIGHT_RAIL_A LEFT_RAIL_B RIGHT_RAIL_B \
  LEFT_MODEL_ROOT RIGHT_MODEL_ROOT
do
  override_name="GB10_DEUCES_DIRECT_${name}"
  target_name="DEUCES_${name}"
  if [[ -n "${!override_name:-}" ]]; then
    printf -v "$target_name" '%s' "${!override_name}"
  fi
done

for name in DEUCES_LEFT_HOST DEUCES_RIGHT_HOST DEUCES_LEFT_NODE DEUCES_RIGHT_NODE \
  DEUCES_LEFT_RAIL_A DEUCES_RIGHT_RAIL_A \
  DEUCES_LEFT_MODEL_ROOT DEUCES_RIGHT_MODEL_ROOT
do
  [[ -n "${!name:-}" ]] || die "private config is missing: $name"
done
interface_count="${DEUCES_DIRECT_INTERFACE_COUNT:-1}"
[[ "$interface_count" == 1 || "$interface_count" == 2 ]] || \
  die 'DEUCES_DIRECT_INTERFACE_COUNT must be 1 or 2'
if [[ "$interface_count" == 2 ]]; then
  for name in DEUCES_LEFT_RAIL_B DEUCES_RIGHT_RAIL_B; do
    [[ -n "${!name:-}" ]] || die "private config is missing: $name"
  done
fi
[[ -n "$profile" ]] || die 'GB10_MODEL_PROFILE is not set; use a deuces-direct-* Nix shell'
case "$profile" in
  glm53-flash-nvfp4-sglang-target-only|deepseek-v41-flash-exl3-29bpw)
    [[ "$interface_count" == 1 ]] || die "$profile requires one direct primary interface"
    ;;
esac
[[ "$mode" == acceptance || "$mode" == qualify-and-serve ]] || \
  die 'mode must be acceptance or qualify-and-serve'
[[ "$evidence_root" == /* && "$evidence_root" != / ]] || \
  die 'private evidence root must be a safe absolute path'
export DEUCES_LEFT_HOST DEUCES_RIGHT_HOST DEUCES_LEFT_NODE DEUCES_RIGHT_NODE
export DEUCES_LEFT_RAIL_A DEUCES_RIGHT_RAIL_A
export DEUCES_DIRECT_INTERFACE_COUNT="$interface_count"
if [[ "$interface_count" == 2 ]]; then
  export DEUCES_LEFT_RAIL_B DEUCES_RIGHT_RAIL_B
fi
export DEUCES_LEFT_MODEL_ROOT DEUCES_RIGHT_MODEL_ROOT
for name in DEUCES_SSH_IDENTITY_FILE DEUCES_SSH_KNOWN_HOSTS_FILE; do
  [[ -z "${!name:-}" ]] || export "$name"
done

rail_a_interface="${DEUCES_RAIL_A_INTERFACE:-enp1s0f0np0}"
rail_b_interface="${DEUCES_RAIL_B_INTERFACE:-enP2p1s0f0np0}"
[[ "$rail_a_interface" == enp1s0f0np0 ]] || \
  die 'direct rail A must be enp1s0f0np0; do not inherit a switched f1 interface'
[[ "$rail_b_interface" == enP2p1s0f0np0 ]] || die 'direct rail B must be enP2p1s0f0np0'
expected_hca=mlx5_0:1
expected_socket_ifname="$rail_a_interface"
if [[ "$interface_count" == 2 ]]; then
  expected_hca=mlx5_0:1,mlx5_2:1
  expected_socket_ifname="$rail_a_interface,$rail_b_interface"
fi
[[ "${DEUCES_NCCL_IB_HCA:-$expected_hca}" == "$expected_hca" ]] || \
  die 'NCCL HCA selection does not match the selected direct rails'
[[ "${DEUCES_NCCL_SOCKET_IFNAME:-$expected_socket_ifname}" == "$expected_socket_ifname" ]] || \
  die 'NCCL socket interfaces do not match the selected direct rails'
[[ "${DEUCES_TP_SOCKET_IFNAME:-$rail_a_interface}" == "$rail_a_interface" ]] || \
  die 'tensor-parallel socket interface does not match direct rail A'
direct_interfaces=("$rail_a_interface")
arp_guard_interfaces=("$rail_a_interface" "$rail_b_interface")
if [[ "$interface_count" == 2 ]]; then
  direct_interfaces+=("$rail_b_interface")
fi
target_mtu="${DEUCES_MTU:-9000}"
run_id="gb10sor-direct-$(date -u +%Y%m%dT%H%M%SZ)-$$"
if [[ "$frontend_child" == 1 ]]; then run_id=$GB10_DEUCES_PREDECLARED_RUN_ID; fi
created_hosts=()
created_uuids=()
created_names=()
created_interfaces=()
created_cidrs=()
link_uuids=()
baseline_hosts=()
baseline_interfaces=()
baseline_mtus=()
baseline_admin_states=()
arp_guard_hosts=()
arp_guard_baseline_interfaces=()
arp_guard_ignores=()
arp_guard_announces=()
owned_child_attempted=0
owned_link_attempted=0
owned_link_plan=''
owned_link_plan_sha=''
preconfigured_direct="${GB10_DEUCES_PRECONFIGURED_DIRECT:-0}"

[[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 0 || "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]] ||
  die 'owned lifecycle mode must be0 or1 before network changes'
[[ "$preconfigured_direct" == 0 || "$preconfigured_direct" == 1 ]] || die 'preconfigured direct mode must be0 or1'
[[ "$preconfigured_direct" == 0 || ( "$frontend_child" == 1 && "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ) ]] ||
  die 'preconfigured direct requires the sealed owned frontend'
if [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]]; then
  [[ "${GB10_DEUCES_PARENT_RUNTIME_SECONDS:-}" =~ ^[1-9][0-9]{1,4}$ ]] &&
    (( GB10_DEUCES_PARENT_RUNTIME_SECONDS >= 60 && GB10_DEUCES_PARENT_RUNTIME_SECONDS <= 86400 )) ||
    die 'owned mode requires finite parent runtime60..86400 before network changes'
  [[ "${GB10_DEUCES_OWNED_LEASE_SECONDS:-}" =~ ^[1-9][0-9]{1,4}$ ]] &&
    (( GB10_DEUCES_OWNED_LEASE_SECONDS >= 180 && GB10_DEUCES_OWNED_LEASE_SECONDS <= 43200 )) ||
    die 'owned mode requires finite lease180..43200 before network changes'
  command -v "${GB10_DEUCES_LOCAL_PYTHON:-python3}" >/dev/null || die 'owned parent Python is unavailable'
  [[ "$interface_count" == 1 ]] || die 'owned link lifecycle currently requires one direct port'
  for name in DEUCES_LINK_SERVER_PLAN DEUCES_LINK_SERVER_PLAN_SHA256 \
    DEUCES_SSH_IDENTITY_FILE DEUCES_SSH_KNOWN_HOSTS_FILE DEUCES_IPERF_BIN; do
    [[ -n "${!name:-}" ]] || die "owned link plan is missing $name before network changes"
    export "$name"
  done
  owned_link_plan=$DEUCES_LINK_SERVER_PLAN
  owned_link_plan_sha=$DEUCES_LINK_SERVER_PLAN_SHA256
  owned_link_labels=(rail-a-left-to-right rail-a-right-to-left
    rail-a-left-to-right-client rail-a-right-to-left-client)
  if [[ -n "${DEUCES_PERFTEST_BIN:-}" ]]; then
    owned_link_labels+=(rdma-a-left-to-right rdma-a-right-to-left
      rdma-a-left-to-right-client rdma-a-right-to-left-client)
  fi
  "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$repo_root/scripts/deuces-link-server-transport.py" check-pair \
    "$owned_link_plan" "$owned_link_plan_sha" "$DEUCES_LEFT_HOST" "$DEUCES_LEFT_NODE" \
    "$DEUCES_RIGHT_HOST" "$DEUCES_RIGHT_NODE" "${owned_link_labels[@]}" >/dev/null || die 'owned link inventory invalid'
fi

ssh_options=(-o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=3
  -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
if [[ -n "${DEUCES_SSH_IDENTITY_FILE:-}" ]]; then
  ssh_options+=(-o IdentitiesOnly=yes -i "$DEUCES_SSH_IDENTITY_FILE")
fi
if [[ -n "${DEUCES_SSH_KNOWN_HOSTS_FILE:-}" ]]; then
  ssh_options+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$DEUCES_SSH_KNOWN_HOSTS_FILE")
fi
remote() {
  local host="$1"
  shift
  [[ $# == 1 ]] || return 2
  # Bypass SSH only when this process is actually running on the declared
  # left node. A matching host string alone is not proof that the controller
  # is local and made offline/preflight fixtures execute host commands on the
  # wrong machine.
  if [[ -n "${DEUCES_LEFT_NODE:-}" && "$(hostname -s)" == "$DEUCES_LEFT_NODE" && "$host" == "$DEUCES_LEFT_HOST" ]]; then
    /run/current-system/sw/bin/bash --noprofile --norc -euo pipefail -c "$1"
    return
  fi
  local quoted
  printf -v quoted '%q' "$1"
  ssh "${ssh_options[@]}" "$host" "/run/current-system/sw/bin/bash --noprofile --norc -euo pipefail -c $quoted"
}

remove_owned_profile() {
  local host=$1 uuid=$2 name=$3 interface=$4 cidr=$5
  remote "$host" "set -euo pipefail
    existing=\$(nmcli -g UUID connection show)
    if printf '%s\\n' \"\$existing\" | grep -Fxq '$uuid'; then
      found_name=\$(nmcli -g connection.id connection show uuid '$uuid')
      found_interface=\$(nmcli -g connection.interface-name connection show uuid '$uuid')
      found_address=\$(nmcli -g ipv4.addresses connection show uuid '$uuid')
      test \"\$found_name\" = '$name'
      test \"\$found_interface\" = '$interface'
      test \"\$found_address\" = '$cidr'
      active=\$(nmcli -g GENERAL.CON-UUID device show '$interface')
      case \"\$active\" in
        '$uuid') sudo -n nmcli --wait 10 connection down uuid '$uuid' >/dev/null ;;
        ''|'--') ;;
        *) echo 'Refusing cleanup: unexpected active connection' >&2; exit 1 ;;
      esac
      sudo -n nmcli connection delete uuid '$uuid' >/dev/null
    fi
    after=\$(nmcli -g UUID connection show)
    if printf '%s\\n' \"\$after\" | grep -Fxq '$uuid'; then exit 1; fi
    active_after=\$(nmcli -g GENERAL.CON-UUID device show '$interface')
    case \"\$active_after\" in ''|'--') ;; *) exit 1 ;; esac"
}

cleanup() {
  local original_status=$1 cleanup_failed=0 index restore_admin_state
  trap - EXIT
  set +e
  if [[ "${owned_child_attempted:-0}" == 1 ]]; then
    # No name-based/empty-inventory substitute for the anchored child proof.
    "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$repo_root/scripts/deuces-resource-parent.py" verify \
      "${DEUCES_PAYLOAD_EVIDENCE_DIR}.parent" "$DEUCES_PAYLOAD_EVIDENCE_DIR" || cleanup_failed=1
  fi
  if [[ "${owned_link_attempted:-0}" == 1 ]]; then
    # Independently verify every declared link slot, including slots whose child
    # start/prepare reply was lost. Child shell exit is not resource proof.
    verify_owned_link_cleanup || cleanup_failed=1
  fi
  if (( cleanup_failed )); then
    printf 'deuces_direct_cleanup=failed; parent resource proof missing or invalid; network restoration skipped\n' >&2
    exit 1
  fi
  # A child coordinator can fail with a model still running. Do not tear down
  # its direct network just because the local shell has reached its EXIT trap.
  # This fresh idle check supplements, but does not replace, owned child receipts
  # and independent rollback (CPU-only work still needs its exact resource gate).
  for ((index = 0; index < ${#created_hosts[@]}; index++)); do
    (require_idle_workloads "${created_hosts[$index]}") || cleanup_failed=1
  done
  if (( cleanup_failed )); then
    printf 'deuces_direct_cleanup=failed; workloads active or unknown; network restoration skipped\n' >&2
    exit 1
  fi
  for ((index = ${#created_uuids[@]} - 1; index >= 0; index--)); do
    remove_owned_profile "${created_hosts[$index]}" "${created_uuids[$index]}" \
      "${created_names[$index]}" "${created_interfaces[$index]}" "${created_cidrs[$index]}" || cleanup_failed=1
  done
  # Never reset MTU/admin/ARP if profile ownership or removal is uncertain.
  # Preserve the failure for the independently guarded controller to inspect.
  if (( cleanup_failed )); then
    printf 'deuces_direct_cleanup=failed; profile ownership/removal uncertain; network restoration skipped\n' >&2
    exit 1
  fi
  for ((index = ${#baseline_hosts[@]} - 1; index >= 0; index--)); do
    if [[ "${baseline_admin_states[$index]}" == up ]]; then
      restore_admin_state=up
    else
      restore_admin_state=down
    fi
    remote "${baseline_hosts[$index]}" \
      "set -e; sudo -n ip link set '${baseline_interfaces[$index]}' mtu '${baseline_mtus[$index]}'; sudo -n ip link set '${baseline_interfaces[$index]}' '$restore_admin_state'; test \"\$(cat /sys/class/net/${baseline_interfaces[$index]}/mtu)\" = '${baseline_mtus[$index]}'; test \"\$(ip -j link show dev '${baseline_interfaces[$index]}' | jq -r 'if (.[0].flags | index(\"UP\")) == null then \"down\" else \"up\" end')\" = '$restore_admin_state'" || cleanup_failed=1
  done
  # The unselected f0 receives only ARP-policy changes, never MTU/admin/address
  # changes. Restore guards last, after temporary addresses have been removed.
  for ((index = ${#arp_guard_hosts[@]} - 1; index >= 0; index--)); do
    remote "${arp_guard_hosts[$index]}" \
      "set -e; sudo -n sysctl -qw 'net.ipv4.conf.${arp_guard_baseline_interfaces[$index]}.arp_ignore=${arp_guard_ignores[$index]}'; sudo -n sysctl -qw 'net.ipv4.conf.${arp_guard_baseline_interfaces[$index]}.arp_announce=${arp_guard_announces[$index]}'; test \"\$(sysctl -n net.ipv4.conf.${arp_guard_baseline_interfaces[$index]}.arp_ignore)\" = '${arp_guard_ignores[$index]}'; test \"\$(sysctl -n net.ipv4.conf.${arp_guard_baseline_interfaces[$index]}.arp_announce)\" = '${arp_guard_announces[$index]}'" || cleanup_failed=1
  done
  if (( cleanup_failed )); then
    printf 'deuces_direct_cleanup=failed; manual state inspection required\n' >&2
    exit 1
  fi
  printf 'deuces_direct_cleanup=pass\n'
  exit "$original_status"
}

verify_owned_link_cleanup() {
  local receipt_dir
  receipt_dir=$(mktemp -d "$link_evidence/parent-owned-cleanup.XXXXXX") || return
  "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$repo_root/scripts/deuces-link-server-transport.py" cleanup-all \
    "$owned_link_plan" "$owned_link_plan_sha" "$receipt_dir" \
    "$DEUCES_SSH_IDENTITY_FILE" "$DEUCES_SSH_KNOWN_HOSTS_FILE" >/dev/null
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_unused_rail_empty() {
  local host=$1
  [[ "$interface_count" == 1 ]] || return 0
  remote "$host" "set -e; addresses=\$(ip -o -4 address show dev '$rail_b_interface'); test -z \"\$addresses\"" || \
    die "$host unused direct rail B must have no IPv4 address"
}

require_idle_autoconnect() {
  local host=$1 interface
  for interface in "${arp_guard_interfaces[@]}"; do
    remote "$host" "set -e; test \"\$(nmcli -g GENERAL.AUTOCONNECT device show '$interface')\" = no; test \"\$(nmcli -g GENERAL.STATE device show '$interface')\" = '30 (disconnected)'" || \
      die "$host $interface requires disconnected state and runtime autoconnect=no before direct launch; apply the reviewed direct-idle profile"
  done
}

require_switched_idle() {
  local host=$1
  remote "$host" "set -euo pipefail
    for interface in enp1s0f1np1 enP2p1s0f1np1; do
      ip -j address show dev \"\$interface\" | jq -e --arg dev \"\$interface\" '
        length==1 and .[0].ifname==\$dev and
        (.[0].flags|index(\"UP\"))==null and
        (.[0].addr_info|type)==\"array\" and (.[0].addr_info|length)==0' >/dev/null
      for family in -4 -6; do
        ip -j \"\$family\" route show table all dev \"\$interface\" |
          jq -e 'type==\"array\" and length==0' >/dev/null
      done
    done
    for family in -4 -6; do
      ip -j \"\$family\" rule show | jq -e '
        type==\"array\" and length>0 and all(.[];
          ([.iif, .iifname, .oif, .oifname] |
           all(. != \"enp1s0f1np1\" and . != \"enP2p1s0f1np1\")))' >/dev/null
    done" || die "$host switched interfaces are not fully idle (addresses, all route tables, or policy rules)"
}

require_idle_workloads() {
  local host=$1
  remote "$host" "set -euo pipefail
    sudo -n true
    for service in cluster-fabric-profile.service cluster-fabric-qualification.service ray-cluster.service; do
      properties=\$(systemctl show \"\$service\" -p LoadState -p ActiveState -p SubState -p MainPID)
      if ! { printf '%s\\n' \"\$properties\" | grep -Eq '^LoadState=(loaded|not-found)$' &&
             printf '%s\\n' \"\$properties\" | grep -Fxq 'ActiveState=inactive' &&
             printf '%s\\n' \"\$properties\" | grep -Fxq 'SubState=dead' &&
             printf '%s\\n' \"\$properties\" | grep -Fxq 'MainPID=0'; }; then
        echo \"Direct preflight requires inactive service: \$service (failed, active or unknown state)\" >&2
        exit 1
      fi
    done
    containers=\$(podman ps -q)
    test -z \"\$containers\"
    root_containers=\$(sudo -n podman ps -q)
    test -z \"\$root_containers\"
    gpu_processes=\$(nvidia-smi --query-compute-apps=pid --format=csv,noheader)
    test -z \"\$gpu_processes\"" || die "$host workload/service status is not verified idle"
}

set_arp_guards() {
  local host interface
  for host in "$DEUCES_LEFT_HOST" "$DEUCES_RIGHT_HOST"; do
    require_unused_rail_empty "$host"
    for interface in "${arp_guard_interfaces[@]}"; do
      remote "$host" "set -e; sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_ignore=1'; sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_announce=2'; test \"\$(sysctl -n net.ipv4.conf.$interface.arp_ignore)\" = 1; test \"\$(sysctl -n net.ipv4.conf.$interface.arp_announce)\" = 2"
    done
  done
}

for host in "$DEUCES_LEFT_HOST" "$DEUCES_RIGHT_HOST"; do
  require_idle_workloads "$host"
  require_switched_idle "$host"
  require_unused_rail_empty "$host"
  if [[ "$preconfigured_direct" == 0 ]]; then require_idle_autoconnect "$host"; fi
done

link_evidence="$evidence_root/deuces-direct-link-$profile-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]]; then
  # Seal/readback ALL fresh slot bytes before the first interface mutation.
  # No helper or benchmark service is started by this staging step.
  if [[ "$frontend_child" != 1 ]]; then
    mkdir -p "$link_evidence"
    stage_evidence=$(mktemp -d "$link_evidence/owned-staging.XXXXXX")
    "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$repo_root/scripts/deuces-link-server-transport.py" stage-all \
      "$owned_link_plan" "$owned_link_plan_sha" "$stage_evidence" \
      "$DEUCES_SSH_IDENTITY_FILE" "$DEUCES_SSH_KNOWN_HOSTS_FILE" "$repo_root/scripts/deuces-link-server.py" >/dev/null
  fi
fi

# Snapshot both hosts completely before changing any interface. A failed read
# cannot leave an unrecorded guard, and the EXIT trap owns every captured tuple.
if [[ "$preconfigured_direct" == 0 ]]; then
for host in "$DEUCES_LEFT_HOST" "$DEUCES_RIGHT_HOST"; do
  for interface in "${arp_guard_interfaces[@]}"; do
    baseline_arp_ignore=$(remote "$host" "sysctl -n net.ipv4.conf.$interface.arp_ignore")
    baseline_arp_announce=$(remote "$host" "sysctl -n net.ipv4.conf.$interface.arp_announce")
    arp_guard_hosts+=("$host")
    arp_guard_baseline_interfaces+=("$interface")
    arp_guard_ignores+=("$baseline_arp_ignore")
    arp_guard_announces+=("$baseline_arp_announce")
  done
  for interface in "${direct_interfaces[@]}"; do
    # Capture the complete tuple before appending so a failed SSH read cannot
    # leave mismatched arrays for the EXIT trap.
    baseline_mtu=$(remote "$host" "cat /sys/class/net/$interface/mtu")
    baseline_admin_state=$(remote "$host" "ip -j link show dev '$interface' | jq -r 'if (.[0].flags | index(\"UP\")) == null then \"down\" else \"up\" end'")
    baseline_hosts+=("$host")
    baseline_interfaces+=("$interface")
    baseline_mtus+=("$baseline_mtu")
    baseline_admin_states+=("$baseline_admin_state")
  done
done
set_arp_guards
for host in "$DEUCES_LEFT_HOST" "$DEUCES_RIGHT_HOST"; do
  for interface in "${direct_interfaces[@]}"; do
    remote "$host" "sudo -n ip link set '$interface' up"
  done
done
fi

run_link_test() {
  # In the finite owned path the link test observes the parent's exact profiles,
  # instead of creating/removing a second pair before model startup.
  local link_preconfigured=0
  local link_firewall=1
  local left_a='' right_a='' left_b='' right_b=''
  if [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]]; then
    link_preconfigured=1
    link_firewall=0  # Durable network owner must provide the reviewed rules.
    owned_link_attempted=1
    [[ ${#link_uuids[@]} == $((interface_count * 2)) ]] || return 1
    left_a=${link_uuids[0]}; right_a=${link_uuids[1]}
    if [[ "$interface_count" == 2 ]]; then
      left_b=${link_uuids[2]}; right_b=${link_uuids[3]}
    fi
  fi
DEUCES_LINK_PRECONFIGURED="$link_preconfigured" \
DEUCES_LINK_LEFT_UUID_A="$left_a" DEUCES_LINK_RIGHT_UUID_A="$right_a" \
DEUCES_LINK_LEFT_UUID_B="$left_b" DEUCES_LINK_RIGHT_UUID_B="$right_b" \
DEUCES_RAIL_A_INTERFACE="$rail_a_interface" \
DEUCES_RAIL_B_INTERFACE="$rail_b_interface" \
DEUCES_DIRECT_INTERFACE_COUNT="$interface_count" \
DEUCES_MTU="$target_mtu" \
DEUCES_ALLOW_TEMPORARY_FIREWALL="$link_firewall" \
DEUCES_EVIDENCE_DIR="$link_evidence" \
  "$repo_root/scripts/deuces-link-smoke.sh"
}
if [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" != 1 ]]; then
  run_link_test
fi

add_profile() {
  local host=$1 name=$2 interface=$3 cidr=$4 uuid
  # Allocate and register ownership BEFORE the mutating SSH request: its reply
  # can be lost even after NetworkManager successfully creates the connection.
  if [[ "${frontend_child:-0}" == 1 ]]; then
    if [[ "$host" == "$DEUCES_LEFT_HOST" ]]; then uuid=$GB10_DEUCES_PREDECLARED_LEFT_UUID
    elif [[ "$host" == "$DEUCES_RIGHT_HOST" ]]; then uuid=$GB10_DEUCES_PREDECLARED_RIGHT_UUID
    else die 'undeclared frontend profile host'; fi
  else
    uuid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  fi
  [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || die 'invalid generated connection UUID'
  remote "$host" "set -e; existing=\$(nmcli -g UUID connection show); if printf '%s\\n' \"\$existing\" | grep -Fxq '$uuid'; then exit 1; fi"
  created_hosts+=("$host")
  created_uuids+=("$uuid")
  created_names+=("$name")
  created_interfaces+=("$interface")
  created_cidrs+=("$cidr")
  link_uuids+=("$uuid")
  remote "$host" "sudo -n nmcli connection add save no type ethernet ifname '$interface' con-name '$name' connection.uuid '$uuid' connection.autoconnect no 802-3-ethernet.mtu '$target_mtu' ipv4.method manual ipv4.addresses '$cidr' ipv4.never-default yes ipv4.ignore-auto-dns yes ipv6.method disabled >/dev/null"
  remote "$host" "set -e; test \"\$(nmcli -g connection.uuid connection show uuid '$uuid')\" = '$uuid'; test \"\$(nmcli -g connection.interface-name connection show uuid '$uuid')\" = '$interface'; test \"\$(nmcli -g connection.id connection show uuid '$uuid')\" = '$name'"
  remote "$host" "set -e; sudo -n nmcli --wait 20 connection up uuid '$uuid' >/dev/null; sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_ignore=1'; sudo -n sysctl -qw 'net.ipv4.conf.$interface.arp_announce=2'"
}

adopt_profile() {
  local host=$1 name=$2 interface=$3 cidr=$4 uuid=$5 metric=$6
  [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die 'invalid predeclared connection UUID'
  [[ "$name" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || die 'invalid predeclared connection name'
  [[ "$metric" =~ ^[1-9][0-9]{0,9}$ ]] && (( metric < 4294967295 )) || die 'invalid predeclared route metric'
  remote "$host" "set -euo pipefail
    test \"\$(nmcli -g connection.id connection show uuid '$uuid')\" = '$name'
    test \"\$(nmcli -g connection.interface-name connection show uuid '$uuid')\" = '$interface'
    test \"\$(nmcli -g connection.autoconnect connection show uuid '$uuid')\" = no
    test \"\$(nmcli -g ipv4.method connection show uuid '$uuid')\" = manual
    test \"\$(nmcli -g ipv4.addresses connection show uuid '$uuid')\" = '$cidr'
    test \"\$(nmcli -g ipv4.route-metric connection show uuid '$uuid')\" = '$metric'
    test \"\$(nmcli -g ipv4.never-default connection show uuid '$uuid')\" = yes
    test \"\$(nmcli -g ipv6.method connection show uuid '$uuid')\" = disabled
    test \"\$(nmcli -g 802-3-ethernet.mtu connection show uuid '$uuid')\" = '$target_mtu'
    test \"\$(nmcli -g GENERAL.CON-UUID device show '$interface')\" = '$uuid'
    ip -j address show dev '$interface' | jq -e --arg cidr '$cidr' '
      length==1 and (.[0].flags|index(\"UP\"))!=null and
      ([.[0].addr_info[]|select(.family==\"inet\")|(.local+\"/\"+(.prefixlen|tostring))]==[\$cidr])' >/dev/null
    test \"\$(cat /sys/class/net/$interface/mtu)\" = '$target_mtu'
    test \"\$(sysctl -n net.ipv4.conf.$interface.arp_ignore)\" = 1
    test \"\$(sysctl -n net.ipv4.conf.$interface.arp_announce)\" = 2"
  link_uuids+=("$uuid")
  created_hosts+=("$host")
}

if [[ "$preconfigured_direct" == 1 ]]; then
  adopt_profile "$DEUCES_LEFT_HOST" "$GB10_DEUCES_PREDECLARED_LEFT_NAME" "$rail_a_interface" "$DEUCES_LEFT_RAIL_A" "$GB10_DEUCES_PREDECLARED_LEFT_UUID" "$GB10_DEUCES_PREDECLARED_LEFT_ROUTE_METRIC"
  adopt_profile "$DEUCES_RIGHT_HOST" "$GB10_DEUCES_PREDECLARED_RIGHT_NAME" "$rail_a_interface" "$DEUCES_RIGHT_RAIL_A" "$GB10_DEUCES_PREDECLARED_RIGHT_UUID" "$GB10_DEUCES_PREDECLARED_RIGHT_ROUTE_METRIC"
else
  add_profile "$DEUCES_LEFT_HOST" "$run_id-left-a" "$rail_a_interface" "$DEUCES_LEFT_RAIL_A"
  add_profile "$DEUCES_RIGHT_HOST" "$run_id-right-a" "$rail_a_interface" "$DEUCES_RIGHT_RAIL_A"
fi
if [[ "$interface_count" == 2 ]]; then
  add_profile "$DEUCES_LEFT_HOST" "$run_id-left-b" "$rail_b_interface" "$DEUCES_LEFT_RAIL_B"
  add_profile "$DEUCES_RIGHT_HOST" "$run_id-right-b" "$rail_b_interface" "$DEUCES_RIGHT_RAIL_B"
fi
# Link-smoke cleanup/NM activation must not leave either f0 able to answer for
# an address assigned only to its sibling. Reassert and verify before payload.
if [[ "$preconfigured_direct" == 0 ]]; then
set_arp_guards
fi

if [[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]]; then
  if [[ "$frontend_child" == 1 ]]; then
    "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I -B "$repo_root/scripts/deuces-direct-frontend.py" profiles-ready "$GB10_DEUCES_FRONTEND_PROOF"
  fi
  run_link_test
fi

# Only the internally sealed foreground controller may request this bounded
# hardware gate. Both remote guards independently refuse all model declarations.
if [[ "${GB10_DEUCES_LINK_ONLY:-0}" != 0 ]]; then
  [[ "${GB10_DEUCES_LINK_ONLY:-}" == 1 && "$frontend_child" == 1 && "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" == 1 ]] || \
    die 'link-only qualification requires the sealed owned frontend'
  printf 'Internal direct-link qualification completed; no model was requested.\n'
  exit 0
fi

export DEUCES_TOPOLOGY=direct
export DEUCES_RAIL_A_INTERFACE="$rail_a_interface"
export DEUCES_RAIL_B_INTERFACE="$rail_b_interface"
export DEUCES_MTU="$target_mtu"
if [[ "$interface_count" == 1 ]]; then
  export DEUCES_NCCL_IB_HCA="${DEUCES_NCCL_IB_HCA:-mlx5_0:1}"
  export DEUCES_NCCL_SOCKET_IFNAME="${DEUCES_NCCL_SOCKET_IFNAME:-$rail_a_interface}"
else
  export DEUCES_NCCL_IB_HCA="${DEUCES_NCCL_IB_HCA:-mlx5_0:1,mlx5_2:1}"
  export DEUCES_NCCL_SOCKET_IFNAME="${DEUCES_NCCL_SOCKET_IFNAME:-$rail_a_interface,$rail_b_interface}"
fi
export DEUCES_TP_SOCKET_IFNAME="${DEUCES_TP_SOCKET_IFNAME:-$rail_a_interface}"
export DEUCES_CLUSTER_PROFILE_PATH="${DEUCES_CLUSTER_PROFILE_PATH:-/dev/null}"
# The direct wrapper has already loaded and exported the reviewed private
# settings. Prevent the delegated engine coordinator from sourcing the
# switched-pair config a second time and replacing this run's direct hosts.
export GB10_DEUCES_SWITCH_CONFIG=/dev/null
export GB10_PRIVATE_EVIDENCE_ROOT="$evidence_root"
export DEUCES_PAYLOAD_EVIDENCE_DIR="${DEUCES_PAYLOAD_EVIDENCE_DIR:-$evidence_root/deuces-direct-$profile-$(date -u +%Y%m%dT%H%M%SZ)}"

[[ "${GB10_DEUCES_OWNED_LIFECYCLE:-0}" != 1 ]] || owned_child_attempted=1
"$repo_root/scripts/deuces-switch-model.sh" "$mode"
