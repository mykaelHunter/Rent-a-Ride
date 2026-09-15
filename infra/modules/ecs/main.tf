# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-cluster"
  }
}

# ---------------------------------------------------------------------------
# Service Connect namespace - lets the frontend container reach the
# backend at the literal hostname "backend" (matching client/nginx.conf's
# `proxy_pass http://backend:3000`, unchanged from its Docker Compose
# form) without any app-code change. A per-task sidecar proxy intercepts
# calls to that configured alias and forwards them over the real network
# to a backend task - unlike plain Cloud Map/Route 53 DNS, this doesn't
# depend on the VPC's DNS search domain matching, so the bare "backend"
# (no dots) just works.
# ---------------------------------------------------------------------------

resource "aws_service_discovery_http_namespace" "this" {
  name = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Security groups
#   alb_sg      - internet -> ALB, port 80 (and 443 if a cert is supplied)
#   ecs_tasks_sg - ALB -> ECS tasks, container ports only
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-alb-sg"
  description = "Allow HTTP(S) inbound from the internet, all outbound"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.enable_https ? [1] : []
    content {
      description = "HTTPS"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-alb-sg"
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-${var.environment}-ecs-tasks-sg"
  description = "Allow container ports from the ALB only, all outbound"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Backend container port from ALB"
    from_port       = var.backend_container_port
    to_port         = var.backend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Frontend container port from ALB"
    from_port       = var.frontend_container_port
    to_port         = var.frontend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Service Connect's per-task proxy makes a real network hop between
  # tasks (frontend's proxy intercepts the "backend" hostname locally,
  # then forwards over the network to a backend task's ENI on its real
  # container port) - self-referencing so any task in this SG can reach
  # any other task in this SG, on any port, rather than opening one
  # narrow rule per service.
  ingress {
    description = "Inter-task traffic within this SG (ECS Service Connect)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound (image pulls via NAT, Mongo, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ecs-tasks-sg"
  }
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = {
    Name = "${var.project_name}-${var.environment}-alb"
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project_name}-${var.environment}-backend-tg"
  port        = var.backend_container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.backend_health_check_path
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-backend-tg"
  }
}

resource "aws_lb_target_group" "frontend" {
  count       = var.enable_frontend ? 1 : 0
  name        = "${var.project_name}-${var.environment}-frontend-tg"
  port        = var.frontend_container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.frontend_health_check_path
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend-tg"
  }
}

# Default listener target: frontend when it exists (var.enable_frontend),
# otherwise the backend directly - so with the frontend disabled (served
# from S3+CloudFront instead) the ALB becomes a plain API endpoint, e.g.
# behind an api.<domain> alias, with no path-prefix required to reach it.
locals {
  default_target_group_arn = var.enable_frontend ? aws_lb_target_group.frontend[0].arn : aws_lb_target_group.backend.arn
}

# Default listener - upgraded to redirect->HTTPS if a certificate ARN is
# supplied.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.enable_https ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = local.default_target_group_arn
    }
  }

  dynamic "default_action" {
    for_each = var.enable_https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.enable_https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = local.default_target_group_arn
  }
}

# Path-based routing: /api/* -> backend, everything else -> frontend
resource "aws_lb_listener_rule" "backend_http" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = [var.backend_path_pattern]
    }
  }
}

resource "aws_lb_listener_rule" "backend_https" {
  count        = var.enable_https ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = [var.backend_path_pattern]
    }
  }
}

# ---------------------------------------------------------------------------
# IAM - execution role (pull image, write logs) + task role (app permissions,
# empty by default; attach policies to task_role if the app needs AWS access)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project_name}-${var.environment}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.project_name}-${var.environment}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# The AmazonECSTaskExecutionRolePolicy attached above covers ECR pulls and
# awslogs writes, but NOT reading secrets - without this, any task with a
# non-empty backend_secrets fails at startup with a
# ResourceInitializationError (a different failure mode than a container
# crash: the task never reaches RUNNING at all). Scoped to just the ARNs
# passed in, not "*".
data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.backend_secrets) > 0 ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = values(var.backend_secrets)
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = length(var.backend_secrets) > 0 ? 1 : 0
  name   = "${var.project_name}-${var.environment}-ecs-execution-secrets"
  role   = aws_iam_role.execution.name
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# ---------------------------------------------------------------------------
# CloudWatch log groups
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.project_name}-${var.environment}/backend"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "frontend" {
  count             = var.enable_frontend ? 1 : 0
  name              = "/ecs/${var.project_name}-${var.environment}/frontend"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Task definitions
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project_name}-${var.environment}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.backend_cpu
  memory                   = var.backend_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = "${var.backend_image_url}:${var.backend_image_tag}"
      essential = true
      portMappings = [
        {
          name          = "backend"
          containerPort = var.backend_container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        for k, v in var.backend_environment : { name = k, value = v }
      ]
      secrets = [
        for k, v in var.backend_secrets : { name = k, valueFrom = v }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backend"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-${var.environment}-backend"
  }
}

resource "aws_ecs_task_definition" "frontend" {
  count                    = var.enable_frontend ? 1 : 0
  family                   = "${var.project_name}-${var.environment}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.frontend_cpu
  memory                   = var.frontend_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = "${var.frontend_image_url}:${var.frontend_image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.frontend_container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        for k, v in var.frontend_environment : { name = k, value = v }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.frontend[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "frontend"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-${var.environment}-frontend"
  }
}

# ---------------------------------------------------------------------------
# Services - tasks land in the private subnets (no public IP); the ALB in
# the public subnets is the only ingress path. Egress (image pulls, calls
# to Mongo, etc.) goes out through the NAT Gateway from the networking module.
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "backend" {
  name            = "${var.project_name}-${var.environment}-backend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = var.backend_container_port
  }

  # Publishes itself reachable at the literal hostname "backend" (the
  # client_alias.dns_name) to anything else in this namespace - the
  # frontend's Service Connect proxy is what makes that alias resolvable
  # inside the frontend task without any code/config change on its side.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

    service {
      port_name      = "backend"
      discovery_name = "backend"

      client_alias {
        port     = var.backend_container_port
        dns_name = "backend"
      }
    }
  }

  depends_on = [aws_lb_listener_rule.backend_http]
}

resource "aws_ecs_service" "frontend" {
  count           = var.enable_frontend ? 1 : 0
  name            = "${var.project_name}-${var.environment}-frontend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.frontend[0].arn
  desired_count   = var.frontend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend[0].arn
    container_name   = "frontend"
    container_port   = var.frontend_container_port
  }

  # Doesn't publish anything of its own (nothing calls "frontend" by
  # name) - just needs to be in the namespace so its per-task proxy picks
  # up the "backend" alias published above and can intercept
  # nginx's proxy_pass http://backend:3000 locally.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn
  }

  depends_on = [aws_lb_listener.http]
}
