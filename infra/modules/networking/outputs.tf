output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of all public subnets."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of all private subnets."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_public_ip" {
  description = "Elastic IP address of the NAT Gateway."
  value       = aws_eip.nat.public_ip
}
