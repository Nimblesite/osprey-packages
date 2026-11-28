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
source_commit=518eff90a1f5e422a4d0fdde46dbf14712360f81
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=darwin-arm64 ;;
    Linux-x86_64) platform=linux-x64 ;;
    MINGW*-x86_64 | MSYS*-x86_64) platform=win32-x64 ;;
    *) echo "osprey-toolchain: no Osprey release for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
linux_sha=40c05f7eb0a8a231b3734ebab2cffc81223b049282fa783979363896846a1b70
case "$tag-$platform" in
    v0.33.0-darwin-arm64) sha=6e6c2dbe3aa1c091c19be3d1ba37a3d8c710594a77dc0f56e84c2a2471b1c9aa; tree=7020be3e1bb29e190f9a1f669d97c168516848e6bdd5f2c65eac7c54e25f2d60 ;;
    v0.33.0-linux-x64) sha=$linux_sha; tree=15ca4fc4c2356c8ffbd888e5579fde1fce0443b2d9c0d30eec6dfa44fc97f094 ;;
    v0.33.0-win32-x64) sha=f8044fafcd88abacb09fa86c959095f94a789aa32f1f6be627a13eadb1264d69; tree=efb55e2dd5e5ea706a30745bc78434e8548f2216dc20dddae7db927a34cd7f38 ;;
    *) echo "osprey-toolchain: pin the $tag $platform digest in $0" >&2; exit 1 ;;
esac
# Checks FILE against the expected SHA-256, computed with shasum or, where it is missing (Windows
# runners), sha256sum, and compared as text: a `-c` check can pass a malformed line. Fails closed on a
# mismatch, an unreadable file or when neither tool exists.
sha256_check() { # EXPECTED FILE
    local actual
    if command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$2" | cut -d' ' -f1)
    elif command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$2" | cut -d' ' -f1)
    else echo "osprey-toolchain: neither shasum nor sha256sum can verify $2" >&2; return 1
    fi
    [ -n "$actual" ] && [ "$actual" = "$1" ] || { echo "osprey-toolchain: $2 has SHA-256 '$actual', expected $1" >&2; return 1; }
}
verify_supplements() {
    sha256_check c0a24fa8c3ceaec375e95402d5e77cada0ed4981183797ef08a151a4f3c5128f "$1/native-host/entry.ospml" &&
    sha256_check d367b7a89cbc04aceefc93e66aa2687ddd635f5145b56d3b760659c6d87f3b00 "$1/native-host/slices.ospml" &&
    sha256_check b2708ab89251cec82f36f9f295e16e6828f7accc0aacc656f8fbdc3cee4d938d "$1/wasi-shim.mjs"
}
# Hash the paths and contents of every installed file. Refuse symlinks, FIFOs
# and devices before reading any contents; the release marker is checked separately.
verify_tree() (
    cd "$1" || return 1
    local special actual
    local -a hash=(sha256sum -b)
    if command -v shasum >/dev/null; then hash=(shasum -b -a 256); fi
    special=$(find . ! -type d ! -type f -print -quit) || return 1
    [[ -z "$special" ]] || return 1
    actual=$(find . -type f ! -path './.release' -exec "${hash[@]}" {} + | LC_ALL=C sort | "${hash[@]}") || return 1
    [[ "${actual%% *}" == "$tree" ]]
)
if [[ -f "$dir/.release" && ! -L "$dir/.release" ]] && [[ "$(cat "$dir/.release")" == "$tag-$platform-$sha" ]] && verify_tree "$dir"; then
    exit 0
fi
name="osprey-${tag#v}-$platform"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/osprey-toolchain.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --retry 3 -o "$scratch/$name.tar.gz" "https://github.com/Nimblesite/osprey/releases/download/$tag/$name.tar.gz"
sha256_check "$sha" "$scratch/$name.tar.gz"
tar -xzf "$scratch/$name.tar.gz" -C "$scratch"
if [[ "$platform" == win32-x64 ]]; then
    # The Windows release ships native binaries only. Its Osprey package sources
    # come from the digest-pinned Linux archive of the identical release.
    linux_name="osprey-${tag#v}-linux-x64"
    curl -fsSL --retry 3 -o "$scratch/packages.tar.gz" "https://github.com/Nimblesite/osprey/releases/download/$tag/$linux_name.tar.gz"
    sha256_check "$linux_sha" "$scratch/packages.tar.gz"
    tar -xzf "$scratch/packages.tar.gz" -C "$scratch" "$linux_name/registry"
    mv "$scratch/$linux_name/registry" "$scratch/$name/"
fi
mkdir -p "$scratch/$name/packages" "$scratch/$name/native-host"
for package in "$scratch/$name"/registry/@osprey/*/; do
    newest=$(ls "$package" | sort -t. -k1,1n -k2,2n | tail -1)
    cp -R "$package$newest" "$scratch/$name/packages/$(basename "$package")"
done
fetch() { curl -fsSL --retry 3 -o "$scratch/$name/$1" "https://raw.githubusercontent.com/Nimblesite/osprey/$source_commit/$2"; }
fetch native-host/entry.ospml src/osprey/packages/native/host/entry.ospml
fetch native-host/slices.ospml src/osprey/packages/native/host/slices.ospml
fetch wasi-shim.mjs src/osprey/examples/wasm/wasi-shim.mjs
verify_supplements "$scratch/$name"
verify_tree "$scratch/$name" || { echo "osprey-toolchain: installed tree differs from its reviewed digest" >&2; exit 1; }
echo "$tag-$platform-$sha" > "$scratch/$name/.release"
rm -rf "$dir"
mkdir -p "$(dirname "$dir")"
mv "$scratch/$name" "$dir"
echo "osprey-toolchain: $tag $platform in $dir"
