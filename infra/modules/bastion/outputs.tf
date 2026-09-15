output "bastion_security_group_id" {
  description = "Security group attached to the bastion instance - allow-list this to grant another resource (e.g. an EKS node group) SSH access via the bastion."
  value       = aws_security_group.bastion.id
}

output "app_instance_id" {
  description = "ID of the app host - used by the monitoring module for alarm dimensions and the Grafana NLB target."
  value       = aws_instance.app.id
}

output "private_security_group_id" {
  description = "ID of the app host's security group."
  value       = aws_security_group.private.id
}

output "app_instance_profile_name" {
  description = "Name of the CloudWatch Agent instance profile attached to the app host (null if enable_cw_agent_profile = false)."
  value       = var.enable_cw_agent_profile ? aws_iam_instance_profile.app_cwagent[0].name : null
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host - SSH here first."
  value       = aws_instance.bastion.public_ip
}

output "app_private_ip" {
  description = "Private IP of the application host - reach it by jumping through the bastion."
  value       = aws_instance.app.private_ip
}

output "private_key_path" {
  description = "Local path to the generated PEM private key used for SSH."
  value       = local_file.private_key.filename
}

output "ssh_bastion_command" {
  description = "Command to SSH directly into the bastion host."
  value       = "ssh -i ${local_file.private_key.filename} ubuntu@${aws_instance.bastion.public_ip}"
}

output "ssh_app_command" {
  description = <<-EOT
    Command to SSH into the private app host, jumping through the bastion.
    Uses ProxyCommand (not the bare ProxyJump flag) so the same identity
    file is used for both the bastion hop and the final host.
  EOT
  value       = "ssh -i ${local_file.private_key.filename} -o ProxyCommand=\"ssh -i ${local_file.private_key.filename} -W %h:%p ubuntu@${aws_instance.bastion.public_ip}\" ubuntu@${aws_instance.app.private_ip}"
}
