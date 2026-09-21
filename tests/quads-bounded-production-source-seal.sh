#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"

legacy=qualification-evidence/2026-09-07-minimax-m3-quads-bounded16k-source-candidate-v3
seal=qualification-evidence/2026-09-08-minimax-m3-quads-bounded16k-functional-v1/source-seal.json
[[ $(sha256sum "$legacy/source-seal.json" | awk '{print $1}') == e716cd3e30699a3f6f427efc35bda8bd11c26f178236ba6468b2bb36e7dc3120 ]] || {
  printf 'FAIL: immutable v3 source seal changed\n' >&2
  exit 1
}
[[ $(sha256sum "$legacy/record.md" | awk '{print $1}') == 57ac46d86798dfb7469de8f2607b76a45a3c1efd67b26172bd33b901cae13fd0 ]] || {
  printf 'FAIL: immutable v3 record changed\n' >&2
  exit 1
}
jq -e '
  .supersedes.sha256 == "e716cd3e30699a3f6f427efc35bda8bd11c26f178236ba6468b2bb36e7dc3120"
  and .supersedes.recordSha256 == "57ac46d86798dfb7469de8f2607b76a45a3c1efd67b26172bd33b901cae13fd0"
' "$seal" >/dev/null
profile=minimax-m3-nvfp4-quads-v028-bounded16k

jq -e --arg profile "$profile" '
  .schemaVersion == 1
  and .evidenceClass == "source-and-hardware-functional-qualification"
  and .profile == $profile
  and .hardwareStatus == "qualified-current-source-four-node-functional-replay-v1"
  and .upstreamProvenance == {
    "workbookSha256":"0c4dafc60f155aeea53fc56171d5fe4ce38d6ac1521ed7da9695fc5361f3c69c",
    "markdownSha256":"47ef39b49770397e93012e7e47ca5844d1541b5169587e1ff91847074d78e9d0",
    "cookbookSha256":"e5c8d981366c134d66466ef593c47f55cecd6db3326f4b8aa2e68d03fdf11ea8",
    "modelCombinationsSha256":"42f18c147ffa967627898c2d6e604c57903599311f18d8fa36f385136f8c7412",
    "selectedQuadsRowsSha256":"befbd60a76efefd7315df335c9a4365df01576fa7233823957873fbb629a65b9"
  }
  and .privateReceiptBoundary == {
    "literalCommandExit":0,
    "modelResult":"pass",
    "coordinatorResult":"pass",
    "rayRestoration":"pass",
    "postflightContainersPerRank":0,
    "postflightGpuProcessesPerRank":0,
    "restoredRay":{"nodes":4,"cpus":80,"gpus":4}
  }
  and (.limitations | any(contains("61,230") and contains("61,217")))
  and (.files | length == 20)
' "$seal" >/dev/null

# Verify every recorded final-source file byte-for-byte, then independently
# verify the canonical scoped objects and dispatch declarations below.
jq -r '.files | to_entries[] | "\(.value)  \(.key)"' "$seal" | sha256sum --strict -c - >/dev/null

expected=$(jq -r '.profileObjectCanonicalSha256' "$seal")
actual=$(jq -cS --arg profile "$profile" '.profiles[$profile]' model-profiles.json | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" ]] || {
  printf 'FAIL: Quads profile canonical hash drifted (expected %s, got %s)\n' "$expected" "$actual" >&2
  exit 1
}

expected=$(jq -r '.matrixV34ObjectCanonicalSha256' "$seal")
actual=$(jq -cS '.matrixV34Reconciliation' cluster-model-candidates.json | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" ]] || {
  printf 'FAIL: matrix-v34 reconciliation hash drifted (expected %s, got %s)\n' "$expected" "$actual" >&2
  exit 1
}

alias_declaration='{ shellName = "minimax-m3-nvfp4-quads-v028-bounded16k"; profileName = "minimax-m3-nvfp4-quads-v028-bounded16k"; }'
expected=$(jq -r '.flakeAliasDeclarationSha256' "$seal")
actual=$(grep -F "$alias_declaration" flake.nix | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" ]] || {
  printf 'FAIL: flake alias declaration hash drifted (expected %s, got %s)\n' "$expected" "$actual" >&2
  exit 1
}
[[ $(grep -Fc "$alias_declaration" flake.nix) == 1 ]] || {
  printf 'FAIL: expected exactly one sealed flake alias declaration\n' >&2
  exit 1
}

wrapper_case='minimax-m3-nvfp4-quads-v028|minimax-m3-nvfp4-quads-v028-bounded16k)'
expected=$(jq -r '.wrapperProfileCaseSha256' "$seal")
actual=$(grep -F "$wrapper_case" scripts/quads-switch-model.sh | sha256sum | awk '{print $1}')
[[ "$actual" == "$expected" ]] || {
  printf 'FAIL: wrapper profile case hash drifted (expected %s, got %s)\n' "$expected" "$actual" >&2
  exit 1
}
[[ $(grep -Fc "$wrapper_case" scripts/quads-switch-model.sh) == 1 ]] || {
  printf 'FAIL: expected exactly one sealed wrapper profile case\n' >&2
  exit 1
}

printf 'PASS: current bounded-16K Quads source and provenance match the qualified functional seal\n'
