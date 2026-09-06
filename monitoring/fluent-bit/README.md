# Kubernetes pod & container logs → CloudWatch

The app host runs the cluster as **kind** (pods live inside the kind node
*containers'* containerd, not on the EC2 host's own Docker). That means the
CloudWatch Agent on the host — which only reads host files — can never see
pod logs directly. The supported path is what CloudWatch Container Insights
itself uses under the hood: run **Fluent Bit as a DaemonSet inside the
cluster**, tailing each node's `/var/log/containers/*.log`, and have it ship
straight to CloudWatch Logs via the `cloudwatch_logs` output plugin.

This covers "Kubernetes pod logs", "application logs" (stdout/stderr from
the backend/frontend/mongo containers — the backend already logs structured
JSON via pino, which Fluent Bit ships as-is) and "container logs" in one
shot. Host-level "system logs" are handled separately by the CloudWatch
Agent (see `../cloudwatch-agent/`).

## Deploy

```bash
kubectl apply -f namespace.yaml
kubectl apply -f service-account.yaml
kubectl apply -f fluent-bit-configmap.yaml
kubectl apply -f fluent-bit-daemonset.yaml
kubectl -n amazon-cloudwatch rollout status daemonset/fluent-bit
```

Each kind worker + control-plane node gets a Fluent Bit pod (3 total for
this cluster's topology) tailing that node's `/var/log/containers`.

## IAM

The node containers run as plain Docker containers on the EC2 host, so
Fluent Bit inside them gets AWS credentials the same way anything else on
the host does: via the **instance profile** attached to the app EC2
instance (see `../terraform/iam.tf`) — kind mounts the host's network
namespace access to the instance metadata service (IMDS) through by
default. No static keys needed. If `aws sts get-caller-identity` from
inside a kind node ever fails, confirm hop-limit for IMDSv2 allows one more
hop (`aws ec2 modify-instance-metadata-options --instance-id <id>
--http-put-response-hop-limit 2`), since traffic to 169.254.169.254 from a
container is a second hop.

## Verify

```bash
kubectl -n amazon-cloudwatch logs -l k8s-app=fluent-bit --tail=50
```

Look for `[cloudwatch_logs]` output lines without `Failed` — then check the
AWS Console under CloudWatch → Log groups → `/rent-a-ride/kubernetes/*`.
