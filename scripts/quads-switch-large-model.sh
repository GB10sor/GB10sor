#!/usr/bin/env bash
set -Eeuo pipefail

# Stable, model-neutral entry point for the reviewed switched-Quads large-model
# coordinator. The implementation remains in the independently reviewed
# coordinator so existing Nemotron receipts and commands remain reproducible.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
exec "$repo_root/scripts/quads-switch-nemotron-model.sh" "$@"
