#!/usr/bin/env bash
# Fires requests designed to produce backend errors/5xx so the log-based
# app-error alarm has something to trip on. Run from anywhere that can
# reach the ingress/NodePort (e.g. the app host itself, or your machine
# if the port is reachable).
#
# Usage: ./generate-app-errors.sh [base_url] [count]
set -euo pipefail
BASE_URL="${1:-http://localhost:30300}"
COUNT="${2:-30}"

echo "==> Firing ${COUNT} error-triggering requests at ${BASE_URL}"
for i in $(seq 1 "$COUNT"); do
  # Malformed JSON body -> express.json() throws -> pino logs an error line.
  curl -s -o /dev/null -w "login (bad json)   -> %{http_code}\n" \
    -X POST "${BASE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{not-valid-json' || true

  # Bad ObjectId format on a route that does findById -> mongoose CastError
  # -> 500/4xx with an error-level log line.
  curl -s -o /dev/null -w "user by bad id     -> %{http_code}\n" \
    "${BASE_URL}/api/user/not-a-valid-object-id" || true

  # Nonexistent route -> 404, harmless but useful for volume/context.
  curl -s -o /dev/null -w "unknown route      -> %{http_code}\n" \
    "${BASE_URL}/api/does-not-exist" || true

  sleep 1
done

echo "==> Done. Check: kubectl -n rent-a-ride logs deploy/backend --tail=50"
echo "    and CloudWatch Logs Insights on /rent-a-ride/kubernetes/app"
