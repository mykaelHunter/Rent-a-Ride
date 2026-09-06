# Blue/Green Deployment

Two Helm releases of the same chart, in separate namespaces, sharing one
database. The ALB decides which one is "live" by which target group its
listener forwards to — cutover and rollback are both a single `aws elbv2
modify-listener` call, not a Kubernetes-level change.

## Why this shape

- **Separate namespaces (`blue`, `green`)** — full isolation of the app
  tier per version: their own Deployments, Services, HPAs, Secrets.
- **One shared MongoDB** — `blue` owns the real `mongo` StatefulSet;
  `green` sets `mongo.enabled: false` and points its `backend-secret`'s
  `mongo_uri` at blue's Mongo across namespaces
  (`mongo-0.mongo.blue.svc.cluster.local`). Without this, cutting over to
  green would mean logging into an empty database — no users, no
  bookings, no vehicles.
- **No cluster Ingress for either color** — the shared ingress-nginx
  controller (hostNetwork, singleton) can't cleanly host two namespaces'
  worth of identical `/` and `/api` path rules at once. Instead, the ALB
  targets each color's frontend NodePort directly; the frontend's own
  nginx already reverse-proxies `/api/` to the backend Service
  in-cluster (see `client/nginx.conf`), so nothing is lost by skipping
  the cluster Ingress here.
- **Two ALB target groups, one live listener, two test listeners** —
  `rent-a-ride-tg-blue` and `rent-a-ride-tg-green`, each health-checked
  independently. `:80`'s default action points at whichever is currently
  live; `:8080`/`:8081` always point at blue/green respectively so both
  stay attached to the ALB (and therefore actively health-checked) no
  matter which one `:80` currently forwards to. Switching `:80` is
  instant and trivially reversible; it doesn't touch Kubernetes at all.

```
                         ALB (rent-a-ride-alb)
                          HTTP :80 listener
                     default action -> ONE of:
                   ┌─────────────┴─────────────┐
                   ▼                           ▼
          tg-blue (port 30080)         tg-green (port 30081)
          health: 30300 /healthz       health: 30301 /healthz
                   │                           │
                   ▼                           ▼
        ┌─────────────────────┐     ┌─────────────────────┐
        │  namespace: blue     │     │  namespace: green     │
        │  frontend + backend  │     │  frontend + backend   │
        │  mongo (real data)   │     │  (no mongo - points    │
        │                       │     │   at blue's mongo)     │
        └─────────────────────┘     └─────────────────────┘
```

## One-time migration: rent-a-ride → blue

If your app is still running as a single release in the `rent-a-ride`
namespace (the pre-blue/green setup), move it into `blue` first:

```bash
cd infra/cli
./migrate-to-blue.sh
```

This copies `mongo-credentials` and `backend-secret` into a new `blue`
namespace, uninstalls the old `rent-a-ride` release (freeing NodePorts
30080/30300), and installs `blue` in their place using the exact same
image tags already pinned in `values.yaml` - so blue ends up running
byte-for-byte what was already live. This step causes a short outage
(the gap between the old release coming down and blue's pods becoming
Ready) since both claim the same NodePorts - see the script's header
comment if you need to avoid that gap entirely. Skip this section if
`blue` is already your live deployment.

## One-time setup

Assumes `infra/cli/create-alb.sh` has already been run (ALB + listener
exist) and `blue` is already deployed as your current stable version
(see migration step above if it isn't yet).

```bash
cd infra/cli
./blue-green-setup.sh
```

This creates both target groups, registers the app instance in each at
its NodePort, opens the private instance's security group to the ALB on
all four ports (30080/30300/30081/30301), adds two permanent **test
listeners** on the ALB (8080 → blue, 8081 → green, see script header for
why), and points the main `:80` listener's default action at `tg-blue` —
matching what's already live.

**Why the test listeners matter:** an ALB target group only gets health-
checked once at least one listener references it. Without them, `tg-green`
sits with a target registered but reports `unused` forever — not
unhealthy, just never checked — until `:80`'s default action is pointed
at it, which is exactly the thing you don't want to do before verifying
it. The 8080/8081 listeners keep both colors permanently attached and
checked regardless of which one is currently live on `:80`.

**Drift note:** the security-group rules this adds go onto the
Terraform-managed private SG (`infra/security_groups.tf`), same caveat as
`create-alb.sh` — the next `terraform apply` will remove them as drift
unless you fold them into the Terraform config.

## Deploying a new version to green

```bash
# 1. Create green's backend-secret first - same as blue's, except
#    mongo_uri points at blue's Mongo instead of a local one:
kubectl create secret generic backend-secret -n green \
  --from-literal=mongo_uri="mongodb://<user>:<url-encoded-pass>@mongo-0.mongo.blue.svc.cluster.local:27017/rent-a-ride?authSource=admin" \
  --from-literal=ACCESS_TOKEN=... \
  --from-literal=REFRESH_TOKEN=... \
  --from-literal=CLOUD_NAME=... \
  --from-literal=API_KEY=... \
  --from-literal=API_SECRET=... \
  --from-literal=EMAIL_HOST=... \
  --from-literal=EMAIL_PASSWORD=... \
  --from-literal=RAZORPAY_KEY_ID=... \
  --from-literal=RAZORPAY_SECRET=...
  # (copy the non-mongo_uri values straight from blue's backend-secret)

# 2. Bump the image tag(s) in values-green.yaml, then install/upgrade:
helm upgrade --install rent-a-ride-green ./helm/rent-a-ride \
  -n green --create-namespace \
  -f helm/rent-a-ride/environments/values-green.yaml

# 3. Verify green directly, bypassing the ALB's live listener entirely:
curl http://<EC2-PUBLIC-IP>:30081/            # kind NodePort - see note below
curl http://<EC2-PUBLIC-IP>:30301/healthz

# 4. Verify through the ALB's test listener (this is what actually
#    determines whether tg-green will report "healthy" for cutover):
curl http://<ALB-DNS-NAME>:8081/
aws elbv2 describe-target-health --target-group-arn <tg-green-arn>
```

**kind NodePort note:** 30081/30301 aren't in `k8s/kind-config.yaml`'s
`extraPortMappings` (only 30080/30300 are, from before blue/green existed),
and that file's mappings only take effect at cluster-creation time - kind
won't pick up an edit on a running cluster. Until the cluster is recreated
with green's ports added, step 3's curls need a manual forward from the
EC2 host into the kind node container:

```bash
NODE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' rent-a-ride-control-plane)
sudo socat TCP-LISTEN:30081,fork,reuseaddr TCP:${NODE_IP}:30081 &
sudo socat TCP-LISTEN:30301,fork,reuseaddr TCP:${NODE_IP}:30301 &
```

Step 4 (through the ALB) doesn't need this - the ALB reaches the instance's
NodePort directly over the VPC, not through localhost.

Green is now running and reachable on its own NodePort/test listener, but the ALB is
still sending all live traffic to blue — nothing user-facing has changed
yet.

## Cutting over

```bash
cd infra/cli
./blue-green-cutover.sh green
```

This checks green's target-group health first and refuses to cut over if
it isn't `healthy` (override with `--force` if you really mean it). Once
it's healthy, it flips the listener's default action to `tg-green` —
live traffic now goes to green.

## Rolling back

Same command, same script, other color:

```bash
./blue-green-cutover.sh blue
```

Since blue was never touched or scaled down, this is instant.

## Promoting green to the new blue (next cycle)

Once green has been live and stable for a while, it *becomes* the new
"blue" for the next release cycle. There's no automatic relabeling — the
practical options are:

1. **Keep the names as-is** and just remember which target group the
   listener currently points at (`aws elbv2 describe-listeners` shows
   it) — the next new version deploys into whichever namespace is
   currently idle.
2. **Reinstall green's content into the blue namespace** once you're
   confident, so `blue` always means "currently live" and `green` always
   means "idle staging slot" — more consistent to reason about, at the
   cost of an extra deploy step per cycle.

Either way: whichever namespace is *not* live is where the next version
gets staged and tested before its own cutover.

## Known limitations

- Both colors' backend Deployments write to the **same Mongo** — a
  schema change in green's backend code needs to stay backward-compatible
  with blue for however long both are live, since they share the exact
  same data.
- Health-check and traffic ports are hardcoded to 30080/30300 (blue) and
  30081/30301 (green) across the Helm values, the setup script, and the
  security-group rules — keep all three in sync if you ever change them.
- `k8s/kind-config.yaml`'s `extraPortMappings` only covers blue's NodePorts
  (30080/30300) since it predates green - green's NodePorts (30081/30301)
  aren't reachable from the EC2 host directly (`curl localhost:30081`
  fails) until either the kind cluster is recreated with green's ports
  added to `extraPortMappings`, or a manual `socat` forward is set up (see
  the "Deploying a new version to green" section above). This does **not**
  affect the ALB, which reaches the instance's NodePorts over the VPC
  network regardless of what's forwarded to `localhost` on the host.
- If blue is ever fully decommissioned (not just idled), remember its
  Mongo StatefulSet is the one green depends on — don't tear down blue's
  namespace while green is live without migrating Mongo out first.
