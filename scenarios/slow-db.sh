#!/usr/bin/env bash
# Hold every catalog database read for 2 seconds. Health checks stay fast.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
use_cluster

case "${1:-}" in
  on)
    kubectl -n "$NS" set env deployment/catalog SLOW_DB_MS=2000
    rollout catalog
    echo "catalog now runs SELECT pg_sleep(2) on each product read."
    printf '%s\n' "Try: curl -s -o /dev/null -w '%{time_total}' http://127.0.0.1:8080/products"
    ;;
  off)
    kubectl -n "$NS" set env deployment/catalog SLOW_DB_MS=0
    rollout catalog
    echo "catalog database reads are back to normal."
    ;;
  *)
    usage
    ;;
esac
