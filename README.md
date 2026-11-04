# Pebble

Pebble is a tiny shop that runs on a local [kind](https://kind.sigs.k8s.io/) cluster. A Node API takes orders, a Python catalog reads products, and Postgres and Redis sit behind them. A load generator keeps the traffic going.

Nothing in the app is instrumented. There is no OpenTelemetry SDK, no Prometheus client, and no tracing-header code. Services log one line per request to stdout. [groundcover](https://docs.groundcover.com/) is an eBPF agent you install on the cluster afterwards. Its sensor is supposed to collect logs, metrics, traces, and a service map without a code change. This repo is a place to see that for yourself.

The shop runs the same way if you never install groundcover.

## What is in the cluster

```
loadgen --> shop (Node) --> catalog (Python) --> postgres
               |                |
               +--> postgres    +--> redis
               +--> redis
```

| Workload | What it does |
| --- | --- |
| `shop` | `GET /products`, `POST /orders`, `GET /orders/:id` |
| `catalog` | Reads the product table. Caches rows in Redis for 30 seconds. |
| `postgres` | Three products and the orders table. Schema: `deploy/postgres/init.sql` |
| `redis` | Catalog cache and a short-lived copy of each new order |
| `loadgen` | About one request every 0.4s: mostly product reads, some checkouts |

Stock is display-only. Orders do not decrement it, so the generator can run indefinitely. The database password in the manifests is a local demo value, `pebble`.

## Prerequisites

groundcover's sensor needs:

- Linux kernel 5.3 or newer, built with BTF. Check with `ls -la /sys/kernel/btf/vmlinux`. The file should exist. [Kernel requirements](https://docs.groundcover.com/reference/requirements/kernel-requirements-for-ebpf-sensor).
- Kubernetes 1.21 or newer. [Kubernetes requirements](https://docs.groundcover.com/reference/requirements/kubernetes-requirements).
- A distribution on their supported list. **kind and k3d are supported. Docker Desktop is not.** Use a Linux machine, or a Linux VM, and run kind there. Do not point this demo at Docker Desktop's built-in Kubernetes.

You also need Docker Engine (so kind can start nodes), `kind`, and `kubectl`. This repo's scripts use kind. k3d is supported by groundcover too, but there is no k3d script here.

The sensor runs as a privileged DaemonSet. That is a documented requirement for loading eBPF programs. kind allows privileged containers by default.

The cluster in `deploy/kind.yaml` has a control plane and one worker. The [coverage policy](https://docs.groundcover.com/getting-started/installation-and-updating/connect-kubernetes-cluster) excludes control-plane nodes, so the shop is scheduled on the worker.

Outbound HTTPS to `app.groundcover.com:443` is required once the sensor is installed. The [requirements](https://docs.groundcover.com/reference/requirements/kubernetes-requirements) say the `portal` pod calls out, and you do not open an ingress for groundcover.

## Quickstart

```bash
./setup.sh          # or: make up
curl http://127.0.0.1:8080/products
curl -H 'content-type: application/json' \
  -d '{"sku":"mug","qty":1}' \
  http://127.0.0.1:8080/orders
```

`setup.sh` is safe to run again. It creates the `pebble` kind cluster if it is missing, builds `pebble-shop`, `pebble-catalog`, and `pebble-loadgen`, loads them into the cluster, applies the manifests, and restarts the app deployments so a rebuilt `:local` image actually starts. Applying the manifests also puts the scenario switches back to off.

Host port 8080 is forwarded to the shop Service (`NodePort` 30080) on the worker. If something else is already bound to 8080, kind will fail to create the cluster; stop that process and run `./setup.sh` again.

`setup.sh` pulls `postgres:16-alpine` and `redis:7-alpine` on the host and loads them into kind, along with the three images it builds. If `kind load` fails with `content digest ... not found`, Docker is probably using the containerd image store (`docker info` shows `containerd-snapshotter: true`). kind imports images with `docker save`, and that export is incomplete under the snapshotter. Switch the daemon to the overlay2 graph driver (`"features": {"containerd-snapshotter": false}` in `/etc/docker/daemon.json`), restart Docker, and run `./setup.sh` again.

If the pods stay unready and the logs say `getaddrinfo` or `Temporary failure in name resolution`, look at `sudo iptables-legacy -S FORWARD`. A `DROP` policy on that chain blocks traffic between kind nodes, so CoreDNS (on the control plane) is unreachable from the worker. `sudo iptables-legacy -P FORWARD ACCEPT` allows it. A machine with a single iptables backend does not need this.

Logs from the laptop:

```bash
kubectl -n pebble logs deploy/shop --tail=20
kubectl -n pebble logs deploy/loadgen --tail=20
```

Tear it down:

```bash
./teardown.sh       # or: make down
```

That deletes the kind cluster, including a groundcover install if you added one.

## Look at groundcover without installing it

The shop does not need an account. To see the product, open [play.groundcover.com](https://play.groundcover.com). A modal asks for an email and says "A live Kubernetes cluster, already full of data. No install. No credit card." After Launch Playground the app shows groundcover's sample cluster, `k8s-demo`. That is not Pebble. `docs/demo-script.md` uses that playground next to the terminal.

## Run it against your own groundcover

Do this only if you are willing to provision a backend in your own cloud account. The sensor has nowhere to send data until that backend exists, and this repo does not create one.

1. Sign up on a computer at [app.groundcover.com](https://app.groundcover.com). The login is an email code through `auth.groundcover.com`. Phones and tablets cannot sign up. The steps start at [Login and Create a Workspace](https://docs.groundcover.com/getting-started/login-and-create-a-workspace), which says to create a workspace and a backend. On 4 Nov 2026 the console banner read "You have 14 days left on your trial". No card was requested, and no plan picker was shown. The [billing page](https://docs.groundcover.com/administer/billing) still lists plan names Free, Team, Enterprise, and On-Premise. That page is not a promise that signup gives you a hosted backend.
2. The console then requires a BYOC backend in an AWS, GCP, or Azure account you own. The screen is [console.groundcover.com/backends/new](https://console.groundcover.com/backends/new), headed "Choose your cloud provider". There was no groundcover-hosted option. Ingestion keys and the endpoint stay out of reach until the backend exists. [Architecture overview](https://docs.groundcover.com/architecture/overview) describes BYOC as a backend in a dedicated cluster in your cloud, with the sensor in each monitored cluster and the UI reached through groundcover's cloud. The same page lists on-prem and air-gapped setups. The [BYOC page](https://docs.groundcover.com/architecture/byoc) is the cloud-account guide (AWS, GCP, Azure). The [intro](https://docs.groundcover.com/) says the BYOC option that runs the control plane in your environment is currently a paid plan, and the [Azure setup](https://docs.groundcover.com/architecture/byoc/setup-byoc-with-azure) says BYOC is for paid plans. Read those before you create cloud resources. This demo does not.
3. After the backend is up, open **Settings → Access → Ingestion Keys** and copy the ingestion endpoint. That value is `{BYOC_ENDPOINT}` in the install docs. A Sensor key is optional. [Ingestion keys](https://docs.groundcover.com/collect-data/ingestion-keys). The [architecture overview](https://docs.groundcover.com/architecture/overview) says price tracks the average number of monitored nodes, not the volume of logs or traces. It does not publish a free-tier node cap, and neither does this repo.
4. On the machine that has the kind cluster:

```bash
cp .env.example .env
# set GROUNDCOVER_SITE to that endpoint
./scripts/install-groundcover.sh    # or: make groundcover
```

The script refuses to run when `.env` is missing or `GROUNDCOVER_SITE` is empty, and it does not modify the shop. It writes `deploy/groundcover/values.local.yaml` (gitignored) in the shape from [Connect Kubernetes clusters](https://docs.groundcover.com/getting-started/installation-and-updating/connect-kubernetes-cluster):

```yaml
global:
  backend:
    enabled: false
  ingress:
    site: your.endpoint.example
clusterId: "pebble"
env: "dev"
```

`clusterId` and `env` are optional in the product. The CLI detects the cluster name if `clusterId` is unset, and an empty `env` shows up as `none` in the Cluster Picker. This demo sets both.

It then runs the documented install:

```bash
sh -c "$(curl -fsSL https://groundcover.com/install.sh)"   # only if the CLI is missing
groundcover deploy -f deploy/groundcover/values.local.yaml
```

If the CLI is not logged in, run `groundcover auth login` (that command is documented on the [EKS add-on](https://docs.groundcover.com/collect-data/byoc/setup-byoc-with-aws/eks-add-on) page) and deploy again. The CLI may prompt about node taints. Skip the control-plane taint. The worker has no taint, and that is where the pods are. The docs also say the CLI will reuse an ingestion key or provision one, so `GROUNDCOVER_TOKEN` can stay empty. Set it only if you already created a Sensor key and want it written as `global.groundcover_token`.

Helm, if you prefer the chart to the CLI, from the same doc page:

```bash
groundcover auth get-ingestion-key sensor
helm repo add groundcover https://helm.groundcover.com && helm repo update groundcover
helm upgrade groundcover groundcover/groundcover \
  -i --create-namespace -n groundcover \
  -f deploy/groundcover/values.local.yaml
```

The Helm values file also needs `global.groundcover_token`. Put the Sensor key in `GROUNDCOVER_TOKEN` and re-run the script to regenerate the file, or add the key yourself. Do not commit the file.

To remove the sensor without deleting the cluster, the docs say `groundcover delete`. `./teardown.sh` removes the whole cluster instead.

The [traces](https://docs.groundcover.com/investigate/traces-and-apm/traces) page says eBPF traces are available within seconds of installation. If a view is empty, confirm pods in the `groundcover` namespace are running and that the host kernel has BTF. A kernel the sensor cannot load still leaves Kubernetes metadata and logs, per the [kernel requirements](https://docs.groundcover.com/reference/requirements/kernel-requirements-for-ebpf-sensor).

## Where to look

These are the pages the current docs actually name, for a cluster whose sensor is reporting. On the playground the same nav labels are Workloads, Map, Logs, Traces, and Events, filled with `k8s-demo` rather than `pebble`. Filter with the scope keys the docs recommend (`namespace`, `workload`, and `cluster` or `env` when you have them). For this repo the namespace is `pebble`.

| You want | Where the docs send you |
| --- | --- |
| Service list | [Workloads](https://docs.groundcover.com/getting-started/5-quick-steps-to-get-you-started), the app home page |
| A dependency map from eBPF only | [Map page](https://docs.groundcover.com/investigate/maps). Nodes are workloads. A line is a detected call. Green means every status on that line is OK. Red means at least one status is Error. |
| The same map including any non-eBPF spans | Traces → Map tab, same page |
| One request, including HTTP bodies and SQL | [Traces](https://docs.groundcover.com/investigate/traces-and-apm/traces). Attributes include `http.path` and `db.statement`. |
| Stdout | [Log Explorer](https://docs.groundcover.com/capabilities/log-management). Collection is automatic. `logfmt` is parsed into attributes, which is why the app logs `level=info`. |
| Latency, error rate, request rate | [Application metrics](https://docs.groundcover.com/investigate/traces-and-apm/application-performance-monitoring-apm/application-metrics), queried as the APM data source in [Explore](https://docs.groundcover.com/use-groundcover/querying-your-groundcover-data/explore-and-monitors-query-builder). Golden signals include Error Rate and P95 Latency. |
| Pod killed or crash-looping | Kubernetes events. [Search performance](https://docs.groundcover.com/investigate/querying-your-groundcover-data/search-performance) gives `type:Warning` and `reason:OOMKilling`. Container state reasons include `OOMKilled` and `CrashLoopBackOff` on the [metrics labels](https://docs.groundcover.com/investigate/traces-and-apm/application-performance-monitoring-apm/application-metrics). |

Postgres and Redis are named resource types (`postgresql`, `redis`) on the [APM query](https://docs.groundcover.com/reference/remote-access-and-apis/api-examples/query-apm-measurements) page, so those calls can show up as their own protocol rather than as plain TCP.

One limit, on purpose: [log and trace correlation by trace id](https://docs.groundcover.com/investigate/log-and-trace-correlation) does not happen by itself. groundcover does not inject a trace id into logs. This app does not write one. A trace is still documented as carrying the logs from that service around the same time, plus container info and Kubernetes events. That is a different link than a shared `trace_id`.

## Scenarios

Run one at a time. Each script patches an environment variable and lets Kubernetes roll the pod. Nothing in git changes. `make fix` turns all three off. `./setup.sh` also restores the defaults, because they live in the manifests.

Check the symptom in the terminal. The "In groundcover" notes apply after a sensor is sending this cluster to a backend you already have. They are not something the playground will show for these pods.

### Slow database

```bash
./scenarios/slow-db.sh on     # make break-slow-db
./scenarios/slow-db.sh off    # make fix-slow-db
```

`SLOW_DB_MS=2000` on `catalog`. Every product read runs `SELECT pg_sleep(2)` before the real query. `/health` does not, so the probe stays green.

What changes: `curl` against `http://127.0.0.1:8080/products` takes about two seconds. Catalog logs a `msg=slow_query` line.

In groundcover: open Traces, scope to `namespace:pebble workload:catalog`, and look at `duration_seconds` (listed as a trace field on the [search performance](https://docs.groundcover.com/investigate/querying-your-groundcover-data/search-performance) page). The SQL text is the `db.statement` attribute. Sampling prefers unusually slow calls, so these are the ones the [traces](https://docs.groundcover.com/investigate/traces-and-apm/traces) page says it keeps. On the workload, the APM golden signals include P95 latency. The Map line stays green unless a call also errors.

### Error spike

```bash
./scenarios/error-spike.sh on     # make break-errors
./scenarios/error-spike.sh off    # make fix-errors
```

`FORCE_ERROR=1` on `shop`. `POST /orders` returns 500 and logs `level=error`. `GET /products` still returns 200. The load generator sends both, so the shop's error rate moves without the process dying.

In groundcover: Logs, `namespace:pebble workload:shop level:error`. Traces, `namespace:pebble workload:shop status_code>=500` (the documented example uses `status_code>=500`). Error responses are one of the sampling rules, so the failed checkouts are kept. The APM Error Rate for the shop's HTTP traffic should climb. On the Map page, a line turns red when any span status on it is Error.

### OOMKill

```bash
./scenarios/oom.sh on     # make break-oom
./scenarios/oom.sh off    # make fix-oom
```

`OOM=1` on `catalog`. The process allocates 8MiB blocks until the kernel kills it. The container limit is 192Mi. The deployment uses `Recreate`, so the healthy pod is removed and the new one crash-loops. There is a cap at 384MiB so a node whose cgroup limit is not enforced does not get eaten; in that case the process exits 137 anyway.

```bash
kubectl -n pebble get pods -l app=catalog
```

You want `OOMKilled` in the last terminated state, and often `CrashLoopBackOff` while Kubernetes backs off. Shop calls to catalog fail while it is down (`502` in the shop log).

In groundcover: events, `namespace:pebble type:Warning reason:OOMKilling`. The metrics docs also list `groundcover_container_memory_oom_events` and `groundcover_container_crash_count`, and a `crash_reason` / `state_reason` label whose examples include `OOMKilled` and `CrashLoopBackOff`. The catalog workload's memory limit metric is `groundcover_container_memory_limit_bytes`. Turning the scenario off rolls a pod that does not allocate, and product reads return 200 again.

## Layout

```
services/shop       Node API
services/catalog    Python catalog
services/loadgen    bash + curl loop
deploy/kind.yaml    control plane + worker, host port 8080
deploy/k8s          namespace and workloads
scenarios           on/off scripts
scripts/install-groundcover.sh
docs/tutorial.md    longer walkthrough
docs/demo-script.md five-minute talk track
```

## Further reading

- [Installation and updating](https://docs.groundcover.com/getting-started/installation-and-updating)
- [5 quick steps](https://docs.groundcover.com/getting-started/5-quick-steps-to-get-you-started)
- [APM](https://docs.groundcover.com/investigate/traces-and-apm/application-performance-monitoring-apm)
- [Maps](https://docs.groundcover.com/investigate/maps)
- [Log management](https://docs.groundcover.com/capabilities/log-management)
- [FAQ](https://docs.groundcover.com/reference/faq) (what the sensor collects, which distributions are supported)
