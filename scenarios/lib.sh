#!/usr/bin/env bash
# Shared helpers for the scenario toggles.

NS="${PEBBLE_NAMESPACE:-pebble}"
CONTEXT="${PEBBLE_CONTEXT:-kind-pebble}"

die() {
  echo "$*" >&2
  exit 1
}

use_cluster() {
  kubectl config use-context "$CONTEXT" >/dev/null 2>&1 \
    || die "Cannot use kubectl context ${CONTEXT}. Run ./setup.sh first."
  kubectl cluster-info >/dev/null 2>&1 \
    || die "Kubernetes context ${CONTEXT} is not responding. Run ./setup.sh first."
}

usage() {
  echo "usage: $(basename "$0") on|off" >&2
  exit 2
}

rollout() {
  local deploy="$1"
  kubectl -n "$NS" rollout status "deployment/${deploy}" --timeout=180s
}
