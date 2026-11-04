# Watch a small shop without adding an SDK

Pebble is a shop with two services and two data stores. `shop` is Node. `catalog` is Python. Postgres holds three products and the orders. Redis holds a short cache. A curl loop hits the shop a couple of times a second.

The services print logfmt to stdout. They do not import OpenTelemetry, a Prometheus client, or anything that writes a tracing header. groundcover's docs say an eBPF sensor on the node collects logs, metrics, traces, and a service map without that code. This repo is a small place to check that on a laptop. If you never install groundcover, `curl` still works.

## Bring up the cluster

Use Linux, or a Linux VM. The [Kubernetes requirements](https://docs.groundcover.com/reference/requirements/kubernetes-requirements) list kind and k3d as supported and Docker Desktop as not supported. The sensor needs kernel 5.3 or newer with BTF. `ls -la /sys/kernel/btf/vmlinux` should print a file. The [kernel page](https://docs.groundcover.com/reference/requirements/kernel-requirements-for-ebpf-sensor) has the list of distros.

The kind config adds a worker beside the control plane. The [install doc](https://docs.groundcover.com/getting-started/installation-and-updating/connect-kubernetes-cluster) says coverage skips control-plane nodes, and a one-node kind cluster is only a control plane.

Install Docker Engine, kind, and kubectl, then:

```bash
./setup.sh
curl -s http://127.0.0.1:8080/products
curl -s -H 'content-type: application/json' \
  -d '{"sku":"mug","qty":1}' \
  http://127.0.0.1:8080/orders
```

The script creates a cluster named `pebble`, builds three local images, loads them into kind, and applies the manifests. Run it again whenever you want. It will not create a second cluster. It restarts the app deployments so a rebuilt `:local` image is what is running, and it turns the break-it switches off. Those switches are environment variables.

`kubectl -n pebble logs deploy/shop --tail=20` shows lines like `level=info service=shop method=GET path=/products status=200 duration_ms=12`. That is the whole telemetry story in the repository.

A product read goes shop, then catalog, then SQL, then a Redis cache for 30 seconds. A checkout asks catalog for the SKU, inserts a row, and stores the order JSON in Redis for ten minutes. Health checks do none of that, so a slow query does not fail the pod probe. There is no mesh and no sidecar. The [APM page](https://docs.groundcover.com/investigate/traces-and-apm/application-performance-monitoring-apm) describes the sensor classifying the protocol and attaching the pods on each side of the call.

## Connect a workspace

Create the workspace from a computer, using [Login and Create a Workspace](https://docs.groundcover.com/getting-started/login-and-create-a-workspace). The docs call the app host [app.groundcover.com](https://app.groundcover.com). Let the console create the backend. The [billing page](https://docs.groundcover.com/use-groundcover/billing) lists a Free plan next to Team, Enterprise, and On-Premise. This walkthrough does not guess what that plan includes. The [pricing page](https://www.groundcover.com/pricing) charges for monitored nodes or hosts, not for ingested volume.

**Settings → Access → Ingestion Keys** shows the ingestion endpoint. Copy `.env.example` to `.env`, set `GROUNDCOVER_SITE`, and run `./scripts/install-groundcover.sh`. The script installs the CLI if it is missing, writes a gitignored values file, and runs `groundcover deploy -f` on it. The values match the install doc: backend disabled, your endpoint as the ingress site, `clusterId` `pebble`, `env` `dev`. If `.env` is missing, the script exits and the shop is untouched.

`groundcover auth login` is the documented login command if the CLI asks. If it asks about taints, skip the control plane. The worker has no taint. You can leave `GROUNDCOVER_TOKEN` empty. The CLI reuses an ingestion key or provisions one.

The sensor is a privileged DaemonSet, which is how it loads eBPF. The `portal` pod calls `app.groundcover.com` on port 443, so the VM needs outbound HTTPS. You do not open an ingress. The [traces page](https://docs.groundcover.com/investigate/traces-and-apm/traces) says eBPF traces show up within seconds. If a page is empty, check the `groundcover` namespace and BTF before you assume the shop is quiet.

## What to open

The [5 quick steps](https://docs.groundcover.com/getting-started/5-quick-steps-to-get-you-started) call Workloads the home page. You should see `shop`, `catalog`, `postgres`, `redis`, and `loadgen`.

The [Map page](https://docs.groundcover.com/investigate/maps) is eBPF spans only. A node is a workload. A line is a call, labeled HTTP, PostgreSQL, or Redis. Green means every status on that line is OK. Red means at least one is Error. Traces → Map can include other span sources. This app emits none, so the two maps should agree.

Open a trace. The traces doc says you get both sides, the resource, and the payload, including bodies. SQL is the `db.statement` attribute. A path is `http.path`. Sampling stores errors, unusually slow calls, and a baseline of normal ones, so the list is not every request. The APM page says the metrics still come from the full stream.

Logs are stdout. [Log management](https://docs.groundcover.com/capabilities/log-management) says collection needs no configuration, and logfmt becomes attributes, so this filter works:

```
namespace:pebble workload:shop level:error
```

The [search page](https://docs.groundcover.com/investigate/querying-your-groundcover-data/search-performance) says to put `namespace` and `workload` first. Do not expect a log line to open a trace by id. The [correlation doc](https://docs.groundcover.com/investigate/log-and-trace-correlation) says groundcover does not inject trace ids, and this code never writes one. A stored trace still carries nearby logs from that service. Filter both pages by workload and by the minute you care about.

Latency and errors are the APM golden signals. In Explore, the APM picker has request rate, error rate, and p50, p95, and p99 latency. `postgresql` and `redis` are resource types in the [query examples](https://docs.groundcover.com/reference/remote-access-and-apis/api-examples/query-apm-measurements).

## Break three things

Each script is `kubectl set env`. Turn it off the same way, or run `make fix`. One at a time.

**Slow database.** `./scenarios/slow-db.sh on` sets `SLOW_DB_MS=2000` on catalog. The next product read runs `SELECT pg_sleep(2)`, then the real select. Time a curl of `/products`. In Traces, filter `namespace:pebble workload:catalog` and read `duration_seconds`. The statement is on the span. P95 latency is the metric form of the same fact. The map stays green, because the call succeeds. `./scenarios/slow-db.sh off` sets the variable back to `0`.

**Error spike.** `./scenarios/error-spike.sh on` sets `FORCE_ERROR=1` on shop. Every `POST /orders` returns 500. Product reads stay 200, and the generator sends both, so the process is up and the error rate is not. Logs use the `level:error` filter above. Traces: `namespace:pebble workload:shop status_code>=500`. The traces doc uses HTTP 500 as the example of a response sampling keeps. Error rate is the APM signal. A map line goes red when any span on it is an error. Turning it off restores `201`.

**Memory.** `./scenarios/oom.sh on` sets `OOM=1`. Catalog allocates until the 192Mi limit kills it. The Deployment uses Recreate, so the old pod is removed and the new one loops. `kubectl -n pebble get pods -l app=catalog` shows `OOMKilled`, and usually `CrashLoopBackOff` once the restart delay starts. Events: `namespace:pebble type:Warning reason:OOMKilling`. The [metrics page](https://docs.groundcover.com/investigate/metrics/metrics-and-labels) also lists `groundcover_container_memory_oom_events`. Shop logs `502` while catalog will not stay up. `./scenarios/oom.sh off` rolls a pod that does not allocate, and `/products` returns 200 again.

The process also stops itself at 384MiB. That only matters if the cgroup limit is not enforced. On a normal kind node the kernel kills it first, which is the `OOMKilled` reason you want.

## When you are done

`./teardown.sh` deletes the kind cluster, sensor included. To drop only groundcover, the install doc says `groundcover delete`.

For a live talk, use [demo-script.md](demo-script.md). Bring the cluster and the sensor up before the clock starts. The minutes that matter are the three toggles, not the image build.
