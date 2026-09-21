#!/usr/bin/env bash
set -Eeuo pipefail

# SGLang-Omni currently normalizes MiniMax Music 3's nested Qwen config in
# place. Keep the checkpoint mounted read-only and expose an ephemeral tree of
# symlinks, replacing only that small config with a writable copy in /tmp.
source_root=/model
shadow_root=/tmp/gb10sor-model-shadow
backbone_relative=qwen_7B/qwen_7B/config.json

[[ -d $source_root && -r $source_root/$backbone_relative ]] || {
  printf 'Music3 model shadow failed: expected checkpoint config is absent\n' >&2
  exit 1
}
[[ ! -e $shadow_root ]] || {
  printf 'Music3 model shadow failed: ephemeral destination already exists\n' >&2
  exit 1
}

mkdir -p "$shadow_root"
cp -a -s "$source_root/." "$shadow_root/"
cp --remove-destination "$source_root/$backbone_relative" "$shadow_root/$backbone_relative"

[[ -f $shadow_root/$backbone_relative && ! -L $shadow_root/$backbone_relative ]] || {
  printf 'Music3 model shadow failed: writable config copy was not created\n' >&2
  exit 1
}

exec sgl-omni serve --model-path "$shadow_root" "$@"
