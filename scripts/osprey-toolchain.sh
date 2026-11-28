#!/usr/bin/env bash
# Lays the released Osprey toolchain at `tag` (bump it with its digests below) into <dir> (default target/osprey)
# [REPO-SPLIT]: the compiler, its runtime archives and the published @osprey packages, verified by
# SHA-256. packages/<name> is the newest release of each published @osprey package. The native host
# entry and the browser WASI shim are not in the release, so they come from the same tag.
# Usage: scripts/osprey-toolchain.sh [dir]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-$here/target/osprey}
tag=v0.33.0
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=darwin-arm64 ;;
    Linux-x86_64) platform=linux-x64 ;;
    MINGW*-x86_64 | MSYS*-x86_64) platform=win32-x64 ;;
    *) echo "osprey-toolchain: no Osprey release for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
case "$tag-$platform" in
    v0.33.0-darwin-arm64) sha=6e6c2dbe3aa1c091c19be3d1ba37a3d8c710594a77dc0f56e84c2a2471b1c9aa ;;
    v0.33.0-linux-x64) sha=40c05f7eb0a8a231b3734ebab2cffc81223b049282fa783979363896846a1b70 ;;
    v0.33.0-win32-x64) sha=f8044fafcd88abacb09fa86c959095f94a789aa32f1f6be627a13eadb1264d69 ;;
    *) echo "osprey-toolchain: pin the $tag $platform digest in $0" >&2; exit 1 ;;
esac
[ "$(cat "$dir/.release" 2>/dev/null)" = "$tag-$platform-$sha" ] && { touch "$dir/.release"; exit 0; }
name="osprey-${tag#v}-$platform"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/osprey-toolchain.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --retry 3 -o "$scratch/$name.tar.gz" "https://github.com/Nimblesite/osprey/releases/download/$tag/$name.tar.gz"
# Git Bash on Windows has sha256sum but no shasum; macOS has shasum but no sha256sum.
if command -v sha256sum >/dev/null; then sha256=(sha256sum); else sha256=(shasum -a 256); fi
echo "$sha  $scratch/$name.tar.gz" | "${sha256[@]}" -c - >/dev/null
tar -xzf "$scratch/$name.tar.gz" -C "$scratch"
mkdir -p "$scratch/$name/packages" "$scratch/$name/native-host"
for package in "$scratch/$name"/registry/@osprey/*/; do
    newest=$(ls "$package" | sort -t. -k1,1n -k2,2n | tail -1)
    cp -R "$package$newest" "$scratch/$name/packages/$(basename "$package")"
done
fetch() { curl -fsSL --retry 3 -o "$scratch/$name/$1" "https://raw.githubusercontent.com/Nimblesite/osprey/$tag/$2"; }
fetch native-host/entry.ospml src/osprey/packages/native/host/entry.ospml
fetch native-host/slices.ospml src/osprey/packages/native/host/slices.ospml
fetch wasi-shim.mjs src/osprey/examples/wasm/wasi-shim.mjs
echo "$tag-$platform-$sha" > "$scratch/$name/.release"
rm -rf "$dir"
mkdir -p "$(dirname "$dir")"
mv "$scratch/$name" "$dir"
echo "osprey-toolchain: $tag $platform in $dir"
