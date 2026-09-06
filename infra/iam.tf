# ---------------------------------------------------------------------------
# IAM role/instance profile so the app EC2 host (and the kind node
# containers running on it, via IMDS) can push metrics/logs to CloudWatch
# without static credentials.
#
# Attach this by adding `iam_instance_profile =
# aws_iam_instance_profile.app_cwagent.name` to the `aws_instance.app`
# resource in ../../ec2.tf, then `terraform apply`.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_cwagent" {
  name               = "${var.project_name}-app-cwagent-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# Managed policy: lets the CloudWatch Agent (and Fluent Bit's
# cloudwatch_logs output) write metrics + logs.
resource "aws_iam_role_policy_attachment" "cwagent_server" {
  role       = aws_iam_role.app_cwagent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Lets Session Manager / basic SSM describe calls work too, useful for
# troubleshooting from the console without needing the bastion hop.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app_cwagent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app_cwagent" {
  name = "${var.project_name}-app-cwagent-profile"
  role = aws_iam_role.app_cwagent.name
}

output "app_instance_profile_name" {
  description = "Attach this to aws_instance.app.iam_instance_profile"
  value       = aws_iam_instance_profile.app_cwagent.name
}
