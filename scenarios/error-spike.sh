#!/usr/bin/env bash
# Make every checkout return HTTP 500. Product reads keep working.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
use_cluster

case "${1:-}" in
  on)
    kubectl -n "$NS" set env deployment/shop FORCE_ERROR=1
    rollout shop
    echo "POST /orders now returns 500. GET /products still returns 200."
    printf '%s\n' "Try: curl -s -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d '{\"sku\":\"mug\",\"qty\":1}' http://127.0.0.1:8080/orders"
    ;;
  off)
    kubectl -n "$NS" set env deployment/shop FORCE_ERROR=0
    rollout shop
    echo "checkouts work again."
    ;;
  *)
    usage
    ;;
esac
