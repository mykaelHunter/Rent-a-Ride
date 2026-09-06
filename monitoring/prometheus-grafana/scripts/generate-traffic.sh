#!/usr/bin/env bash
# Generates a mix of real traffic against the app so Prometheus/Grafana
# dashboards have something to show, and prints pod status/CPU/memory
# while it runs so you can watch the effect live in another terminal too.
#
# Usage: ./generate-traffic.sh [base_url] [duration_seconds] [requests_per_second]
set -euo pipefail
BASE_URL="${1:-http://localhost:30300}"
DURATION="${2:-300}"
RPS="${3:-5}"

if command -v hey >/dev/null 2>&1; then
  echo "==> Using hey for ${DURATION}s at ~${RPS} req/s against ${BASE_URL}/"
  hey -z "${DURATION}s" -q "$RPS" -m GET "${BASE_URL}/api/does-not-exist" &
  HEY_PID=$!
else
  echo "==> hey not found, falling back to a curl loop (install hey for real load-test output: https://github.com/rakyll/hey)"
  (
    END=$((SECONDS + DURATION))
    while [ $SECONDS -lt $END ]; do
      curl -s -o /dev/null "${BASE_URL}/api/does-not-exist" &
      curl -s -o /dev/null "${BASE_URL}/" &
      sleep "$(awk -v r="$RPS" 'BEGIN{print 1/r}')"
    done
    wait
  ) &
  HEY_PID=$!
fi

echo "==> Watching rent-a-ride pod status/CPU/memory for ${DURATION}s (Ctrl+C to stop early)"
END=$((SECONDS + DURATION))
while [ $SECONDS -lt $END ]; do
  echo "--- $(date '+%H:%M:%S') ---"
  kubectl -n rent-a-ride get pods -o wide --no-headers
  kubectl -n rent-a-ride top pods 2>/dev/null || echo "(metrics-server not ready yet for 'kubectl top')"
  sleep 15
done

wait "$HEY_PID" 2>/dev/null || true
echo "==> Done. Check Grafana dashboard 'Rent-a-Ride — App, Kubernetes & Infra' for the request-rate/latency/error-rate panels."
