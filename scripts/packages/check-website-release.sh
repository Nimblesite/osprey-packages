#!/usr/bin/env bash
# [PACKAGE-HOSTED-RELEASE] Check the visitor's redirect and the canonical deployment bytes.
set -euo pipefail
origin="${1:?canonical registry website origin required}"
[[ "$origin" == https://packages.* && "${origin#https://}" != */* ]]
alias_origin="https://package.${origin#https://packages.}"
path='/release/?from=registry'
redirect="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{redirect_url}' "$alias_origin$path")"
[[ "$redirect" == "308 $origin$path" ]] || { echo "Invalid website redirect from $alias_origin$path: $redirect" >&2; exit 1; }
if [[ $# == 2 ]]; then
  site="$2"
  body="$(mktemp)"
  trap 'rm -f "$body"' EXIT
  verify() {
    local code
    code="$(curl -sS --compressed --max-time 30 -o "$body" -w '%{http_code}' "$origin/$1")"
    [[ "$code" == 200 ]] && cmp -s "$body" "$2" || { echo "Production bytes differ at $origin/$1 (HTTP $code)" >&2; exit 1; }
  }
  verify '' "$site/index.html"
  verify 'release/' "$site/release/index.html"
  verify 'signin/' "$site/signin/index.html"
  for asset in "$site"/*.mjs "$site"/*.css "$site"/*.wasm; do
    verify "${asset##*/}" "$asset"
  done
fi
