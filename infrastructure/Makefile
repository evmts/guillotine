# Makefile for Cloud Benchmark Infrastructure

.PHONY: help build-amis deploy-x86 deploy-arm64 deploy-both clean validate test

# Default target
help:
	@echo "Guillotine Cloud Benchmark Infrastructure"
	@echo ""
	@echo "Available targets:"
	@echo "  build-amis         Build AMIs for both architectures"
	@echo "  build-ami-x86      Build AMI for x86_64 only"
	@echo "  build-ami-arm64    Build AMI for ARM64 only"
	@echo "  deploy-x86         Deploy and run x86_64 benchmarks"
	@echo "  deploy-arm64       Deploy and run ARM64 benchmarks"
	@echo "  deploy-both        Deploy and run benchmarks on both architectures"
	@echo "  clean              Destroy all infrastructure"
	@echo "  validate           Validate Packer and Terraform configurations"
	@echo "  test               Run configuration tests"
	@echo ""
	@echo "Environment variables:"
	@echo "  AWS_REGION         AWS region (default: us-east-1)"
	@echo "  USE_SPOT           Use spot instances (default: true)"
	@echo "  NUM_RUNS           Number of benchmark runs (default: 20)"

# Variables
AWS_REGION ?= us-east-1
USE_SPOT ?= true
NUM_RUNS ?= 20
TIMESTAMP := $(shell date +%Y%m%d-%H%M%S)

# Directories
PACKER_DIR := packer
TERRAFORM_DIR := terraform

# AMI building targets
build-amis: build-ami-x86 build-ami-arm64

build-ami-x86:
	@echo "Building x86_64 AMI..."
	@cd $(PACKER_DIR) && \
		mkdir -p keys && \
		if [ ! -f keys/benchmark_key ]; then \
			ssh-keygen -t rsa -b 2048 -f keys/benchmark_key -N ""; \
		fi && \
		packer init image.pkr.hcl && \
		packer build -only="x86-build" \
			-var "aws_region=$(AWS_REGION)" \
			-var "ssh_public_key_path=./keys/benchmark_key.pub" \
			image.pkr.hcl

build-ami-arm64:
	@echo "Building ARM64 AMI..."
	@cd $(PACKER_DIR) && \
		mkdir -p keys && \
		if [ ! -f keys/benchmark_key ]; then \
			ssh-keygen -t rsa -b 2048 -f keys/benchmark_key -N ""; \
		fi && \
		packer init image.pkr.hcl && \
		packer build -only="arm-build" \
			-var "aws_region=$(AWS_REGION)" \
			-var "ssh_public_key_path=./keys/benchmark_key.pub" \
			image.pkr.hcl

# Deployment targets
deploy-x86: check-ami-x86
	@echo "Deploying x86_64 benchmark infrastructure..."
	@cd $(TERRAFORM_DIR) && \
		terraform init && \
		terraform apply -auto-approve \
			-var "architecture=x86" \
			-var "ami_id_x86=$$(cat ../$(PACKER_DIR)/ami-x86.txt)" \
			-var "use_spot_instances=$(USE_SPOT)" \
			-var "num_benchmark_runs=$(NUM_RUNS)" \
			-var "aws_region=$(AWS_REGION)"

deploy-arm64: check-ami-arm64
	@echo "Deploying ARM64 benchmark infrastructure..."
	@cd $(TERRAFORM_DIR) && \
		terraform init && \
		terraform apply -auto-approve \
			-var "architecture=arm64" \
			-var "ami_id_arm64=$$(cat ../$(PACKER_DIR)/ami-arm64.txt)" \
			-var "use_spot_instances=$(USE_SPOT)" \
			-var "num_benchmark_runs=$(NUM_RUNS)" \
			-var "aws_region=$(AWS_REGION)"

deploy-both: check-ami-both
	@echo "Deploying benchmarks for both architectures..."
	@$(MAKE) deploy-x86
	@$(MAKE) clean-x86
	@$(MAKE) deploy-arm64
	@$(MAKE) clean-arm64
	@echo "Creating combined results..."
	@mkdir -p ../benchmark-results-both-$(TIMESTAMP)
	@if [ -d $(TERRAFORM_DIR)/results-x86 ]; then \
		cp -r $(TERRAFORM_DIR)/results-x86 ../benchmark-results-both-$(TIMESTAMP)/; \
	fi
	@if [ -d $(TERRAFORM_DIR)/results-arm64 ]; then \
		cp -r $(TERRAFORM_DIR)/results-arm64 ../benchmark-results-both-$(TIMESTAMP)/; \
	fi
	@echo "Combined results saved to: ../benchmark-results-both-$(TIMESTAMP)"

# Cleanup targets
clean: clean-x86 clean-arm64

clean-x86:
	@echo "Cleaning up x86_64 infrastructure..."
	@cd $(TERRAFORM_DIR) && \
		if [ -f terraform.tfstate ] && [ -s terraform.tfstate ]; then \
			if [ -f ../$(PACKER_DIR)/ami-x86.txt ]; then \
				terraform destroy -auto-approve \
					-var "architecture=x86" \
					-var "ami_id_x86=$$(cat ../$(PACKER_DIR)/ami-x86.txt)" \
					-var "use_spot_instances=$(USE_SPOT)" \
					-var "aws_region=$(AWS_REGION)" || true; \
			else \
				terraform destroy -auto-approve \
					-var "architecture=x86" \
					-var "use_spot_instances=$(USE_SPOT)" \
					-var "aws_region=$(AWS_REGION)" || true; \
			fi \
		fi

clean-arm64:
	@echo "Cleaning up ARM64 infrastructure..."
	@cd $(TERRAFORM_DIR) && \
		if [ -f terraform.tfstate ] && [ -s terraform.tfstate ]; then \
			if [ -f ../$(PACKER_DIR)/ami-arm64.txt ]; then \
				terraform destroy -auto-approve \
					-var "architecture=arm64" \
					-var "ami_id_arm64=$$(cat ../$(PACKER_DIR)/ami-arm64.txt)" \
					-var "use_spot_instances=$(USE_SPOT)" \
					-var "aws_region=$(AWS_REGION)" || true; \
			else \
				terraform destroy -auto-approve \
					-var "architecture=arm64" \
					-var "use_spot_instances=$(USE_SPOT)" \
					-var "aws_region=$(AWS_REGION)" || true; \
			fi \
		fi

# Validation targets
validate:
	@echo "Validating Packer configuration..."
	@cd $(PACKER_DIR) && packer validate image.pkr.hcl
	@echo "Validating Terraform configuration..."
	@cd $(TERRAFORM_DIR) && terraform init -backend=false && terraform validate

# Test targets
test: validate
	@echo "Running configuration tests..."
	@echo "Checking AWS credentials..."
	@aws sts get-caller-identity > /dev/null || (echo "AWS credentials not configured" && exit 1)
	@echo "Checking required tools..."
	@command -v packer >/dev/null || (echo "packer not found" && exit 1)
	@command -v terraform >/dev/null || (echo "terraform not found" && exit 1)
	@command -v aws >/dev/null || (echo "aws CLI not found" && exit 1)
	@command -v jq >/dev/null || (echo "jq not found" && exit 1)
	@echo "All tests passed!"

# Helper targets for checking AMI availability
check-ami-x86:
	@if [ ! -f $(PACKER_DIR)/ami-x86.txt ]; then \
		echo "x86_64 AMI not found. Building..."; \
		$(MAKE) build-ami-x86; \
	else \
		echo "Using existing x86_64 AMI: $$(cat $(PACKER_DIR)/ami-x86.txt)"; \
	fi

check-ami-arm64:
	@if [ ! -f $(PACKER_DIR)/ami-arm64.txt ]; then \
		echo "ARM64 AMI not found. Building..."; \
		$(MAKE) build-ami-arm64; \
	else \
		echo "Using existing ARM64 AMI: $$(cat $(PACKER_DIR)/ami-arm64.txt)"; \
	fi

check-ami-both: check-ami-x86 check-ami-arm64

# Format targets
fmt:
	@echo "Formatting Terraform files..."
	@cd $(TERRAFORM_DIR) && terraform fmt
	@echo "Formatting Packer files..."
	@cd $(PACKER_DIR) && packer fmt image.pkr.hcl

# Information targets
info:
	@echo "Current configuration:"
	@echo "  AWS Region: $(AWS_REGION)"
	@echo "  Use Spot: $(USE_SPOT)"
	@echo "  Benchmark Runs: $(NUM_RUNS)"
	@echo ""
	@if [ -f $(PACKER_DIR)/ami-x86.txt ]; then \
		echo "  x86_64 AMI: $$(cat $(PACKER_DIR)/ami-x86.txt)"; \
	else \
		echo "  x86_64 AMI: Not built"; \
	fi
	@if [ -f $(PACKER_DIR)/ami-arm64.txt ]; then \
		echo "  ARM64 AMI: $$(cat $(PACKER_DIR)/ami-arm64.txt)"; \
	else \
		echo "  ARM64 AMI: Not built"; \
	fi

# Quick run targets
quick-x86:
	@$(MAKE) build-ami-x86 deploy-x86

quick-arm64:
	@$(MAKE) build-ami-arm64 deploy-arm64

quick-both:
	@$(MAKE) build-amis deploy-both