#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
template="$script_dir/timewarrior-sync.svg.in"
asset_dir="$repo_dir/plugins/timewarrior/assets"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

generate_frame() {
  local frame="$1"
  local angle
  angle=$((frame * 30))
  sed "s/ROTATION/$angle/" "$template" > "$tmp_dir/timewarrior-sync.svg"
  magick -background none -density 96 "$tmp_dir/timewarrior-sync.svg" \
    -resize 24x24 -depth 8 -define png:color-type=6 \
    "$asset_dir/sync-spinner-$(printf '%02d' "$frame").png"
}

main() {
  local frame
  for ((frame = 0; frame < 12; frame++))
  do
    generate_frame "$frame"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi

# vim: set ft=sh et ts=2 sw=2 :
