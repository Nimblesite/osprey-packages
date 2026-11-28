#!/bin/sh
# Bridge the native Osprey status report to the job scheduler's exit status.
set -eu
case "${0##*/}" in
  registry-collect-once) binary=/usr/local/bin/osprey-registry-collect ;;
  registry-scan-once|registry-scan-once.sh) binary=${REGISTRY_SCAN_BINARY:-/usr/local/bin/osprey-registry-scan} ;;
  *) exit 1 ;;
esac
result=$(printf '%s\n' "${1:-}" | "$binary")
test "$result" = 'status: 0'
