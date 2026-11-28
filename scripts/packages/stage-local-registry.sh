#!/usr/bin/env bash
# Stage the released @osprey packages as a folder registry ([PACKAGE-FOLDER-REGISTRY]).
#
# Every <packages>/<name>/osprey.toml that declares a [package] name is published (default
# target/osprey/packages, the released @osprey packages scripts/osprey-toolchain.sh lays down)
# with the package client's `publish --folder`, so each release is checked and
# digested exactly as the server will check it. The result is the tree the local
# registry serves (`make registry-serve`).
# A package that binds a raw native function is refused by design (source.unclassified-builtin);
# any other refusal, a bad manifest or name, is a mistake and fails the staging.
#
# Usage: scripts/packages/stage-local-registry.sh <osprey-pkg> <registry-root> [packages]
set -euo pipefail

client="$1"
out="$2"
packages="${3:-$(cd "$(dirname "$0")/../.." && pwd)/target/osprey/packages}"

case "$client" in /*) ;; *) client="$PWD/$client" ;; esac
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

rm -rf "$out"
mkdir -p "$out"

receipts=$(mktemp "${out}.receipts.XXXXXX")
trap 'rm -f "$receipts"' EXIT
published=0
refused=0
mistakes=0
for manifest in "$packages"/*/osprey.toml; do
  project="$(dirname "$manifest")"
  grep -q '^\[package\]' "$manifest" || continue
  key="$(sed -n 's/^name = "\(@[^"]*\)"/\1/p' "$manifest" | head -1)"
  report="$(echo "publish --folder $out --project $project" | "$client" 2>&1 || true)"
  if printf '%s\n' "$report" | grep -qx 'status: 0'; then
    printf '%s\n' "$report" | grep -E '^published @[a-z0-9-]+/[a-z0-9-]+ e[0-9]+\.r[0-9]+ sha256:[a-f0-9]{64}$' >> "$receipts"
    published=$((published + 1))
    echo "  published $key"
  else
    refused=$((refused + 1))
    reason="$(printf '%s\n' "$report" | grep -v '^status:' | tr '\n' ' ')"
    echo "  refused   $key: $reason" >&2
    case "$reason" in source.unclassified-builtin*) ;; *) mistakes=$((mistakes + 1)) ;; esac
  fi
done

echo "staged $published packages into $out ($refused refused)"
[ "$mistakes" -eq 0 ] || { echo "stage-local-registry: $mistakes package(s) refused for a manifest mistake" >&2; exit 1; }
[ "$published" -gt 0 ]
mv "$receipts" "${out}.receipts"
