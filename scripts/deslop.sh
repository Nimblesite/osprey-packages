#!/usr/bin/env bash
# Runs the released deslop pinned below (SHA-256 checked) over the repo. .deslop.toml fails it (exit 3)
# above its duplication threshold. Usage: scripts/deslop.sh [extra deslop args]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tag=v0.45.0
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=macos-arm64; sha=c1072668ab310cbe07ec1b743e6b407c7c6f57ad8ed8b0b36f5d0e1f871ab5af ;;
    Linux-x86_64) platform=linux-x64; sha=74a6ad4b35ee33997622f7d35c13f17168f0bded96d83027265afc303d7547a3 ;;
    *) echo "deslop.sh: no pinned deslop for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
name="deslop-${tag#v}-$platform"
bin="$here/target/deslop-bin/$name/deslop"
if [ ! -x "$bin" ]; then
    mkdir -p "$here/target/deslop-bin"
    archive="$here/target/deslop-bin/$name.tar.gz"
    curl -fsSL --retry 3 -o "$archive" "https://github.com/Nimblesite/deslop/releases/download/$tag/$name.tar.gz"
    echo "$sha  $archive" | shasum -a 256 -c - >/dev/null
    tar -xzf "$archive" -C "$here/target/deslop-bin"
fi
cd "$here"
"$bin" . --nohtml --nojson --output target/deslop/gate/report "$@"
sed -n 2p target/deslop/gate/report.txt
