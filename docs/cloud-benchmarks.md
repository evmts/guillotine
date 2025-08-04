# Cloud Benchmark Infrastructure Guide

This guide provides comprehensive instructions for setting up and using the cloud-based benchmark infrastructure for Guillotine EVM performance testing.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Configuration](#configuration)
5. [Usage Methods](#usage-methods)
6. [Cost Management](#cost-management)
7. [Performance Analysis](#performance-analysis)
8. [Troubleshooting](#troubleshooting)
9. [Best Practices](#best-practices)

## Overview

The cloud benchmark infrastructure automates the process of running EVM performance tests on AWS EC2 instances across multiple CPU architectures. This setup ensures:

- **Reproducible Results**: Identical software environments via custom AMIs
- **Multi-Architecture Testing**: x86_64 (Intel/AMD) and ARM64 (AWS Graviton) support
- **Cost Optimization**: Spot instance support for up to 90% cost savings
- **Automation**: GitHub Actions integration and local CLI tools
- **Performance Consistency**: Dedicated compute-optimized instances

### Architecture Comparison

| Architecture | AWS Instance Family | Performance Characteristics |
|--------------|--------------------|-----------------------------|
| x86_64 | C6i (Intel), C5 (Intel) | High single-thread performance, mature ecosystem |
| ARM64 | C7g (Graviton3), C6g (Graviton2) | Excellent price/performance, energy efficient |

## Prerequisites

### Required Tools

Install the following tools on your local machine:

```bash
# macOS (using Homebrew)
brew install terraform packer awscli jq

# Linux (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y unzip curl jq

# Install Terraform
wget https://releases.hashicorp.com/terraform/1.6.0/terraform_1.6.0_linux_amd64.zip
unzip terraform_1.6.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# Install Packer
wget https://releases.hashicorp.com/packer/1.10.0/packer_1.10.0_linux_amd64.zip
unzip packer_1.10.0_linux_amd64.zip
sudo mv packer /usr/local/bin/

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

### AWS Account Setup

1. **Create AWS Account**: If you don't have one, create an AWS account at [aws.amazon.com](https://aws.amazon.com)

2. **Create IAM User**: Create an IAM user with programmatic access and the following permissions:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "ec2:*",
           "vpc:Describe*",
           "iam:PassRole",
           "iam:CreateRole",
           "iam:DeleteRole",
           "iam:GetRole",
           "iam:AttachRolePolicy",
           "iam:DetachRolePolicy"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

3. **Configure AWS CLI**:
   ```bash
   aws configure
   # AWS Access Key ID: [Your Access Key]
   # AWS Secret Access Key: [Your Secret Key]
   # Default region name: us-east-1
   # Default output format: json
   ```

4. **Verify Configuration**:
   ```bash
   aws sts get-caller-identity
   ```

### GitHub Actions Setup (Optional)

For automated benchmarks via GitHub Actions:

1. **Add Repository Secrets**:
   - `AWS_ACCESS_KEY_ID`: Your AWS access key
   - `AWS_SECRET_ACCESS_KEY`: Your AWS secret key
   - `FALLBACK_AMI_X86`: Fallback AMI ID for x86_64 (optional)
   - `FALLBACK_AMI_ARM64`: Fallback AMI ID for ARM64 (optional)

2. **Enable Actions**: Ensure GitHub Actions are enabled in your repository settings

## Quick Start

### Method 1: One-Command Execution

The fastest way to run cloud benchmarks:

```bash
# Run x86_64 benchmarks on spot instances
./scripts/cloud-bench-local.sh x86 spot

# Run ARM64 benchmarks
./scripts/cloud-bench-local.sh arm64 spot

# Run both architectures
./scripts/cloud-bench-local.sh both spot
```

This script will:
1. Build custom AMIs with Packer (5-10 minutes)
2. Deploy EC2 instances with Terraform
3. Run the full benchmark suite
4. Download results locally
5. Clean up all AWS resources

### Method 2: GitHub Actions

1. Navigate to your repository's **Actions** tab
2. Select **"Cloud EVM Benchmarks"** workflow
3. Click **"Run workflow"**
4. Choose your options:
   - Architecture: `x86`, `arm64`, or `both`
   - Use spot instances: `true` (recommended)
   - Number of runs: `20` (default)
   - Rebuild AMIs: `false` (unless you need fresh images)
5. Click **"Run workflow"**

Results will be available as workflow artifacts.

## Configuration

### Environment Variables

Set these environment variables to customize behavior:

```bash
export AWS_REGION="us-east-1"        # AWS region
export NUM_RUNS="20"                 # Benchmark iterations
export USE_SPOT="true"               # Use spot instances
```

### Terraform Variables

Create `infrastructure/terraform/terraform.tfvars`:

```hcl
# Basic configuration
aws_region     = "us-east-1"
architecture   = "x86"              # or "arm64"
use_spot_instances = true

# Performance instance types
instance_type_x86   = "c6i.large"   # 2 vCPU, 4 GiB
instance_type_arm64 = "c7g.large"   # 2 vCPU, 4 GiB

# Benchmark settings
benchmark_timeout_minutes = 30
num_benchmark_runs        = 20

# Security (restrict SSH access if needed)
allowed_cidr_blocks = ["0.0.0.0/0"]
```

### Instance Type Selection

Choose instance types based on your performance requirements:

#### x86_64 Options
- **c6i.large** (2 vCPU, 4 GiB) - Balanced performance, Intel Ice Lake
- **c6i.xlarge** (4 vCPU, 8 GiB) - Higher performance
- **c5.large** (2 vCPU, 4 GiB) - Cost-effective, Intel Skylake

#### ARM64 Options
- **c7g.large** (2 vCPU, 4 GiB) - Latest Graviton3, best performance
- **c7g.xlarge** (4 vCPU, 8 GiB) - Higher performance
- **c6g.large** (2 vCPU, 4 GiB) - Graviton2, slightly lower cost

## Usage Methods

### 1. Local CLI Script (Recommended)

The `cloud-bench-local.sh` script provides the simplest interface:

```bash
# Basic usage
./scripts/cloud-bench-local.sh [architecture] [instance_type]

# Examples
./scripts/cloud-bench-local.sh x86 spot           # x86 on spot instances
./scripts/cloud-bench-local.sh arm64 ondemand     # ARM64 on on-demand
./scripts/cloud-bench-local.sh both spot          # Both architectures

# With custom settings
NUM_RUNS=50 AWS_REGION=us-west-2 ./scripts/cloud-bench-local.sh x86 spot
```

### 2. Makefile Interface

For development and testing:

```bash
cd infrastructure/

# Build AMIs
make build-amis              # Both architectures
make build-ami-x86          # x86_64 only
make build-ami-arm64        # ARM64 only

# Deploy and run benchmarks
make deploy-x86             # x86_64 benchmarks
make deploy-arm64           # ARM64 benchmarks
make deploy-both            # Both architectures

# Cleanup
make clean                  # Destroy all infrastructure
make clean-x86              # x86_64 infrastructure only

# Utilities
make validate               # Validate configurations
make test                   # Run all tests
make info                   # Show current configuration
```

### 3. Manual Terraform/Packer

For maximum control:

```bash
# Step 1: Build AMIs
cd infrastructure/packer
mkdir -p keys
ssh-keygen -t rsa -b 2048 -f keys/benchmark_key -N ""
packer init image.pkr.hcl
packer build image.pkr.hcl

# Step 2: Deploy infrastructure
cd ../terraform
terraform init
terraform apply -var "ami_id_x86=ami-xxxxxxxxx"

# Step 3: Cleanup
terraform destroy
```

## Cost Management

### Spot vs On-Demand Pricing

Estimated costs for 30-minute benchmark runs in us-east-1:

| Instance Type | On-Demand | Spot (typical) | Savings |
|---------------|-----------|----------------|---------|
| c6i.large     | $0.43     | $0.13          | 70%     |
| c7g.large     | $0.36     | $0.11          | 69%     |
| c6i.xlarge    | $0.86     | $0.26          | 70%     |
| c7g.xlarge    | $0.72     | $0.22          | 69%     |

### Cost Optimization Strategies

1. **Use Spot Instances**: Enable `use_spot_instances = true` (default)
2. **Right-Size Instances**: Start with `.large` instances and scale up if needed
3. **Optimize Regions**: Some regions have lower spot prices
4. **Batch Runs**: Run multiple architectures in sequence rather than parallel
5. **Cleanup Automation**: Always destroy resources after benchmarks

### Monitoring Costs

Set up AWS billing alerts:

```bash
# Create a billing alarm (requires AWS CLI)
aws cloudwatch put-metric-alarm \
  --alarm-name "BenchmarkCosts" \
  --alarm-description "Alert when benchmark costs exceed $10" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold
```

## Performance Analysis

### Understanding Results

Benchmark results include statistical measures:

- **Mean**: Average execution time across all runs
- **Median**: Middle value (less affected by outliers)
- **Min/Max**: Best and worst case performance
- **Std Dev**: Performance consistency (lower is better)

### Comparing Architectures

When comparing x86_64 vs ARM64:

1. **Absolute Performance**: Raw execution times
2. **Performance Per Dollar**: Factor in spot pricing differences
3. **Consistency**: Compare standard deviations
4. **Workload Characteristics**: Some operations favor different architectures

### Example Analysis

```markdown
## ERC20 Transfer Benchmark Results

| Architecture | Mean (ms) | Median (ms) | Std Dev | Price/Performance |
|--------------|-----------|-------------|---------|-------------------|
| x86_64       | 2.45      | 2.41        | 0.12    | $0.053/ms         |
| ARM64        | 2.78      | 2.76        | 0.08    | $0.040/ms         |

**Analysis**: 
- x86_64 is 13% faster in absolute terms
- ARM64 provides 25% better price/performance
- ARM64 shows more consistent performance (lower std dev)
```

### Benchmark Interpretation

- **< 5% difference**: Results are essentially equivalent
- **5-15% difference**: Meaningful but not dramatic difference
- **> 15% difference**: Significant performance gap

## Troubleshooting

### Common Issues

#### 1. Packer Build Failures

**Symptom**: Packer fails to build AMI
```bash
Error: Failed to find the latest AMI
```

**Solutions**:
```bash
# Check AWS credentials
aws sts get-caller-identity

# Verify region supports the base AMI
aws ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"

# Try a different region
packer build -var "aws_region=us-west-2" image.pkr.hcl
```

#### 2. Terraform Apply Failures

**Symptom**: Terraform fails to create instances
```bash
Error: InvalidAMIID.NotFound
```

**Solutions**:
```bash
# Check AMI exists in target region
aws ec2 describe-images --image-ids ami-xxxxxxxxx

# Verify AMI ID is correct
cat infrastructure/packer/manifest-x86.json | jq -r '.builds[0].artifact_id'

# Check instance type availability
aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=c6i.large
```

#### 3. Spot Instance Interruptions

**Symptom**: Benchmarks fail due to spot interruption
```bash
Error: Spot instance interrupted
```

**Solutions**:
```bash
# Use on-demand instances
terraform apply -var "use_spot_instances=false"

# Try different instance types with better spot availability
terraform apply -var "instance_type_x86=c5.large"

# Increase bid price (set to on-demand price)
# This is automatic with spot_price = null in our configuration
```

#### 4. SSH Connection Issues

**Symptom**: Cannot connect to benchmark instance
```bash
Error: timeout waiting for SSH
```

**Solutions**:
```bash
# Check security group allows SSH
aws ec2 describe-security-groups --group-ids sg-xxxxxxxxx

# Verify instance is running
aws ec2 describe-instances --instance-ids i-xxxxxxxxx

# Check SSH key permissions
chmod 600 infrastructure/packer/keys/benchmark_key

# Try manual SSH connection
ssh -i infrastructure/packer/keys/benchmark_key ubuntu@<instance-ip>
```

#### 5. Benchmark Timeouts

**Symptom**: Benchmarks don't complete within timeout
```bash
Error: Benchmark execution timed out
```

**Solutions**:
```bash
# Increase timeout
terraform apply -var "benchmark_timeout_minutes=60"

# Use faster instance types
terraform apply -var "instance_type_x86=c6i.xlarge"

# Reduce number of benchmark runs
terraform apply -var "num_benchmark_runs=10"
```

### Debug Mode

Enable detailed logging:

```bash
# Packer debug mode
PACKER_LOG=1 packer build image.pkr.hcl

# Terraform debug mode
TF_LOG=DEBUG terraform apply

# AWS CLI debug mode
aws --debug ec2 describe-instances
```

### Getting Help

1. **Check CloudWatch Logs**: Instance boot and application logs
2. **Review Terraform State**: Current infrastructure state
3. **Examine Security Groups**: Network access rules
4. **Verify AMI Status**: AMI availability and permissions
5. **Test Locally**: Verify benchmark scripts work locally first

## Best Practices

### 1. Development Workflow

```bash
# 1. Test locally first
zig build && zig build test
./scripts/perf-slow.sh

# 2. Validate infrastructure configs
make validate

# 3. Test with single architecture
make quick-x86

# 4. Full deployment
make deploy-both
```

### 2. Cost Management

- Always use spot instances for development
- Set billing alerts
- Clean up resources immediately after benchmarks
- Use smaller instance types for testing configurations

### 3. Performance Testing

- Run benchmarks multiple times for statistical significance
- Use consistent instance types for comparisons
- Document test conditions (instance type, region, spot vs on-demand)
- Compare results over time to track performance changes

### 4. Security

- Restrict SSH access to specific IP ranges when possible
- Use temporary SSH keys (generated per run)
- Enable EBS encryption (already configured)
- Regularly update AMIs with security patches

### 5. Maintenance

- Rebuild AMIs monthly for security updates
- Clean up old AMIs and snapshots
- Monitor AWS costs and set up alerts
- Keep Terraform and Packer versions updated

### 6. Result Management

- Archive important benchmark results
- Compare results across different code versions
- Track performance trends over time
- Document significant performance changes

## Advanced Usage

### Custom Benchmark Configurations

Modify the benchmark execution:

```bash
# Custom number of runs
NUM_RUNS=100 ./scripts/cloud-bench-local.sh x86 spot

# Custom timeout
terraform apply -var "benchmark_timeout_minutes=60"

# Different AWS region
AWS_REGION=eu-west-1 ./scripts/cloud-bench-local.sh arm64 spot
```

### Multi-Region Benchmarking

Run benchmarks in multiple regions:

```bash
for region in us-east-1 us-west-2 eu-west-1; do
  AWS_REGION=$region ./scripts/cloud-bench-local.sh x86 spot
done
```

### Batch Processing

Automate multiple benchmark runs:

```bash
#!/bin/bash
# Run weekly benchmark suite
./scripts/cloud-bench-local.sh both spot
mv benchmark-results-* "results-$(date +%Y-%m-%d)/"
```

This comprehensive infrastructure setup provides a robust, cost-effective, and reproducible environment for EVM performance benchmarking across multiple CPU architectures.