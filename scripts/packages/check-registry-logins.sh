#!/usr/bin/env bash
# [PACKAGE-OWNERSHIP-RLS] Evaluate the production login map with no credentials or remote state.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
ops="$root/src/manager/ops"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/terraform/.terraform" "$work/supabase"
cp "$ops"/terraform/*.tf "$ops/terraform/.terraform.lock.hcl" "$work/terraform/"
cp "$ops/supabase/supabase-root-2021.crt" "$work/supabase/"
sed '/backend "gcs" {}/d' "$ops/terraform/versions.tf" > "$work/terraform/versions.tf"
ln -s "${TF_DATA_DIR:?initialized provider directory required}/providers" "$work/terraform/.terraform/providers"
unset TF_DATA_DIR
roles="$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load_file(ARGV[0], aliases: true).fetch("roles").select { |r| r["login"] }.map { |r| r.fetch("name") }.sort)' "$ops/supabase/migrations/schema.yaml")"
result="$(terraform -chdir="$work/terraform" console <<EOF
sort(values(local.database_logins)) == tolist($roles) && local.publication_logins == {collector="registry_publication_collector", scan="registry_scan_worker"} && length(setintersection(toset(values(local.api_database_logins)), toset(values(local.publication_logins)))) == 0
EOF
)"
[[ "$result" == true ]] || { echo "Terraform login roles differ from the schema or publication roles enter the API map" >&2; exit 1; }
