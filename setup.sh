#!/usr/bin/env bash
# Create the kind cluster, build images, deploy Pebble, start the load generator.
# Safe to run again. Does not install groundcover.
set -euo pipefail

cd "$(dirname "$0")"

CLUSTER="${PEBBLE_CLUSTER:-pebble}"
NS="${PEBBLE_NAMESPACE:-pebble}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing '$1'. $2" >&2
    exit 1
  fi
}

need docker "Install Docker Engine on Linux. Docker Desktop's Kubernetes is not a supported groundcover target."
need kind "Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/"
need kubectl "Install kubectl: https://kubernetes.io/docs/tasks/tools/"

if ! docker info >/dev/null 2>&1; then
  echo "docker is installed but the daemon is not reachable. Start Docker and run this again." >&2
  exit 1
fi

if kind get clusters | grep -qx "$CLUSTER"; then
  echo "kind cluster ${CLUSTER} already exists"
else
  echo "creating kind cluster ${CLUSTER}"
  kind create cluster --config deploy/kind.yaml
fi

kubectl config use-context "kind-${CLUSTER}" >/dev/null

echo "building images"
docker build -t pebble-shop:local services/shop
docker build -t pebble-catalog:local services/catalog
docker build -t pebble-loadgen:local services/loadgen

echo "pulling Postgres and Redis on the host so the kind nodes do not need registry access"
docker pull postgres:16-alpine
docker pull redis:7-alpine

echo "loading images into kind"
kind load docker-image pebble-shop:local --name "$CLUSTER"
kind load docker-image pebble-catalog:local --name "$CLUSTER"
kind load docker-image pebble-loadgen:local --name "$CLUSTER"
kind load docker-image postgres:16-alpine --name "$CLUSTER"
kind load docker-image redis:7-alpine --name "$CLUSTER"

echo "deploying"
kubectl apply -f deploy/k8s/00-namespace.yaml
kubectl -n "$NS" create configmap postgres-init \
  --from-file=init.sql=deploy/postgres/init.sql \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f deploy/k8s/

# Same tag (:local) is cached by the nodes. Restart so a rebuilt image is what runs.
# Applying the manifests also puts SLOW_DB_MS, FORCE_ERROR, and OOM back to their defaults.
kubectl -n "$NS" rollout restart deployment/shop deployment/catalog deployment/loadgen

echo "waiting for rollouts"
kubectl -n "$NS" rollout status deployment/postgres --timeout=180s
kubectl -n "$NS" rollout status deployment/redis --timeout=180s
kubectl -n "$NS" rollout status deployment/catalog --timeout=180s
kubectl -n "$NS" rollout status deployment/shop --timeout=180s
kubectl -n "$NS" rollout status deployment/loadgen --timeout=180s

echo
echo "Pebble is up. The load generator is sending traffic."
echo "  curl http://127.0.0.1:8080/products"
echo "  curl -H 'content-type: application/json' -d '{\"sku\":\"mug\",\"qty\":1}' http://127.0.0.1:8080/orders"
echo
echo "groundcover is not installed yet. The shop does not need it."
echo "When you have a .env file: ./scripts/install-groundcover.sh"
echo "Scenarios: ./scenarios/slow-db.sh on|off, ./scenarios/error-spike.sh on|off, ./scenarios/oom.sh on|off"
echo "Tear down: ./teardown.sh"
