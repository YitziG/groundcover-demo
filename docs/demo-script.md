# Five-minute demo

Do this without a groundcover backend. `./setup.sh` should already have finished, so image builds are not part of the five minutes. Have a terminal in this repo and a browser on [play.groundcover.com](https://play.groundcover.com).

The playground modal says "Explore the groundcover playground" and "A live Kubernetes cluster, already full of data. No install. No credit card." Type an email, click Launch Playground, and leave the Workloads page up. The cluster in that app is `k8s-demo`. Say that out loud the first time you switch windows. It is groundcover's sample data, not Pebble.

Rollouts take about twenty seconds. Talk over them. If one runs long, skip to the next beat instead of clicking around a page you have not opened.

## 0:00 — What this is

Say:

> This is Pebble, a two-service shop. Node takes the order, Python reads the catalog, Postgres and Redis sit behind them. Nothing in the code imports an SDK. The logs are stdout. I am not installing groundcover on this cluster. A real install needs a BYOC backend in your own AWS, GCP, or Azure account before an ingestion endpoint even exists. The UI I will click is their public playground, which is a different cluster.

Show `services/shop/package.json` and `services/catalog/requirements.txt`. The dependencies are `pg`, `redis`, and `psycopg`.

```bash
curl -s http://127.0.0.1:8080/products
kubectl -n pebble logs deploy/loadgen --tail=5
```

Say the path the lines imply: loadgen, shop, catalog, then Postgres and Redis.

## 1:10 — Slow query, in the terminal

```bash
./scenarios/slow-db.sh on
```

While catalog restarts:

> This sets `SLOW_DB_MS=2000`. Every product read runs `SELECT pg_sleep(2)`. The health check does not, so the pod stays Ready.

```bash
curl -s -o /dev/null -w 'products took %{time_total}s\n' http://127.0.0.1:8080/products
kubectl -n pebble logs deploy/catalog --tail=8
```

Read the `msg=slow_query` line. Then:

```bash
./scenarios/slow-db.sh off
```

You do not have to wait for this rollout. Switch to the browser.

## 2:20 — The same kinds of signals, on their cluster

On Workloads, the table columns include Requests, Error Rate, and P95. The cluster column says `k8s-demo`. Scroll to namespace `flower-shop`. When this was checked on 4 Nov 2026, `order-service` showed an error rate of 100% and a P95 around 28 ms, and `postgres` in that namespace showed an error rate around 54%. Say those numbers only if they are still on screen. They are not Pebble.

Open Map. The facet list counted HTTP, PostgreSQL, and Redis among the edge types, and split sources into eBPF and opentelemetry. Edges on the graph were labeled `http`, `grpc`, and `postgresql`. Point at `load-generator` and `product-catalog` if they are in view. Say Pebble's calls are the same protocols, on a laptop, and this graph is not those pods.

Open Traces. The page has a Golden Signals strip: Requests, Errors, Latencies, with P95 and P50 on the latency chart. The Errors legend includes `500`. Click one short row if you want the drawer. One that was open was labeled "eBPF Trace", a `200` from `frontend-proxy` to `frontend`, with the request headers in a Request tab. Sorting the Latency column brought 10 minute `flagd` `EventStream` calls, some marked `DEADLINE_EXCEEDED`. Say what that is: long-lived RPCs in the sample, not the two-second SQL sleep you just timed.

## 3:40 — Errors

```bash
./scenarios/error-spike.sh on
curl -s -o /dev/null -w 'checkout %{http_code}\n' \
  -H 'content-type: application/json' \
  -d '{"sku":"mug","qty":1}' \
  http://127.0.0.1:8080/orders
kubectl -n pebble logs deploy/shop --tail=5
```

Say `POST /orders` is 500 and `GET /products` is still 200. The shop log line is `level=error`.

In the playground, open Logs and use the filter `level:Error`. The chip showed on the order of 9K results. Read an `order-service` line if it is there. The ones on screen were "Failed to process order" and "Failed to create order in database", from namespace `flower-shop`. That is the sample shop failing, not ours.

```bash
./scenarios/error-spike.sh off
```

## 4:30 — OOM, terminal only

```bash
./scenarios/oom.sh on
kubectl -n pebble get pods -l app=catalog
```

Say:

> `OOM=1` allocates past the 192Mi limit. You want the reason `OOMKilled`. The playground nav has Events. I did not find an OOM example there, so this beat stays on the pod list.

Run `kubectl get pods` again if the first line still says Running. Then:

```bash
./scenarios/oom.sh off
```

> Same three switches, no code edit. The playground is their cluster. Pebble stays on the laptop until someone provisions a BYOC backend and runs `./scripts/install-groundcover.sh`. `./teardown.sh` deletes the kind cluster.

If someone asks about trace ids: the product correlates a log to a trace when the log line contains a trace id. This demo never writes one.

## If you are cut short

Do the slow `curl`, the `flower-shop` error rate on Workloads, and one `level:Error` log. Skip the OOM, or read the `./scenarios/oom.sh` command without waiting for the kill. Do not skip the "no SDK, and the playground is not this app" line.
