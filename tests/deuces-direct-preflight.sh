#!/usr/bin/env bash
# Offline regression: every conflicting service must abort before fabric mutation.
set -Eeuo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -f "$fixture/bin/ssh" "$fixture/bin/sudo" "$fixture/bin/systemctl" "$fixture/bin/ip" "$fixture/config" "$fixture/output" "$fixture/mutation"; rmdir "$fixture/bin" "$fixture"' EXIT
mkdir "$fixture/bin"
printf '%s\n' '#!/usr/bin/env bash' 'command=${!#}' \
  'exec bash -c "${command/#\/run\/current-system\/sw\/bin\/bash/bash}"' > "$fixture/bin/ssh"
printf '%s\n' '#!/usr/bin/env bash' '[[ "$*" == "-n true" ]] || exit 91' > "$fixture/bin/sudo"
printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == show ]] || exit 91' \
  'if [[ "$2" == "$TEST_ACTIVE_SERVICE" ]]; then printf "LoadState=loaded\nActiveState=active\nSubState=running\nMainPID=12\n"; else printf "LoadState=loaded\nActiveState=inactive\nSubState=dead\nMainPID=0\n"; fi' > "$fixture/bin/systemctl"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$TEST_MUTATION_MARKER"' 'exit 92' > "$fixture/bin/ip"
chmod +x "$fixture/bin/ssh" "$fixture/bin/sudo" "$fixture/bin/systemctl" "$fixture/bin/ip"
printf '%s\n' \
  'DEUCES_LEFT_HOST=fixture-left' 'DEUCES_RIGHT_HOST=fixture-right' \
  'DEUCES_LEFT_NODE=fixture-left' 'DEUCES_RIGHT_NODE=fixture-right' \
  'DEUCES_LEFT_RAIL_A=192.0.2.10/24' 'DEUCES_RIGHT_RAIL_A=192.0.2.11/24' \
  'DEUCES_LEFT_MODEL_ROOT=/fixture/models' 'DEUCES_RIGHT_MODEL_ROOT=/fixture/models' \
  > "$fixture/config"
for service in cluster-fabric-profile.service cluster-fabric-qualification.service ray-cluster.service; do
  if PATH="$fixture/bin:$PATH" \
    TEST_ACTIVE_SERVICE="$service" TEST_MUTATION_MARKER="$fixture/mutation" \
    GB10_DEUCES_DIRECT_CONFIG="$fixture/config" \
    GB10_PRIVATE_EVIDENCE_ROOT="$fixture/evidence" \
    GB10_MODEL_PROFILE=qwen38-flash-next-direct-bounded \
    bash "$repo_root/scripts/deuces-direct-model.sh" acceptance > "$fixture/output" 2>&1; then
    printf 'FAIL: active service was accepted: %s\n' "$service" >&2
    exit 1
  fi
  grep -Fq "Direct preflight requires inactive service: $service" "$fixture/output" || {
    printf 'FAIL: expected service gate was not reported: %s\n' "$service" >&2
    sed -n '1,120p' "$fixture/output" >&2
    exit 1
  }
  [[ ! -e "$fixture/mutation" ]] || { printf 'FAIL: fabric touched\n' >&2; exit 1; }
  printf 'PASS: %s blocks direct launch before fabric changes\n' "$service"
done

for owned_setting in GB10_DEUCES_OWNED_LIFECYCLE=invalid GB10_DEUCES_PARENT_RUNTIME_SECONDS=0 GB10_DEUCES_OWNED_LEASE_SECONDS=0; do
  if env PATH="$fixture/bin:$PATH" TEST_ACTIVE_SERVICE=none TEST_MUTATION_MARKER="$fixture/mutation" \
    GB10_DEUCES_DIRECT_CONFIG="$fixture/config" GB10_PRIVATE_EVIDENCE_ROOT="$fixture/evidence" \
    GB10_MODEL_PROFILE=qwen38-flash-next-direct-bounded GB10_DEUCES_OWNED_LIFECYCLE=1 \
    GB10_DEUCES_PARENT_RUNTIME_SECONDS=7200 GB10_DEUCES_OWNED_LEASE_SECONDS=3700 \
    "$owned_setting" bash "$repo_root/scripts/deuces-direct-model.sh" acceptance > "$fixture/output" 2>&1; then
    printf 'FAIL invalid owned setting accepted\n' >&2; exit 1
  fi
  grep -Eq 'owned lifecycle mode|owned mode requires finite' "$fixture/output"
  [[ ! -e "$fixture/mutation" ]]
  printf 'PASS invalid owned setting before network: %s\n' "$owned_setting"
done

# Exercise the actual EXIT handler in isolation: a failed remote cleanup must
# not be hidden by an otherwise successful model run, nor may cleanup erase
# an earlier model failure.
if PATH="$fixture/bin:$PATH" \
  TEST_ACTIVE_SERVICE=none TEST_MUTATION_MARKER="$fixture/mutation" \
  GB10_DEUCES_DIRECT_CONFIG="$fixture/config" \
  GB10_PRIVATE_EVIDENCE_ROOT="$fixture/evidence" \
  GB10_MODEL_PROFILE=glm53-flash-nvfp4-sglang-target-only \
  DEUCES_DIRECT_INTERFACE_COUNT=2 \
  DEUCES_LEFT_RAIL_B=198.51.100.10/24 DEUCES_RIGHT_RAIL_B=198.51.100.11/24 \
  bash "$repo_root/scripts/deuces-direct-model.sh" acceptance > "$fixture/output" 2>&1; then
  printf 'FAIL: target-only dual rail accepted\n' >&2
  exit 1
fi
grep -Fq 'glm53-flash-nvfp4-sglang-target-only requires one direct primary interface' "$fixture/output" || {
  printf 'FAIL: unexpected target-only dual-rail diagnostic\n' >&2
  sed -n '1,20p' "$fixture/output" >&2
  exit 1
}
[[ ! -e "$fixture/mutation" ]]
if PATH="$fixture/bin:$PATH" \
  GB10_DEUCES_SWITCH_CONFIG="$fixture/config" \
  GB10_PRIVATE_EVIDENCE_ROOT="$fixture/evidence" \
  GB10_MODEL_PROFILE=glm53-flash-nvfp4-sglang-target-only \
  DEUCES_CLUSTER_PROFILE_PATH=/fixture/profile DEUCES_DIRECT_INTERFACE_COUNT=1 \
  DEUCES_TOPOLOGY=switch \
  bash "$repo_root/scripts/deuces-switch-model.sh" acceptance > "$fixture/output" 2>&1; then
  printf 'FAIL: target-only switched launch accepted\n' >&2
  exit 1
fi
grep -Fq 'GLM target-only candidate requires single-primary Deuces-direct' "$fixture/output" || {
  printf 'FAIL: unexpected target-only switched diagnostic\n' >&2
  sed -n '1,20p' "$fixture/output" >&2
  exit 1
}
[[ ! -e "$fixture/mutation" ]]
printf 'PASS: target-only rejects dual-rail and switched entrypoints before remote work\n'

for case_spec in '0 0 0' '1 0 1' '0 7 7'; do
  read -r remote_status model_status expected_status <<< "$case_spec"
  actual_status=0
  (
    eval "$(sed -n '/^cleanup() {$/,/^}$/p' "$repo_root/scripts/deuces-direct-model.sh")"
    created_hosts=(fixture-left)
    created_uuids=(fixture-uuid)
    created_names=(fixture-name)
    created_interfaces=(enp1s0f0np0)
    created_cidrs=(192.0.2.10/24)
    baseline_hosts=()
    arp_guard_hosts=()
    remote() { return "$remote_status"; }
    require_idle_workloads() { return 0; }
    remove_owned_profile() { remote "$@"; }
    cleanup "$model_status"
  ) > "$fixture/output" 2>&1 || actual_status=$?
  [[ "$actual_status" == "$expected_status" ]] || {
    printf 'FAIL: cleanup exit status %s, expected %s\n' "$actual_status" "$expected_status" >&2
    exit 1
  }
  printf 'PASS: cleanup remote=%s model=%s returns %s\n' "$remote_status" "$model_status" "$actual_status"
done
for setting in \
  DEUCES_RAIL_A_INTERFACE=enp1s0f1np1 \
  DEUCES_RAIL_B_INTERFACE=enP2p1s0f1np1 \
  DEUCES_NCCL_IB_HCA=mlx5_1:1,mlx5_3:1 \
  DEUCES_NCCL_SOCKET_IFNAME=enp1s0f1np1,enP2p1s0f1np1 \
  DEUCES_TP_SOCKET_IFNAME=enp1s0f1np1; do
  if PATH="$fixture/bin:$PATH" \
    TEST_ACTIVE_SERVICE=none TEST_MUTATION_MARKER="$fixture/mutation" \
    GB10_DEUCES_DIRECT_CONFIG="$fixture/config" \
    GB10_PRIVATE_EVIDENCE_ROOT="$fixture/evidence" \
    GB10_MODEL_PROFILE=qwen38-flash-next-direct-bounded \
    env "$setting" bash "$repo_root/scripts/deuces-direct-model.sh" acceptance > "$fixture/output" 2>&1; then
    printf 'FAIL: inherited switched setting accepted: %s\n' "$setting" >&2
    exit 1
  fi
  grep -Fq 'Deuces-direct launcher failed:' "$fixture/output"
  [[ ! -e "$fixture/mutation" ]] || { printf 'FAIL: fabric touched\n' >&2; exit 1; }
  printf 'PASS: rejects switched setting %s before fabric changes\n' "$setting"
done

# Exercise both-f0 guarding independently of SSH/network access. The exact
# remote command must touch only per-interface ARP controls, verify both values,
# and check the unused rail before any mutation on that host.
(
  eval "$(sed -n '/^require_unused_rail_empty() {$/,/^}$/p' "$repo_root/scripts/deuces-direct-model.sh")"
  eval "$(sed -n '/^set_arp_guards() {$/,/^}$/p' "$repo_root/scripts/deuces-direct-model.sh")"
  interface_count=1
  rail_a_interface=enp1s0f0np0
  rail_b_interface=enP2p1s0f0np0
  arp_guard_interfaces=("$rail_a_interface" "$rail_b_interface")
  DEUCES_LEFT_HOST=fixture-left
  DEUCES_RIGHT_HOST=fixture-right
  remote() { printf '%s %s\n' "$1" "$2"; }
  set_arp_guards
) > "$fixture/output"
[[ $(grep -c 'sudo -n sysctl' "$fixture/output") == 4 ]]
[[ $(grep -c 'ip -o -4 address show dev' "$fixture/output") == 2 ]]
for host in fixture-left fixture-right; do
  for interface in enp1s0f0np0 enP2p1s0f0np0; do
    grep -F "$host set -e;" "$fixture/output" | grep -F "net.ipv4.conf.$interface.arp_ignore=1" | \
      grep -F "net.ipv4.conf.$interface.arp_announce=2" | \
      grep -F "sysctl -n net.ipv4.conf.$interface.arp_ignore" | \
      grep -F "sysctl -n net.ipv4.conf.$interface.arp_announce" >/dev/null
  done
done
! grep -Eq 'ip link|nmcli|net.ipv4.conf.all\.' "$fixture/output"
printf 'PASS: guards and verifies both f0s on both hosts without MTU/admin/address changes\n'

for count in 1 2; do
  actual_status=0
  (
    eval "$(sed -n '/^require_unused_rail_empty() {$/,/^}$/p' "$repo_root/scripts/deuces-direct-model.sh")"
    interface_count=$count
    rail_b_interface=enP2p1s0f0np0
    remote() { return 1; }
    die() { printf '%s\n' "$*"; exit 23; }
    require_unused_rail_empty fixture-right
  ) > "$fixture/output" 2>&1 || actual_status=$?
  if [[ "$count" == 1 ]]; then
    [[ "$actual_status" == 23 ]]
    grep -Fq 'unused direct rail B must have no IPv4 address' "$fixture/output"
  else
    [[ "$actual_status" == 0 ]]
  fi
  printf 'PASS: unused-B IPv4 gate is enforced only for interface_count=%s\n' "$count"
done

# Run the actual cleanup command text against in-memory sysctl stand-ins.
# An unselected B baseline must be restored exactly (including nonzero values),
# and observed drift after a nominally successful write must fail closed.
for drift in no yes; do
  actual_status=0
  (
    eval "$(sed -n '/^cleanup() {$/,/^}$/p' "$repo_root/scripts/deuces-direct-model.sh")"
    created_uuids=()
    created_hosts=()
    baseline_hosts=()
    arp_guard_hosts=(fixture-right)
    arp_guard_baseline_interfaces=(enP2p1s0f0np0)
    arp_guard_ignores=(2)
    arp_guard_announces=(1)
    observed_ignore=1
    observed_announce=2
    sudo() {
      [[ "$1" == -n && "$2" == sysctl && "$3" == -qw ]] || return 91
      case "$4" in
        net.ipv4.conf.enP2p1s0f0np0.arp_ignore=2) observed_ignore=2 ;;
        net.ipv4.conf.enP2p1s0f0np0.arp_announce=1) observed_announce=1 ;;
        *) return 92 ;;
      esac
    }
    sysctl() {
      [[ "$1" == -n ]] || return 93
      case "$2" in
        net.ipv4.conf.enP2p1s0f0np0.arp_ignore) printf '%s\n' "$observed_ignore" ;;
        net.ipv4.conf.enP2p1s0f0np0.arp_announce)
          if [[ "$drift" == yes ]]; then printf '2\n'; else printf '%s\n' "$observed_announce"; fi ;;
        *) return 94 ;;
      esac
    }
    # Match SSH's process boundary so the remote command's `set -e` cannot
    # alter cleanup's local `set +e` behavior (notably on macOS Bash 3.2).
    remote() { ( eval "$2" ); }
    cleanup 0
  ) > "$fixture/output" 2>&1 || actual_status=$?
  if [[ "$drift" == no ]]; then
    [[ "$actual_status" == 0 ]]
    grep -Fq 'deuces_direct_cleanup=pass' "$fixture/output"
  else
    [[ "$actual_status" == 1 ]] || { printf 'Unexpected drift cleanup status: %s\n' "$actual_status" >&2; cat "$fixture/output" >&2; exit 1; }
    grep -Fq 'deuces_direct_cleanup=failed' "$fixture/output" || { cat "$fixture/output" >&2; exit 1; }
  fi
  printf 'PASS: unused-B exact ARP restoration drift=%s returns %s\n' "$drift" "$actual_status"
done

# Verify the coordinator invokes guarding before link smoke and reasserts it
# after profile activation, rather than adding an unused helper only.
awk '
  /^set_arp_guards$/ { guards++; if (!smoke) before++ }
  /"\$repo_root\/scripts\/deuces-link-smoke.sh"/ { smoke=1 }
  /^export DEUCES_TOPOLOGY=direct$/ { if (guards != 2 || before != 1) exit 1; checked=1 }
  END { if (!checked) exit 1 }
' "$repo_root/scripts/deuces-direct-model.sh"
printf 'PASS: both-f0 guards bracket link smoke and profile activation\n'
