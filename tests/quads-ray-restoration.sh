#!/usr/bin/env bash
# Offline coordinator regression: all SSH/service behavior is simulated.
set -Eeuo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repo/scripts"
cp "$repo_root/scripts/quads-switch-model.sh" "$fixture/repo/scripts/"
cat >"$fixture/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -eu
args=("$@")
host=${args[${#args[@]}-2]}
command=${args[${#args[@]}-1]}
state_file="$TEST_CASE/state-$host"
printf '%s %s\n' "$host" "$command" >>"$TEST_CASE/ssh.log"
case "$command" in
  *arp_ignore*)
    if [[ "$TEST_SCENARIO" == arp-profile && "$host" == host2 ]]; then exit 1; fi
    printf 'fabric-profile=pass\n'
    ;;
  *'ip -j -4 route get'*)
    if [[ "$TEST_SCENARIO" == worker-pair && "$host" == host2 && "$command" == *192.0.2.3* ]]; then exit 1; fi
    printf 'route-and-ping=pass\n'
    ;;
  *LoadState*)
    if [[ "$TEST_SCENARIO" == off || "$TEST_SCENARIO" == off-* ]]; then printf 'not-found\ninactive\n'; exit 0; fi
    if [[ "$TEST_SCENARIO" == preflight-transport && "$host" == host2 ]]; then exit 255; fi
    if [[ "$TEST_SCENARIO" == restore-probe && -e "$TEST_CASE/model" && "$host" == host2 ]]; then exit 255; fi
    if [[ "$TEST_SCENARIO" == missing && "$host" == host2 ]]; then printf 'not-found\ninactive\n'; exit 0; fi
    if [[ "$TEST_SCENARIO" == unstable && "$host" == host2 ]]; then printf 'loaded\nactivating\n'; exit 0; fi
    printf 'loaded\n'; cat "$state_file"
    ;;
  *cluster-profile.json*)
    if [[ "$TEST_SCENARIO" == off-mismatch && "$host" == host2 ]]; then exit 1; fi
    if [[ "$TEST_SCENARIO" == off-transport && "$host" == host2 ]]; then exit 255; fi
    if [[ "$TEST_SCENARIO" == off-drift && -e "$TEST_CASE/model" && "$host" == host2 ]]; then exit 1; fi
    ;;
  *'stop ray-cluster.service')
    printf 'stop %s\n' "$host" >>"$TEST_CASE/mutations"
    printf 'inactive\n' >"$state_file"
    if [[ "$TEST_SCENARIO" == stop-failed && "$host" == host2 ]]; then exit 255; fi
    ;;
  *'start ray-cluster.service')
    printf 'start %s\n' "$host" >>"$TEST_CASE/mutations"
    if [[ "$TEST_SCENARIO" == restore-start && "$host" == host2 ]]; then exit 1; fi
    printf 'active\n' >"$state_file"
    ;;
  *) exit 99 ;;
esac
MOCK
cat >"$fixture/repo/scripts/cluster-vllm-acceptance.sh" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_CASE/model"
if [[ "$TEST_SCENARIO" == off-source-edit ]]; then
  printf '{"nodes":[]}\n' >"$TEST_CASE/attestations.json"
fi
if [[ "$TEST_SCENARIO" == inactive-drift ]]; then printf 'active\n' >"$TEST_CASE/state-host4"; fi
if [[ "$TEST_SCENARIO" == signal-term ]]; then kill -TERM "$PPID"; exit 0; fi
if [[ "$TEST_SCENARIO" == signal-int ]]; then kill -INT "$PPID"; exit 0; fi
if [[ "$TEST_SCENARIO" == model-failed ]]; then exit 7; fi
MOCK
chmod +x "$fixture/bin/ssh" "$fixture/repo/scripts/cluster-vllm-acceptance.sh"
touch "$fixture/key" "$fixture/known_hosts"

run_case() {
  local scenario=$1 expected=$2 state=active host actual=0
  local profile=${3:-minimax-m3-nvfp4-quads-v028}
  local case_dir="$fixture/$scenario"
  mkdir "$case_dir"
  for host in host1 host2 host3 host4; do
    state=active
    if [[ "$scenario" == inactive || "$scenario" == inactive-drift || \
      ( "$scenario" == mixed && ( "$host" == host2 || "$host" == host4 ) ) ]]; then state=inactive; fi
    printf '%s\n' "$state" >"$case_dir/state-$host"
  done
  printf '{"railAInterface":"fabric0","railBInterface":"fabric1","nodes":[{"host":"host1","railA":"192.0.2.1/24","railB":"198.51.100.1/24"},{"host":"host2","railA":"192.0.2.2/24","railB":"198.51.100.2/24"},{"host":"host3","railA":"192.0.2.3/24","railB":"198.51.100.3/24"},{"host":"host4","railA":"192.0.2.4/24","railB":"198.51.100.4/24"}]}\n' >"$case_dir/inventory.json"
  if [[ "$scenario" == duplicate ]]; then
    printf '{"nodes":[{"host":"host1"},{"host":"host1"},{"host":"host3"},{"host":"host4"}]}\n' >"$case_dir/inventory.json"
  fi
  printf 'QUADS_MINIMAX_M3_INVENTORY_FILE=%q\nQUADS_SSH_IDENTITY_FILE=%q\nQUADS_SSH_KNOWN_HOSTS_FILE=%q\n' \
    "$case_dir/inventory.json" "$fixture/key" "$fixture/known_hosts" >"$case_dir/config"
  if [[ "$scenario" == off || "$scenario" == off-* ]]; then
    jq -n '{nodes:[range(1;5) | {host:("host"+tostring),hostname:("host"+tostring),closure:("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-host"+tostring)}]}' >"$case_dir/attestations.json"
    if [[ "$scenario" == off-duplicate ]]; then
      jq '.nodes += [.nodes[0]]' "$case_dir/attestations.json" >"$case_dir/changed.json"
      mv "$case_dir/changed.json" "$case_dir/attestations.json"
    fi
    if [[ "$scenario" == off-bad-closure ]]; then
      jq '.nodes[0].closure = "/nix/store/not-a-pinned-closure"' "$case_dir/attestations.json" >"$case_dir/changed.json"
      mv "$case_dir/changed.json" "$case_dir/attestations.json"
    fi
    if [[ "$scenario" != off-no-opt-in ]]; then
      printf 'QUADS_ALLOW_DECLARED_RAY_OFF=1\nQUADS_RAY_OFF_ATTESTATIONS=%q\n' "$case_dir/attestations.json" >>"$case_dir/config"
    fi
  fi
  PATH="$fixture/bin:$PATH" TEST_CASE="$case_dir" TEST_SCENARIO="$scenario" \
    GB10_MODEL_PROFILE="$profile" \
    GB10_QUADS_SWITCH_CONFIG="$case_dir/config" GB10_PRIVATE_EVIDENCE_ROOT="$case_dir/evidence" \
    GB10_CLUSTER_EVIDENCE_DIR="$case_dir/model-evidence" \
    bash "$fixture/repo/scripts/quads-switch-model.sh" acceptance >"$case_dir/output" 2>&1 || actual=$?
  [[ "$actual" == "$expected" ]] || {
    cat "$case_dir/output" >&2
    printf 'FAIL %s: exit %s expected %s\n' "$scenario" "$actual" "$expected" >&2; exit 1;
  }
  case "$scenario" in
    preflight-transport|missing|unstable|duplicate|arp-profile|worker-pair|off-mismatch|off-transport|off-no-opt-in|off-duplicate|off-bad-closure)
      [[ ! -e "$case_dir/model" && ! -e "$case_dir/mutations" ]] ;;
    stop-failed)
      [[ ! -e "$case_dir/model" ]]
      grep -Fxq 'start host2' "$case_dir/mutations"
      jq -e '.modelExit == 255 and .rayRestoration == "pass"' "$case_dir/model-evidence-coordinator/result.json" >/dev/null ;;
    restore-start|restore-probe|inactive-drift|off-drift)
      jq -e '.result == "fail" and .modelExit == 0 and .rayRestoration == "fail"' "$case_dir/model-evidence-coordinator/result.json" >/dev/null ;;
    *)
      cmp "$case_dir/model-evidence-coordinator/ray-before.tsv" "$case_dir/model-evidence-coordinator/ray-after.tsv"
      jq -e '.rayRestoration == "pass"' "$case_dir/model-evidence-coordinator/result.json" >/dev/null
      if [[ "$scenario" == inactive ]]; then [[ ! -e "$case_dir/mutations" ]]; fi
      if [[ "$scenario" == off || "$scenario" == off-source-edit ]]; then
        [[ ! -e "$case_dir/mutations" ]]
        [[ $(grep -c 'absent-off' "$case_dir/model-evidence-coordinator/ray-after.tsv") == 4 ]]
        jq -e '.nodes | length == 4' "$case_dir/model-evidence-coordinator/ray-off-attestations.json" >/dev/null
      fi
      if [[ "$scenario" == mixed ]]; then [[ $(wc -l <"$case_dir/mutations" | tr -d ' ') == 4 ]]; fi
      ;;
  esac
  printf 'PASS %s\n' "$scenario"
}
run_case active 0
run_case bounded-profile 0 minimax-m3-nvfp4-quads-v028-bounded16k
run_case mixed 0
run_case inactive 0
run_case preflight-transport 1
run_case missing 1
run_case unstable 1
run_case duplicate 1
run_case stop-failed 255
run_case model-failed 7
run_case restore-start 1
run_case restore-probe 1
run_case inactive-drift 1
run_case signal-term 143
run_case signal-int 130
run_case arp-profile 1
run_case worker-pair 1
run_case off 0
run_case off-no-opt-in 1
run_case off-mismatch 1
run_case off-transport 1
run_case off-drift 1
run_case off-duplicate 1
run_case off-bad-closure 1
run_case off-source-edit 0
