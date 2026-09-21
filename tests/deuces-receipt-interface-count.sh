#!/usr/bin/env bash
set -Eeuo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
for engine in vllm sglang; do
  expression=$(sed -n 's/.*logicalInterfaces:\(.*\),hcas:.*/\1/p' "$repo_root/scripts/deuces-$engine-acceptance.sh")
  [[ -n "$expression" ]]
  for count in 1 2; do
    actual=$(jq -n --arg topologyMode direct --arg interfaceCount "$count" "$expression")
    [[ "$actual" == "$count" ]]
  done
  actual=$(jq -n --arg topologyMode switch --arg interfaceCount 2 "$expression")
  [[ "$actual" == null ]]
  printf 'PASS: %s receipt distinguishes one direct interface, two direct interfaces, and switched topology\n' "$engine"
done
