output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = aws_subnet.private.id
}

output "nat_gateway_public_ip" {
  description = "Elastic IP address of the NAT Gateway."
  value       = aws_eip.nat.public_ip
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
    file is used for both the bastion hop and the final host - a plain
    `-o ProxyJump=user@host` only applies -i to the final destination and
    leaves the jump hop to fall back to your default key, which fails.
  EOT
  value       = "ssh -i ${local_file.private_key.filename} -o ProxyCommand=\"ssh -i ${local_file.private_key.filename} -W %h:%p ubuntu@${aws_instance.bastion.public_ip}\" ubuntu@${aws_instance.app.private_ip}"
}
