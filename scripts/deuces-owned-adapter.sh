# Sourced candidate for explicit finite owned mode only. The caller supplies the
# existing remote/scp functions, command arrays and acceptance variables. No
# network restoration is implemented here. Do not source as a standalone job.
owned_enabled=${GB10_DEUCES_OWNED_LIFECYCLE:-0}
[[ "$owned_enabled" == 0 || "$owned_enabled" == 1 ]] || die 'invalid owned lifecycle mode'
owned_hosts=() owned_nodes=() owned_roots=() owned_configs=() owned_pythons=()
owned_attempted=() owned_cids=() owned_hash_cleanup=() owned_hash_archive=()
owned_declared=0

owned_settings_json() {
  local lease=${GB10_DEUCES_OWNED_LEASE_SECONDS:-}
  [[ "$lease" =~ ^[1-9][0-9]*$ ]] || return 1
  jq -n --argjson startup "$startup_timeout" --argjson request "$request_timeout" \
    --argjson serve "$serve_max_seconds" --argjson qualify "$qualify_and_serve" --argjson lease "$lease" \
    --argjson hermes "$accept_hermes" --argjson streaming "$accept_streaming" \
    --argjson structured "$accept_structured" --argjson image "$accept_image" --argjson audio "$accept_audio" \
    --argjson stressTokens "$stress_minimum_prompt_tokens" --argjson concurrency "$stress_concurrency" \
    '{startup:$startup,request:$request,serve:$serve,qualify:($qualify==1),lease:$lease,
      hermes:$hermes,streaming:$streaming,structured:$structured,image:$image,audio:$audio,
      stressTokens:$stressTokens,concurrency:$concurrency}'
}

owned_local_python() {
  "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$repo_root/scripts/deuces-owned-adapter.py" "$@"
}

owned_bounded_scp() {
  timeout --signal=TERM --kill-after=10 180 scp "$@"
}

owned_budget_preflight() {
  [[ "$owned_enabled" == 1 ]] || return 0
  # This precedes every resource mutation; no implicit fallback on refusal.
  local settings
  settings=$(owned_settings_json) || return 1
  owned_local_python budget "$settings" >/dev/null
}

owned_slots_declare() {
  [[ "$owned_enabled" == 1 ]] || return 0
  local rank host node selected_python metadata image_json layers argv token source_engine source_container source_adapter settings
  local sources nodes='[]' hashes='[]' cfg host_meta root shell_sha python_sha
  owned_owner=${GB10_DEUCES_OWNED_INVOCATION_OWNER:-}
  [[ "$owned_owner" =~ ^[a-f0-9]{64}$ ]] || return 1
  # Both remote configurations and the complete hash inventory are declared
  # before hash helper staging, test-file copies, guards or container writes.
  token=$("${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I -c 'import uuid; print(uuid.uuid4().hex)') || return 1
  source_engine=$(sha256sum "$repo_root/scripts/deuces-$engine-acceptance.sh" | awk '{print $1}') || return 1
  source_container=$(sha256sum "$repo_root/scripts/deuces-owned-container.py" | awk '{print $1}') || return 1
  python_sha=$(sha256sum "$repo_root/scripts/deuces-owned-adapter.py" | awk '{print $1}') || return 1
  shell_sha=$(sha256sum "$repo_root/scripts/deuces-owned-adapter.sh" | awk '{print $1}') || return 1
  source_adapter=$(printf '%s  deuces-owned-adapter.py\n%s  deuces-owned-adapter.sh\n' "$python_sha" "$shell_sha" | sha256sum | awk '{print $1}') || return 1
  sources=$(jq -n --arg engine "$source_engine" --arg containerHelper "$source_container" --arg hashHelper "$hash_helper_sha" --arg adapter "$source_adapter" \
    '{engine:$engine,containerHelper:$containerHelper,hashHelper:$hashHelper,adapter:$adapter}') || return 1
  owned_hosts=("$left_host" "$right_host")
  owned_nodes=("$DEUCES_LEFT_NODE" "$DEUCES_RIGHT_NODE")
  for rank in 0 1; do
    host=${owned_hosts[$rank]}; node=${owned_nodes[$rank]}
    if (( rank == 0 )); then
      selected_python=${GB10_DEUCES_LEFT_OWNED_PYTHON:-}
      argv=$(printf '%s\n' "${left_command[@]}" | jq -Rsc 'split("\n")[:-1]') || return 1
    else
      selected_python=${GB10_DEUCES_RIGHT_OWNED_PYTHON:-}
      argv=$(printf '%s\n' "${right_command[@]}" | jq -Rsc 'split("\n")[:-1]') || return 1
    fi
    [[ "$selected_python" =~ ^/nix/store/[A-Za-z0-9][A-Za-z0-9+._-]*/bin/python3(\.[0-9]+)*$ ]] || return 1
    metadata=$(remote_profile_gate "$host" "
      test \"\$(hostname -s)\" = '$node'
      test -x '$selected_python'
      test \"\$(readlink -f '$selected_python')\" = '$selected_python'
      test -x /run/current-system/sw/bin/timeout
      hostname -s
      readlink -f /run/current-system
      readlink -f '$selected_python'
      for tool in podman systemctl systemd-run journalctl hostname; do command -v \"\$tool\"; done
    ") || return 1
    host_meta=$(printf '%s\n' "$metadata" | jq -Rsc 'split("\n")[:-1] | select(length==8)') || return 1
    [[ -n "$host_meta" ]] || return 1
    [[ "$(jq -r '.[2]' <<<"$host_meta")" == "$selected_python" ]] || return 1
    image_json=$(remote_profile_gate "$host" "podman image inspect '$image'") || return 1
    layers=$(jq -c '.[0].RootFS.Layers' <<<"$image_json" | sha256sum | awk '{print $1}') || return 1
    root="/tmp/gb10sor-owned-model.$token-rank$rank"
    cfg=$(jq -n --argjson rank "$rank" --arg host "$host" --arg node "$node" --arg stateRoot "$root" \
      --argjson metadata "$host_meta" --argjson image "$image_json" --arg imageRef "$image" --arg layers "$layers" --argjson argv "$argv" \
      '{rank:$rank,host:$host,node:$node,stateRoot:$stateRoot,systemClosure:$metadata[1],python:$metadata[2],
        tools:{podman:$metadata[3],systemctl:$metadata[4],"systemd-run":$metadata[5],journalctl:$metadata[6],hostname:$metadata[7]},
        imageRef:$imageRef,imageId:($image[0].Id|sub("^sha256:";"")),imageLayersSha256:$layers,argv:$argv}') || return 1
    nodes=$(jq -c --argjson node "$cfg" '.+[$node]' <<<"$nodes") || return 1
    owned_roots+=("$root"); owned_pythons+=("$(jq -r '.python' <<<"$cfg")")
    owned_attempted+=(no); owned_cids+=('')
  done
  for ((rank=0; rank<${#hash_hosts[@]}; rank++)); do
    cfg=$(jq -n --arg slot "${hash_kinds[$rank]}-${hash_ranks[$rank]}" --argjson rank "${hash_ranks[$rank]#rank}" \
      --arg host "${hash_hosts[$rank]}" --arg stateRoot "${hash_states[$rank]}" --arg unit "${hash_units[$rank]}" \
      --arg token "${hash_tokens[$rank]}" --arg helperSha256 "$hash_helper_sha" --arg expectedTreeSha256 "${hash_expected[$rank]}" \
      '{slot:$slot,rank:$rank,host:$host,stateRoot:$stateRoot,unit:$unit,token:$token,helperSha256:$helperSha256,expectedTreeSha256:$expectedTreeSha256}') || return 1
    hashes=$(jq -c --argjson value "$cfg" '.+[$value]' <<<"$hashes") || return 1
  done
  settings=$(owned_settings_json) || return 1
  jq -n --arg invocationOwner "$owned_owner" --arg runId "$run_id" --arg engine "$engine" \
    --argjson sourceSha256 "$sources" --argjson nodes "$nodes" --argjson hashes "$hashes" --argjson settings "$settings" \
    '{invocationOwner:$invocationOwner,runId:$runId,engine:$engine,sourceSha256:$sourceSha256,nodes:$nodes,hashes:$hashes,settings:$settings}' \
    >"$evidence_dir/owned-input.json" || return 1
  owned_local_python plan "$evidence_dir/owned-input.json" "$repo_root/scripts/deuces-owned-container.py" "$evidence_dir/owned" \
    >"$evidence_dir/owned-declaration.sha256" || return 1
  for rank in 0 1; do
    owned_configs+=("$(sha256sum "$evidence_dir/owned/rank$rank-config.json" | awk '{print $1}')")
  done
  owned_budget_sha=$(sha256sum "$evidence_dir/owned/budget.json" | awk '{print $1}') || return 1
  readonly owned_budget_sha
  owned_declared=1
}

owned_verify_config() {
  local rank=$1 expected observed declaration_sha
  [[ "$owned_declared" == 1 ]] || return 1
  declaration_sha=$(cat "$evidence_dir/owned-declaration.sha256") || return 1
  [[ "$declaration_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
  observed=$(sha256sum "$evidence_dir/owned/declaration.json" | awk '{print $1}') || return 1
  [[ "$observed" == "$declaration_sha" ]] || return 1
  expected=$(jq -er --argjson rank "$rank" '.containers[]|select(.rank==$rank)|.configSha256' "$evidence_dir/owned/declaration.json") || return 1
  observed=$(sha256sum "$evidence_dir/owned/rank$rank-config.json" | awk '{print $1}') || return 1
  [[ "$observed" == "$expected" && "$expected" == "${owned_configs[$rank]}" ]]
}

owned_verify_sources() {
  local file engine_sha container_sha hash_sha python_sha shell_sha adapter_sha
  for file in "deuces-$engine-acceptance.sh" deuces-owned-container.py cluster-weight-hash.sh deuces-owned-adapter.py deuces-owned-adapter.sh; do
    [[ -f "$repo_root/scripts/$file" && ! -L "$repo_root/scripts/$file" ]] || return 1
  done
  engine_sha=$(sha256sum "$repo_root/scripts/deuces-$engine-acceptance.sh" | awk '{print $1}') || return 1
  container_sha=$(sha256sum "$repo_root/scripts/deuces-owned-container.py" | awk '{print $1}') || return 1
  hash_sha=$(sha256sum "$repo_root/scripts/cluster-weight-hash.sh" | awk '{print $1}') || return 1
  python_sha=$(sha256sum "$repo_root/scripts/deuces-owned-adapter.py" | awk '{print $1}') || return 1
  shell_sha=$(sha256sum "$repo_root/scripts/deuces-owned-adapter.sh" | awk '{print $1}') || return 1
  adapter_sha=$(printf '%s  deuces-owned-adapter.py\n%s  deuces-owned-adapter.sh\n' "$python_sha" "$shell_sha" | sha256sum | awk '{print $1}') || return 1
  jq -e --arg engine "$engine_sha" --arg containerHelper "$container_sha" --arg hashHelper "$hash_sha" --arg adapter "$adapter_sha" \
    '.sourceSha256=={engine:$engine,containerHelper:$containerHelper,hashHelper:$hashHelper,adapter:$adapter}' \
    "$evidence_dir/owned/declaration.json" >/dev/null
}

owned_parent_ack() {
  [[ "$owned_enabled" == 1 ]] || return 0
  local channel=${GB10_DEUCES_DECLARATION_CHANNEL:-} pin=${GB10_DEUCES_DECLARATION_HELPER_SHA256:-}
  local wait_seconds=${GB10_DEUCES_DECLARATION_WAIT_SECONDS:-120} actual helper="$repo_root/scripts/deuces-declaration-channel.py"
  [[ "$channel" == /* && "$channel" != *$'\n'* && "$channel" != *$'\r'* && "$pin" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] && (( wait_seconds <= 120 )) || return 1
  [[ -f "$helper" && ! -L "$helper" ]] || return 1
  actual=$(sha256sum "$helper" | awk '{print $1}') || return 1
  [[ "$actual" == "$pin" ]] || return 1
  owned_verify_config 0 && owned_verify_config 1 && owned_verify_sources || return 1
  jq -e --arg owner "$owned_owner" '.invocationOwner==$owner' "$evidence_dir/owned/declaration.json" >/dev/null || return 1
  "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$helper" offer "$channel" "$evidence_dir/owned/declaration.json" \
    >"$evidence_dir/owned/parent-offer.txt" 2>"$evidence_dir/owned/parent-offer.stderr" || return 1
  "${GB10_DEUCES_LOCAL_PYTHON:-python3}" -I "$helper" wait "$channel" "$evidence_dir/owned/declaration.json" "$wait_seconds" \
    >"$evidence_dir/owned/parent-ack.json" 2>"$evidence_dir/owned/parent-ack.stderr" || return 1
  # The parent's helper is pinned separately, not by inventing a fifth source4
  # field. Recheck source/config seals after the blocking exchange and before
  # the first resource staging call. A failed ACK never falls back to legacy.
  actual=$(sha256sum "$helper" | awk '{print $1}') || return 1
  [[ "$actual" == "$pin" ]] || return 1
  owned_verify_config 0 && owned_verify_config 1 && owned_verify_sources
}

owned_action() {
  local rank=$1 action=$2 bound=150 quoted
  [[ "$owned_declared" == 1 && "${owned_attempted[$rank]}" != no ]] || return 1
  owned_verify_config "$rank" || return 1
  case "$action" in cleanup) bound=360 ;; disarm) bound=180 ;; prepare|arm|create|start|inspect) ;; *) return 1 ;; esac
  printf -v quoted '%q ' /run/current-system/sw/bin/timeout --signal=TERM --kill-after=30 "$bound" \
    "${owned_pythons[$rank]}" -I "${owned_roots[$rank]}/worker.py" "$action" "${owned_roots[$rank]}" "${owned_configs[$rank]}"
  remote_profile_gate "${owned_hosts[$rank]}" "cd /; sudo -n prlimit --pid \$\$ --memlock=unlimited; $quoted"
}

owned_slots_launch() {
  local rank first=0 second=1 root current_id current_layers
  [[ "$owned_declared" == 1 ]] || return 1
  # Reconcile the declared cached image against the full preflight, not merely
  # the preliminary read-only metadata used to render immutable configurations.
  for rank in 0 1; do
    owned_verify_config "$rank" || return 1
    current_id=$(jq -er '.imageId' "$evidence_dir/rank$rank-preflight.json") || return 1
    current_layers=$(jq -er '.rootfsLayersSha256 // .imageLayersSha256' "$evidence_dir/rank$rank-preflight.json") || return 1
    jq -e --arg id "$current_id" --arg layers "$current_layers" '.imageId==$id and .imageLayersSha256==$layers' \
      "$evidence_dir/owned/rank$rank-config.json" >/dev/null || return 1
  done
  for rank in 0 1; do
    root=${owned_roots[$rank]}
    owned_attempted[$rank]=attempted
    printf '%s\tsetup-attempted\n' "$rank" >>"$evidence_dir/owned/setup.tsv" || return 1
    remote_profile_gate "${owned_hosts[$rank]}" "umask 077; mkdir '$root'; printf '%s\\n' '$owned_owner' >'$root/OWNER'" || return 1
    owned_bounded_scp "${scp_options[@]}" "$repo_root/scripts/deuces-owned-container.py" "${owned_hosts[$rank]}:$root/worker.py" || return 1
    owned_bounded_scp "${scp_options[@]}" "$evidence_dir/owned/rank$rank-config.json" "${owned_hosts[$rank]}:$root/config.json" || return 1
    owned_action "$rank" prepare >"$evidence_dir/owned/rank$rank-prepare.json" || return 1
    owned_attempted[$rank]=prepared
  done
  # All prerequisites for both ranks before the first model can be created.
  for rank in 0 1; do owned_action "$rank" arm >"$evidence_dir/owned/rank$rank-arm.json" || return 1; done
  for rank in 0 1; do
    owned_action "$rank" create >"$evidence_dir/owned/rank$rank-create.json" || return 1
    owned_cids[$rank]=$(jq -er '.cid | select(test("^[a-f0-9]{64}$"))' "$evidence_dir/owned/rank$rank-create.json") || return 1
    printf '%s\n' "${owned_cids[$rank]}" >"$evidence_dir/rank$rank-container-id.txt" || return 1
  done
  [[ "${start_order:-head-first}" != worker-first ]] || { first=1; second=0; }
  owned_action "$first" start >"$evidence_dir/owned/rank$first-start.json" || return 1
  sleep 2
  owned_action "$second" start >"$evidence_dir/owned/rank$second-start.json"
}

owned_rank() {
  [[ "$1" == "$left_host" && "$2" == "$left_container" ]] && { printf 0; return 0; }
  [[ "$1" == "$right_host" && "$2" == "$right_container" ]] && { printf 1; return 0; }
  return 1
}

owned_inspect() {
  local rank
  rank=$(owned_rank "$1" "$2") || return 1
  owned_action "$rank" inspect
}

container_running() {
  if [[ "$owned_enabled" == 1 ]]; then
    owned_inspect "$1" "$2" | jq -er 'if .State.Running == true then "true" elif .State.Running == false then "false" else error("missing running state") end'
  else
    remote "$1" "podman inspect '$2' --format '{{.State.Running}}'"
  fi
}

container_logs() {
  local rank cid quoted podman_path
  if [[ "$owned_enabled" == 1 ]]; then
    rank=$(owned_rank "$1" "$2") || return 1
    owned_action "$rank" inspect >/dev/null || return 1
    cid=${owned_cids[$rank]}
    [[ "$cid" =~ ^[a-f0-9]{64}$ ]] || return 1
    podman_path=$(jq -er '.tools.podman' "$evidence_dir/owned/rank$rank-config.json") || return 1
    printf -v quoted '%q ' /run/current-system/sw/bin/timeout --kill-after=10 60 "$podman_path" logs "$cid"
    remote_profile_gate "$1" "$quoted"
  else
    remote "$1" "podman logs '$2'"
  fi
}

owned_exec() {
  local host=$1 container=$2 rank cid cap kind=runtime quoted podman_path budget_sha
  shift 2
  rank=$(owned_rank "$host" "$container") || return 1
  owned_action "$rank" inspect >/dev/null || return 1
  cid=${owned_cids[$rank]}
  [[ "$cid" =~ ^[a-f0-9]{64}$ ]] || return 1
  case "${2:-}" in
    /opt/gb10/model-openai-smoke.py)
      kind=${3:-}
      case "$kind" in multimodal) kind=image ;; stream) kind=streaming ;; esac ;;
    /opt/gb10/hermes-openai-smoke.py) kind=hermes ;;
    /opt/gb10/model-openai-stress.py) kind=stress ;;
    -c) kind=runtime ;;
    *) return 1 ;;
  esac
  budget_sha=$(sha256sum "$evidence_dir/owned/budget.json" | awk '{print $1}') || return 1
  [[ "$budget_sha" == "$owned_budget_sha" ]] || return 1
  cap=$(jq -er --arg kind "$kind" '.execCaps[$kind] | select(type=="number" and .>0)' "$evidence_dir/owned/budget.json") || return 1
  podman_path=$(jq -er '.tools.podman' "$evidence_dir/owned/rank$rank-config.json") || return 1
  printf -v quoted '%q ' /run/current-system/sw/bin/timeout --signal=TERM --kill-after=30 "$cap" "$podman_path" exec "$cid" "$@"
  remote_profile_gate "$host" "cd /; sudo -n prlimit --pid \$\$ --memlock=unlimited; $quoted"
}

owned_slots_cleanup() {
  local rank cleanup_status disarm_status archive_status capture_status inspect_status value rows='[]' path removed_by_guard inspection_uncertain
  local cleanup_results=() disarm_results=() archive_results=() capture_results=() guard_removed=()
  [[ "$owned_declared" == 1 ]] || return 1
  # An archive filesystem failure cannot prevent attempts to stop other ranks.
  mkdir -p "$evidence_dir/owned/archive" || true
  for rank in 0 1; do
    cleanup_status=1; disarm_status=1; archive_status=1; capture_status=0; removed_by_guard=0; inspection_uncertain=0
    if [[ "${owned_attempted[$rank]}" != no ]]; then
      # Stop every attempted rank even when earlier evidence capture failed.
      if [[ "${owned_cids[$rank]}" =~ ^[a-f0-9]{64}$ ]]; then
        inspect_status=1
        owned_action "$rank" inspect >"$evidence_dir/rank$rank-final-inspect.json" 2>"$evidence_dir/rank$rank-final-inspect.stderr" && inspect_status=0
        if (( inspect_status == 0 )) && jq -e -s 'length==1 and .[0]==null' "$evidence_dir/rank$rank-final-inspect.json" >/dev/null; then
          # This is the exact helper's positive removed-CID inspection, NOT an
          # absent/failed Podman query. Strict disarm below must still establish
          # original cleanup/removed/journal/cgroup proof. Do not overwrite the
          # timer's cleanup.json with a second manual cleanup invocation.
          removed_by_guard=1
          capture_status=1
        elif (( inspect_status == 0 )) && jq -e -s --arg cid "${owned_cids[$rank]}" \
          'length==1 and (.[0]|type=="object") and .[0].Id==$cid and
           (.[0].State.Running|type=="boolean") and (.[0].State.Pid|type=="number")' \
          "$evidence_dir/rank$rank-final-inspect.json" >/dev/null; then
          container_logs "${owned_hosts[$rank]}" "${run_id}-rank$rank" >"$evidence_dir/rank$rank.log" 2>"$evidence_dir/rank$rank-log.stderr" || capture_status=1
        else
          # Lost/foreign/unknown inspection is not a null result. Preserve any
          # original guard receipt and leave its independent guard armed; do
          # not overwrite unknown prior cleanup provenance with a new writer.
          inspection_uncertain=1
          capture_status=1
        fi
      fi
      if (( removed_by_guard == 0 && inspection_uncertain == 0 )); then
        owned_action "$rank" cleanup >"$evidence_dir/owned/rank$rank-cleanup.json" 2>"$evidence_dir/owned/rank$rank-cleanup.stderr" && cleanup_status=0
      fi
    fi
    cleanup_results+=("$cleanup_status"); disarm_results+=("$disarm_status")
    archive_results+=("$archive_status"); capture_results+=("$capture_status")
    guard_removed+=("$removed_by_guard")
  done
  # Every stop has been attempted before disarm or any archive transfer. A
  # failed first-rank stop never prevents the second independent stop attempt.
  for rank in 0 1; do
    if [[ "${cleanup_results[$rank]}" == 0 || "${guard_removed[$rank]}" == 1 ]]; then
      if owned_action "$rank" disarm >"$evidence_dir/owned/rank$rank-disarm.json" 2>"$evidence_dir/owned/rank$rank-disarm.stderr"; then
        disarm_results[$rank]=0
        cleanup_results[$rank]=0
      fi
    fi
  done
  for rank in 0 1; do
    if [[ "${owned_attempted[$rank]}" != no ]]; then
      owned_bounded_scp "${scp_options[@]}" -r "${owned_hosts[$rank]}:${owned_roots[$rank]}" "$evidence_dir/owned/archive/" \
        >"$evidence_dir/owned/rank$rank-archive.txt" 2>&1 && archive_results[$rank]=0
    fi
  done
  # Build JSON only after both stop/disarm attempts; a local serialization error
  # must not abandon a still-running second rank.
  for rank in 0 1; do
    path="owned/archive/${owned_roots[$rank]##*/}"
    cleanup_status=${cleanup_results[$rank]}; disarm_status=${disarm_results[$rank]}
    archive_status=${archive_results[$rank]}; capture_status=${capture_results[$rank]}
    value=$(jq -n --argjson rank "$rank" --arg archivePath "$path" --argjson cleanupStatus "$cleanup_status" \
      --argjson disarmStatus "$disarm_status" --argjson archiveStatus "$archive_status" --argjson captureStatus "$capture_status" \
      '{rank:$rank,archivePath:$archivePath,cleanupStatus:$cleanupStatus,disarmStatus:$disarmStatus,archiveStatus:$archiveStatus,captureStatus:$captureStatus}') || return 1
    rows=$(jq -c --argjson value "$value" '.+[$value]' <<<"$rows") || return 1
  done
  printf '%s\n' "$rows" >"$evidence_dir/owned/container-cleanup-status.json" || return 1
  jq -e 'all(.[]; .cleanupStatus==0 and .disarmStatus==0 and .archiveStatus==0)' <<<"$rows" >/dev/null
}

owned_resources_finish() {
  local rank value rows hashes='[]'
  [[ "$owned_declared" == 1 ]] || return 1
  rows=$(cat "$evidence_dir/owned/container-cleanup-status.json") || return 1
  for ((rank=0; rank<${#hash_hosts[@]}; rank++)); do
    value=$(jq -n --arg slot "${hash_kinds[$rank]}-${hash_ranks[$rank]}" --arg archivePath "weight-hash-state/${hash_units[$rank]}" \
      --arg outputPath "weight-hash-$rank-cleanup.txt" --argjson cleanupStatus "${owned_hash_cleanup[$rank]:-1}" --argjson archiveStatus "${owned_hash_archive[$rank]:-1}" \
      '{slot:$slot,archivePath:$archivePath,outputPath:$outputPath,cleanupStatus:$cleanupStatus,archiveStatus:$archiveStatus}') || return 1
    hashes=$(jq -c --argjson value "$value" '.+[$value]' <<<"$hashes") || return 1
  done
  jq -n --argjson containers "$rows" --argjson hashes "$hashes" '{containers:$containers,hashes:$hashes}' >"$evidence_dir/owned/cleanup-status.json" || return 1
  owned_local_python aggregate "$evidence_dir" "$evidence_dir/owned/cleanup-status.json" >"$evidence_dir/owned/aggregate-output.json"
}
