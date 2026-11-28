#!/usr/bin/env bash
# Implements [PACKAGE-HOSTED-TOPOLOGY] and [PACKAGE-HOSTED-RELEASE]: one idempotent operator command
# that stands up (or converges) an environment: Cloudflare → Cloud Run → Supabase.
#   src/manager/ops/deploy.sh production [all|local|supabase|infra|github|database|release|ship|website|smoke]
# Reads src/manager/ops/deploy.env (template: deploy.env.example). Secrets go through stdin,
# environment variables or Secret Manager, never argv. Every step is safe to re-run.
set -euo pipefail
shopt -s inherit_errexit # a failure inside $(…) stops the run too
export CLOUDSDK_CORE_DISABLE_PROMPTS=1 # never block on a gcloud question

OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$OPS/../../.." && pwd)"
ENV_NAME="${1:?usage: deploy.sh production [step]}"
STEP="${2:-all}"
NAME="osprey-registry-$ENV_NAME"
WORK="$ROOT/target/deploy/$ENV_NAME"
TF_DIR="$OPS/terraform"
CA="$OPS/supabase/supabase-root-2021.crt"
REPO="Nimblesite/osprey-packages"
SUPABASE_API="https://api.supabase.com/v1"

log() { printf '\033[1;36m[deploy %s] %s\033[0m\n' "$ENV_NAME" "$*" >&2; }
die() { printf '\033[1;31m[deploy %s] FATAL: %s\033[0m\n' "$ENV_NAME" "$*" >&2; exit 1; }

read_environment() {
  [[ "$ENV_NAME" == production ]] || die "production is the only environment (a test environment is an exact Prod → Dev copy, paused)"
  [[ -f "$OPS/deploy.env" ]] || die "copy $OPS/deploy.env.example to $OPS/deploy.env (docs/DEPLOY.md)"
  set -a; . "$OPS/deploy.env"; set +a
}

load_config() {
  read_environment
  local var
  for var in terraform gcloud gh jq curl psql openssl; do
    command -v "$var" >/dev/null || die "missing command: $var"
  done
  for var in GCP_PROJECT_ID DOMAIN SUPABASE_ORG_ID SUPABASE_REGION CLOUDFLARE_API_TOKEN; do
    [[ -n "${!var:-}" ]] || die "$var is empty in deploy.env"
  done
  derive_config
  mkdir -p "$WORK"
}

# Everything an account already knows is looked up, never typed.
derive_config() {
  : "${SUPABASE_ACCESS_TOKEN:=$(supabase_cli_token)}"
  [[ -n "$SUPABASE_ACCESS_TOKEN" ]] || die "run \`supabase login\` (or set SUPABASE_ACCESS_TOKEN)"
  local zone; zone="$(cloudflare_api "/zones?name=$DOMAIN" | jq -c '.result[0] // empty')"
  [[ -n "$zone" ]] || die "zone $DOMAIN is not on Cloudflare, or CLOUDFLARE_API_TOKEN cannot read it"
  CLOUDFLARE_ZONE_ID="$(jq -r .id <<<"$zone")"; CLOUDFLARE_ACCOUNT_ID="$(jq -r .account.id <<<"$zone")"
  export SUPABASE_ACCESS_TOKEN CLOUDFLARE_ZONE_ID CLOUDFLARE_ACCOUNT_ID
}

# The token `supabase login` stored in the OS keychain (go-keyring encoding).
supabase_cli_token() {
  local raw; raw="$(security find-generic-password -s "Supabase CLI" -a supabase -w 2>/dev/null || true)"
  [[ "$raw" == go-keyring-base64:* ]] && raw="$(printf '%s' "${raw#go-keyring-base64:}" | base64 -d)"
  printf '%s' "$raw"
}

cloudflare_api() { curl -sS --fail-with-body -H @<(printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN") "https://api.cloudflare.com/client/v4$1"; }

# Creates the project and links billing when missing; the billing account defaults to the caller's only open one.
ensure_project() {
  gcloud projects describe "$GCP_PROJECT_ID" >/dev/null 2>&1 \
    || { log "creating GCP project $GCP_PROJECT_ID"; gcloud projects create "$GCP_PROJECT_ID" --name="Osprey Registry" >&2; }
  GCP_BILLING_ACCOUNT="$(gcloud billing projects describe "$GCP_PROJECT_ID" --format='value(billingAccountName)' | sed 's|.*/||')"
  if [[ -z "$GCP_BILLING_ACCOUNT" ]]; then
    local open; open="$(gcloud billing accounts list --filter=open=true --format='value(name)' | sed 's|.*/||')"
    [[ "$(wc -l <<<"$open" | tr -d ' ')" == 1 && -n "$open" ]] || die "link a billing account: gcloud billing projects link $GCP_PROJECT_ID --billing-account=<ID>"
    gcloud billing projects link "$GCP_PROJECT_ID" --billing-account="$open" >/dev/null
    GCP_BILLING_ACCOUNT="$open"
  fi
}

host() { printf '%s.%s' "$1" "$DOMAIN"; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

supabase_api() { # METHOD PATH [stdin body]
  curl -sS --fail-with-body -X "$1" -H @<(printf 'Authorization: Bearer %s\n' "$SUPABASE_ACCESS_TOKEN") \
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

REGION=us-central1 # the cheapest US GCP region (Tier 1 pricing for Cloud Run, Storage, KMS, Artifact Registry)
# --- Cost guard [PACKAGE-HOSTED-SPEND-CAP]: alerts plus a hard stop, before anything can spend --
BUDGET=50 # in the billing account's own currency (AUD here); the API rejects any other
CAP_NAME=osprey-registry-spend-cap

# Both environments share the project, so the cap is one project singleton, not per-environment Terraform.
ensure_spend_cap() {
  gcloud services enable billingbudgets.googleapis.com cloudbilling.googleapis.com pubsub.googleapis.com \
    storage.googleapis.com secretmanager.googleapis.com cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com \
    workflows.googleapis.com eventarc.googleapis.com --project="$GCP_PROJECT_ID" >/dev/null
  gcloud pubsub topics describe "$CAP_NAME" --project="$GCP_PROJECT_ID" >/dev/null 2>&1 \
    || gcloud pubsub topics create "$CAP_NAME" --project="$GCP_PROJECT_ID" >/dev/null
  cap_workflow
  ensure_budget
}

# Unlinks billing once the month's cost reaches the budget. A declarative Cloud Workflow, not code:
# its identity holds only Project Billing Manager plus what Eventarc delivery needs.
cap_workflow() {
  local sa="$CAP_NAME@$GCP_PROJECT_ID.iam.gserviceaccount.com" role
  gcloud iam service-accounts describe "$sa" --project="$GCP_PROJECT_ID" >/dev/null 2>&1 \
    || gcloud iam service-accounts create "$CAP_NAME" --display-name="Unlinks billing at the budget" --project="$GCP_PROJECT_ID" >/dev/null
  for role in billing.projectManager workflows.invoker eventarc.eventReceiver logging.logWriter; do
    gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" --member="serviceAccount:$sa" --role="roles/$role" --condition=None >/dev/null
  done
  gcloud workflows deploy "$CAP_NAME" --location="$REGION" --project="$GCP_PROJECT_ID" \
    --source="$OPS/spend-cap/workflow.yaml" --service-account="$sa" >/dev/null
  gcloud eventarc triggers describe "$CAP_NAME" --location="$REGION" --project="$GCP_PROJECT_ID" >/dev/null 2>&1 \
    || gcloud eventarc triggers create "$CAP_NAME" --location="$REGION" --project="$GCP_PROJECT_ID" \
      --destination-workflow="$CAP_NAME" --destination-workflow-location="$REGION" \
      --event-filters=type=google.cloud.pubsub.topic.v1.messagePublished \
      --transport-topic="projects/$GCP_PROJECT_ID/topics/$CAP_NAME" --service-account="$sa" >/dev/null
}

ensure_budget() {
  local existing currency
  existing="$(gcloud billing budgets list --billing-project="$GCP_PROJECT_ID" --billing-account="$GCP_BILLING_ACCOUNT" \
    --filter="displayName=osprey-registry" --format='value(name)')"
  currency="$(gcloud billing accounts describe "$GCP_BILLING_ACCOUNT" --format='value(currencyCode)')"
  local args=(--billing-project="$GCP_PROJECT_ID" --billing-account="$GCP_BILLING_ACCOUNT" --budget-amount="$BUDGET$currency"
    --notifications-rule-pubsub-topic="projects/$GCP_PROJECT_ID/topics/$CAP_NAME")
  if [[ -n "$existing" ]]; then
    gcloud billing budgets update "$existing" "${args[@]}" >/dev/null
  else
    gcloud billing budgets create "${args[@]}" --display-name=osprey-registry \
      --filter-projects="projects/$GCP_PROJECT_ID" \
      --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 >/dev/null
  fi
  log "spend cap $BUDGET $currency/month on $GCP_PROJECT_ID: emails at 50/90/100%, billing unlinked at 100%"
}

# --- Supabase: project, keys, pooler, Auth [PACKAGE-HOSTED-AUTH] ------------------------------
supabase_ref() { supabase_api GET /projects | jq -r --arg n "$NAME" '[.[] | select(.name == $n)][0].id // empty'; }

supabase_create() {
  log "creating Supabase project $NAME in $SUPABASE_REGION (owner password → Secret Manager $NAME-db-owner)"
  local password; password="$(openssl rand -hex 32)"
  printf '%s' "$password" | secret_put "$NAME-db-owner"
  PROJECT_PASSWORD="$password" jq -nc --arg n "$NAME" --arg o "$SUPABASE_ORG_ID" --arg r "$SUPABASE_REGION" \
    '{name:$n, organization_slug:$o, region:$r, db_pass:env.PROJECT_PASSWORD, desired_instance_size:"micro"}' | supabase_api POST /projects body >/dev/null
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
    github="$(OAUTH_SECRET="${!secret_var}" jq -nc --arg i "${!id_var}" \
      '{external_github_enabled:true, external_github_client_id:$i, external_github_secret:env.OAUTH_SECRET}')"
  else
    log "GitHub sign-in stays off: create a GitHub OAuth app with callback https://$1.supabase.co/auth/v1/callback, set $id_var/$secret_var, re-run"
  fi
  # [PACKAGE-HOSTED-AUTH]: ten-minute tokens; Supabase redirects only to the exact API callback.
  # Passkeys are the first sign-in method; the relying party is the website host.
  jq -c --arg site "https://$(host packages)" --arg rp "$(host packages)" \
    --arg cb "https://$(host packages-api)/v1/auth/github/callback" <<<"$github" \
    '{site_url:$site, uri_allow_list:$cb, jwt_exp:600, mailer_autoconfirm:false, passkey_enabled:true,
      webauthn_rp_id:$rp, webauthn_rp_origins:$site, webauthn_rp_display_name:"Osprey Packages"} + .' \
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
# A fresh token from the signed-in gcloud on every call: no separate application-default login to go stale.
tf() { GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)" TF_DATA_DIR="$WORK/terraform" terraform -chdir="$TF_DIR" "$@"; }

tf_init() {
  local bucket="$GCP_PROJECT_ID-osprey-registry-tfstate"
  if ! gcloud storage buckets describe "gs://$bucket" >/dev/null 2>&1; then
    log "creating private versioned state bucket gs://$bucket"
    gcloud storage buckets create "gs://$bucket" --project="$GCP_PROJECT_ID" --location="$REGION" \
      --uniform-bucket-level-access --public-access-prevention
    gcloud storage buckets update "gs://$bucket" --versioning
  fi
  tf init -input=false -reconfigure -lockfile=readonly -backend-config="bucket=$bucket" -backend-config="prefix=$ENV_NAME" >/dev/null
}

tfvars() { # IMAGE
  jq -n --slurpfile s "$WORK/supabase.json" --arg env "$ENV_NAME" --arg project "$GCP_PROJECT_ID" --arg region "$REGION" \
    --arg cfa "$CLOUDFLARE_ACCOUNT_ID" --arg cfz "$CLOUDFLARE_ZONE_ID" \
    --arg api "$(host packages-api)" --arg web "$(host packages)" --arg content "$(host packages-content)" \
    --arg image "$1" '{
      environment:$env, project_id:$project, region:$region,
      cloudflare_account_id:$cfa, cloudflare_zone_id:$cfz,
      api_hostname:$api, website_hostname:$web, content_hostname:$content, image:$image,
      supabase_project_ref:$s[0].ref, supabase_publishable_key:$s[0].publishable_key,
      supabase_pooler_host:$s[0].pooler_host }' > "$WORK/terraform.tfvars.json"
}

image_repo() { printf '%s-docker.pkg.dev/%s/%s' "$REGION" "$GCP_PROJECT_ID" "$NAME"; }

deployed_image() {
  gcloud run services describe "$NAME" --region="$REGION" --project="$GCP_PROJECT_ID" \
    --format='value(spec.template.spec.containers[0].image)' 2>/dev/null || true
}

# The service needs an image before Terraform can create it: create the repository, then build one.
bootstrap_image() {
  log "no Cloud Run service yet: creating the image repository and building the first image"
  tfvars "$(image_repo)/api@sha256:$(printf '0%.0s' $(seq 1 64))"
  tf apply -input=false -auto-approve -var-file="$WORK/terraform.tfvars.json" \
    -target=google_artifact_registry_repository.registry -target=cloudflare_pages_project.website >&2
  build_image
}

# Cloud Build from a `git archive` of HEAD: the exact committed tree, never uncommitted edits.
build_image() {
  local sha context ref; sha="$(git -C "$ROOT" rev-parse HEAD)"; context="$WORK/context.tar.gz"
  ref="$(image_repo)/api:$sha"
  if ! gcloud artifacts docker images describe "$ref" --project="$GCP_PROJECT_ID" >/dev/null 2>&1; then
    gcloud services enable cloudbuild.googleapis.com --project="$GCP_PROJECT_ID" >/dev/null
    gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" --condition=None >/dev/null \
      --member="serviceAccount:$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')-compute@developer.gserviceaccount.com" \
      --role=roles/artifactregistry.writer
    local paths; read -ra paths <<<"$(make -s -C "$ROOT" _registry-hosted-context)"
    git -C "$ROOT" archive --format=tar.gz --output="$context" "$sha" "${paths[@]}" src/manager/ops/cloudbuild.yaml
    log "building $ref in Cloud Build"
    gcloud builds submit "$context" --project="$GCP_PROJECT_ID" --region="$REGION" \
      --config="$OPS/cloudbuild.yaml" --substitutions="_IMAGE=$ref,_SHA=$sha" >&2
  fi
  printf '%s/api@%s' "$(image_repo)" "$(gcloud artifacts docker images describe "$ref" --project="$GCP_PROJECT_ID" --format='value(image_summary.digest)')"
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
  tf output -raw pages_token | gh secret set CLOUDFLARE_PAGES_TOKEN --env "$env" --repo "$REPO"
  log "GitHub environment $env synced"
}

dispatch() {
  local url run sha
  sha="$(git -C "$ROOT" rev-parse HEAD)"
  url="$(gh workflow run deploy.yml --repo "$REPO" --ref main -f environment="$ENV_NAME" -f expected_sha="$sha")" || die "workflow dispatch failed"
  run="${url##*/}"
  [[ "$run" =~ ^[1-9][0-9]*$ && "$url" == "https://github.com/$REPO/actions/runs/$run" ]] || die "GitHub did not identify the dispatched run"
  log "watching deploy run $run (CI at the exact SHA first)"
  gh run watch "$run" --repo "$REPO" --exit-status >&2
}

# --- Database: schema, migration, restricted logins [PACKAGE-OWNERSHIP-RLS] -------------------
step_database() (
  local ref pooler; ref="$(jq -r .ref "$WORK/supabase.json")"; pooler="$(jq -r .pooler_host "$WORK/supabase.json")"
  log "applying src/manager/ops/supabase/migrations/schema.yaml in Cloud Build"
  gcloud secrets add-iam-policy-binding "$NAME-db-owner" --project="$GCP_PROJECT_ID" --condition=None >/dev/null \
    --member="serviceAccount:$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')-compute@developer.gserviceaccount.com" \
    --role=roles/secretmanager.secretAccessor
  local context="$WORK/migrate.tar.gz"
  git -C "$ROOT" archive --format=tar.gz --output="$context" HEAD Makefile src/manager/ops/supabase/migrations/schema.yaml \
    src/manager/ops/supabase/supabase-root-2021.crt src/manager/ops/cloudbuild-migrate.yaml
  gcloud builds submit "$context" --project="$GCP_PROJECT_ID" --region="$REGION" --config="$OPS/cloudbuild-migrate.yaml" \
    --substitutions="_HOST=$pooler,_USER=postgres.$ref,_SECRET=$NAME-db-owner" >&2
  # The migration owns every role and grant; a password is the one thing schema.yaml cannot declare.
  # Each travels through the environment and \getenv, never argv.
  local role secret logins password
  logins="$(tf output -json database_logins | jq -er 'select(type == "object" and length > 0) | to_entries[] | "\(.key) \(.value)"')"
  password="$(owner_password)"
  export PGHOST="$pooler" PGPORT=5432 PGUSER="postgres.$ref" PGDATABASE=postgres PGSSLMODE=verify-full PGSSLROOTCERT="$CA" PGCONNECT_TIMEOUT=10
  PGPASSWORD="$password" psql -XAt -v ON_ERROR_STOP=1 -f "$ROOT/scripts/packages/registry-table-inventory.sql" | \
    ruby "$ROOT/scripts/packages/check-registry-tables.rb"
  while read -r role secret; do
    PGPASSWORD="$password" ROLE_PASSWORD="$secret" psql -X -q -v ON_ERROR_STOP=1 -v role="$role" <<'PSQL'
\getenv secret ROLE_PASSWORD
ALTER ROLE :"role" PASSWORD :'secret';
PSQL
  done <<< "$logins"
  log "schema migrated and restricted logins converged"
)

# --- Smoke [PACKAGE-HOSTED-CONFORMANCE] origin row ------------------------------------------------
status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" || true; }

step_smoke() {
  "$ROOT/scripts/packages/check-website-release.sh" "https://$(host packages)"
  local api run; api="https://$(host packages-api)"; run="$(gcloud run services describe "$NAME" --region="$REGION" --project="$GCP_PROJECT_ID" --format='value(status.url)')"
  [[ "$run" == https://*.run.app ]] || die "missing Cloud Run service URL"
  local edge direct web
  edge="$(status "$api/v1/packages")"; direct="$(status "$run/v1/packages")"; web="$(status "https://$(host packages)/")"
  log "edge $api/v1/packages → $edge (must be 200)"
  log "direct $run/v1/packages → $direct (must be 403)"
  log "website → $web (must be 200)"
  # [PACKAGE-OWNERSHIP-RLS]: Supabase's Data API never serves the private schema, table or routine.
  local ref key data rpc; ref="$(jq -r .ref "$WORK/supabase.json")"; key="$(jq -r .publishable_key "$WORK/supabase.json")"
  data="$(status -H "apikey: $key" -H 'Accept-Profile: registry' "https://$ref.supabase.co/rest/v1/principals?limit=1")"
  rpc="$(status --head -H "apikey: $key" -H 'Accept-Profile: registry' "https://$ref.supabase.co/rest/v1/rpc/refresh_public_catalog")"
  log "Supabase Data API on the registry schema → table $data, routine $rpc (both must be 406)"
  [[ "$data" == 406 && "$rpc" == 406 ]] || die "the registry schema is exposed through the Supabase Data API"
  [[ "$edge" == 200 ]] && [[ "$direct" == 403 ]] && [[ "$web" == 200 ]] || die "smoke failed"
}

# Website: the content-addressed archive, uploaded to Pages with the Terraform-minted token.
# Built from a git archive of HEAD with a fresh digest-verified toolchain.
step_website() {
  local src="$WORK/site-src" revision
  revision="$(git -C "$ROOT" rev-parse HEAD)"
  log "publishing Pages from $revision"
  rm -rf "$src" && mkdir -p "$src/target"
  git -C "$ROOT" archive "$revision" | tar -x -C "$src"
  make -s -C "$src" _toolchain >&2
  REGISTRY_API_ORIGIN="https://$(host packages-api)" REGISTRY_CONTENT_ORIGIN="https://$(host packages-content)" \
    make -s -C "$src" _registry-website-archive >&2
  local archive upload="$WORK/pages-upload"; archive="$(ls "$src"/target/registry-artifacts/*.zip)"
  [[ "$(wc -l <<<"$archive" | tr -d ' ')" == 1 ]] || die "expected one website archive, found: $archive"
  rm -rf "$upload" && mkdir -p "$upload" && unzip -q "$archive" -d "$upload"
  local publisher="$src/src/manager/ops/cloudflare"
  npm ci --prefix "$publisher" --ignore-scripts --no-audit --no-fund >&2
  CLOUDFLARE_API_TOKEN="$(tf output -raw pages_token)" CLOUDFLARE_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID" \
    "$publisher/node_modules/.bin/wrangler" pages deploy "$upload" --project-name="$NAME" --branch=main \
    --commit-hash="$revision" >&2
  "$ROOT/scripts/packages/check-website-release.sh" "https://$(host packages)" "$upload"
}

# Operator release of HEAD: image via Cloud Build, Cloud Run rolled to its digest, website uploaded.
step_ship() {
  local image; image="$(build_image)"
  "$ROOT/scripts/packages/roll-registry-image.sh" "$NAME" "$REGION" "$GCP_PROJECT_ID" "$(tf output -raw release_scanner)" "$image" >&2
  step_website
}

# Production takes main's pushed head and nothing else: no feature branch, no unmerged commit, no
# uncommitted file. Every step that changes production passes through here first.
require_main() {
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "deploys run from main only; this checkout is on $(git rev-parse --abbrev-ref HEAD)"
  git fetch -q origin main || die "cannot fetch origin/main"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "deploys run from origin/main's head only; HEAD is $(git rev-parse --short HEAD)"
  [[ -z "$(git status --porcelain)" ]] || die "deploys run from a clean main checkout only"
}

main() {
  if [[ "$STEP" == smoke ]]; then
    read_environment
    step_smoke
    return
  fi
  require_main
  load_config
  ensure_project
  ensure_spend_cap
  case "$STEP" in github|database|ship|website) tf_init ;; esac
  case "$STEP" in
    all|release) step_supabase; step_infra; step_github; step_database; dispatch; step_smoke ;;
    # Straight from this checkout's HEAD, without the GitHub workflow.
    local) step_supabase; step_infra; step_database; step_website; step_smoke ;;
    supabase|infra|github|database|ship|website) "step_$STEP" ;;
    *) die "unknown step $STEP" ;;
  esac
  log "$STEP done"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
