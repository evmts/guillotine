# Instance Information
output "instance_id" {
  description = "ID of the benchmark instance"
  value       = local.instance_id
}

output "instance_ip" {
  description = "Public IP address of the benchmark instance"
  value       = local.instance_ip
}

output "instance_type" {
  description = "EC2 instance type used for benchmarks"
  value       = local.target_instance_type
}

# SSH Access
output "ssh_command" {
  description = "SSH command to connect to the benchmark instance"
  value       = local.instance_ip != null ? "ssh -i <(echo '${tls_private_key.benchmark_key.private_key_pem}') ubuntu@${local.instance_ip}" : "Instance not available"
  sensitive   = true
}

output "ssh_private_key" {
  description = "Private SSH key for accessing the instance"
  value       = tls_private_key.benchmark_key.private_key_pem
  sensitive   = true
}

# Configuration
output "architecture" {
  description = "Target architecture for benchmarks"
  value       = var.architecture
}

output "use_spot_instances" {
  description = "Whether spot instances are being used"
  value       = var.use_spot_instances
}

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}

# Results
output "results_directory" {
  description = "Local directory containing downloaded benchmark results"
  value       = "./results-${var.architecture}/"
}

# Security Group
output "security_group_id" {
  description = "ID of the security group used by the benchmark instance"
  value       = aws_security_group.benchmark_sg.id
}

# Key Pair
output "key_pair_name" {
  description = "Name of the EC2 key pair used for SSH access"
  value       = aws_key_pair.benchmark_key.key_name
}

# Timing
output "deployment_timestamp" {
  description = "Timestamp when the infrastructure was deployed"
  value       = timestamp()
}