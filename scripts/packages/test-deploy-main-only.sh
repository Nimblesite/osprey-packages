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

need() { grep -Fq -- "$2" "$root/$1" || { echo "$1 lost its main-only guard: $2" >&2; exit 1; }; }
need .github/workflows/deploy.yml 'run: test "$GITHUB_REF" = refs/heads/main'
need .github/workflows/deploy.yml 'needs: main-only'
need .github/workflows/pages.yml 'run: test "$GITHUB_REF" = refs/heads/main'
need src/manager/ops/terraform/identity.tf "assertion.ref == 'refs/heads/main'"
need src/manager/ops/deploy.sh '--ref main'
echo "deploys run from main only: 9 deploy.sh steps refused, 5 guards present"
