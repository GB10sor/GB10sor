#!/usr/bin/env bash
# Offline: selecting direct must not change the already-qualified switched recipe.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
eval "$(sed -n '/^arguments_for_topology() {$/,/^}$/p' "$root/scripts/deuces-sglang-acceptance.sh")"
eval "$(sed -n '/^profile_allows_topology() {$/,/^}$/p' "$root/scripts/deuces-sglang-acceptance.sh")"
profile=$(jq -c '.profiles["glm53-flash-nvfp4-sglang-dflash2"]' "$root/model-profiles.json")
base=$(jq -c '.arguments' <<<"$profile")
digest() { shasum -a 256 | awk '{print $1}'; }
# Compact JSON including trailing newline, sealed from the switched recipe and
# the successful private 16K/C8 smaller-prefill receipt respectively.
[[ $(printf '%s\n' "$base" | digest) == 1815901757d334c248773ab81b5abf3e6155e93fee02aa28645b7aa6b7ac7164 ]]
[[ $(arguments_for_topology switch <<<"$profile") == "$base" ]]
direct=$(arguments_for_topology direct <<<"$profile")
[[ $(printf '%s\n' "$direct" | digest) == 7bc4ea438319aed181726a26223423a18b625d30f5bd824393d833dec05dd343 ]]
expected=$(jq -c '.topologyArgumentSets.direct' <<<"$profile")
[[ "$direct" == "$expected" ]]
printf 'PASS sealed GLM switched argv unchanged and exact smaller-prefill direct argv\n'
target=$(jq -c '.profiles["glm53-flash-nvfp4-sglang-target-only"]' "$root/model-profiles.json")
[[ $(arguments_for_topology direct <<<"$target" | digest) == 5dae4f3ee1c783d336fc3310582bf79e6dddc31b4d611dbb2c3888eb30d3ddb3 ]]
profile_allows_topology direct <<<"$target"
if profile_allows_topology switch <<<"$target"; then exit 1; fi
for invalid in 'null' '[]' '"direct"' '["direct","direct"]' '["direct","typo"]' '[null]'; do
  if profile_allows_topology direct <<<"{\"allowedTopologies\":$invalid}" 2>/dev/null; then exit 1; fi
done
for topology in direct switch; do
  profile_allows_topology "$topology" <<<'{}'
  profile_allows_topology "$topology" <<<'{"allowedTopologies":["direct","switch"]}'
done
if profile_allows_topology typo <<<'{}'; then exit 1; fi
printf 'PASS target-only sealed argv and fail-closed topology scope\n'
while IFS= read -r other; do
  for topology in direct switch; do
    actual=$(arguments_for_topology "$topology" <<<"$other") || exit 1
    [[ "$actual" == "$(jq -c '.arguments' <<<"$other")" ]] || exit 1
  done
done < <(jq -c '.profiles | to_entries[] |
  select(.key!="glm53-flash-nvfp4-sglang-dflash2" and
    .key!="radixark-qwen38" and .value.engine=="sglang" and
    ((.value.benchmark.nodes // 2) > 1)) |
  .value' "$root/model-profiles.json")
printf 'PASS all other multi-node SGLang profile arguments unchanged\n'
# Solo's explicit TP=1 argv remains invalid for this two-node coordinator.
solo=$(jq -c '.profiles["radixark-qwen38"]' "$root/model-profiles.json")
if arguments_for_topology direct <<<"$solo" >/dev/null 2>&1; then exit 1; fi
for topology in switch direct; do
  [[ $(arguments_for_topology "$topology" <<<'{"arguments":["--sleep-on-idle"]}') == '["--sleep-on-idle"]' ]]
done
printf 'PASS profiles without topology arguments remain unchanged\n'
for invalid in \
  '{"arguments":[],"topologyArguments":null}' \
  '{"arguments":[],"topologyArguments":{"typo":[]}}' \
  '{"arguments":[],"topologyArguments":{"direct":"--disable-cuda-graph"}}' \
  '{"arguments":[],"topologyArguments":{"direct":[null]}}' \
  '{"arguments":[],"topologyArguments":{"direct":["one\ntwo"]}}' \
  '{"arguments":[],"topologyArguments":{"direct":["--host=0.0.0.0"]}}' \
  '{"arguments":[],"topologyArgumentSets":null}' \
  '{"arguments":[],"topologyArgumentSets":{"direct":[]}}' \
  '{"arguments":[],"topologyArgumentSets":{"typo":["--eager"]}}' \
  '{"arguments":[],"topologyArgumentSets":{"switch":[null]}}' \
  '{"arguments":[],"topologyArgumentSets":{"direct":["one\u0000two"]}}' \
  '{"arguments":[],"topologyArgumentSets":{"direct":["one\rtwo"]}}' \
  '{"arguments":[],"topologyArgumentSets":{"direct":["--eager"]},"topologyArguments":{"direct":[]}}' \
  '{"arguments":["--eager"],"topologyArguments":{"switch":["--eager"]}}' \
  '{"arguments":[],"topologyArgumentSets":{"direct":["--size=2","--size","3"]}}' \
  '{"arguments":[],"topologyArgumentSets":{"switch":["--host=0.0.0.0"]}}' \
  '{"arguments":["--tp-size","4"]}'; do
  if arguments_for_topology direct <<<"$invalid" >/dev/null 2>&1; then
    printf 'FAIL malformed or conflicting argument contract accepted\n' >&2
    exit 1
  fi
done
for flag in --tp --tp-size --tensor-parallel-size --nnodes --node-rank --dist-init-addr --host --port; do
  for value in "$flag" "$flag=value"; do
    invalid=$(jq -nc --arg flag "$value" '{arguments:[],topologyArgumentSets:{direct:[$flag]}}')
    if arguments_for_topology direct <<<"$invalid" >/dev/null 2>&1; then exit 1; fi
  done
done
if arguments_for_topology typo <<<"$profile" >/dev/null 2>&1; then exit 1; fi
printf 'PASS malformed contracts and transport overrides rejected\n'
# Argument validation must execute before the first remote preparation call.
awk '
  /^selected_arguments_json=/ { checked=1 }
  /^remote / { if (!checked) exit 1; found=1; exit }
  END { if (!checked) exit 1 }
' "$root/scripts/deuces-sglang-acceptance.sh"
