#!/usr/bin/env bash
# Burns CPU on the app host for DURATION seconds to trip the high-cpu alarm.
# Run ON the app instance. Usage: ./generate-cpu-load.sh [duration_seconds]
set -euo pipefail
DURATION="${1:-360}"

if ! command -v stress-ng >/dev/null 2>&1; then
  sudo apt-get update -y && sudo apt-get install -y stress-ng
fi

echo "==> Loading all CPUs for ${DURATION}s (Ctrl+C to stop early)"
stress-ng --cpu "$(nproc)" --cpu-load 95 --timeout "${DURATION}s" --metrics-brief
