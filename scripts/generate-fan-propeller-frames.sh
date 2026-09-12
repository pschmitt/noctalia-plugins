#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
template="$script_dir/fan-propeller.svg.in"
asset_dir="$repo_dir/plugins/ha/assets"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

for frame in $(seq 0 23); do
  angle=$((frame * 15))
  sed "s/ROTATION/$angle/" "$template" > "$tmp_dir/fan-propeller.svg"
  magick -background none -density 96 "$tmp_dir/fan-propeller.svg" \
    -resize 24x24 -depth 8 -define png:color-type=6 \
    "$asset_dir/fan-propeller-$(printf '%02d' "$frame").png"
done
