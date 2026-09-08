# Internet-facing Network Load Balancer for Grafana, forwarding to the app
# instance's NodePort (30030). This is a genuine AWS load balancer -
# unlike a Kubernetes Service with type: LoadBalancer, which does NOTHING
# on kind (no cloud controller manager to fulfill it; EXTERNAL-IP would
# sit at <pending> forever). The NLB lives in AWS, outside the cluster
# entirely, and just forwards TCP to the instance's already-working
# NodePort - the Grafana Service itself stays type: NodePort.
#
# Unlike the original standalone version of this file, no extra subnet is
# created here: the networking module already provisions public subnets
# in both AZs, and the app host's private subnet shares an AZ with
# public_subnet_ids[0] - so var.public_subnet_ids (passed straight from
# the networking module) already covers the AZ the target needs.

variable "grafana_allowed_cidr" {
  description = "CIDR allowed to reach Grafana through the NLB - restrict this to your own IP (curl ifconfig.me), NOT 0.0.0.0/0, since this exposes Grafana to the public internet. Must match the same value passed to the bastion module's grafana_allowed_cidr, which opens the matching security-group rule."
  type        = string
}

# NLBs preserve the CLIENT's source IP through to instance targets by
# default (unlike ALBs) - so the app host's security group must allow
# var.grafana_allowed_cidr directly. That rule is added in the bastion
# module (see its grafana_allowed_cidr/grafana_nodeport variables) rather
# than here, to keep the security group a single authoritative resource -
# mixing inline SG ingress blocks with a standalone aws_security_group_rule
# on the same group causes the AWS provider to fight over which one owns
# the rule set.

resource "aws_lb" "grafana" {
  name               = "${var.project_name}-grafana-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids

  tags = {
    Name = "${var.project_name}-grafana-nlb"
  }
}

resource "aws_lb_target_group" "grafana" {
  name        = "${var.project_name}-grafana-tg"
  port        = 30030
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "30030"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }
}

resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = var.app_instance_id
  port             = 30030
}

resource "aws_lb_listener" "grafana" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

output "grafana_url" {
  description = "Browse Grafana directly here - no SSH tunnel needed."
  value       = "http://${aws_lb.grafana.dns_name}"
}
