#!/usr/bin/env bash
# [PACKAGE-HOSTED-RELEASE] A local cache marker cannot vouch for modified inputs.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
cp -R "$root/target/osprey" "$work/installed"
mkdir "$work/bin"
printf '#!/bin/sh\nexit 81\n' > "$work/bin/curl"
chmod +x "$work/bin/curl"
verify() { PATH="$work/bin:$PATH" "$root/scripts/osprey-toolchain.sh" "$work/installed"; }
verify
runtime="$work/installed/libfiber_runtime_arc.a"
mv "$runtime" "$work/original"
printf 'changed' > "$runtime"
if verify; then echo "Accepted changed runtime" >&2; exit 1; fi
mv "$work/original" "$runtime"
touch "$work/installed/packages/unreviewed.osp"
if verify; then echo "Accepted extra package source" >&2; exit 1; fi
rm "$work/installed/packages/unreviewed.osp"
ln -s "$runtime" "$work/installed/runtime-link"
if verify; then echo "Accepted unexpected link" >&2; exit 1; fi
rm "$work/installed/runtime-link"
verify
