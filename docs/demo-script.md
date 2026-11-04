# Five-minute demo

Practice this once before you give it. `./setup.sh` and `./scripts/install-groundcover.sh` should already have finished, and the Workloads page should already show the `pebble` namespace. Image builds and the first sensor sync are a bad use of the five minutes.

Have two windows ready: a terminal in this repo, and the groundcover app with the time range set to the last 15 minutes. The Cluster Picker should be on `pebble` / `dev`.

If a rollout feels slow, keep talking using the "while that restarts" lines. Do not click ahead into a page you have not opened during practice.

## 0:00 — What this is

Say:

> This is Pebble, a two-service shop. Node takes the order, Python reads the catalog, Postgres and Redis are the data stores. Nothing in the code imports an SDK. The only logs are stdout. groundcover is an eBPF sensor on the node. I want to show the map, a trace, a log line, and then break three things without editing code.

Show `services/shop/package.json` and `services/catalog/requirements.txt`. The dependencies are `pg`, `redis`, and `psycopg`. Point at one `console.log` / `print` in `services/shop/server.js` or `services/catalog/app.py`.

```bash
curl -s http://127.0.0.1:8080/products
```

Say: the load generator has been hitting this since the cluster came up.

## 0:45 — What the sensor already sees

Open the Workloads page. Filter or scroll to namespace `pebble`. Name `shop`, `catalog`, `postgres`, `redis`, `loadgen`.

Open the Map page (the eBPF-only one, not Traces → Map). You should see HTTP from `loadgen` to `shop` and from `shop` to `catalog`, plus PostgreSQL and Redis. Say that a green line means every status on it is OK, which is the legend in the maps doc.

Click one HTTP trace. Mention the status code, the path, and that the body is visible because the sensor captured the payload. If a SQL span is on screen, read the statement. Do not claim the log line is tied to this trace by a trace id. Say the app never writes one, so you correlate by workload and time. The trace view does include nearby logs from that service.

If the map is empty, fall back to `kubectl -n pebble get pods` and say the sensor is not seeing the worker. Check the `groundcover` namespace after the demo. Do not invent a reason on stage.

## 2:00 — Slow query

```bash
./scenarios/slow-db.sh on
```

While the catalog pod restarts (about twenty seconds):

> This sets `SLOW_DB_MS=2000` on the catalog Deployment. The process runs `SELECT pg_sleep(2)` on every product read. Health checks do not, so Kubernetes still thinks the pod is fine.

Then:

```bash
curl -s -o /dev/null -w 'products took %{time_total}s\n' http://127.0.0.1:8080/products
```

In Traces, filter:

```
namespace:pebble workload:catalog
```

Point at `duration_seconds` and, if the span has it, `db.statement`. Mention P95 latency on the catalog workload as the metric form of the same thing. The map line stays green.

Leave it on for the next sentence, then turn it off so the later steps are not all slow:

```bash
./scenarios/slow-db.sh off
```

You do not have to wait for this rollout before you start the next sentence. Start the error toggle once the command is in.

## 3:10 — Checkouts fail, the process stays up

```bash
./scenarios/error-spike.sh on
```

While `shop` restarts:

> `FORCE_ERROR=1` makes `POST /orders` return 500. `GET /products` still returns 200. The load generator sends both, so the error rate moves and the pod does not die.

```bash
curl -s -o /dev/null -w 'checkout %{http_code}\n' \
  -H 'content-type: application/json' \
  -d '{"sku":"mug","qty":1}' \
  http://127.0.0.1:8080/orders
```

Logs:

```
namespace:pebble workload:shop level:error
```

Traces:

```
namespace:pebble workload:shop status_code>=500
```

Say the failed checkout is the kind of call the traces doc says sampling keeps. If the map has refreshed, the line into `shop` for those checkouts is red. Error rate is the APM signal, same page family as the latency you just showed.

```bash
./scenarios/error-spike.sh off
```

## 4:10 — Kill the catalog pod

```bash
./scenarios/oom.sh on
kubectl -n pebble get pods -l app=catalog
```

Say:

> `OOM=1` allocates until the 192Mi limit kills the container. The Deployment is Recreate, so the old pod is gone. You want the reason `OOMKilled`. After a couple of restarts Kubernetes shows `CrashLoopBackOff` as well.

Run the get command a second time if the first still says `Running`. It usually flips within a few seconds.

Events filter, if you have time to open it:

```
namespace:pebble type:Warning reason:OOMKilling
```

One sentence on the user side: shop now logs 502 when it cannot reach catalog. You can show that with `kubectl -n pebble logs deploy/shop --tail=5` if the UI is behind.

## 4:40 — Close

```bash
./scenarios/oom.sh off
```

Say:

> That puts `OOM` back to 0 and rolls a normal catalog pod. Same command shape for all three failures: on, off, no code edit. The repo README has the filters I just used, with links to the doc page each one comes from. `./teardown.sh` deletes the cluster.

Stop talking. If someone asks about trace-id correlation, answer it: the product can do it when the log line contains a trace id, and this demo does not emit one, on purpose.

## If you are cut short

Do the map, the slow query, and the 500. Describe the OOM from `./scenarios/oom.sh` and the `reason:OOMKilling` filter instead of waiting for the pod to loop. Do not skip the "no SDK in the code" moment. That is the point of the repo.
