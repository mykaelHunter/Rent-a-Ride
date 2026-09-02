#!/usr/bin/env bash
# One-time setup for blue/green cutover on the existing ALB: creates two
# target groups (blue, green), registers the app instance in both at their
# respective NodePorts, and points the existing HTTP listener's default
# action at blue (the current stable, live version).
#
# Run this ONCE. After this, use blue-green-cutover.sh to switch traffic.
#
# Assumes:
#   - The ALB + HTTP:80 listener from infra/cli/create-alb.sh already exist.
#   - helm/rent-a-ride/environments/values-blue.yaml has been installed to
#     namespace "blue" (frontend NodePort 30080, backend NodePort 30300).
#   - values-green.yaml has been (or will be) installed to namespace
#     "green" (frontend NodePort 30081, backend NodePort 30301).

set -euo pipefail

PROJECT_NAME="rent-a-ride"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

BLUE_TRAFFIC_PORT=30080
BLUE_HEALTH_PORT=30300
GREEN_TRAFFIC_PORT=30081
GREEN_HEALTH_PORT=30301

echo "== Discovering existing resources =="

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
  --query 'Vpcs[0].VpcId' --output text)

APP_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=private-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT_NAME}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)

echo "VPC:          $VPC_ID"
echo "App instance: $APP_INSTANCE_ID"
echo "ALB:          $ALB_ARN"
echo "Listener:     $LISTENER_ARN"

create_tg () {
  local color="$1" traffic_port="$2" health_port="$3"
  aws elbv2 create-target-group \
    --name "${PROJECT_NAME}-tg-${color}" \
    --protocol HTTP \
    --port "$traffic_port" \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-port "$health_port" \
    --health-check-path /healthz \
    --health-check-interval-seconds 15 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --matcher HttpCode=200 \
    --query 'TargetGroups[0].TargetGroupArn' --output text
}

echo "== Creating target groups =="

TG_BLUE_ARN=$(create_tg blue "$BLUE_TRAFFIC_PORT" "$BLUE_HEALTH_PORT")
echo "Blue target group:  $TG_BLUE_ARN (traffic $BLUE_TRAFFIC_PORT, health $BLUE_HEALTH_PORT)"

TG_GREEN_ARN=$(create_tg green "$GREEN_TRAFFIC_PORT" "$GREEN_HEALTH_PORT")
echo "Green target group: $TG_GREEN_ARN (traffic $GREEN_TRAFFIC_PORT, health $GREEN_HEALTH_PORT)"

echo "== Opening the private instance's SG to both colors' ports (ALB source only) =="
echo "    (drift note: this SG is Terraform-managed - see infra/README.md)"

PRIVATE_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-private-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-alb-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

for port in "$BLUE_TRAFFIC_PORT" "$BLUE_HEALTH_PORT" "$GREEN_TRAFFIC_PORT" "$GREEN_HEALTH_PORT"; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$PRIVATE_SG_ID" \
    --protocol tcp --port "$port" --source-group "$ALB_SG_ID" 2>/dev/null \
    || echo "  (port $port already authorized - skipping)"
done

echo "== Registering the instance in both target groups =="

aws elbv2 register-targets --target-group-arn "$TG_BLUE_ARN" \
  --targets "Id=${APP_INSTANCE_ID},Port=${BLUE_TRAFFIC_PORT}"

aws elbv2 register-targets --target-group-arn "$TG_GREEN_ARN" \
  --targets "Id=${APP_INSTANCE_ID},Port=${GREEN_TRAFFIC_PORT}"

echo "== Pointing the listener's default action at BLUE (current stable) =="

aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=${TG_BLUE_ARN}"

echo
echo "Done. Target groups:"
echo "  blue:  $TG_BLUE_ARN"
echo "  green: $TG_GREEN_ARN"
echo
echo "Listener now forwards to blue. Once green is deployed and healthy,"
echo "use blue-green-cutover.sh green to switch live traffic to it."
