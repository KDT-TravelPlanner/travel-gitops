output "app_route_table_ids" {
  description = "Private application route table IDs. The ephemeral runtime adds and removes NAT routes here."
  value       = aws_route_table.app[*].id
}

output "app_subnet_ids" {
  description = "Private backend application subnet IDs."
  value       = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  description = "Isolated data subnet IDs."
  value       = aws_subnet.data[*].id
}

output "public_subnet_ids" {
  description = "Public ALB and NAT Gateway subnet IDs."
  value       = aws_subnet.public[*].id
}

output "vpc_id" {
  description = "Environment VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Environment VPC CIDR used to derive the Route 53 Resolver address."
  value       = aws_vpc.this.cidr_block
}
