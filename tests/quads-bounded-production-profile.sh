#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"

prior=minimax-m3-nvfp4-quads-v028
bounded=minimax-m3-nvfp4-quads-v028-bounded16k

jq -e --arg prior "$prior" --arg bounded "$bounded" '
  .profiles[$prior] as $priorProfile
  | .profiles[$bounded] as $boundedProfile
  | $priorProfile.status == "candidate-quads-gb10-vllm-0.28.0-tp4-kv4g-bounded17k"
  and $priorProfile.servedContextLength == 65536
  and $boundedProfile.status == "qualified-quads-gb10-switched-vllm-0.28.0-tp4-kv4g-bounded16k-functional-v1"
  and ($boundedProfile.status | startswith("qualified-"))
  and $boundedProfile.servedContextLength == 16384
  and $boundedProfile.qualificationBoundary.maximumServedContextTokens == 16384
  and $boundedProfile.qualificationBoundary.hardwareStatus == "qualified-current-source-four-node-functional-replay-v1"
  and ($boundedProfile.qualificationBoundary.knownExcludedFailure | contains("61,230") and contains("61,217"))
  and $boundedProfile.acceptance.stress == {"minimumPromptTokens":8192,"concurrency":1}
  and (["modelId","modelPath","modelRevision","modelBytes","modelBytesAllowed",
        "weightFiles","weightBytes","weightTreeSha256","engine","engineVersion",
        "torchCudaVersion","containerCudaVersion","flashinferVersion","image",
        "runtimeImageRef","imageId","rootfsLayersSha256","imageArchitecture",
        "source","environment"]
       | all(. as $key | $boundedProfile[$key] == $priorProfile[$key]))
  and (($boundedProfile.arguments | index("--max-model-len")) as $index
       | $index != null
       and $boundedProfile.arguments[$index + 1] == "16384"
       and ($boundedProfile.arguments[$index + 1] | tonumber) <= 17601)
  and (($boundedProfile.arguments | index("--kv-cache-memory-bytes")) as $index
       | $index != null and $boundedProfile.arguments[$index + 1] == "4294967296")
  and (($boundedProfile.arguments | index("--max-num-seqs")) as $index
       | $index != null and $boundedProfile.arguments[$index + 1] == "1")
' model-profiles.json >/dev/null

jq -e '
  .matrixV34Reconciliation.sha256 == "0c4dafc60f155aeea53fc56171d5fe4ce38d6ac1521ed7da9695fc5361f3c69c"
  and .matrixV34Reconciliation.markdownSha256 == "47ef39b49770397e93012e7e47ca5844d1541b5169587e1ff91847074d78e9d0"
  and .matrixV34Reconciliation.cookbookSha256 == "e5c8d981366c134d66466ef593c47f55cecd6db3326f4b8aa2e68d03fdf11ea8"
  and .matrixV34Reconciliation.modelCombinationsSha256 == "42f18c147ffa967627898c2d6e604c57903599311f18d8fa36f385136f8c7412"
  and .matrixV34Reconciliation.selectedQuadsRowsSha256 == "befbd60a76efefd7315df335c9a4365df01576fa7233823957873fbb629a65b9"
  and (.matrixV34Reconciliation.policy | contains("remains a candidate"))
' cluster-model-candidates.json >/dev/null

grep -Fq 'minimax-m3-nvfp4-quads-v028|minimax-m3-nvfp4-quads-v028-bounded16k)' \
  scripts/quads-switch-model.sh
grep -Fq 'nix develop path:.#quads-switch-minimax-m3-nvfp4-quads-v028-bounded16k --command ./scripts/quads-switch-model.sh acceptance' \
  docs/QUADS.md
grep -Fq 'nix develop path:.#quads-switch-minimax-m3-nvfp4-quads-v028-bounded16k --command ./scripts/quads-switch-model.sh qualify-and-serve' \
  docs/QUADS.md
grep -Fq '61,230' docs/QUADS.md
grep -Fq '61,217' docs/QUADS.md
grep -Fq 'functional qualification' docs/QUADS.md
grep -Fq 'current-source bounded-16K functional replay' VALIDATION-STATUS.md

printf 'PASS: bounded-production MiniMax Quads profile records the qualified functional boundary\n'
