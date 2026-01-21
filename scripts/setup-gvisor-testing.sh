#!/bin/bash
#
# Setup script for gVisor comparison testing
# Run with: sudo ./scripts/setup-gvisor-testing.sh
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "=============================================="
echo "   ZViz gVisor Testing Setup"
echo "=============================================="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_fail "This script must be run as root (sudo)"
    exit 1
fi

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    log_fail "Cannot detect OS"
    exit 1
fi

log_info "Detected OS: $OS"

# Install Docker
install_docker() {
    log_info "Installing Docker..."

    case $OS in
        ubuntu|debian)
            apt-get update
            apt-get install -y ca-certificates curl gnupg

            # Add Docker's official GPG key
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            # Add repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io
            ;;
        fedora)
            dnf -y install dnf-plugins-core
            dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io
            ;;
        *)
            log_fail "Unsupported OS for automatic Docker installation: $OS"
            log_info "Please install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
            ;;
    esac

    systemctl enable docker
    systemctl start docker

    log_pass "Docker installed"
}

# Install gVisor
install_gvisor() {
    log_info "Installing gVisor..."

    case $OS in
        ubuntu|debian)
            curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | tee /etc/apt/sources.list.d/gvisor.list > /dev/null
            apt-get update
            apt-get install -y runsc
            ;;
        fedora)
            curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor -o /etc/pki/rpm-gpg/RPM-GPG-KEY-gvisor
            cat > /etc/yum.repos.d/gvisor.repo << 'REPO'
[gvisor]
name=gVisor
baseurl=https://storage.googleapis.com/gvisor/releases/rpm/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-gvisor
REPO
            dnf install -y runsc
            ;;
        *)
            # Manual installation
            log_info "Installing gVisor manually..."
            ARCH=$(uname -m)
            URL="https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}"

            curl -fsSL "${URL}/runsc" -o /usr/local/bin/runsc
            curl -fsSL "${URL}/containerd-shim-runsc-v1" -o /usr/local/bin/containerd-shim-runsc-v1

            chmod +x /usr/local/bin/runsc
            chmod +x /usr/local/bin/containerd-shim-runsc-v1
            ;;
    esac

    log_pass "gVisor installed: $(runsc --version 2>&1 | head -1)"
}

# Configure Docker to use gVisor
configure_docker_gvisor() {
    log_info "Configuring Docker to use gVisor..."

    # Backup existing config
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        log_info "Backed up existing Docker config"
    fi

    # Find runsc path
    RUNSC_PATH=$(which runsc)

    # Create or update config
    mkdir -p /etc/docker

    if [[ -f /etc/docker/daemon.json ]]; then
        # Merge with existing config using jq if available
        if command -v jq &> /dev/null; then
            jq '. + {"runtimes": {"runsc": {"path": "'"$RUNSC_PATH"'"}}}' /etc/docker/daemon.json.bak > /etc/docker/daemon.json
        else
            # Simple replacement
            cat > /etc/docker/daemon.json << EOF
{
  "runtimes": {
    "runsc": {
      "path": "$RUNSC_PATH"
    }
  }
}
EOF
        fi
    else
        cat > /etc/docker/daemon.json << EOF
{
  "runtimes": {
    "runsc": {
      "path": "$RUNSC_PATH"
    }
  }
}
EOF
    fi

    # Restart Docker
    systemctl restart docker

    log_pass "Docker configured with gVisor runtime"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    echo ""

    # Check Docker
    if docker info &> /dev/null; then
        log_pass "Docker is running"
    else
        log_fail "Docker is not running"
        return 1
    fi

    # Check gVisor runtime in Docker
    if docker info 2>/dev/null | grep -q runsc; then
        log_pass "gVisor runtime is configured in Docker"
    else
        log_fail "gVisor runtime not found in Docker"
        return 1
    fi

    # Test gVisor container
    log_info "Testing gVisor container..."
    if docker run --rm --runtime=runsc alpine:latest echo "gVisor test successful" 2>&1 | grep -q "successful"; then
        log_pass "gVisor container test passed"
    else
        log_fail "gVisor container test failed"
        log_info "Try running: docker run --rm --runtime=runsc alpine:latest echo test"
        return 1
    fi

    echo ""
    log_pass "All checks passed! gVisor testing is ready."
    return 0
}

# Add current user to docker group
add_user_to_docker() {
    if [[ -n "$SUDO_USER" ]]; then
        log_info "Adding $SUDO_USER to docker group..."
        usermod -aG docker "$SUDO_USER"
        log_pass "Added $SUDO_USER to docker group (re-login required)"
    fi
}

# Main
main() {
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        install_docker
    else
        log_pass "Docker already installed: $(docker --version)"
    fi

    # Check if gVisor is installed
    if ! command -v runsc &> /dev/null; then
        install_gvisor
    else
        log_pass "gVisor already installed: $(runsc --version 2>&1 | head -1)"
    fi

    # Configure Docker
    if ! docker info 2>/dev/null | grep -q runsc; then
        configure_docker_gvisor
    else
        log_pass "Docker already configured with gVisor"
    fi

    # Add user to docker group
    add_user_to_docker

    # Verify
    echo ""
    verify_installation

    echo ""
    echo "=============================================="
    echo "   Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Log out and back in (for docker group)"
    echo "  2. Build syscall tester: zig build syscall-tester"
    echo "  3. Run comparison: ./tests/compare_runtimes.sh"
    echo ""
}

main "$@"
