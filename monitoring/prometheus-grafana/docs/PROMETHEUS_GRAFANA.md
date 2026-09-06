# Rent-a-Ride — Prometheus & Grafana

Covers steps 7–10: Prometheus, Grafana, dashboards, and load-test verification.

## Why kube-prometheus-stack, not separate installs

Installing Prometheus and Grafana "by hand" means also separately wiring
node-exporter (node CPU/memory/disk/network), kube-state-metrics (pod/
deployment/node *status* - "Pod status" in the task list comes from here,
not from Prometheus scraping containers directly), the Prometheus
Operator's CRDs (ServiceMonitor, PodMonitor), and Grafana's datasource/
dashboard provisioning. `kube-prometheus-stack` bundles all of it as one
Helm chart with sane defaults - it's the standard approach for exactly
this task, not a shortcut.

## 1. Install Prometheus + Grafana

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f helm-values-kube-prometheus-stack.yaml \
  --set grafana.adminPassword='<pick-a-real-password>'

kubectl -n monitoring get pods -w
```

Wait for everything (`prometheus-*`, `alertmanager-*`, `grafana-*`,
`kube-prometheus-stack-operator-*`, `kube-state-metrics-*`, and one
`node-exporter` pod per node) to reach `Running`.

## Verify Prometheus is scraping targets

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```
Open `http://localhost:9090/targets` (or via SSH tunnel/bastion if
browsing from your own machine) - every target should show `UP`. This
covers "Verify that Prometheus is successfully scraping the required
targets" directly: node-exporter, kube-state-metrics, kubelet/cAdvisor
(node + pod + container CPU/memory), and the Prometheus/Grafana/
Alertmanager components themselves.

## 2. Enable application metrics (ingress-nginx)

Use kind's OWN ingress-nginx manifest, not the generic cloud one - the
generic manifest's Service is `type: LoadBalancer`, which on kind means a
permanently `<pending>` external IP AND a randomly-assigned NodePort each
time it's installed. That random port is never in `kind-config.yaml`'s
`extraPortMappings`, so it's unreachable from the host - the exact same
class of problem as an un-mapped Grafana NodePort.

```bash
kubectl delete namespace ingress-nginx   # if the generic manifest is currently installed
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller
```

This manifest routes real traffic via `hostPort` binding directly on the
node labeled `ingress-ready: "true"` (see `kind-config.yaml`'s own
comments) - through host ports 31080/31443, NOT through the Service's
LoadBalancer/NodePort at all (that Service staying `<pending>` here is
expected and harmless; ignore it).

**This specific controller build does not enable Prometheus metrics by
default** - `--enable-metrics` is absent from its args and the `/metrics`
endpoint only serves Go runtime metrics (`go_gc_*`) without it, not
`nginx_ingress_controller_*`. Confirmed by checking:
```bash
kubectl -n ingress-nginx get deploy ingress-nginx-controller -o yaml | grep -A20 args:
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- curl -s localhost:10254/metrics | grep nginx_ingress
```
If the second command returns nothing, patch the flag in:
```bash
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--enable-metrics=true"}]'
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller
```

Then apply the metrics Service + ServiceMonitor:
```bash
kubectl apply -f ingress-nginx-servicemonitor.yaml
```

This adds a metrics `Service` + `ServiceMonitor` for ingress-nginx (port
10254). This is what makes request rate, response time, and error rate
available without touching backend code - see `../docs` notes on the app
not currently exposing its own `/metrics`.

**Important - what this build of ingress-nginx actually exposes**: after
enabling metrics, checking the full metric list
(`curl -s localhost:9090/api/v1/label/__name__/values`) showed only
process-level counters here - `nginx_ingress_controller_nginx_process_requests_total`
(unlabeled, controller-wide), connections, CPU/memory, plus admission/
config/leader-election metrics. None of the labeled, per-request metrics
(`nginx_ingress_controller_requests`, `_request_duration_seconds`,
status-code breakdowns) that older guides assume exist in this build.
That means:
- **Request rate** IS available (`rate(nginx_ingress_controller_nginx_process_requests_total[5m])`) - just without a per-ingress/path breakdown.
- **p50/p95 latency and error rate are NOT available from ingress-nginx on
  this build** - confirmed absent, not a config issue. The dashboard's
  application section reflects this: request rate uses the real metric,
  and latency/error-rate are replaced with a text panel pointing at the
  `prom-client` option below as the actual path to get them.

**Important for load-testing**: send traffic to the ingress's real host
port (31080 per `kind-config.yaml`), NOT any application NodePort
(30300/30080/etc.) - traffic sent directly to a NodePort bypasses
ingress-nginx entirely, so it will never appear in these metrics even
though the app itself responds fine.

## 3. Install Grafana dashboards

The Helm values already auto-import three community dashboards (Node
Exporter Full, Kubernetes Cluster Monitoring, Kubernetes Pods) via
`grafana.dashboards.default` - nothing further needed for those.

For the application-specific dashboard (request rate / response time /
error rate, plus a rent-a-ride-scoped view of the infra/K8s panels):

```bash
kubectl apply -f dashboards/rentaride-app-dashboard-configmap.yaml
```

Grafana's dashboard sidecar (`grafana.sidecar.dashboards`, enabled in the
values file) auto-loads any ConfigMap labeled `grafana_dashboard: "1"` in
any namespace - no manual import through the UI needed.

## Access Grafana

```bash
kubectl -n monitoring get svc kube-prometheus-stack-grafana
```
NodePort `30030` per the values file. Log in as `admin` / whatever you set
with `--set grafana.adminPassword=...` above.

## Verify the Grafana ↔ Prometheus connection

Grafana → Connections → Data sources → **Prometheus** should already show
green/"Data source is working" (kube-prometheus-stack wires this
automatically). Confirm further: Grafana → Explore → run `up` - you
should get a result listing every scrape target.

## 4. Dashboards checklist

Open **Dashboards** in Grafana and confirm each of these renders live
data within a minute of load:

| Dashboard | Covers |
|---|---|
| Node Exporter Full (1860) | Infrastructure: CPU, memory, disk, network |
| Kubernetes Cluster Monitoring (315) | Kubernetes: node resource usage |
| Kubernetes Pods (6417) | Kubernetes: container resource usage |
| **Rent-a-Ride — App, Kubernetes & Infra** (custom) | All of the above scoped to `rent-a-ride`, plus request rate / response time / error rate |

## 5. Generate load and observe

```bash
cd scripts
./generate-traffic.sh http://localhost:30300 300 5
```

While it runs, watch:
- **Rent-a-Ride dashboard** in Grafana - request rate, p50/p95 latency,
  and error-rate panels should start moving within ~15-30s (matches
  Prometheus's scrape interval).
- **Kubernetes Pods dashboard** - pod CPU/memory should tick up under
  load.
- The script's own terminal output - live `kubectl get pods` / `kubectl
  top pods` alongside the Grafana view, so you can cross-check the two.

If `kubectl top pods` says metrics-server isn't ready, that's a separate
component from this Prometheus stack (see `k8s/README.md`'s autoscaling
section) - Grafana's panels still work either way since they read from
Prometheus, not the metrics API.

## Optional: true custom application metrics

Everything above gets request rate/latency/error-rate from ingress-nginx,
which is accurate for anything that goes through the ingress but is
still an "outside-in" view. For real in-process metrics (business logic
timers, queue depths, custom counters), the backend would need a
`/metrics` endpoint via `prom-client`:

```js
// server.js additions (not applied - opt-in)
const client = require('prom-client');
client.collectDefaultMetrics();
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});
```
...plus a `ServiceMonitor` pointed at the backend Service's new metrics
port. Left as a stretch item since it requires an application code change
and a rebuild/redeploy, not just cluster-side configuration.
