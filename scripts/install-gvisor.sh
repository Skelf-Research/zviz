#!/bin/bash
# Install gVisor (runsc) for ZViz comparison testing
#
# Usage:
#   ./scripts/install-gvisor.sh           # Install runsc + Docker integration
#   ./scripts/install-gvisor.sh --no-docker  # Install runsc only (for direct OCI use)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DOCKER_RUNTIME=true

# Parse args
for arg in "$@"; do
    case $arg in
        --no-docker)
            INSTALL_DOCKER_RUNTIME=false
            ;;
        --help|-h)
            echo "Usage: $0 [--no-docker]"
            echo ""
            echo "Options:"
            echo "  --no-docker  Install runsc only, skip Docker runtime configuration"
            echo ""
            echo "This script installs gVisor's runsc runtime for comparison with ZViz."
            exit 0
            ;;
    esac
done

echo -e "${GREEN}=== Installing gVisor (runsc) ===${NC}"

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    echo -e "${RED}Error: gVisor only supports x86_64, detected: $ARCH${NC}"
    exit 1
fi

# Check if already installed
if command -v runsc &>/dev/null; then
    CURRENT_VERSION=$(runsc --version 2>/dev/null | head -1 || echo "unknown")
    echo -e "${YELLOW}runsc already installed: $CURRENT_VERSION${NC}"
    read -p "Reinstall/upgrade? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping installation."
        exit 0
    fi
fi

# Method 1: Try apt repository (preferred for Debian/Ubuntu)
install_via_apt() {
    echo "Installing via apt repository..."

    # Add gVisor signing key
    curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg 2>/dev/null || true

    # Add repository
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | \
        sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null

    # Install
    sudo apt-get update
    sudo apt-get install -y runsc
}

# Method 2: Direct binary download (fallback)
install_via_binary() {
    echo "Installing via direct binary download..."

    RELEASE_URL="https://storage.googleapis.com/gvisor/releases/release/latest/x86_64"

    # Download runsc
    curl -fsSL "${RELEASE_URL}/runsc" -o /tmp/runsc
    curl -fsSL "${RELEASE_URL}/runsc.sha512" -o /tmp/runsc.sha512

    # Verify checksum
    cd /tmp
    if sha512sum -c runsc.sha512; then
        echo -e "${GREEN}Checksum verified${NC}"
    else
        echo -e "${RED}Checksum verification failed!${NC}"
        exit 1
    fi

    # Install
    chmod +x /tmp/runsc
    sudo mv /tmp/runsc /usr/local/bin/runsc
    rm -f /tmp/runsc.sha512
}

# Try apt first, fall back to binary
if command -v apt-get &>/dev/null; then
    install_via_apt || install_via_binary
else
    install_via_binary
fi

# Verify installation
if ! command -v runsc &>/dev/null; then
    echo -e "${RED}Installation failed: runsc not found in PATH${NC}"
    exit 1
fi

echo -e "${GREEN}runsc installed successfully${NC}"
runsc --version

# Configure Docker runtime (optional)
if [[ "$INSTALL_DOCKER_RUNTIME" == "true" ]]; then
    echo ""
    echo -e "${GREEN}=== Configuring Docker Runtime ===${NC}"

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}Docker not installed, skipping runtime configuration${NC}"
    else
        # Install runsc as Docker runtime
        sudo runsc install

        # Restart Docker
        echo "Restarting Docker daemon..."
        sudo systemctl restart docker

        # Verify
        echo "Verifying Docker + gVisor integration..."
        if docker run --rm --runtime=runsc hello-world &>/dev/null; then
            echo -e "${GREEN}Docker + gVisor working!${NC}"
        else
            echo -e "${YELLOW}Warning: Docker + gVisor test failed${NC}"
            echo "You may need to manually restart Docker or check /etc/docker/daemon.json"
        fi
    fi
fi

echo ""
echo -e "${GREEN}=== Installation Complete ===${NC}"
echo ""
echo "Usage:"
echo "  runsc --version                    # Check version"
echo "  runsc do ls                        # Run command in sandbox (quick test)"
echo "  runsc run <id> --bundle <path>     # Run OCI container (like ZViz)"
echo ""
if [[ "$INSTALL_DOCKER_RUNTIME" == "true" ]] && command -v docker &>/dev/null; then
    echo "  docker run --runtime=runsc alpine  # Run via Docker"
    echo ""
fi
echo "To run ZViz demo with gVisor comparison:"
echo "  ./demo.sh --all"
