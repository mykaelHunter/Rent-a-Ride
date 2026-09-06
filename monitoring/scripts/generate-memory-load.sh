#!/usr/bin/env bash
# Allocates and holds memory on the app host to trip the high-memory alarm.
# Run ON the app instance. Usage: ./generate-memory-load.sh [duration_seconds] [target_percent_of_total_ram]
#
# Sizes the allocation as (target % of total RAM) MINUS what's already
# used, so it actually pushes usage UP to the target instead of asking
# stress-ng for a flat "85% of total" that can be *less* than your
# current baseline (e.g. kind's control-plane + workers already using
# 70%+ on a small instance) - which does nothing - or so far above
# available memory that the OOM killer kills stress-ng before it holds
# long enough for a CloudWatch sample to catch it.
set -euo pipefail
DURATION="${1:-360}"
TARGET_PCT="${2:-85}"

if ! command -v stress-ng >/dev/null 2>&1; then
  sudo apt-get update -y && sudo apt-get install -y stress-ng
fi

TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
AVAILABLE_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
USED_PCT=$(( 100 - (AVAILABLE_KB * 100 / TOTAL_KB) ))

echo "==> Current usage: ~${USED_PCT}% (available: $((AVAILABLE_KB / 1024))MB of $((TOTAL_KB / 1024))MB total)"

if (( USED_PCT >= TARGET_PCT )); then
  echo "==> Already at/above ${TARGET_PCT}% - nothing to add. Raise the target or check what's already using memory (kind's control-plane/workers on a small instance can sit high at rest)."
  exit 0
fi

TOP_UP_KB=$(( (TARGET_PCT - USED_PCT) * TOTAL_KB / 100 ))
# Leave a small safety margin so we approach the target without tipping
# into the OOM killer, which would end the test early with no warning.
SAFETY_MARGIN_KB=$(( TOTAL_KB * 5 / 100 ))
TOP_UP_KB=$(( TOP_UP_KB > SAFETY_MARGIN_KB ? TOP_UP_KB - SAFETY_MARGIN_KB : TOP_UP_KB ))
TOP_UP_MB=$(( TOP_UP_KB / 1024 ))

echo "==> Allocating an additional ${TOP_UP_MB}MB to approach ~${TARGET_PCT}% total usage, held for ${DURATION}s (Ctrl+C to stop early)"
stress-ng --vm 1 --vm-bytes "${TOP_UP_MB}M" --vm-keep --timeout "${DURATION}s" --metrics-brief
