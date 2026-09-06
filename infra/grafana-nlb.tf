# Internet-facing Network Load Balancer for Grafana, forwarding to the
# app instance's NodePort (30030). This is a genuine AWS load balancer -
# unlike a Kubernetes Service with type: LoadBalancer, which does NOTHING
# on kind (no cloud controller manager to fulfill it; EXTERNAL-IP would
# sit at <pending> forever). The NLB lives in AWS, outside the cluster
# entirely, and just forwards TCP to the instance's already-working
# NodePort - the Grafana Service itself stays type: NodePort.

variable "grafana_allowed_cidr" {
  description = "CIDR allowed to reach Grafana through the NLB - restrict this to your own IP (curl ifconfig.me), NOT 0.0.0.0/0, since this exposes Grafana to the public internet."
  type        = string
}

# NLBs preserve the CLIENT's source IP through to instance targets by
# default (unlike ALBs) - so the private instance's security group must
# allow var.grafana_allowed_cidr directly, NOT the public subnet's CIDR.
# Add this rule to your EXISTING private security group resource (see
# security_groups.tf) rather than creating a conflicting duplicate:
#
#   ingress {
#     description = "Grafana NodePort from NLB (client IP preserved)"
#     from_port   = 30030
#     to_port     = 30030
#     protocol    = "tcp"
#     cidr_blocks = [var.grafana_allowed_cidr]
#   }

# Second public subnet, same AZ as the private subnet - needed only so
# the Grafana NLB can be enabled in that AZ (see below). NLBs with
# instance targets can only route to targets in an AZ the LB is
# explicitly enabled for; without this, the target sits permanently in
# state "unused"/"Target.NotInUse" since the NLB only spans the original
# public subnet's (different) AZ.
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 99)   # small dedicated block, unlikely to collide with existing subnet CIDRs
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet-b"
    Tier = "public"
  }
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_lb" "grafana" {
  name               = "${var.project_name}-grafana-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = [aws_subnet.public.id, aws_subnet.public_b.id]

  tags = {
    Name = "${var.project_name}-grafana-nlb"
  }
}

resource "aws_lb_target_group" "grafana" {
  name        = "${var.project_name}-grafana-tg"
  port        = 30030
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
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
  target_id        = aws_instance.app.id
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
  description = "Browse Grafana directly here - no SSH tunnel needed"
  value       = "http://${aws_lb.grafana.dns_name}"
}
