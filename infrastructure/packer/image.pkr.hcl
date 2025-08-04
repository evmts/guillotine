packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# Variables
variable "aws_region" {
  description = "AWS region for building AMIs"
  type        = string
  default     = "us-east-1"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for benchmark access"
  type        = string
  default     = "./keys/benchmark_key.pub"
}

# Locals for dynamic values
locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}

# Data sources for latest Ubuntu 22.04 AMIs
data "amazon-ami" "ubuntu-x86" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "x86_64"
  }
  owners      = ["099720109477"] # Canonical
  most_recent = true
  region      = var.aws_region
}

data "amazon-ami" "ubuntu-arm" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "arm64"
  }
  owners      = ["099720109477"] # Canonical
  most_recent = true
  region      = var.aws_region
}

# Build source for x86_64
source "amazon-ebs" "ubuntu-x86" {
  region            = var.aws_region
  instance_type     = "t3.medium"
  source_ami        = data.amazon-ami.ubuntu-x86.id
  ssh_username      = "ubuntu"
  ami_name          = "guillotine-bench-x86-${local.timestamp}"
  ami_description   = "Guillotine EVM benchmark environment for x86_64"
  
  # EBS settings for performance
  ebs_optimized = true
  
  tags = {
    Name        = "guillotine-bench-x86-${local.timestamp}"
    Environment = "benchmark"
    Architecture = "x86_64"
    CreatedBy   = "packer"
  }
}

# Build source for ARM64
source "amazon-ebs" "ubuntu-arm" {
  region            = var.aws_region
  instance_type     = "t4g.medium"
  source_ami        = data.amazon-ami.ubuntu-arm.id
  ssh_username      = "ubuntu"
  ami_name          = "guillotine-bench-arm-${local.timestamp}"
  ami_description   = "Guillotine EVM benchmark environment for ARM64"
  
  # EBS settings for performance
  ebs_optimized = true
  
  tags = {
    Name        = "guillotine-bench-arm-${local.timestamp}"
    Environment = "benchmark"
    Architecture = "arm64"
    CreatedBy   = "packer"
  }
}

# Build configuration for x86_64
build {
  name = "x86-build"
  sources = ["source.amazon-ebs.ubuntu-x86"]

  # Upload public SSH key if provided
  provisioner "file" {
    source      = var.ssh_public_key_path
    destination = "/tmp/benchmark_key.pub"
    only        = ["amazon-ebs.ubuntu-x86"]
  }

  # Main provisioning script
  provisioner "shell" {
    script = "scripts/install-deps.sh"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "ARCH=x86_64"
    ]
  }

  # Post-processor to capture AMI ID
  post-processor "manifest" {
    output = "manifest-x86.json"
    strip_path = true
  }
}

# Build configuration for ARM64
build {
  name = "arm-build"
  sources = ["source.amazon-ebs.ubuntu-arm"]

  # Upload public SSH key if provided
  provisioner "file" {
    source      = var.ssh_public_key_path
    destination = "/tmp/benchmark_key.pub"
    only        = ["amazon-ebs.ubuntu-arm"]
  }

  # Main provisioning script
  provisioner "shell" {
    script = "scripts/install-deps.sh"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "ARCH=aarch64"
    ]
  }

  # Post-processor to capture AMI ID
  post-processor "manifest" {
    output = "manifest-arm.json"
    strip_path = true
  }
}