# Rent-a-Ride — CloudWatch Monitoring & Alerting

Covers infra metrics, log collection, SNS notifications, alarms, and the
test procedure/results for the app host (Ubuntu 24.04 EC2, private subnet)
running the kind cluster.

## Architecture

```
                 ┌──────────────────────────── app EC2 host ─────────────────────────────┐
                 │                                                                        │
                 │  CloudWatch Agent (host process)      kind cluster (Docker containers) │
                 │   - cpu/mem/disk/diskio/net metrics     ┌─────────────────────────┐    │
                 │     -> CW namespace RentARide/App       │ Fluent Bit DaemonSet    │    │
                 │   - /var/log/syslog, auth.log,          │  tails /var/log/containers│  │
                 │     docker.log -> CW Logs                │  -> CW Logs (app + cluster)│ │
                 │                                          └─────────────────────────┘    │
                 │  Both use the instance's IAM role (CloudWatchAgentServerPolicy) via IMDS │
                 └────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
                    CloudWatch Alarms (CPU / memory / disk / app-error metric filter)
                                              │
                                              ▼
                              SNS Topic: rent-a-ride-monitoring-alerts
                                              │
                                              ▼
                                     Email subscription
```

Metrics and host-level logs come from the CloudWatch Agent directly on the
EC2 instance. Pod/container logs come from a Fluent Bit DaemonSet running
*inside* the kind cluster, because kind's nodes are themselves Docker
containers — pod logs live in the kind node's containerd, not in a file the
host-level agent can tail. This is the same split CloudWatch Container
Insights uses for self-managed Kubernetes.

## Setup steps

1. **IAM**: copy `../terraform/*.tf` into `infra/`, attach
   `aws_iam_instance_profile.app_cwagent` to `aws_instance.app`, `terraform apply`.
2. **SNS**: created by the same apply (`sns.tf`) — confirm the email
   subscription before doing anything else; unconfirmed subscriptions drop
   notifications silently.
3. **CloudWatch Agent**: SSH to the app host, run
   `../cloudwatch-agent/install-cwagent.sh`.
4. **Fluent Bit**: `kubectl apply -f ../fluent-bit/{namespace,service-account,fluent-bit-configmap,fluent-bit-daemonset}.yaml`.
5. **Alarms**: created by the same Terraform apply as step 1 (`alarms.tf`) —
   fill in `app_instance_id` and re-apply once the instance exists, then
   check the disk alarm's `dimensions` match the console's actual
   `path`/`fstype`/`device` values (see `../terraform/README.md`).

## Verification checklist

Fill in after running each step against the real environment.

| Check | How | Result |
|---|---|---|
| CPU/mem/disk/net metrics visible | CloudWatch → Metrics → `RentARide/App` namespace | |
| System logs visible | CloudWatch → Log groups → `/rent-a-ride/ec2/system-logs` | |
| Pod/container logs visible | CloudWatch → Log groups → `/rent-a-ride/kubernetes/app` and `.../cluster` | |
| SNS email subscription confirmed | Inbox for `alert_email`, clicked "Confirm subscription" | |
| Alarms in `OK` state at rest | CloudWatch → Alarms | |
| High-CPU alarm fires | `scripts/generate-cpu-load.sh` on app host, watch alarm flip `OK → ALARM` | |
| High-memory alarm fires | `scripts/generate-memory-load.sh` on app host | |
| App-error alarm fires | `scripts/generate-app-errors.sh`, then Logs Insights query below | |
| Email delivered for each | Inbox | |
| Alarm returns to `OK` after load stops | CloudWatch → Alarms, a few minutes after the script exits | |

Logs Insights query to confirm the metric filter's pattern is actually
matching real lines before/while testing:

```
fields @timestamp, @message
| filter @message like /ERROR|Exception|Failed|"level":"error"|"level":"fatal"| 5[0-9][0-9] /
| sort @timestamp desc
| limit 50
```

## Test log (fill in per test run)

### Test 1 — CPU
- Command: `./generate-cpu-load.sh 360`
- Alarm state change observed: `OK → ALARM` at **[timestamp]**, `ALARM → OK` at **[timestamp]**
- Email received: **yes/no**, at **[timestamp]**
- Notes:

### Test 2 — Memory
- Command: `./generate-memory-load.sh 360 85`
- Alarm state change observed:
- Email received:
- Notes:

### Test 3 — Application errors
- Command: `./generate-app-errors.sh http://<node-ip>:30300 30`
- Metric filter match count (Logs Insights):
- Alarm state change observed:
- Email received:
- Notes:

## Thresholds chosen and why

| Alarm | Metric | Threshold | Evaluation | Rationale |
|---|---|---|---|---|
| High CPU | `cpu_usage_idle` (inverted) | >80% non-idle | 3 × 60s | Sustained load, not a single scheduling spike — matches the HPA's own CPU-based scale trigger, so this alarm should mostly fire only if the HPA is maxed out or misconfigured. |
| High memory | `mem_used_percent` | >85% | 3 × 60s | Leaves headroom before OOM-killer activity; 3 consecutive periods filters transient GC/build spikes. |
| Disk | `used_percent` (root) | >85% | 2 × 300s | Slower-moving signal — longer period is fine and cuts noise. |
| App errors | log metric filter count | >5 per 5 min | 1 × 300s | A handful of errors can be normal (bad client input); a burst indicates a real regression. Tune per actual traffic volume once baseline is known. |

Adjust all of these in `terraform.tfvars` (`cpu_alarm_threshold`,
`mem_alarm_threshold`, `disk_alarm_threshold`, `error_alarm_threshold`,
`alarm_evaluation_periods`) rather than editing `alarms.tf` directly.
