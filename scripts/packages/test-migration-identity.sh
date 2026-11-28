#!/usr/bin/env bash
# [PACKAGE-HOSTED-RELEASE] Exercise the operator's migration dispatch without provider access.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
source "$root/src/manager/ops/deploy.sh" production database
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
GCP_PROJECT_ID=registry-fixture
default_account=serviceAccount:123-compute@developer.gserviceaccount.com
migration_account=projects/registry-fixture/serviceAccounts/registry-production-migrate@registry-fixture.iam.gserviceaccount.com
tf() {
  [[ "$*" == 'output -json migration_build' ]] || return 1
  jq -nc --arg account "$migration_account" '{account:$account,bucket:"fixture-stage"}'
}
gcloud() {
  case "$1 $2 $3" in
    'projects describe registry-fixture') echo 123 ;;
    'secrets get-iam-policy osprey-registry-production-db-owner')
      [[ "$LEGACY" != failed ]] || return 1
      if [[ "$LEGACY" == present ]]; then
        jq -nc --arg member "$default_account" '{bindings:[{role:"roles/secretmanager.secretAccessor",members:[$member]}]}'
      else echo '{}'; fi ;;
    'secrets remove-iam-policy-binding osprey-registry-production-db-owner')
      [[ "$*" == *"--member=$default_account"* && "$*" == *'--role=roles/secretmanager.secretAccessor'* && "$*" == *'--condition=None'* ]] || return 1
      echo revoke >> "$work/actions" ;;
    'builds submit context')
      [[ "$*" == *"--service-account=$migration_account"* && "$*" == *'--gcs-source-staging-dir=gs://fixture-stage/source'* ]] || return 1
      echo build >> "$work/actions" ;;
    *) return 1 ;;
  esac
}
for scenario in present absent failed; do
  : > "$work/actions"
  set +e
  ( set -e; LEGACY="$scenario" migrate_build context pooler ref )
  outcome=$?
  set -e
  case "$scenario" in
    present) [[ $outcome == 0 ]]; printf '%s\n' revoke build | diff - "$work/actions" ;;
    absent) [[ $outcome == 0 && $(cat "$work/actions") == build ]] ;;
    failed) [[ $outcome != 0 && ! -s "$work/actions" ]] ;;
  esac
done
