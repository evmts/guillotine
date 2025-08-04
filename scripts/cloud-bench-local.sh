#!/bin/bash
set -euo pipefail

# Cloud Benchmark Local Runner
# This script allows running cloud benchmarks from your local machine
# Usage: ./scripts/cloud-bench-local.sh [x86|arm64|both] [spot|ondemand]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRASTRUCTURE_DIR="$PROJECT_ROOT/infrastructure"

# Default values
ARCHITECTURE="${1:-x86}"
INSTANCE_TYPE="${2:-spot}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NUM_RUNS="${NUM_RUNS:-20}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v packer >/dev/null 2>&1; then
        missing_deps+=("packer")
    fi
    
    if ! command -v terraform >/dev/null 2>&1; then
        missing_deps+=("terraform")
    fi
    
    if ! command -v aws >/dev/null 2>&1; then
        missing_deps+=("aws-cli")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing_deps[*]}"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error "AWS credentials not configured. Run 'aws configure' first."
    fi
    
    success "All dependencies found"
}

# Build AMIs with Packer
build_amis() {
    local arch="$1"
    log "Building AMI for architecture: $arch"
    
    cd "$INFRASTRUCTURE_DIR/packer"
    
    # Generate SSH key if it doesn't exist
    if [ ! -f keys/benchmark_key ]; then
        mkdir -p keys
        ssh-keygen -t rsa -b 2048 -f keys/benchmark_key -N ""
        log "Generated SSH key pair"
    fi
    
    # Initialize Packer
    packer init image.pkr.hcl
    
    # Build AMI based on architecture
    case $arch in
        x86)
            log "Building x86_64 AMI..."
            packer build -only="x86-build" \
                -var "aws_region=$AWS_REGION" \
                -var "ssh_public_key_path=./keys/benchmark_key.pub" \
                image.pkr.hcl
            
            AMI_X86=$(jq -r '.builds[0].artifact_id' manifest-x86.json | cut -d':' -f2)
            log "Built x86_64 AMI: $AMI_X86"
            echo "$AMI_X86" > ami-x86.txt
            ;;
        arm64)
            log "Building ARM64 AMI..."
            packer build -only="arm-build" \
                -var "aws_region=$AWS_REGION" \
                -var "ssh_public_key_path=./keys/benchmark_key.pub" \
                image.pkr.hcl
            
            AMI_ARM64=$(jq -r '.builds[0].artifact_id' manifest-arm.json | cut -d':' -f2)
            log "Built ARM64 AMI: $AMI_ARM64"
            echo "$AMI_ARM64" > ami-arm64.txt
            ;;
        both)
            build_amis "x86"
            build_amis "arm64"
            return
            ;;
        *)
            error "Invalid architecture: $arch. Use x86, arm64, or both"
            ;;
    esac
    
    success "AMI build completed"
}

# Run benchmarks with Terraform
run_benchmarks() {
    local arch="$1"
    local use_spot="$2"
    
    log "Running benchmarks for architecture: $arch (spot: $use_spot)"
    
    cd "$INFRASTRUCTURE_DIR/terraform"
    
    # Initialize Terraform
    terraform init
    
    # Get AMI ID
    local ami_var=""
    if [ "$arch" = "x86" ]; then
        if [ -f ../packer/ami-x86.txt ]; then
            AMI_ID=$(cat ../packer/ami-x86.txt)
            ami_var="-var ami_id_x86=$AMI_ID"
        else
            error "x86_64 AMI not found. Build AMIs first."
        fi
    elif [ "$arch" = "arm64" ]; then
        if [ -f ../packer/ami-arm64.txt ]; then
            AMI_ID=$(cat ../packer/ami-arm64.txt)
            ami_var="-var ami_id_arm64=$AMI_ID"
        else
            error "ARM64 AMI not found. Build AMIs first."
        fi
    fi
    
    # Apply Terraform
    log "Deploying infrastructure and running benchmarks..."
    terraform apply -auto-approve \
        -var "architecture=$arch" \
        -var "use_spot_instances=$use_spot" \
        -var "num_benchmark_runs=$NUM_RUNS" \
        -var "aws_region=$AWS_REGION" \
        $ami_var
    
    # Get instance information
    INSTANCE_IP=$(terraform output -raw instance_ip)
    log "Benchmark instance deployed at: $INSTANCE_IP"
    
    # Wait for results
    log "Waiting for benchmark completion..."
    
    # Results should be downloaded automatically by Terraform
    if [ -d "results-$arch" ]; then
        success "Benchmark results downloaded to: results-$arch/"
        
        if [ -f "results-$arch/results.md" ]; then
            log "Results summary:"
            head -20 "results-$arch/results.md"
        fi
    else
        warn "Results directory not found"
    fi
}

# Cleanup infrastructure
cleanup() {
    local arch="$1"
    log "Cleaning up infrastructure for $arch..."
    
    cd "$INFRASTRUCTURE_DIR/terraform"
    
    # Get AMI ID for cleanup
    local ami_var=""
    if [ "$arch" = "x86" ] && [ -f ../packer/ami-x86.txt ]; then
        AMI_ID=$(cat ../packer/ami-x86.txt)
        ami_var="-var ami_id_x86=$AMI_ID"
    elif [ "$arch" = "arm64" ] && [ -f ../packer/ami-arm64.txt ]; then
        AMI_ID=$(cat ../packer/ami-arm64.txt)
        ami_var="-var ami_id_arm64=$AMI_ID"
    fi
    
    terraform destroy -auto-approve \
        -var "architecture=$arch" \
        -var "use_spot_instances=true" \
        -var "num_benchmark_runs=$NUM_RUNS" \
        -var "aws_region=$AWS_REGION" \
        $ami_var || warn "Cleanup may have encountered issues"
    
    success "Cleanup completed"
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [ARCHITECTURE] [INSTANCE_TYPE]

ARCHITECTURE:
  x86     - Run benchmarks on x86_64 (Intel/AMD)
  arm64   - Run benchmarks on ARM64 (Graviton)
  both    - Run benchmarks on both architectures

INSTANCE_TYPE:
  spot      - Use spot instances (cheaper, may be interrupted)
  ondemand  - Use on-demand instances (more expensive, guaranteed)

Environment Variables:
  AWS_REGION    - AWS region to use (default: us-east-1)
  NUM_RUNS      - Number of benchmark runs (default: 20)

Examples:
  $0 x86 spot           # Run x86 benchmarks on spot instances
  $0 arm64 ondemand     # Run ARM64 benchmarks on on-demand instances
  $0 both spot          # Run both architectures on spot instances

EOF
}

# Validate arguments
validate_args() {
    case $ARCHITECTURE in
        x86|arm64|both) ;;
        *) error "Invalid architecture: $ARCHITECTURE. Use x86, arm64, or both" ;;
    esac
    
    case $INSTANCE_TYPE in
        spot|ondemand) ;;
        *) error "Invalid instance type: $INSTANCE_TYPE. Use spot or ondemand" ;;
    esac
}

# Main execution
main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi
    
    validate_args
    
    log "Starting cloud benchmark run"
    log "Architecture: $ARCHITECTURE"
    log "Instance Type: $INSTANCE_TYPE"
    log "AWS Region: $AWS_REGION"
    log "Number of runs: $NUM_RUNS"
    
    check_dependencies
    
    # Convert instance type to boolean
    USE_SPOT="true"
    if [ "$INSTANCE_TYPE" = "ondemand" ]; then
        USE_SPOT="false"
    fi
    
    # Build AMIs
    log "Building AMIs..."
    build_amis "$ARCHITECTURE"
    
    # Run benchmarks
    if [ "$ARCHITECTURE" = "both" ]; then
        for arch in x86 arm64; do
            log "Running benchmarks for $arch..."
            run_benchmarks "$arch" "$USE_SPOT"
        done
        
        # Generate combined report
        log "Generating combined report..."
        mkdir -p "$PROJECT_ROOT/benchmark-results-$(date +%Y%m%d-%H%M%S)"
        REPORT_DIR="$PROJECT_ROOT/benchmark-results-$(date +%Y%m%d-%H%M%S)"
        
        if [ -d "$INFRASTRUCTURE_DIR/terraform/results-x86" ]; then
            cp -r "$INFRASTRUCTURE_DIR/terraform/results-x86" "$REPORT_DIR/"
        fi
        
        if [ -d "$INFRASTRUCTURE_DIR/terraform/results-arm64" ]; then
            cp -r "$INFRASTRUCTURE_DIR/terraform/results-arm64" "$REPORT_DIR/"
        fi
        
        success "Combined results saved to: $REPORT_DIR"
    else
        run_benchmarks "$ARCHITECTURE" "$USE_SPOT"
        
        # Copy results to timestamped directory
        REPORT_DIR="$PROJECT_ROOT/benchmark-results-$ARCHITECTURE-$(date +%Y%m%d-%H%M%S)"
        if [ -d "$INFRASTRUCTURE_DIR/terraform/results-$ARCHITECTURE" ]; then
            cp -r "$INFRASTRUCTURE_DIR/terraform/results-$ARCHITECTURE" "$REPORT_DIR"
            success "Results saved to: $REPORT_DIR"
        fi
    fi
    
    # Cleanup
    if [ "$ARCHITECTURE" = "both" ]; then
        cleanup "x86"
        cleanup "arm64"
    else
        cleanup "$ARCHITECTURE"
    fi
    
    success "Cloud benchmark run completed!"
}

# Trap cleanup on exit
trap 'error "Script interrupted"' INT TERM

# Run main function
main "$@"