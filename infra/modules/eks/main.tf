# ---------------------------------------------------------------------------
# Cluster IAM role - assumed by the EKS control plane itself, not the nodes.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.project_name}-${var.environment}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# EKS cluster
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = "${var.project_name}-${var.environment}"
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.control_plane_subnet_ids
    endpoint_public_access   = var.endpoint_public_access
    endpoint_private_access  = true
    public_access_cidrs      = var.endpoint_public_access_cidrs
  }

  # API-only auth mode manages cluster access via aws_eks_access_entry
  # resources (below) instead of the legacy aws-auth ConfigMap - skips
  # needing a kubernetes/kubectl provider just to grant IAM users access.
  access_config {
    authentication_mode = "API"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# Grant the applying IAM principal cluster-admin via an access entry,
# since API auth mode starts with only the cluster creator's original
# identity mapped - explicit here so it survives being re-applied by a
# different role/user later.
data "aws_caller_identity" "current" {}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ---------------------------------------------------------------------------
# Node IAM role - assumed by the worker EC2 instances via the EC2 instance
# profile EKS attaches automatically to a managed node group.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.project_name}-${var.environment}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ---------------------------------------------------------------------------
# Optional SSH access to nodes, reusing an existing key pair + security
# group (e.g. the bastion's) rather than opening SSH to the world.
# ---------------------------------------------------------------------------

resource "aws_security_group" "node_ssh" {
  count = var.ssh_key_pair_name != "" && var.bastion_security_group_id != "" ? 1 : 0

  name        = "${var.project_name}-${var.environment}-eks-node-ssh"
  description = "Allow SSH into EKS nodes from the bastion security group."
  vpc_id      = var.vpc_id

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Managed node group - capacity_type = SPOT, t3a.medium, fixed at 3 nodes
# (desired = min = max, so the ASG never scales the count on its own).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# IAM OIDC provider - lets Kubernetes service accounts assume IAM roles
# (IRSA), which the EBS CSI driver's controller pod needs to call the EC2
# API and create/attach EBS volumes on the cluster's behalf.
# ---------------------------------------------------------------------------

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ---------------------------------------------------------------------------
# EBS CSI driver addon - without this, PVCs never provision on EKS: the
# in-tree "kubernetes.io/aws-ebs" volume plugin (the "gp2" StorageClass
# EKS ships by default) has no controller listening behind it on recent
# Kubernetes versions, so any StatefulSet with a PVC (e.g. Mongo) sits
# Pending forever.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  name = "${var.project_name}-${var.environment}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Needs at least one node Ready to schedule its controller/node pods onto.
  depends_on = [aws_eks_node_group.this]
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller - the EKS-native replacement for
# cli/create-alb.sh. Instead of AWS CLI calls hand-wiring an ALB to one
# EC2 instance's NodePort, this controller watches Kubernetes Ingress
# objects and manages the ALB (subnets, target group, listener, target
# registration) to match - driven by k8s manifests instead of a shell
# script, and target-type "ip" so it registers pod IPs directly rather
# than a NodePort on a specific instance. It also owns the primitive
# blue/green needs later: weighted target-group actions
# (alb.ingress.kubernetes.io/actions.<name>) let one Ingress split
# traffic by percentage across two Services without recreating the ALB.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lb_controller" {
  name = "${var.project_name}-${var.environment}-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "lb_controller" {
  name   = "${var.project_name}-${var.environment}-AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/aws-lb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_addon" "lb_controller" {
  count = var.lb_controller_install_method == "addon" ? 1 : 0

  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-load-balancer-controller"
  service_account_role_arn = aws_iam_role.lb_controller.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# NOTE: when lb_controller_install_method = "helm", the actual
# helm_release lives in the ROOT main.tf, not here - the "helm" provider
# can't be configured inside a module that's invoked with `count` (this
# one is: count = var.enable_eks ? 1 : 0). This module only provides the
# IRSA role (above) the root's helm_release attaches to the controller's
# service account.

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-${var.environment}-${var.node_group_name}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.node_subnet_ids

  capacity_type  = var.capacity_type
  instance_types = var.instance_types
  disk_size      = var.node_disk_size

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  # Rolling updates: allow at most 1 node unavailable at a time so the
  # cluster doesn't lose all 3 nodes at once during a version/AMI bump.
  update_config {
    max_unavailable = 1
  }

  dynamic "remote_access" {
    for_each = var.ssh_key_pair_name != "" ? [1] : []
    content {
      ec2_ssh_key               = var.ssh_key_pair_name
      source_security_group_ids = var.bastion_security_group_id != "" ? [aws_security_group.node_ssh[0].id] : null
    }
  }

  labels = {
    "capacity-type" = lower(var.capacity_type)
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]

  lifecycle {
    # SPOT interruptions and manual scaling (kubectl scale, cluster-autoscaler)
    # change desired_size out-of-band - don't fight that on the next plan.
    ignore_changes = [scaling_config[0].desired_size]
  }
}
