#!/usr/bin/env bash
# Switches live ALB traffic to the given color by flipping the listener's
# default action to that color's target group - the actual "cutover" step.
# Run blue-green-setup.sh once before using this.
#
# Usage:
#   ./blue-green-cutover.sh green     # promote green to live
#   ./blue-green-cutover.sh blue      # roll back to blue (same command)
#
# Refuses to cut over if the target color isn't reporting healthy yet -
# override with --force if you really want to (e.g. testing).

set -euo pipefail

PROJECT_NAME="rent-a-ride"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

COLOR="${1:-}"
FORCE="${2:-}"

if [[ "$COLOR" != "blue" && "$COLOR" != "green" ]]; then
  echo "Usage: $0 <blue|green> [--force]" >&2
  exit 1
fi

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT_NAME}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)

TG_ARN=$(aws elbv2 describe-target-groups \
  --names "${PROJECT_NAME}-tg-${COLOR}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

CURRENT_TG_ARN=$(aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)

if [[ "$CURRENT_TG_ARN" == "$TG_ARN" ]]; then
  echo "Listener already points at ${COLOR} (${TG_ARN}). Nothing to do."
  exit 0
fi

echo "== Checking ${COLOR}'s target health before cutover =="

HEALTH_STATE=$(aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)

echo "${COLOR} target health: ${HEALTH_STATE}"

if [[ "$HEALTH_STATE" != "healthy" && "$FORCE" != "--force" ]]; then
  echo "Refusing to cut over: ${COLOR} is not healthy yet (state: ${HEALTH_STATE})." >&2
  echo "Check the app in ${COLOR}'s namespace, or pass --force to override." >&2
  exit 1
fi

echo "== Cutting over: listener -> ${COLOR} (${TG_ARN}) =="

aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo
echo "Done. Live traffic now routes to ${COLOR}."
echo "Verify: curl -I http://${ALB_DNS}/"
echo "Roll back any time with: $0 $([[ "$COLOR" == "blue" ]] && echo green || echo blue)"
