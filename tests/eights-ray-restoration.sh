#!/usr/bin/env bash
# Offline Eights coordinator regression. All SSH, Ray, fabric, and model
# behavior is simulated; this test must never contact or modify a real host.
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repo/scripts"
cp "$repo_root/scripts/eights-switch-model.sh" "$fixture/repo/scripts/"

cat >"$fixture/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -eu
args=("$@")
host=${args[${#args[@]}-2]}
command=${args[${#args[@]}-1]}
state_file="$TEST_CASE/state-$host"
printf '%s %s\n' "$host" "$command" >>"$TEST_CASE/ssh.log"
case "$command" in
  *cluster-profile.json*)
    [[ "$TEST_SCENARIO" != host-binding || "$host" != host4 ]]
    ;;
  *arp_ignore*)
    [[ "$TEST_SCENARIO" != fabric-profile || "$host" != host4 ]]
    ;;
  *'ip -j -4 route get'*)
    if [[ "$TEST_SCENARIO" == peer-route && "$host" == host4 && "$command" == *192.0.2.5* ]]; then
      exit 1
    fi
    ;;
  *LoadState*)
    if [[ "$TEST_SCENARIO" == ray-inspection && "$host" == host4 ]]; then exit 255; fi
    if [[ "$TEST_SCENARIO" == ray-missing && "$host" == host4 ]]; then
      printf 'not-found\ninactive\n'
      exit 0
    fi
    if [[ "$TEST_SCENARIO" == ray-unstable && "$host" == host4 ]]; then
      printf 'loaded\nactivating\n'
      exit 0
    fi
    printf 'loaded\n'
    cat "$state_file"
    ;;
  *ray.cluster_resources*)
    if [[ "$TEST_SCENARIO" == ray-before && ! -e "$TEST_CASE/model" ]]; then exit 1; fi
    if [[ "$TEST_SCENARIO" == ray-after && -e "$TEST_CASE/model" ]]; then exit 1; fi
    printf '{"CPU": 160.0, "GPU": 8.0, "alive_nodes": 8, "nodes": ["192.0.2.1"]}\n'
    ;;
  *'stop ray-cluster.service')
    printf 'stop %s\n' "$host" >>"$TEST_CASE/mutations"
    printf 'inactive\n' >"$state_file"
    if [[ "$TEST_SCENARIO" == stop-failed && "$host" == host4 ]]; then exit 255; fi
    ;;
  *'start ray-cluster.service')
    printf 'start %s\n' "$host" >>"$TEST_CASE/mutations"
    if [[ "$TEST_SCENARIO" == restore-start && "$host" == host4 ]]; then exit 1; fi
    printf 'active\n' >"$state_file"
    ;;
  *) exit 99 ;;
esac
MOCK

cat >"$fixture/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
# Do not make simulated retry loops consume wall-clock time.
exit 0
MOCK

cat >"$fixture/repo/scripts/eights-vllm-acceptance.sh" <<'MOCK'
#!/usr/bin/env bash
touch "$TEST_CASE/model"
case "$TEST_SCENARIO" in
  model-failed) exit 7 ;;
  signal-term) kill -TERM "$PPID"; exit 0 ;;
  signal-int) kill -INT "$PPID"; exit 0 ;;
esac
MOCK
chmod +x "$fixture/bin/ssh" "$fixture/bin/sleep" "$fixture/repo/scripts/eights-vllm-acceptance.sh"
touch "$fixture/key" "$fixture/known_hosts"

run_case() {
  local scenario=$1 expected=$2 actual=0 case_dir
  case_dir="$fixture/$scenario"
  mkdir "$case_dir"
  for index in {1..8}; do printf 'active\n' >"$case_dir/state-host$index"; done

  jq -n '{railAInterface:"fabric0",railBInterface:"fabric1",nodes:[range(1;9) | {
    host:("host"+tostring),railA:("192.0.2."+tostring+"/24"),railB:("198.51.100."+tostring+"/24")}]}' \
    >"$case_dir/inventory.json"
  jq -n '{nodes:[range(0;8) as $rank | {
    host:("host"+($rank+1|tostring)),hostname:("host"+($rank+1|tostring)),rank:$rank,
    role:(if $rank == 0 then "head" else "worker" end),
    systemClosure:("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-host"+($rank+1|tostring))}]}' \
    >"$case_dir/host-bindings.json"
  cat >"$case_dir/config" <<EOF
EIGHTS_NEMOTRON_ULTRA_INVENTORY_FILE='$case_dir/inventory.json'
EIGHTS_SSH_IDENTITY_FILE='$fixture/key'
EIGHTS_SSH_KNOWN_HOSTS_FILE='$fixture/known_hosts'
EIGHTS_HOST_BINDINGS_FILE='$case_dir/host-bindings.json'
EOF

  PATH="$fixture/bin:$PATH" TEST_CASE="$case_dir" TEST_SCENARIO="$scenario" \
    GB10_MODEL_PROFILE=nemotron-ultra-eights-vllm022 \
    GB10_EIGHTS_SWITCH_CONFIG="$case_dir/config" \
    GB10_PRIVATE_EVIDENCE_ROOT="$case_dir/evidence" \
    GB10_CLUSTER_EVIDENCE_DIR="$case_dir/model-evidence" \
    bash "$fixture/repo/scripts/eights-switch-model.sh" acceptance \
    >"$case_dir/output" 2>&1 || actual=$?

  [[ "$actual" == "$expected" ]] || {
    cat "$case_dir/output" >&2
    printf 'FAIL %s: exit %s expected %s\n' "$scenario" "$actual" "$expected" >&2
    exit 1
  }

  case "$scenario" in
    host-binding|fabric-profile|peer-route|ray-inspection|ray-missing|ray-unstable|ray-before)
      [[ ! -e "$case_dir/model" && ! -e "$case_dir/mutations" ]]
      ;;
    stop-failed)
      [[ ! -e "$case_dir/model" ]]
      grep -Fxq 'start host4' "$case_dir/mutations"
      jq -e '.modelExit == 255 and .rayRestoration == "pass"' \
        "$case_dir/model-evidence-coordinator/result.json" >/dev/null
      ;;
    restore-start|ray-after)
      jq -e '.result == "fail" and .modelExit == 0 and .rayRestoration == "fail"' \
        "$case_dir/model-evidence-coordinator/result.json" >/dev/null
      ;;
    *)
      cmp "$case_dir/model-evidence-coordinator/ray-before.tsv" \
        "$case_dir/model-evidence-coordinator/ray-after.tsv"
      jq -e '.rayRestoration == "pass"' \
        "$case_dir/model-evidence-coordinator/result.json" >/dev/null
      ;;
  esac
  printf 'PASS eights-%s\n' "$scenario"
}

run_case success 0
run_case host-binding 1
run_case fabric-profile 1
run_case peer-route 1
run_case ray-inspection 1
run_case ray-missing 1
run_case ray-unstable 1
run_case ray-before 1
run_case stop-failed 255
run_case model-failed 7
run_case restore-start 1
run_case ray-after 1
run_case signal-term 143
run_case signal-int 130
