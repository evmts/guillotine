terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "architecture" {
  description = "Target architecture (x86 or arm64)"
  type        = string
  default     = "x86"
  validation {
    condition     = contains(["x86", "arm64"], var.architecture)
    error_message = "Architecture must be either 'x86' or 'arm64'."
  }
}

variable "use_spot_instances" {
  description = "Whether to use spot instances for cost savings"
  type        = bool
  default     = true
}

variable "ami_id_x86" {
  description = "AMI ID for x86_64 instances"
  type        = string
  default     = ""
}

variable "ami_id_arm64" {
  description = "AMI ID for ARM64 instances"
  type        = string
  default     = ""
}

variable "instance_type_x86" {
  description = "EC2 instance type for x86_64"
  type        = string
  default     = "c6i.large"
}

variable "instance_type_arm64" {
  description = "EC2 instance type for ARM64"
  type        = string
  default     = "c7g.large"
}

variable "benchmark_timeout_minutes" {
  description = "Timeout for benchmark execution in minutes"
  type        = number
  default     = 30
}

# Locals for computed values
locals {
  target_ami           = var.architecture == "x86" ? var.ami_id_x86 : var.ami_id_arm64
  target_instance_type = var.architecture == "x86" ? var.instance_type_x86 : var.instance_type_arm64
  
  common_tags = {
    Project     = "guillotine-benchmarks"
    Environment = "benchmark"
    Architecture = var.architecture
    CreatedBy   = "terraform"
    Timestamp   = timestamp()
  }
}

# Data sources
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Generate SSH key pair for temporary access
resource "tls_private_key" "benchmark_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "benchmark_key" {
  key_name   = "benchmark-key-${var.architecture}-${random_id.run_id.hex}"
  public_key = tls_private_key.benchmark_key.public_key_openssh
  
  tags = local.common_tags
}

# Random ID for unique resource naming
resource "random_id" "run_id" {
  byte_length = 4
}

# Security group for SSH access
resource "aws_security_group" "benchmark_sg" {
  name_prefix = "benchmark-sg-"
  description = "Security group for benchmark instances"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "benchmark-sg-${var.architecture}"
  })
}

# EC2 instance for benchmarks
resource "aws_spot_instance_request" "benchmark" {
  count = var.use_spot_instances ? 1 : 0
  
  ami                     = local.target_ami
  instance_type          = local.target_instance_type
  key_name               = aws_key_pair.benchmark_key.key_name
  vpc_security_group_ids = [aws_security_group.benchmark_sg.id]
  subnet_id              = data.aws_subnets.default.ids[0]
  
  # Spot instance configuration
  spot_price                      = null # Use current spot price
  spot_type                      = "one-time"
  instance_interruption_behavior = "terminate"
  wait_for_fulfillment           = true
  
  # Performance optimization
  ebs_optimized = true
  
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    
    tags = merge(local.common_tags, {
      Name = "benchmark-root-${var.architecture}"
    })
  }
  
  tags = merge(local.common_tags, {
    Name = "guillotine-benchmark-${var.architecture}-${random_id.run_id.hex}"
  })
  
  timeouts {
    create = "10m"
    delete = "5m"
  }
}

resource "aws_instance" "benchmark" {
  count = var.use_spot_instances ? 0 : 1
  
  ami                     = local.target_ami
  instance_type          = local.target_instance_type
  key_name               = aws_key_pair.benchmark_key.key_name
  vpc_security_group_ids = [aws_security_group.benchmark_sg.id]
  subnet_id              = data.aws_subnets.default.ids[0]
  
  # Performance optimization
  ebs_optimized = true
  
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    
    tags = merge(local.common_tags, {
      Name = "benchmark-root-${var.architecture}"
    })
  }
  
  tags = merge(local.common_tags, {
    Name = "guillotine-benchmark-${var.architecture}-${random_id.run_id.hex}"
  })
}

# Local values for instance selection
locals {
  instance_ip = var.use_spot_instances ? (
    length(aws_spot_instance_request.benchmark) > 0 ? aws_spot_instance_request.benchmark[0].public_ip : null
  ) : (
    length(aws_instance.benchmark) > 0 ? aws_instance.benchmark[0].public_ip : null
  )
  
  instance_id = var.use_spot_instances ? (
    length(aws_spot_instance_request.benchmark) > 0 ? aws_spot_instance_request.benchmark[0].spot_instance_id : null
  ) : (
    length(aws_instance.benchmark) > 0 ? aws_instance.benchmark[0].id : null
  )
}

# Wait for instance to be ready
resource "time_sleep" "wait_for_instance" {
  depends_on = [
    aws_spot_instance_request.benchmark,
    aws_instance.benchmark
  ]
  
  create_duration = "60s"
}

# Execute benchmarks via remote-exec
resource "null_resource" "run_benchmarks" {
  depends_on = [time_sleep.wait_for_instance]
  
  connection {
    type        = "ssh"
    host        = local.instance_ip
    user        = "ubuntu"
    private_key = tls_private_key.benchmark_key.private_key_pem
    timeout     = "5m"
  }
  
  provisioner "remote-exec" {
    inline = [
      "echo 'Starting benchmark execution on ${var.architecture} instance...'",
      "uname -a",
      "free -h",
      "nproc",
      
      # Clone the repository
      "cd /opt/benchmark",
      "git clone https://github.com/evmts/guillotine.git",
      "cd guillotine",
      
      # Build the benchmark tools
      "echo 'Building Guillotine benchmark tools...'",
      "zig build build-evm-runner -Doptimize=ReleaseFast",
      "zig build build-orchestrator -Doptimize=ReleaseFast",
      
      # Run the performance benchmarks
      "echo 'Running performance benchmarks...'",
      "timeout ${var.benchmark_timeout_minutes}m ./scripts/perf-slow.sh || echo 'Benchmark completed or timed out'",
      
      # Create results directory
      "mkdir -p /tmp/benchmark-results",
      "cp bench/official/results.* /tmp/benchmark-results/ 2>/dev/null || echo 'No results files to copy'",
      
      "echo 'Benchmark execution completed.'"
    ]
  }
  
  # Download results
  provisioner "file" {
    source      = "/tmp/benchmark-results/"
    destination = "./results-${var.architecture}/"
    direction   = "download"
  }
  
  # Cleanup on destroy
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "echo 'Cleaning up benchmark workspace...'",
      "rm -rf /opt/benchmark/guillotine",
      "rm -rf /tmp/benchmark-results"
    ]
  }
}

# Outputs
output "instance_id" {
  description = "ID of the benchmark instance"
  value       = local.instance_id
}

output "instance_ip" {
  description = "Public IP of the benchmark instance"
  value       = local.instance_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i <(echo '${tls_private_key.benchmark_key.private_key_pem}') ubuntu@${local.instance_ip}"
  sensitive   = true
}

output "architecture" {
  description = "Target architecture"
  value       = var.architecture
}

output "results_directory" {
  description = "Local directory containing benchmark results"
  value       = "./results-${var.architecture}/"
}