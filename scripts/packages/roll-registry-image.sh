#!/usr/bin/env bash
# [PACKAGE-HOSTED-RELEASE] Apply the same reviewed image to the scanner and listener.
set -euo pipefail
service=${1:?service required}
region=${2:?region required}
project=${3:?project required}
scanner=${4:?scanner configuration required}
image=${5:?image required}
[[ "$image" =~ ^[^@[:space:]]+@sha256:[a-f0-9]{64}$ ]] || { echo "Expected an immutable registry image digest" >&2; exit 1; }
options=("--region=$region" "--project=$project" "--image=$image" --quiet)
case "$scanner" in
  "$service-scan") gcloud run jobs update "$scanner" "${options[@]}" ;;
  disabled) ;;
  *) echo "Unexpected registry scanner job" >&2; exit 1 ;;
esac
gcloud run services update "$service" "${options[@]}"
