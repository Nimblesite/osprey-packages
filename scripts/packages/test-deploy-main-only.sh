#!/usr/bin/env bash
# Production takes main and nothing else. This proves every guard is in place: deploy.sh refuses each
# deploying step on another branch, the deploy workflows fail on any other ref, and Google only
# federates the production deploy identity for refs/heads/main.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone -q --no-hardlinks "$root" "$work/repo"
cp "$root/src/manager/ops/deploy.sh" "$work/repo/src/manager/ops/deploy.sh"
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
for url do
  case "$url" in -X|--request|--data*) exit 98;; esac
done
case "$url" in
  https://packages-api.example.test/v1/packages) printf %s "$CATALOG_STATUS";;
  https://packages.example.test/) printf 200;;
  https://fixture.run.app/v1/packages) printf 403;;
  https://fixture.supabase.co/rest/v1/*) printf 406;;
  *) exit 98;;
esac
MOCK
chmod +x "$work/bin/"*
smoke() { (cd "$work/repo" && PATH="$work/bin:$PATH" CATALOG_STATUS="$1" src/manager/ops/deploy.sh production smoke); }
smoke 200
if smoke 503; then echo "unavailable catalog passed production smoke" >&2; exit 1; fi

need() { grep -Fq -- "$2" "$root/$1" || { echo "$1 lost its main-only guard: $2" >&2; exit 1; }; }
need .github/workflows/deploy.yml 'run: test "$GITHUB_REF" = refs/heads/main'
need .github/workflows/deploy.yml 'needs: main-only'
need .github/workflows/pages.yml 'run: test "$GITHUB_REF" = refs/heads/main'
need src/manager/ops/terraform/identity.tf "assertion.ref == 'refs/heads/main'"
need src/manager/ops/deploy.sh '--ref main'
echo "deploys run from main only: 9 deploy.sh steps refused, 5 guards present"
