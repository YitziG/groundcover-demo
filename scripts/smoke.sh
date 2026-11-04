#!/usr/bin/env bash
# Happy-path checks against a cluster setup.sh already brought up.
set -euo pipefail

NS="${PEBBLE_NAMESPACE:-pebble}"
CONTEXT="${PEBBLE_CONTEXT:-kind-pebble}"

kubectl config use-context "$CONTEXT" >/dev/null

shop() {
  kubectl -n "$NS" exec deployment/loadgen -- curl -sS --max-time 15 "$@"
}

echo "health"
health="$(shop http://shop:8080/health)"
echo "$health"
echo "$health" | grep -q '"ok":true'

echo "products"
products="$(shop http://shop:8080/products)"
echo "$products"
echo "$products" | grep -q 'mug'

echo "order"
order="$(shop -H 'content-type: application/json' -d '{"sku":"mug","qty":1}' http://shop:8080/orders)"
echo "$order"
echo "$order" | grep -q '"sku":"mug"'
echo "$order" | grep -q '"total_cents":1200'

echo "load generator"
# Give the loop a moment on a fresh pod.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if kubectl -n "$NS" logs deployment/loadgen --tail=40 | grep -q 'status=200'; then
    echo "loadgen has recorded HTTP 200"
    exit 0
  fi
  sleep 1
done

echo "loadgen logs did not show status=200" >&2
kubectl -n "$NS" logs deployment/loadgen --tail=40 >&2 || true
exit 1
