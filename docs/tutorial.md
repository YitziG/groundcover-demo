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

## Look, without a backend

[play.groundcover.com](https://play.groundcover.com) opens groundcover's own sample cluster. The modal says "A live Kubernetes cluster, already full of data. No install. No credit card." The cluster picker is `k8s-demo`. None of those workloads are Pebble. Use it to see the shape of the UI: Workloads lists Requests, Error Rate, and P95; Map draws HTTP, PostgreSQL, and Redis edges; Logs and Traces are separate pages. The five-minute script in [demo-script.md](demo-script.md) walks the screens that were actually open, and it keeps the broken pods in the terminal.

## Your own groundcover

A sensor install needs a backend first. [Login and Create a Workspace](https://docs.groundcover.com/getting-started/login-and-create-a-workspace) says to create a workspace and a backend, then follow the console to create a groundcover BYOC backend. Signup at [app.groundcover.com](https://app.groundcover.com) is an email code through `auth.groundcover.com`, and it only works from a computer. On 4 Nov 2026 the banner read "You have 14 days left on your trial". No card was asked, and no plan list appeared. The [billing page](https://docs.groundcover.com/administer/billing) still names Free, Team, Enterprise, and On-Premise. That list did not show up as a choice, and it did not offer a groundcover-hosted place to send data.

The next console screen is [backends/new](https://console.groundcover.com/backends/new): choose AWS, GCP, or Azure. Ingestion keys stay unavailable until that backend exists. [Architecture overview](https://docs.groundcover.com/architecture/overview) describes the backend as a dedicated cluster in your cloud, with the eBPF sensor in each monitored cluster and the UI reached through groundcover's cloud. The same page lists on-prem and air-gapped setups, and it says price follows the average number of monitored nodes rather than data volume. The [BYOC page](https://docs.groundcover.com/architecture/byoc) is the cloud-account guide. The [intro](https://docs.groundcover.com/) says the BYOC control-plane option is currently a paid plan, and the [Azure guide](https://docs.groundcover.com/architecture/byoc/setup-byoc-with-azure) says BYOC is for paid plans. Creating the account costs money. Skip it if you only want the shop and the playground.

When a backend is up, copy the ingestion endpoint from **Settings → Access → Ingestion Keys** into `.env` as `GROUNDCOVER_SITE` and run `./scripts/install-groundcover.sh`. The script writes a gitignored values file and runs `groundcover deploy -f`, matching the [install doc](https://docs.groundcover.com/getting-started/installation-and-updating/connect-kubernetes-cluster): backend disabled, your endpoint as the site, `clusterId` `pebble`, `env` `dev`. If `.env` is missing, the script exits and the shop is untouched. `groundcover auth login` is the documented login command if the CLI asks. If it asks about taints, skip the control plane. Leave `GROUNDCOVER_TOKEN` empty unless you already created a Sensor key. The sensor is a privileged DaemonSet. The `portal` pod calls `app.groundcover.com` on port 443, so the VM needs outbound HTTPS. The [traces page](https://docs.groundcover.com/investigate/traces-and-apm/traces) says eBPF traces show up within seconds. If a page is empty, check the `groundcover` namespace and BTF.

## What the sensor would show

The [5 quick steps](https://docs.groundcover.com/getting-started/5-quick-steps-to-get-you-started) call Workloads the home page. With a sensor on this cluster you would see `shop`, `catalog`, `postgres`, `redis`, and `loadgen`. The [Map page](https://docs.groundcover.com/investigate/maps) is eBPF spans: a node is a workload, a line is a call, green means every status is OK, red means one is Error. Traces include the payload and, for SQL, `db.statement`. Logs are the stdout lines. [Log management](https://docs.groundcover.com/capabilities/log-management) says logfmt is parsed, so `namespace:pebble workload:shop level:error` is a real filter. groundcover does not inject trace ids, and this code never writes one, so a log line does not jump to a trace by id. [Correlation](https://docs.groundcover.com/investigate/log-and-trace-correlation) needs the id in the log.

## Break three things

Each script is `kubectl set env`. Turn it off the same way, or run `make fix`. One at a time. Confirm the symptom with curl and `kubectl` even if you never install the sensor.

**Slow database.** `./scenarios/slow-db.sh on` sets `SLOW_DB_MS=2000`. The next product read runs `SELECT pg_sleep(2)`. Time a curl of `/products`, then read `msg=slow_query` in the catalog log. `./scenarios/slow-db.sh off` sets it back to `0`.

**Error spike.** `./scenarios/error-spike.sh on` sets `FORCE_ERROR=1`. Every `POST /orders` returns 500 and logs `level=error`. `GET /products` stays 200. Off restores `201`.

**Memory.** `./scenarios/oom.sh on` sets `OOM=1`. Catalog allocates until the 192Mi limit kills it. `kubectl -n pebble get pods -l app=catalog` shows `OOMKilled`. The docs' event query for that is `reason:OOMKilling`, on the [search page](https://docs.groundcover.com/investigate/querying-your-groundcover-data/search-performance). The playground's Events nav was not opened far enough to find an example, so treat the pod status as the check. `./scenarios/oom.sh off` rolls a pod that does not allocate.

## When you are done

`./teardown.sh` deletes the kind cluster, sensor included. To drop only groundcover, the install doc says `groundcover delete`.

For a live talk, use [demo-script.md](demo-script.md). Bring the kind cluster up before the clock starts. Leave the sensor uninstalled unless you already have a backend. The minutes that matter are the three toggles in the terminal, then the playground as a picture of someone else's cluster.
