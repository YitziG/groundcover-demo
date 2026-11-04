#!/usr/bin/env bash
# Delete the kind cluster. Idempotent.
set -euo pipefail

CLUSTER="${PEBBLE_CLUSTER:-pebble}"

if ! command -v kind >/dev/null 2>&1; then
  echo "kind is not installed; nothing to delete." >&2
  exit 1
fi

if kind get clusters | grep -qx "$CLUSTER"; then
  kind delete cluster --name "$CLUSTER"
else
  echo "kind cluster ${CLUSTER} is not present"
fi
