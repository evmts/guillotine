# AWS Configuration
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

# Architecture Selection
variable "architecture" {
  description = "Target architecture (x86 or arm64)"
  type        = string
  default     = "x86"
  
  validation {
    condition     = contains(["x86", "arm64"], var.architecture)
    error_message = "Architecture must be either 'x86' or 'arm64'."
  }
}

# Cost Optimization
variable "use_spot_instances" {
  description = "Whether to use spot instances for cost savings"
  type        = bool
  default     = true
}

# AMI Configuration
variable "ami_id_x86" {
  description = "AMI ID for x86_64 instances (built by Packer)"
  type        = string
  default     = ""
}

variable "ami_id_arm64" {
  description = "AMI ID for ARM64 instances (built by Packer)"
  type        = string
  default     = ""
}

# Instance Types
variable "instance_type_x86" {
  description = "EC2 instance type for x86_64 benchmarks"
  type        = string
  default     = "c6i.large"
  
  validation {
    condition = can(regex("^[crmx][0-9]+[a-z]*\\.[a-z]+$", var.instance_type_x86))
    error_message = "Instance type must be a valid EC2 instance type format."
  }
}

variable "instance_type_arm64" {
  description = "EC2 instance type for ARM64 benchmarks"
  type        = string
  default     = "c7g.large"
  
  validation {
    condition = can(regex("^[crmx][0-9]+[a-z]*\\.[a-z]+$", var.instance_type_arm64))
    error_message = "Instance type must be a valid EC2 instance type format."
  }
}

# Benchmark Configuration
variable "benchmark_timeout_minutes" {
  description = "Timeout for benchmark execution in minutes"
  type        = number
  default     = 30
  
  validation {
    condition     = var.benchmark_timeout_minutes > 0 && var.benchmark_timeout_minutes <= 120
    error_message = "Benchmark timeout must be between 1 and 120 minutes."
  }
}

variable "num_benchmark_runs" {
  description = "Number of runs for each benchmark test"
  type        = number
  default     = 20
  
  validation {
    condition     = var.num_benchmark_runs > 0 && var.num_benchmark_runs <= 100
    error_message = "Number of benchmark runs must be between 1 and 100."
  }
}

# Network Configuration
variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to SSH to benchmark instances"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Tag Configuration
variable "project_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}