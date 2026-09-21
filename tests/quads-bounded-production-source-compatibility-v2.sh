#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"

seal=qualification-evidence/2026-09-16-minimax-m3-quads-bounded16k-source-compatibility-v10/source-seal.json
profile=minimax-m3-nvfp4-quads-v028-bounded16k

jq -e '
  .schemaVersion == 1
  and .evidenceClass == "source-compatibility-with-functional-and-benchmark-receipts"
  and .profile == "minimax-m3-nvfp4-quads-v028-bounded16k"
  and .hardwareStatus == "qualified-four-node-functional-replay-and-benchmark-v1"
  and .preservedReceipt.modelResult == "pass"
  and .preservedReceipt.coordinatorResult == "pass"
  and .preservedReceipt.rayRestoration == "pass"
  and .preservedReceipt.postflightContainersPerRank == 0
  and .preservedReceipt.postflightGpuProcessesPerRank == 0
  and .benchmarkReceipt.pointsPassed == 2
  and .benchmarkReceipt.pointsTotal == 2
  and .benchmarkReceipt.runs == 6
  and .supersedes.sha256 == "8d7cf4738f323be65c01cd1670dd4b2ac46978ffcc70257dba4b47a6d54531ea"
' "$seal" >/dev/null

while IFS=$'\t' read -r path expected; do
  [[ $(sha256sum "$path" | awk '{print $1}') == "$expected" ]] || {
    printf 'FAIL: preserved Quads receipt changed: %s\n' "$path" >&2
    exit 1
  }
done < <(jq -r '.preservedReceipt | [.sourceSealPath,.sourceSealSha256], [.recordPath,.recordSha256] | @tsv' "$seal")

jq -r '.files | to_entries[] | "\(.value)  \(.key)"' "$seal" |
  sha256sum --strict -c - >/dev/null

expected=$(jq -r '.profileObjectCanonicalSha256' "$seal")
actual=$(jq -cS --arg profile "$profile" '.profiles[$profile]' model-profiles.json | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { printf 'FAIL: scoped Quads profile drifted\n' >&2; exit 1; }

expected=$(jq -r '.matrixV35ObjectCanonicalSha256' "$seal")
actual=$(jq -cS '.matrixV35Reconciliation' cluster-model-candidates.json | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { printf 'FAIL: matrix-v35 provenance drifted\n' >&2; exit 1; }

alias_declaration='{ shellName = "minimax-m3-nvfp4-quads-v028-bounded16k"; profileName = "minimax-m3-nvfp4-quads-v028-bounded16k"; }'
expected=$(jq -r '.flakeAliasDeclarationSha256' "$seal")
actual=$(grep -F "$alias_declaration" flake.nix | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" && $(grep -Fc "$alias_declaration" flake.nix) == 1 ]] || {
  printf 'FAIL: scoped Quads flake alias drifted\n' >&2
  exit 1
}

wrapper_case='minimax-m3-nvfp4-quads-v028|minimax-m3-nvfp4-quads-v028-bounded16k)'
expected=$(jq -r '.wrapperProfileCaseSha256' "$seal")
actual=$(grep -F "$wrapper_case" scripts/quads-switch-model.sh | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" && $(grep -Fc "$wrapper_case" scripts/quads-switch-model.sh) == 1 ]] || {
  printf 'FAIL: scoped Quads wrapper dispatch drifted\n' >&2
  exit 1
}

printf 'PASS: current scoped Quads source and MiniMax benchmark receipt are sealed (V10)\n'
