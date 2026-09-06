variable "alert_email" {
  description = "Email address to subscribe to the monitoring SNS topic. You must click the confirmation link AWS emails to this address before any alarm will actually deliver — an unconfirmed subscription silently drops notifications."
  type        = string
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-monitoring-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Allow CloudWatch Alarms to publish to the topic.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.alerts.arn
      }
    ]
  })
}

output "sns_topic_arn" {
  description = "ARN of the monitoring SNS topic — reference this from alarms.tf and from the AWS console."
  value       = aws_sns_topic.alerts.arn
}
