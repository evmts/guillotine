#!/bin/bash
set -euxo pipefail

# Variables
ARCH=${ARCH:-$(uname -m)}
ZIG_VERSION="0.14.1"
NODE_VERSION="20"

echo "Installing dependencies for architecture: $ARCH"

# Update system packages
sudo apt-get update -y
sudo apt-get upgrade -y

# Install essential packages
sudo apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    unzip \
    software-properties-common \
    ca-certificates \
    gnupg \
    lsb-release \
    hyperfine \
    python3 \
    python3-pip

# Install Go (latest stable)
echo "Installing Go..."
sudo add-apt-repository -y ppa:longsleep/golang-backports
sudo apt-get update -y
sudo apt-get install -y golang-go

# Verify Go installation
go version

# Install Rust via rustup
echo "Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
source $HOME/.cargo/env
echo 'source $HOME/.cargo/env' >> $HOME/.bashrc

# Verify Rust installation
rustc --version
cargo --version

# Install Zig
echo "Installing Zig $ZIG_VERSION for $ARCH..."
if [ "$ARCH" = "x86_64" ]; then
    ZIG_ARCH="x86_64"
elif [ "$ARCH" = "aarch64" ]; then
    ZIG_ARCH="aarch64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

ZIG_URL="https://ziglang.org/download/$ZIG_VERSION/zig-linux-$ZIG_ARCH-$ZIG_VERSION.tar.xz"
wget -q "$ZIG_URL" -O "/tmp/zig-linux-$ZIG_ARCH-$ZIG_VERSION.tar.xz"
cd /tmp
tar -xf "zig-linux-$ZIG_ARCH-$ZIG_VERSION.tar.xz"
sudo mv "zig-linux-$ZIG_ARCH-$ZIG_VERSION" "/opt/zig-$ZIG_VERSION"
sudo ln -sf "/opt/zig-$ZIG_VERSION/zig" /usr/local/bin/zig

# Verify Zig installation
zig version

# Install Node.js and npm
echo "Installing Node.js $NODE_VERSION..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verify Node.js installation
node --version
npm --version

# Install Bun (JavaScript runtime)
echo "Installing Bun..."
curl -fsSL https://bun.sh/install | bash
# Move bun to system path
sudo cp $HOME/.bun/bin/bun /usr/local/bin/bun
sudo chmod +x /usr/local/bin/bun

# Verify Bun installation
bun --version

# Install additional performance tools
sudo apt-get install -y \
    htop \
    iotop \
    sysstat \
    perf-tools-unstable \
    linux-tools-common \
    linux-tools-generic

# Set up benchmark user SSH key if provided
if [ -f /tmp/benchmark_key.pub ]; then
    echo "Setting up SSH key for benchmark user..."
    mkdir -p /home/ubuntu/.ssh
    cp /tmp/benchmark_key.pub /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    chmod 700 /home/ubuntu/.ssh
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    rm /tmp/benchmark_key.pub
fi

# Create benchmark workspace
sudo mkdir -p /opt/benchmark
sudo chown ubuntu:ubuntu /opt/benchmark

# Install markserv for result viewing (optional)
sudo npm install -g markserv

# Clean up package cache to reduce image size
sudo apt-get autoremove -y
sudo apt-get autoclean -y
sudo rm -rf /var/lib/apt/lists/*

# Clear shell history and temporary files
history -c
sudo rm -rf /tmp/*
sudo rm -rf /var/tmp/*

echo "Dependencies installation completed successfully!"
echo "Installed versions:"
echo "  Go: $(go version)"
echo "  Rust: $(rustc --version)"
echo "  Zig: $(zig version)"
echo "  Node.js: $(node --version)"
echo "  Bun: $(bun --version)"
echo "  hyperfine: $(hyperfine --version)"