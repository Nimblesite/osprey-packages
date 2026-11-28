#!/usr/bin/env bash
# Implements [PACKAGE-HOSTED-TOPOLOGY] and [PACKAGE-HOSTED-RELEASE]: one idempotent operator command
# that stands up (or converges) an environment: Cloudflare → Cloud Run → Supabase.
#   src/manager/ops/deploy.sh <staging|production> [all|supabase|infra|github|database|release|smoke]
# Reads src/manager/ops/deploy.env (template: deploy.env.example). Secrets go through stdin,
# environment variables or Secret Manager, never argv. Every step is safe to re-run.
set -euo pipefail
shopt -s inherit_errexit # a failure inside $(…) stops the run too

OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$OPS/../../.." && pwd)"
ENV_NAME="${1:?usage: deploy.sh <staging|production> [step]}"
STEP="${2:-all}"
NAME="osprey-registry-$ENV_NAME"
WORK="$ROOT/target/deploy/$ENV_NAME"
TF_DIR="$OPS/terraform"
CA="$OPS/supabase/supabase-root-2021.crt"
REPO="Nimblesite/osprey-packages"
SUPABASE_API="https://api.supabase.com/v1"

log() { printf '\033[1;36m[deploy %s] %s\033[0m\n' "$ENV_NAME" "$*" >&2; }
die() { printf '\033[1;31m[deploy %s] FATAL: %s\033[0m\n' "$ENV_NAME" "$*" >&2; exit 1; }

load_config() {
  case "$ENV_NAME" in staging|production) ;; *) die "environment must be staging or production" ;; esac
  [[ -f "$OPS/deploy.env" ]] || die "copy $OPS/deploy.env.example to $OPS/deploy.env and fill it (docs/DEPLOY.md)"
  set -a; . "$OPS/deploy.env"; set +a
  local var
  for var in GCP_PROJECT_ID GCP_BILLING_ACCOUNT CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID DOMAIN SUPABASE_ORG_ID \
             SUPABASE_REGION CLOUDFLARE_API_TOKEN CLOUDFLARE_PAGES_TOKEN SUPABASE_ACCESS_TOKEN; do
    [[ -n "${!var:-}" ]] || die "$var is empty in deploy.env"
  done
  for var in terraform gcloud gh jq curl psql dotnet openssl; do
    command -v "$var" >/dev/null || die "missing command: $var"
  done
  mkdir -p "$WORK"
}

# Production owns the bare names; staging appends -staging.
host() { printf '%s%s.%s' "$1" "$([[ "$ENV_NAME" == production ]] || echo -staging)" "$DOMAIN"; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

supabase_api() { # METHOD PATH [stdin body]
  curl -sS --fail-with-body -X "$1" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" ${3:+--data-binary @-} "$SUPABASE_API$2"
}

secret_put() { # NAME (value on stdin)
  if gcloud secrets describe "$1" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets versions add "$1" --data-file=- --project="$GCP_PROJECT_ID" >/dev/null
  else
    gcloud secrets create "$1" --data-file=- --replication-policy=automatic --project="$GCP_PROJECT_ID" >/dev/null
  fi
}

owner_password() { gcloud secrets versions access latest --secret="$NAME-db-owner" --project="$GCP_PROJECT_ID"; }

# --- Supabase: project, keys, pooler, Auth [PACKAGE-HOSTED-AUTH] ------------------------------
supabase_ref() { supabase_api GET /projects | jq -r --arg n "$NAME" '[.[] | select(.name == $n)][0].id // empty'; }

supabase_create() {
  log "creating Supabase project $NAME in $SUPABASE_REGION (owner password → Secret Manager $NAME-db-owner)"
  local password; password="$(openssl rand -hex 32)"
  printf '%s' "$password" | secret_put "$NAME-db-owner"
  jq -nc --arg n "$NAME" --arg o "$SUPABASE_ORG_ID" --arg r "$SUPABASE_REGION" --arg p "$password" \
    '{name:$n, organization_slug:$o, region:$r, db_pass:$p}' | supabase_api POST /projects body >/dev/null
}

supabase_wait() {
  local i status
  for i in $(seq 1 60); do
    status="$(supabase_api GET "/projects/$1" | jq -r .status)"
    [[ "$status" == ACTIVE_HEALTHY ]] && return 0
    log "Supabase status $status; waiting ($i/60)"; sleep 10
  done
  die "Supabase project $1 never became healthy"
}

supabase_auth() { # REF
  local id_var secret_var
  id_var="GITHUB_OAUTH_CLIENT_ID_$(upper "$ENV_NAME")"; secret_var="GITHUB_OAUTH_CLIENT_SECRET_$(upper "$ENV_NAME")"
  local github='{}'
  if [[ -n "${!id_var:-}" && -n "${!secret_var:-}" ]]; then
    github="$(jq -nc --arg i "${!id_var}" --arg s "${!secret_var}" \
      '{external_github_enabled:true, external_github_client_id:$i, external_github_secret:$s}')"
  else
    log "GitHub sign-in stays off: create a GitHub OAuth app with callback https://$1.supabase.co/auth/v1/callback, set $id_var/$secret_var, re-run"
  fi
  # [PACKAGE-HOSTED-AUTH]: ten-minute tokens; Supabase redirects only to the exact API callback.
  jq -nc --arg site "https://$(host packages)" --arg cb "https://$(host packages-api)/v1/auth/github/callback" --argjson gh "$github" \
    '{site_url:$site, uri_allow_list:$cb, jwt_exp:600, mailer_autoconfirm:false} + $gh' \
    | supabase_api PATCH "/projects/$1/config/auth" body >/dev/null
}

step_supabase() {
  local ref; ref="$(supabase_ref)"
  [[ -n "$ref" ]] || { supabase_create; ref="$(supabase_ref)"; }
  [[ -n "$ref" ]] || die "Supabase project $NAME was not created"
  supabase_wait "$ref"
  supabase_auth "$ref"
  local key pooler
  key="$(supabase_api GET "/projects/$ref/api-keys" | jq -r '([.[] | select(.type == "publishable")][0].api_key) // ([.[] | select(.name == "anon")][0].api_key)')"
  pooler="$(supabase_api GET "/projects/$ref/config/database/pooler" | jq -r '[.[] | .db_host][0]')"
  jq -nc --arg r "$ref" --arg k "$key" --arg p "$pooler" '{ref:$r, publishable_key:$k, pooler_host:$p}' > "$WORK/supabase.json"
  log "Supabase $ref ready (pooler $pooler)"
}

# --- Terraform [PACKAGE-HOSTED-TOPOLOGY] ------------------------------------------------------
tf() { TF_DATA_DIR="$WORK/terraform" terraform -chdir="$TF_DIR" "$@"; }

tf_init() {
  local bucket="$GCP_PROJECT_ID-osprey-registry-tfstate"
  gcloud services enable storage.googleapis.com secretmanager.googleapis.com --project="$GCP_PROJECT_ID" >/dev/null
  if ! gcloud storage buckets describe "gs://$bucket" >/dev/null 2>&1; then
    log "creating private versioned state bucket gs://$bucket"
    gcloud storage buckets create "gs://$bucket" --project="$GCP_PROJECT_ID" --location=australia-southeast1 \
      --uniform-bucket-level-access --public-access-prevention
    gcloud storage buckets update "gs://$bucket" --versioning
  fi
  tf init -input=false -reconfigure -lockfile=readonly -backend-config="bucket=$bucket" -backend-config="prefix=$ENV_NAME" >/dev/null
}

tfvars() { # IMAGE
  local others='[]'
  [[ "$ENV_NAME" == production ]] && others="$(jq -nc --arg a "packages-api-staging.$DOMAIN" --arg c "packages-content-staging.$DOMAIN" \
    --arg extra "${RATE_LIMIT_EXTRA_HOSTS:-}" '[$a,$c] + ($extra | split(" ") | map(select(. != "")))')"
  jq -n --slurpfile s "$WORK/supabase.json" --arg env "$ENV_NAME" --arg project "$GCP_PROJECT_ID" \
    --arg billing "$GCP_BILLING_ACCOUNT" --arg cfa "$CLOUDFLARE_ACCOUNT_ID" --arg cfz "$CLOUDFLARE_ZONE_ID" \
    --arg api "$(host packages-api)" --arg web "$(host packages)" --arg content "$(host packages-content)" \
    --arg image "$1" --argjson others "$others" '{
      environment:$env, project_id:$project, billing_account:$billing,
      cloudflare_account_id:$cfa, cloudflare_zone_id:$cfz,
      api_hostname:$api, website_hostname:$web, content_hostname:$content, image:$image,
      supabase_project_ref:$s[0].ref, supabase_publishable_key:$s[0].publishable_key,
      supabase_pooler_host:$s[0].pooler_host, rate_limit_other_hostnames:$others }' > "$WORK/terraform.tfvars.json"
}

image_repo() { printf 'australia-southeast1-docker.pkg.dev/%s/%s' "$GCP_PROJECT_ID" "$NAME"; }

deployed_image() {
  gcloud run services describe "$NAME" --region=australia-southeast1 --project="$GCP_PROJECT_ID" \
    --format='value(spec.template.spec.containers[0].image)' 2>/dev/null || true
}

# The service needs an image before Terraform can create it; CI builds the first one.
bootstrap_image() {
  log "no Cloud Run service yet: provisioning the registry and deploy identity, then building the first image in CI"
  tfvars "$(image_repo)/api@sha256:$(printf '0%.0s' $(seq 1 64))"
  tf apply -input=false -auto-approve -var-file="$WORK/terraform.tfvars.json" \
    -target=google_artifact_registry_repository_iam_member.deploy -target=google_service_account_iam_member.federated_deploy \
    -target=google_iam_workload_identity_pool_provider.github -target=cloudflare_pages_project.website >&2
  step_github >&2
  dispatch >&2
  main_image
}

# The digest CI built for main's head, or nothing.
main_image() {
  local sha digest; sha="$(gh api "repos/$REPO/commits/main" --jq .sha)"
  digest="$(gcloud artifacts docker images describe "$(image_repo)/api:$sha" --format='value(image_summary.digest)' 2>/dev/null || true)"
  [[ -z "$digest" ]] || printf '%s/api@%s' "$(image_repo)" "$digest"
}

step_infra() {
  [[ -f "$WORK/supabase.json" ]] || step_supabase
  tf_init
  local image; image="$(deployed_image)"
  [[ -n "$image" ]] || image="$(bootstrap_image)"
  tfvars "$image"
  tf apply -input=false -auto-approve -var-file="$WORK/terraform.tfvars.json"
}

# --- GitHub environment the deploy workflow reads ---------------------------------------------
step_github() {
  local env="registry-$ENV_NAME"
  if [[ "$ENV_NAME" == production ]]; then
    jq -nc '{deployment_branch_policy:{protected_branches:false, custom_branch_policies:true}}' \
      | gh api -X PUT "repos/$REPO/environments/$env" --input - >/dev/null
    gh api "repos/$REPO/environments/$env/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main \
      || gh api -X POST "repos/$REPO/environments/$env/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  else
    gh api -X PUT "repos/$REPO/environments/$env" >/dev/null
  fi
  tf output -json github_environment | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | while IFS=$'\t' read -r key value; do
    gh variable set "$key" --env "$env" --repo "$REPO" --body "$value"
  done
  printf '%s' "$CLOUDFLARE_PAGES_TOKEN" | gh secret set CLOUDFLARE_PAGES_TOKEN --env "$env" --repo "$REPO"
  log "GitHub environment $env synced"
}

dispatch() {
  local before; before="$(gh run list --repo "$REPO" --workflow=deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
  gh workflow run deploy.yml --repo "$REPO" --ref main -f environment="$ENV_NAME"
  local run=""
  while [[ -z "$run" || "$run" == "$before" ]]; do sleep 5
    run="$(gh run list --repo "$REPO" --workflow=deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  done
  log "watching deploy run $run (CI at the exact SHA first)"
  gh run watch "$run" --repo "$REPO" --exit-status >&2
}

# --- Database: schema, migration, restricted logins [PACKAGE-OWNERSHIP-RLS] -------------------
step_database() {
  local ref pooler; ref="$(jq -r .ref "$WORK/supabase.json")"; pooler="$(jq -r .pooler_host "$WORK/supabase.json")"
  local password; password="$(owner_password)"
  export PGHOST="$pooler" PGPORT=5432 PGUSER="postgres.$ref" PGDATABASE=postgres PGSSLMODE=verify-full PGSSLROOTCERT="$CA" PGPASSWORD="$password"
  psql -X -v ON_ERROR_STOP=1 -qc 'CREATE SCHEMA IF NOT EXISTS registry'
  local migrator; migrator="$(make -s -C "$ROOT" _registry-migration-tool | tail -1)"
  log "applying src/manager/supabase/migrations/schema.yaml"
  dotnet "$migrator" migrate --provider postgres --schema "$ROOT/src/manager/supabase/migrations/schema.yaml" \
    --output "Host=$pooler;Port=5432;Username=postgres.$ref;Database=postgres;SSL Mode=VerifyFull;Root Certificate=$CA"
  local logins; logins="$(tf output -json database_logins)"
  REGISTRY_CATALOG_READER_PASSWORD="$(jq -r .registry_catalog_reader <<<"$logins")" \
  REGISTRY_LOGIN_RUNTIME_PASSWORD="$(jq -r .registry_login_runtime <<<"$logins")" \
  REGISTRY_SESSION_ISSUER_PASSWORD="$(jq -r .registry_session_issuer <<<"$logins")" \
  REGISTRY_SESSION_RUNTIME_PASSWORD="$(jq -r .registry_session_runtime <<<"$logins")" \
  REGISTRY_SESSION_REVOKER_PASSWORD="$(jq -r .registry_session_revoker <<<"$logins")" \
    psql -X -q -f "$OPS/supabase/roles.sql"
  log "schema migrated and restricted logins converged"
}

# --- Smoke [PACKAGE-HOSTED-CONFORMANCE] origin row ------------------------------------------------
status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" || true; }

step_smoke() {
  local api run; api="https://$(host packages-api)"; run="https://$(tf output -raw run_host)"
  local edge direct web
  edge="$(status "$api/v1/packages")"; direct="$(status "$run/v1/packages")"; web="$(status "https://$(host packages)/")"
  log "edge $api/v1/packages → $edge (200, or 503 until the catalog projection exists)"
  log "direct $run/v1/packages → $direct (must be 403)"
  log "website → $web (must be 200)"
  [[ "$edge" == 200 || "$edge" == 503 ]] && [[ "$direct" == 403 ]] && [[ "$web" == 200 ]] || die "smoke failed"
}

# Skips when main's head is already serving (a bootstrap run just deployed it).
step_release() {
  local built; built="$(main_image)"
  if [[ -n "$built" && "$built" == "$(deployed_image)" ]]; then log "main's head is already deployed"; else dispatch; fi
}

main() {
  load_config
  [[ "$STEP" == supabase ]] || tf_init
  case "$STEP" in
    all) step_supabase; step_infra; step_github; step_database; step_release; step_smoke ;;
    supabase|infra|github|database|release|smoke) "step_$STEP" ;;
    *) die "unknown step $STEP" ;;
  esac
  log "$STEP done"
}

main
