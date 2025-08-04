# Cloud Benchmark Infrastructure

This directory contains the Infrastructure-as-Code (IaC) setup for running Guillotine EVM benchmarks in AWS EC2 instances using Terraform and Packer.

## Overview

The cloud benchmark infrastructure provides:

- **Reproducible Environments**: Custom AMIs with all dependencies pre-installed
- **Multi-Architecture Support**: x86_64 (Intel/AMD) and ARM64 (AWS Graviton) instances  
- **Cost Optimization**: Support for spot instances to reduce costs
- **Automation**: GitHub Actions workflows and local CLI scripts
- **Consistent Performance**: Dedicated instances with predictable CPU performance

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│     Packer      │    │    Terraform    │    │ GitHub Actions  │
│                 │    │                 │    │                 │
│ • Ubuntu 22.04  │    │ • EC2 Instances │    │ • Workflow      │
│ • Zig 0.14.1+   │───▶│ • Security Groups│───▶│   Automation    │
│ • Rust/Go/Node  │    │ • SSH Keys      │    │ • Result        │
│ • hyperfine     │    │ • Benchmarking  │    │   Collection    │
│ • Bun runtime   │    │ • Cleanup       │    │ • Multi-arch    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
       AMI                   EC2                  CI/CD
```

## Prerequisites

### Local Development

Install required tools:

```bash
# macOS
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

# Install AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

### AWS Configuration

Configure AWS credentials:

```bash
aws configure
# AWS Access Key ID: [Your Access Key]
# AWS Secret Access Key: [Your Secret Key]  
# Default region name: us-east-1
# Default output format: json
```

Required AWS IAM permissions:
- EC2: Full access for instance management
- VPC: Read access for networking
- IAM: Limited access for instance profiles
- Spot: Access for spot instance requests

## Directory Structure

```
infrastructure/
├── packer/                    # AMI building
│   ├── image.pkr.hcl         # Packer template
│   ├── scripts/
│   │   └── install-deps.sh   # Dependency installation
│   └── keys/                 # SSH keys (generated)
├── terraform/                # Infrastructure deployment
│   ├── main.tf              # Main configuration
│   ├── variables.tf         # Variable definitions
│   └── outputs.tf           # Output definitions
└── README.md                # This file
```

## Usage

### Method 1: Local CLI Script (Recommended)

Use the provided script for one-command execution:

```bash
# Run x86_64 benchmarks on spot instances
./scripts/cloud-bench-local.sh x86 spot

# Run ARM64 benchmarks on on-demand instances  
./scripts/cloud-bench-local.sh arm64 ondemand

# Run both architectures on spot instances
./scripts/cloud-bench-local.sh both spot
```

The script will:
1. Build custom AMIs with Packer
2. Deploy EC2 instances with Terraform
3. Run benchmarks automatically
4. Download results locally
5. Clean up all resources

### Method 2: Manual Step-by-Step

#### Step 1: Build AMIs

```bash
cd infrastructure/packer

# Generate SSH key
mkdir -p keys
ssh-keygen -t rsa -b 2048 -f keys/benchmark_key -N ""

# Initialize Packer
packer init image.pkr.hcl

# Build x86_64 AMI
packer build -only="x86-build" \
  -var "aws_region=us-east-1" \
  -var "ssh_public_key_path=./keys/benchmark_key.pub" \
  image.pkr.hcl

# Build ARM64 AMI
packer build -only="arm-build" \
  -var "aws_region=us-east-1" \
  -var "ssh_public_key_path=./keys/benchmark_key.pub" \
  image.pkr.hcl
```

#### Step 2: Deploy and Run Benchmarks

```bash
cd infrastructure/terraform

# Initialize Terraform
terraform init

# Extract AMI IDs from Packer manifests
AMI_X86=$(jq -r '.builds[0].artifact_id' ../packer/manifest-x86.json | cut -d':' -f2)
AMI_ARM64=$(jq -r '.builds[0].artifact_id' ../packer/manifest-arm.json | cut -d':' -f2)

# Run x86_64 benchmarks
terraform apply -auto-approve \
  -var "architecture=x86" \
  -var "ami_id_x86=$AMI_X86" \
  -var "use_spot_instances=true"

# Results will be downloaded to ./results-x86/

# Clean up
terraform destroy -auto-approve \
  -var "architecture=x86" \
  -var "ami_id_x86=$AMI_X86"
```

### Method 3: GitHub Actions

Trigger cloud benchmarks via GitHub Actions:

1. Go to Actions tab in GitHub repository
2. Select "Cloud EVM Benchmarks" workflow
3. Click "Run workflow"
4. Choose architecture and options
5. Results will be available as workflow artifacts

## Configuration

### Packer Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region for AMI building | `us-east-1` |
| `ssh_public_key_path` | Path to SSH public key | `./keys/benchmark_key.pub` |

### Terraform Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `architecture` | Target architecture (`x86` or `arm64`) | `x86` |
| `use_spot_instances` | Use spot instances for cost savings | `true` |
| `ami_id_x86` | AMI ID for x86_64 instances | Required |
| `ami_id_arm64` | AMI ID for ARM64 instances | Required |
| `instance_type_x86` | EC2 instance type for x86_64 | `c6i.large` |
| `instance_type_arm64` | EC2 instance type for ARM64 | `c7g.large` |
| `benchmark_timeout_minutes` | Timeout for benchmark execution | `30` |

## Instance Types

### Recommended Instance Types

**x86_64 Options:**
- `c6i.large` - 2 vCPU, 4 GiB RAM (balanced)
- `c6i.xlarge` - 4 vCPU, 8 GiB RAM (higher performance)
- `c5.large` - 2 vCPU, 4 GiB RAM (cost-effective)

**ARM64 Options:**
- `c7g.large` - 2 vCPU, 4 GiB RAM (latest Graviton3)
- `c7g.xlarge` - 4 vCPU, 8 GiB RAM (higher performance)
- `c6g.large` - 2 vCPU, 4 GiB RAM (Graviton2)

### Performance Considerations

- Use compute-optimized instances (C-series) for CPU-intensive benchmarks
- Avoid burstable instances (T-series) for consistent performance
- Consider EBS-optimized instances for better I/O performance

## Cost Management

### Spot Instances

Spot instances can reduce costs by 70-90% compared to on-demand:

```bash
# Enable spot instances (default)
terraform apply -var "use_spot_instances=true"

# Use on-demand for guaranteed availability
terraform apply -var "use_spot_instances=false"
```

### Estimated Costs (us-east-1)

| Instance Type | On-Demand | Spot (est.) | Duration | Total Cost |
|---------------|-----------|-------------|----------|------------|
| c6i.large | $0.0864/hr | $0.0259/hr | 30 min | $0.43 / $0.13 |
| c7g.large | $0.0725/hr | $0.0217/hr | 30 min | $0.36 / $0.11 |

*Spot prices vary based on demand*

## Security

### Network Security

- Security group allows SSH (port 22) from any IP during benchmark
- All other ports are blocked
- Instance is terminated after benchmark completion

### SSH Access

- Temporary SSH key pair generated for each run
- Private key stored securely in GitHub Actions secrets
- Keys deleted after infrastructure cleanup

### Data Protection

- EBS volumes encrypted at rest
- No sensitive data stored in AMI
- Results contain only benchmark performance data

## Troubleshooting

### Common Issues

**Packer build fails:**
```bash
# Check AWS credentials
aws sts get-caller-identity

# Verify region setting
packer validate image.pkr.hcl
```

**Terraform apply fails:**
```bash
# Check AMI ID is valid
aws ec2 describe-images --image-ids ami-xxxxxxxxx

# Verify spot instance availability
aws ec2 describe-spot-price-history --instance-types c6i.large
```

**Benchmark timeout:**
```bash
# Increase timeout
terraform apply -var "benchmark_timeout_minutes=60"
```

**SSH connection issues:**
```bash
# Check security group rules
aws ec2 describe-security-groups --group-ids sg-xxxxxxxxx

# Verify instance is running
aws ec2 describe-instances --instance-ids i-xxxxxxxxx
```

### Debug Mode

Enable debug logging:

```bash
# Packer debug
PACKER_LOG=1 packer build image.pkr.hcl

# Terraform debug
TF_LOG=DEBUG terraform apply
```

## Maintenance

### AMI Updates

Rebuild AMIs when:
- Zig version updates (0.14.1+)
- Major dependency changes
- Security updates needed

### Cleanup

Remove old resources:

```bash
# List old AMIs
aws ec2 describe-images --owners self --filters "Name=name,Values=guillotine-bench-*"

# Delete old AMI (replace with actual AMI ID)
aws ec2 deregister-image --image-id ami-xxxxxxxxx
```

## Contributing

When modifying the infrastructure:

1. Test changes locally first
2. Update documentation
3. Ensure cleanup works properly
4. Test both architectures if applicable
5. Verify GitHub Actions workflow

## Support

For issues with the cloud infrastructure:

1. Check AWS CloudWatch logs
2. Review Terraform state files
3. Examine Packer build logs
4. Test locally before using CI/CD

## References

- [Packer Documentation](https://developer.hashicorp.com/packer/docs)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS EC2 Instance Types](https://aws.amazon.com/ec2/instance-types/)
- [AWS Spot Instances](https://aws.amazon.com/ec2/spot/)