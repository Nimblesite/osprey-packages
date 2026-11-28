#!/usr/bin/env bash
# Production takes main and nothing else. This proves every guard is in place: deploy.sh refuses each
# deploying step on another branch, the deploy workflows fail on any other ref, and Google only
# federates the production deploy identity for refs/heads/main.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
"$root/scripts/packages/test-roll-registry-image.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

GIT_LFS_SKIP_SMUDGE=1 git clone -q --no-hardlinks "$root" "$work/repo"
cp "$root/src/manager/ops/deploy.sh" "$work/repo/src/manager/ops/deploy.sh"
cp "$root/scripts/packages/check-website-release.sh" "$work/repo/scripts/packages/"
git -C "$work/repo" checkout -q -b not-main
for step in all local supabase infra github database release ship website; do
  if out="$(cd "$work/repo" && src/manager/ops/deploy.sh production "$step" 2>&1)"; then
    echo "deploy.sh production $step ran on a branch other than main" >&2; exit 1
  fi
  grep -Fq "deploys run from main only" <<<"$out" || { echo "deploy.sh production $step failed for another reason: $out" >&2; exit 1; }
done

# A read-only smoke check on a feature branch uses the existing service and public endpoints.
mkdir -p "$work/bin" "$work/repo/target/deploy/production"
printf 'DOMAIN=example.test\nGCP_PROJECT_ID=test-project\n' > "$work/repo/src/manager/ops/deploy.env"
printf '{"ref":"fixture","publishable_key":"public"}\n' > "$work/repo/target/deploy/production/supabase.json"
cat > "$work/bin/gcloud" <<'MOCK'
#!/bin/sh
test "$*" = 'run services describe osprey-registry-production --region=us-central1 --project=test-project --format=value(status.url)' || exit 97
echo https://fixture.run.app
MOCK
cat > "$work/bin/curl" <<'MOCK'
#!/bin/sh
output=
previous=
for url do
  if [ "$previous" = -o ]; then output=$url; fi
  previous=$url
  case "$url" in -X|--request|--data*) exit 98;; esac
done
if [ -n "${SERVED_SITE:-}" ]; then
  case "$url" in
    https://packages.example.test/*)
      path=${url#https://packages.example.test/}
      case "$path" in ''|*/) path=${path}index.html;; esac
      cp "$SERVED_SITE/$path" "$output" || exit 99
      printf 200
      exit 0;;
  esac
fi
case "$url" in
  https://packages-api.example.test/v1/packages) printf %s "$CATALOG_STATUS";;
  https://packages.example.test/) printf 200;;
  https://package.example.test/*) printf %s "$WEBSITE_REDIRECT";;
  https://fixture.run.app/v1/packages) printf 403;;
  https://fixture.supabase.co/rest/v1/*) printf 406;;
  *) exit 98;;
esac
MOCK
chmod +x "$work/bin/"*
smoke() { (cd "$work/repo" && PATH="$work/bin:$PATH" CATALOG_STATUS="$1" WEBSITE_REDIRECT="${2-308 https://packages.example.test/release/?from=registry}" src/manager/ops/deploy.sh production smoke); }
smoke 200
if smoke 200 "308 https://packages.example.test/"; then echo "wrong website redirect passed" >&2; exit 1; fi
if smoke 503; then echo "unavailable catalog passed production smoke" >&2; exit 1; fi

mkdir -p "$work/archive/release" "$work/archive/signin"
for path in index.html release/index.html signin/index.html module.mjs style.css site.wasm; do echo "$path" > "$work/archive/$path"; done
cp -R "$work/archive" "$work/served"
verify_site() {
  PATH="$work/bin:$PATH" SERVED_SITE="$work/served" WEBSITE_REDIRECT='308 https://packages.example.test/release/?from=registry' \
    "$root/scripts/packages/check-website-release.sh" https://packages.example.test "$work/archive"
}
verify_site
echo stale > "$work/served/site.wasm"
if verify_site; then echo "stale deployed WASM passed" >&2; exit 1; fi

# Record production operations without contacting providers, including a migration failure.
rollout() (
  # shellcheck disable=SC1091
  source "$root/src/manager/ops/deploy.sh" production "$1"
  for action in require_main load_config ensure_project ensure_spend_cap step_supabase step_infra step_github dispatch step_smoke; do
    eval "$action() { echo $action; }"
  done
  local migration_status="$2"
  step_database() { echo step_database; return "$migration_status"; }
  log() { :; }
  main
)
for entry in all release; do
  rollout "$entry" 0 > "$work/steps"
  printf '%s\n' require_main load_config ensure_project ensure_spend_cap step_supabase step_infra step_github step_database dispatch step_smoke | diff - "$work/steps"
done
set +e
( set -e; rollout release 1 ) > "$work/steps"
failed=$?
set -e
[[ "$failed" != 0 && "$(tail -1 "$work/steps")" == step_database ]] || { echo "failed migration did not stop release" >&2; exit 1; }

# Assert provider requests carry credentials to the destination without placing them in argv.
(
  source "$root/src/manager/ops/deploy.sh" production release
  export SUPABASE_ACCESS_TOKEN=private-fixture-token CLOUDFLARE_API_TOKEN=private-fixture-cloud
  export GITHUB_OAUTH_CLIENT_ID_PRODUCTION=test-client GITHUB_OAUTH_CLIENT_SECRET_PRODUCTION=private-fixture-oauth
  DOMAIN=example.test SUPABASE_ORG_ID=fixture SUPABASE_REGION=fixture
  jq() {
    [[ "$*" != *private-fixture* ]] || exit 93
    command jq "$@"
  }
  curl() {
    [[ "$*" != *private-fixture* ]] || exit 94
    local previous="" arg auth=""
    for arg do
      if [[ "$previous" == -H && "$arg" == @* ]]; then auth="$(cat "${arg#@}")"; fi
      previous="$arg"
    done
    case "${!#}" in
      *cloudflare*) [[ "$auth" == "Authorization: Bearer $CLOUDFLARE_API_TOKEN" ]] ;;
      *) [[ "$auth" == "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" ]] && cat > "$work/request.json" ;;
    esac
  }
  openssl() { echo private-fixture-password; }
  secret_put() { cat >/dev/null; }
  cloudflare_api /zones
  supabase_create
  command jq -e '.db_pass == "private-fixture-password"' "$work/request.json" >/dev/null
  supabase_auth fixture
  command jq -e '.external_github_secret == "private-fixture-oauth"' "$work/request.json" >/dev/null
)

# The dispatch response identifies the only run this operator may accept.
verify_dispatch() (
  source "$root/src/manager/ops/deploy.sh" production release
  gh() {
    if [[ "$1 $2" == "workflow run" ]]; then
      [[ "$*" == *"expected_sha=$(git rev-parse HEAD)"* ]] || return 91
      echo "$1" >> "$work/dispatched"
      echo "$DISPATCH_URL"
    elif [[ "$1 $2 $3" == "run watch 123" ]]; then
      echo watched >> "$work/dispatched"
    else
      return 92
    fi
  }
  dispatch
)
DISPATCH_URL=https://github.com/Nimblesite/osprey-packages/actions/runs/123 verify_dispatch
printf '%s\n' workflow watched | diff - "$work/dispatched"
if DISPATCH_URL=https://github.com/other/project/actions/runs/123 verify_dispatch; then exit 1; fi

need() { grep -Fq -- "$2" "$root/$1" || { echo "$1 lost its main-only guard: $2" >&2; exit 1; }; }
need .github/workflows/deploy.yml 'run: test "$GITHUB_REF" = refs/heads/main'
need .github/workflows/deploy.yml 'needs: main-only'
need .github/workflows/deploy.yml 'run: test "$GITHUB_SHA" = "$EXPECTED_SHA"'
need .github/workflows/pages.yml 'run: test "$GITHUB_REF" = refs/heads/main'
need src/manager/ops/terraform/identity.tf "assertion.ref == 'refs/heads/main'"
need src/manager/ops/deploy.sh '--ref main'
echo "deploys run from main only: 9 deploy.sh steps refused, 5 guards present"
