output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = aws_subnet.public.id
}

output "scanner_security_group_id" {
  description = "ID of the scanner security group"
  value       = aws_security_group.scanner.id
}
