########################################
# Networking Outputs
########################################
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of private subnets (EKS nodes will go here)"
  value       = module.networking.private_subnet_ids
}

output "data_subnet_ids" {
  description = "IDs of data subnets (RDS will go here)"
  value       = module.networking.data_subnet_ids
}

output "nat_gateway_ip" {
  description = "Public IP of the NAT gateway"
  value       = module.networking.nat_gateway_ip
}

########################################
# Remote State
########################################
output "tfstate_bucket" {
  description = "S3 bucket for Terraform state"
  value       = aws_s3_bucket.tfstate.id
}
