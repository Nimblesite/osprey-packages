#!/bin/sh
# Bridge the native Osprey status report to the job scheduler's exit status.
set -eu
result=$(printf '%s\n' "${1:-}" | "${REGISTRY_SCAN_BINARY:-/usr/local/bin/osprey-registry-scan}")
test "$result" = 'status: 0'
