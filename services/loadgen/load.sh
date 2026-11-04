#!/bin/bash
# Steady traffic against the shop. Logs go to stdout; nothing is instrumented.
set -u

SHOP="${SHOP_URL:-http://shop:8080}"
echo "level=info service=loadgen msg=starting shop=${SHOP}"

while true; do
  n=$((RANDOM % 10))
  if [[ "$n" -lt 5 ]]; then
    curl -sS -o /dev/null --max-time 15 \
      -w "level=info service=loadgen method=GET path=/products status=%{http_code} duration_s=%{time_total}\n" \
      "${SHOP}/products" \
      || echo "level=error service=loadgen method=GET path=/products msg=curl_failed"
  elif [[ "$n" -lt 9 ]]; then
    pick=$((RANDOM % 3))
    if [[ "$pick" -eq 0 ]]; then
      sku="mug"
    elif [[ "$pick" -eq 1 ]]; then
      sku="notebook"
    else
      sku="pen"
    fi
    qty=$((RANDOM % 2 + 1))
    curl -sS -o /dev/null --max-time 15 \
      -w "level=info service=loadgen method=POST path=/orders status=%{http_code} duration_s=%{time_total}\n" \
      -H "content-type: application/json" \
      -d "{\"sku\":\"${sku}\",\"qty\":${qty}}" \
      "${SHOP}/orders" \
      || echo "level=error service=loadgen method=POST path=/orders msg=curl_failed"
  else
    curl -sS -o /dev/null --max-time 5 \
      -w "level=info service=loadgen method=GET path=/health status=%{http_code} duration_s=%{time_total}\n" \
      "${SHOP}/health" \
      || echo "level=error service=loadgen method=GET path=/health msg=curl_failed"
  fi
  sleep 0.4
done
