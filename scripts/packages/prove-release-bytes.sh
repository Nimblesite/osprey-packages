#!/usr/bin/env bash
# [PACKAGE-HOSTED-PUBLISH-FLOW] Check the ARC hosted API's emitted IR with Osprey's IR-to-Lean translator.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
compiler="$root/target/osprey/osprey"
commit=$("$root/scripts/osprey-toolchain.sh" --source-commit)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
source_repo=${OSPREY_PROOF_REPO:-}
if [[ -z $source_repo ]]; then
  source_repo="$out/upstream.git"
  git init -q --bare "$source_repo"
  git -C "$source_repo" remote add origin https://github.com/Nimblesite/osprey.git
  git -C "$source_repo" fetch -q --depth=1 --filter=blob:none origin "$commit"
fi
translator=src/osprey/examples/proof/ir_lean
model=src/toolchain/benchmarks/proof/tools
git -C "$source_repo" archive "$commit" "$translator" "$model/LlvmSubset" "$model/LlvmSubset.lean" \
  "$model/OwnershipLedger.lean" "$model/lean-toolchain" | tar -x -C "$out"
mkdir -p "$out/src/osprey/packages"
ln -s "$root/target/osprey/packages/xdsl" "$out/src/osprey/packages/xdsl"
"$compiler" "$out/$translator" --compile --quiet --warnings-as-errors -o "$out/ir_lean"
"$compiler" "$root/src/manager/api/hosted" --llvm --memory=arc > "$out/api.ll"
llvm_bin=${LLVM_BIN:-$(dirname "$(command -v mlir-translate)")}
base=__osp_8x7265676973747279_5x4279746573
"$llvm_bin/llvm-extract" --recursive --func="${base}_7x69734469676974" --func="${base}_13x6c6f7765724865784469676974" \
  --func="${base}_7x6973416c6e756d" --func="${base}_12x69734c6f7765724469676974" \
  -S "$out/api.ll" -o "$out/release.ll"
cd "$out/$model"
export LEAN_PATH="$PWD"
for unit in OwnershipLedger LlvmSubset/{Syntax,Memory,Force,Exec,Ledger,Tactic} LlvmSubset; do
  lean -DwarningAsError=true -o "$unit.olean" "$unit.lean"
done
cp "$root/src/manager/api/tests/proofs/ReleaseBytes.lean" .
translate() {
  "$llvm_bin/mlir-translate" --import-llvm "$1" | "$llvm_bin/mlir-opt" --mlir-print-op-generic > "$out/release.mlir"
  "$out/ir_lean" "$out/release.mlir" ReleaseIR > ReleaseIR.lean
  if grep -Eq 'REFUSED|IR-LEAN-FAILED' ReleaseIR.lean; then cat ReleaseIR.lean >&2; return 1; fi
  lean -DwarningAsError=true -o ReleaseIR.olean ReleaseIR.lean
}
translate "$out/release.ll"
lean -DwarningAsError=true ReleaseBytes.lean
# The inclusive upper endpoint of lowercase hex must reject 'g'.
sed 's/i64 102)/i64 103)/g' "$out/release.ll" > "$out/mutant.ll"
if cmp -s "$out/release.ll" "$out/mutant.ll"; then echo "Missing hex bound for mutation" >&2; exit 1; fi
translate "$out/mutant.ll"
if lean -DwarningAsError=true ReleaseBytes.lean > "$out/rejection" 2>&1; then
  echo "Lean accepted the widened hex alphabet" >&2; exit 1
fi
grep -Fq 'commitHex' "$out/rejection" || grep -Fq '6c6f7765724865784469676974' "$out/rejection"
echo 'Lean verified six release byte predicates over all 256 bytes and rejected the widened hex range.'
