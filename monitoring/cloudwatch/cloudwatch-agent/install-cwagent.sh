#!/usr/bin/env bash
# Installs and configures the Amazon CloudWatch Agent on the Rent-a-Ride
# app EC2 host (private subnet, runs the kind cluster).
#
# Run this ON the app instance (SSH in via the bastion — see infra/README.md
# / `terraform output ssh_app_command`). Requires the instance to have the
# IAM instance profile from infra/monitoring/terraform/iam.tf attached.
#
# Usage: sudo ./install-cwagent.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo ./install-cwagent.sh)" >&2
  exit 1
fi

# Resolve this script's own directory to an ABSOLUTE path up front — the
# next step cd's to /tmp to download the agent package, which would break
# a relative $(dirname "$0") lookup later (it'd resolve against /tmp
# instead of wherever this script actually lives).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Downloading CloudWatch Agent package"
cd /tmp
curl -fsSL -o amazon-cloudwatch-agent.deb \
  https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb

echo "==> Installing package"
dpkg -i -E ./amazon-cloudwatch-agent.deb

echo "==> Writing agent config"
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cp "${SCRIPT_DIR}/amazon-cloudwatch-agent.json" \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "==> Enabling syslog / docker daemon logging (if not already)"
touch /var/log/docker.log
if ! grep -q '"log-driver"' /etc/docker/daemon.json 2>/dev/null; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker || echo "WARN: restart docker manually — this drops kind's containers, do it during a maintenance window"
fi

echo "==> Starting CloudWatch Agent with the config"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "==> Status"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status

echo "Done. Metrics land in CloudWatch under the 'RentARide/App' namespace."
echo "Logs land under /rent-a-ride/ec2/system-logs, /rent-a-ride/ec2/cwagent, /rent-a-ride/ec2/docker-daemon."
