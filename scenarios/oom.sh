#!/usr/bin/env bash
# Ask catalog to allocate past its memory limit until the kernel OOM-kills it.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
use_cluster

case "${1:-}" in
  on)
    kubectl -n "$NS" set env deployment/catalog OOM=1 >/dev/null
    echo "catalog will allocate until it is OOMKilled, then restart and do it again."
    echo "The deployment uses Recreate, so the previous pod is removed first."
    echo "Watch: kubectl -n ${NS} get pods -l app=catalog -w"
    ;;
  off)
    kubectl -n "$NS" set env deployment/catalog OOM=0 >/dev/null
    rollout catalog
    echo "catalog is back within its memory limit."
    ;;
  *)
    usage
    ;;
esac
