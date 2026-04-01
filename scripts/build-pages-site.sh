#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${1:-"$repo_root/.pages-dist"}"

rm -rf "$out_dir"
mkdir -p "$out_dir"

# Publish the same script bytes at both the vanity root URL and the explicit path.
cp "$repo_root/select-mate.sh" "$out_dir/index.html"
cp "$repo_root/select-mate.sh" "$out_dir/select-mate.sh"
printf 'select-mate.sh\n' > "$out_dir/CNAME"
touch "$out_dir/.nojekyll"
