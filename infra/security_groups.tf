# ---------------------------------------------------------------------------
# Bastion SG - only entry point from the internet, SSH only.
# ---------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-bastion-sg"
  description = "Allow SSH inbound from allowed_ssh_cidr, all outbound"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-bastion-sg"
  }
}

# ---------------------------------------------------------------------------
# Private instance SG - no direct internet ingress. SSH only from the
# bastion's SG (SSH "jump" pattern), plus any app ports opened only to
# traffic already inside the VPC.
# ---------------------------------------------------------------------------

resource "aws_security_group" "private" {
  name        = "${var.project_name}-private-sg"
  description = "Allow SSH from bastion only, plus app ports from within the VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from bastion host"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  dynamic "ingress" {
    for_each = var.private_ingress_ports
    content {
      description = "App port ${ingress.value} from within the VPC"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  # Grafana NodePort, reachable via the internet-facing NLB
  # (grafana-nlb.tf). NLBs preserve the client's real source IP through
  # to instance targets by default, so this must allow the actual
  # browsing client's CIDR - not the NLB's own subnet.
  ingress {
    description = "Grafana NodePort from NLB (client IP preserved)"
    from_port   = 30030
    to_port     = 30030
    protocol    = "tcp"
    cidr_blocks = [var.grafana_allowed_cidr]
  }

  egress {
    description = "All outbound (via NAT Gateway)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-private-sg"
  }
}
