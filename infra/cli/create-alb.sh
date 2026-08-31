#!/usr/bin/env bash
# Provisions: 2nd public subnet (2nd AZ), ALB security group, target group
# (health-checked on the backend's own NodePort, traffic on the ingress
# NodePort), the ALB itself, and an HTTP listener.
#
# Assumes the Terraform-provisioned VPC/subnet/instance already exist and
# are still tagged the way infra/vpc.tf and infra/ec2.tf leave them
# (Name=rent-a-ride-vpc, Name=rent-a-ride-public-subnet, Role=private-app,
# etc.) - everything below is discovered from those tags, nothing is
# hardcoded to an ID.
#
# NOTE ON DRIFT: step 5 adds ingress rules to the private instance's
# security group, which is Terraform-managed with inline `ingress {}`
# blocks. The next `terraform apply` will see those CLI-added rules as
# drift and remove them unless you also add them to
# infra/security_groups.tf / infra/variables.tf afterward. Nothing below
# touches Terraform state - this is plain AWS CLI, run it as-is.

set -euo pipefail

PROJECT_NAME="rent-a-ride"
AWS_REGION="${AWS_REGION:-us-east-1}"   # match infra/terraform.tfvars' aws_region

export AWS_DEFAULT_REGION="$AWS_REGION"

echo "== Discovering existing Terraform-managed resources =="

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
  --query 'Vpcs[0].VpcId' --output text)

PUBLIC_SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-public-subnet" \
  --query 'Subnets[0].SubnetId' --output text)

PUBLIC_SUBNET_AZ=$(aws ec2 describe-subnets \
  --subnet-ids "$PUBLIC_SUBNET_ID" \
  --query 'Subnets[0].AvailabilityZone' --output text)

PRIVATE_SUBNET_AZ=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-private-subnet" \
  --query 'Subnets[0].AvailabilityZone' --output text)

PUBLIC_RT_ID=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-public-rt" \
  --query 'RouteTables[0].RouteTableId' --output text)

APP_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=private-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

PRIVATE_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-private-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

echo "VPC:              $VPC_ID"
echo "Public subnet:    $PUBLIC_SUBNET_ID ($PUBLIC_SUBNET_AZ)"
echo "Private subnet AZ: $PRIVATE_SUBNET_AZ"
echo "App instance:      $APP_INSTANCE_ID"
echo "Private SG:         $PRIVATE_SG_ID"

echo "== 1. Second public subnet, in the AZ the private subnet already uses =="

# ALB requires 2+ subnets in 2+ different AZs. Reusing the private
# subnet's AZ means no new AZ is introduced - just a second public subnet
# alongside it.
SECOND_PUBLIC_SUBNET_CIDR="10.0.3.0/24"   # adjust if this overlaps anything in your VPC

SECOND_PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SECOND_PUBLIC_SUBNET_CIDR" \
  --availability-zone "$PRIVATE_SUBNET_AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT_NAME}-public-subnet-2},{Key=Tier,Value=public}]" \
  --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute \
  --subnet-id "$SECOND_PUBLIC_SUBNET_ID" \
  --map-public-ip-on-launch

aws ec2 associate-route-table \
  --subnet-id "$SECOND_PUBLIC_SUBNET_ID" \
  --route-table-id "$PUBLIC_RT_ID"

echo "Second public subnet: $SECOND_PUBLIC_SUBNET_ID ($PRIVATE_SUBNET_AZ)"

echo "== 2. ALB security group (80 from the internet) =="

ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-alb-sg" \
  --description "Allow HTTP from the internet to the ALB" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-egress \
  --group-id "$ALB_SG_ID" \
  --protocol -1 --port -1 --cidr 0.0.0.0/0 2>/dev/null || true   # SGs allow all egress by default; ignore if it already exists

echo "ALB SG: $ALB_SG_ID"

echo "== 3. Allow the ALB into the private instance's SG (traffic + health check ports) =="
echo "    (this is the step that will drift on the next 'terraform apply' - see note at top)"

aws ec2 authorize-security-group-ingress \
  --group-id "$PRIVATE_SG_ID" \
  --protocol tcp --port 31080 --source-group "$ALB_SG_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$PRIVATE_SG_ID" \
  --protocol tcp --port 30300 --source-group "$ALB_SG_ID"

echo "== 4. Target group - traffic on 31080 (ingress), health check on 30300 /healthz (backend direct) =="

TG_ARN=$(aws elbv2 create-target-group \
  --name "${PROJECT_NAME}-tg" \
  --protocol HTTP \
  --port 31080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port 30300 \
  --health-check-path /healthz \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

echo "Target group: $TG_ARN"

echo "== 5. Register the app instance (traffic port matches the group's default: 31080) =="

aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=${APP_INSTANCE_ID}"

echo "== 6. ALB itself, across both public subnets =="

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${PROJECT_NAME}-alb" \
  --type application \
  --scheme internet-facing \
  --subnets "$PUBLIC_SUBNET_ID" "$SECOND_PUBLIC_SUBNET_ID" \
  --security-groups "$ALB_SG_ID" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

echo "Waiting for the ALB to become active..."
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"

echo "== 7. HTTP listener -> target group =="

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo
echo "Done. ALB DNS name: $ALB_DNS"
echo "It'll take a minute or two for the target to pass health checks - check with:"
echo "  aws elbv2 describe-target-health --target-group-arn $TG_ARN"
