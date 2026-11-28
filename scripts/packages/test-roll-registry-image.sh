#!/usr/bin/env bash
# [PACKAGE-HOSTED-RELEASE] Verify the production rollout order with no cloud credentials.
set -eu
root=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/gcloud" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$ROLLOUT_LOG"
[[ "$2" != jobs || "$SCANNER_STATUS" == ok ]]
MOCK
chmod +x "$scratch/gcloud"
export ROLLOUT_LOG="$scratch/calls" PATH="$scratch:$PATH"
image="registry.example/repo/api@sha256:$(printf '%064d' 1)"
roll() { : > "$ROLLOUT_LOG"; SCANNER_STATUS="$2" bash "$root/scripts/packages/roll-registry-image.sh" registry region project "$1" "$3"; }
roll registry-scan ok "$image"
printf '%s\n' "run jobs update registry-scan --region=region --project=project --image=$image --quiet" "run services update registry --region=region --project=project --image=$image --quiet" | diff - "$ROLLOUT_LOG"
roll disabled ok "$image"
[[ $(wc -l < "$ROLLOUT_LOG") -eq 1 ]]
if roll registry-scan failed "$image"; then exit 1; fi
[[ $(wc -l < "$ROLLOUT_LOG") -eq 1 ]]
for scanner in '' other-job; do
  if roll "$scanner" ok "$image"; then exit 1; fi
  [[ ! -s "$ROLLOUT_LOG" ]]
done
if roll registry-scan ok registry.example/repo/api:latest; then exit 1; fi
[[ ! -s "$ROLLOUT_LOG" ]]
