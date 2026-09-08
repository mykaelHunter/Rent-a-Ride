# ---------------------------------------------------------------------------
# Infrastructure alarms - driven by the custom "RentARide/App" namespace
# the CloudWatch Agent publishes to on the app host. EC2's default AWS/EC2
# namespace has no memory metric, hence the agent.
# ---------------------------------------------------------------------------

variable "cpu_alarm_threshold" {
  description = "CPU utilization percent (non-idle) above which the high-CPU alarm fires."
  type        = number
  default     = 80
}

variable "mem_alarm_threshold" {
  description = "Memory used percent above which the high-memory alarm fires."
  type        = number
  default     = 85
}

variable "disk_alarm_threshold" {
  description = "Root volume used percent above which the disk-space alarm fires."
  type        = number
  default     = 85
}

variable "alarm_evaluation_periods" {
  description = "Number of consecutive periods a threshold breach must persist before the alarm fires - avoids paging on a single noisy datapoint."
  type        = number
  default     = 3
}

variable "alarm_period_seconds" {
  description = "Length of each evaluation period, in seconds. Must match/exceed the agent's metrics_collection_interval (60s)."
  type        = number
  default     = 60
}

locals {
  common_dimensions = { InstanceId = var.app_instance_id }
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.project_name}-high-cpu"
  alarm_description   = "App host CPU (non-idle) above ${var.cpu_alarm_threshold}% for ${var.alarm_evaluation_periods} consecutive ${var.alarm_period_seconds}s periods."
  namespace           = "RentARide/App"
  metric_name         = "cpu_usage_idle"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = 100 - var.cpu_alarm_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  dimensions          = local.common_dimensions
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  alarm_name          = "${var.project_name}-high-memory"
  alarm_description   = "App host memory used above ${var.mem_alarm_threshold}% for ${var.alarm_evaluation_periods} consecutive ${var.alarm_period_seconds}s periods."
  namespace           = "RentARide/App"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.mem_alarm_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  dimensions          = local.common_dimensions
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "high_disk" {
  alarm_name          = "${var.project_name}-high-disk"
  alarm_description   = "App host root volume used above ${var.disk_alarm_threshold}%."
  namespace           = "RentARide/App"
  metric_name         = "used_percent"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.disk_alarm_threshold
  period              = 300
  evaluation_periods  = 2
  dimensions          = merge(local.common_dimensions, { path = "/", fstype = "ext4" })
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# Application error alarm - metric filter over the Fluent Bit-shipped app
# log group, matching ERROR / Exception / Failed / 5xx status lines, turned
# into a count metric and alarmed on.
# ---------------------------------------------------------------------------

variable "app_log_group_name" {
  description = "Log group Fluent Bit ships rent-a-ride namespace logs to - must match log_group_name in fluent-bit-configmap.yaml."
  type        = string
  default     = "/rent-a-ride/kubernetes/app"
}

variable "error_alarm_threshold" {
  description = "Number of matching error log lines within the evaluation period that trips the alarm."
  type        = number
  default     = 5
}

resource "aws_cloudwatch_log_group" "app" {
  name              = var.app_log_group_name
  retention_in_days = 14
}

resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${var.project_name}-app-error-lines"
  log_group_name = aws_cloudwatch_log_group.app.name
  # JSON pattern syntax, not plain-text terms - this app's logs are
  # structured pino JSON with a NUMERIC level field (30=info, 40=warn,
  # 50=error, 60=fatal), never the literal words "error"/"ERROR". A
  # plain-text pattern matched nothing during testing: bad-input test
  # requests returned 400/404 (not 5xx), and the logged "SyntaxError"
  # string didn't match a case-sensitive "ERROR" term either. This
  # matches pino's actual error/fatal levels plus any real 5xx response.
  pattern = "{ ($.level = 50) || ($.level = 60) || ($.res.statusCode = 500) || ($.res.statusCode = 502) || ($.res.statusCode = 503) || ($.res.statusCode = 504) }"

  metric_transformation {
    name          = "AppErrorCount"
    namespace     = "RentARide/App"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "${var.project_name}-application-errors"
  alarm_description   = "More than ${var.error_alarm_threshold} ERROR/Exception/Failed/5xx log lines in a 5-minute window."
  namespace           = aws_cloudwatch_log_metric_filter.app_errors.metric_transformation[0].namespace
  metric_name         = aws_cloudwatch_log_metric_filter.app_errors.metric_transformation[0].name
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_alarm_threshold
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.high_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.high_memory.alarm_name,
    aws_cloudwatch_metric_alarm.high_disk.alarm_name,
    aws_cloudwatch_metric_alarm.app_errors.alarm_name,
  ]
}
