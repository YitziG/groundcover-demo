#!/usr/bin/env bash
# Turn each scenario on, check the symptom, turn it off, check recovery.
set -euo pipefail

cd "$(dirname "$0")/.."

NS="${PEBBLE_NAMESPACE:-pebble}"

cleanup() {
  status=$?
  if [[ "$status" -ne 0 ]]; then
    echo "scenario check failed; turning toggles off"
    ./scenarios/slow-db.sh off || true
    ./scenarios/error-spike.sh off || true
    ./scenarios/oom.sh off || true
  fi
  exit "$status"
}
trap cleanup EXIT

shop_code_time() {
  kubectl -n "$NS" exec deployment/loadgen -- \
    curl -sS -o /dev/null --max-time 20 -w "%{http_code} %{time_total}\n" "$@"
}

echo "== slow database =="
./scenarios/slow-db.sh on
read -r slow_code slow_time < <(shop_code_time http://shop:8080/products)
echo "slow products -> ${slow_code} in ${slow_time}s"
awk -v t="$slow_time" 'BEGIN { exit !(t+0 >= 1.5) }' \
  || { echo "expected product latency >= 1.5s, got ${slow_time}"; exit 1; }
[[ "$slow_code" == "200" ]] || { echo "expected 200 during slow-db, got ${slow_code}"; exit 1; }

./scenarios/slow-db.sh off
read -r fast_code fast_time < <(shop_code_time http://shop:8080/products)
echo "recovered products -> ${fast_code} in ${fast_time}s"
awk -v t="$fast_time" 'BEGIN { exit !(t+0 < 1.0) }' \
  || { echo "expected product latency < 1s after fix, got ${fast_time}"; exit 1; }
[[ "$fast_code" == "200" ]] || { echo "expected 200 after slow-db off, got ${fast_code}"; exit 1; }

echo "== error spike =="
./scenarios/error-spike.sh on
read -r err_code _ < <(shop_code_time -H 'content-type: application/json' -d '{"sku":"mug","qty":1}' http://shop:8080/orders)
echo "forced checkout -> ${err_code}"
[[ "$err_code" == "500" ]] || { echo "expected 500, got ${err_code}"; exit 1; }
read -r still_ok _ < <(shop_code_time http://shop:8080/products)
[[ "$still_ok" == "200" ]] || { echo "products should stay 200 during the error spike, got ${still_ok}"; exit 1; }

./scenarios/error-spike.sh off
read -r ok_code _ < <(shop_code_time -H 'content-type: application/json' -d '{"sku":"pen","qty":1}' http://shop:8080/orders)
echo "recovered checkout -> ${ok_code}"
[[ "$ok_code" == "201" ]] || { echo "expected 201 after error spike off, got ${ok_code}"; exit 1; }

echo "== oom =="
./scenarios/oom.sh on
reason=""
for _ in $(seq 1 40); do
  reason="$(kubectl -n "$NS" get pods -l app=catalog -o jsonpath='{range .items[*]}{.metadata.name}{" waiting="}{.status.containerStatuses[*].state.waiting.reason}{" terminated="}{.status.containerStatuses[*].state.terminated.reason}{" last="}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}')"
  echo "$reason"
  if grep -q 'OOMKilled' <<<"$reason"; then
    break
  fi
  if grep -q 'CrashLoopBackOff' <<<"$reason"; then
    break
  fi
  sleep 3
  reason=""
done

if [[ -z "$reason" ]] || ! grep -Eq 'OOMKilled|CrashLoopBackOff' <<<"$reason"; then
  echo "catalog did not reach OOMKilled or CrashLoopBackOff" >&2
  kubectl -n "$NS" describe pods -l app=catalog >&2 || true
  exit 1
fi

./scenarios/oom.sh off
read -r back_code _ < <(shop_code_time http://shop:8080/products)
echo "catalog recovered -> ${back_code}"
[[ "$back_code" == "200" ]] || { echo "expected 200 after oom off, got ${back_code}"; exit 1; }

echo "all three scenarios toggled on and off"
