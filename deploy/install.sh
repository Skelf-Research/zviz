#!/bin/bash
#
# ZigViz Installation Script
#
# This script installs ZigViz as a container runtime and configures
# containerd for Kubernetes integration.
#
# Usage:
#   ./install.sh                    # Install with default options
#   ./install.sh --node-only        # Only install binary, don't configure containerd
#   ./install.sh --uninstall        # Remove ZigViz
#
# Requirements:
#   - Linux kernel >= 5.6 (for seccomp user notification)
#   - containerd >= 1.6
#   - Root privileges

set -e

ZIGVIZ_VERSION="${ZIGVIZ_VERSION:-0.1.0}"
ZIGVIZ_BIN="/usr/local/bin/zigviz"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
STATE_DIR="/run/zigviz"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_requirements() {
    log_info "Checking requirements..."

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check kernel version
    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
    KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

    if [[ $KERNEL_MAJOR -lt 5 ]] || [[ $KERNEL_MAJOR -eq 5 && $KERNEL_MINOR -lt 6 ]]; then
        log_error "Kernel version >= 5.6 required (found: $(uname -r))"
        log_error "seccomp user notification requires kernel 5.6+"
        exit 1
    fi

    log_info "Kernel version: $(uname -r) ✓"

    # Check for containerd
    if command -v containerd &> /dev/null; then
        CONTAINERD_VERSION=$(containerd --version | awk '{print $3}')
        log_info "containerd version: $CONTAINERD_VERSION ✓"
    else
        log_warn "containerd not found - skipping containerd configuration"
    fi

    # Check for required kernel features
    if [[ -f /proc/config.gz ]]; then
        if zcat /proc/config.gz | grep -q "CONFIG_SECCOMP_FILTER=y"; then
            log_info "seccomp filter support ✓"
        else
            log_error "Kernel compiled without CONFIG_SECCOMP_FILTER"
            exit 1
        fi
    fi
}

install_binary() {
    log_info "Installing ZigViz binary..."

    # Check if binary exists in current directory
    if [[ -f "./zig-out/bin/zigviz" ]]; then
        cp ./zig-out/bin/zigviz "$ZIGVIZ_BIN"
    elif [[ -f "./zigviz" ]]; then
        cp ./zigviz "$ZIGVIZ_BIN"
    else
        log_error "ZigViz binary not found. Please build first with 'zig build'"
        exit 1
    fi

    chmod +x "$ZIGVIZ_BIN"
    log_info "Installed $ZIGVIZ_BIN"

    # Verify installation
    if "$ZIGVIZ_BIN" version &> /dev/null; then
        log_info "ZigViz $($ZIGVIZ_BIN version 2>&1 | head -1) installed successfully"
    else
        log_error "Installation verification failed"
        exit 1
    fi

    # Create state directory
    mkdir -p "$STATE_DIR"
    log_info "Created state directory: $STATE_DIR"
}

configure_containerd() {
    log_info "Configuring containerd..."

    if [[ ! -f "$CONTAINERD_CONFIG" ]]; then
        log_warn "containerd config not found at $CONTAINERD_CONFIG"
        log_warn "Creating new config..."
        mkdir -p $(dirname "$CONTAINERD_CONFIG")
        containerd config default > "$CONTAINERD_CONFIG"
    fi

    # Backup existing config
    cp "$CONTAINERD_CONFIG" "${CONTAINERD_CONFIG}.backup.$(date +%s)"
    log_info "Backed up existing config"

    # Check if zigviz runtime already configured
    if grep -q "runtimes.zigviz" "$CONTAINERD_CONFIG"; then
        log_warn "ZigViz runtime already configured in containerd"
    else
        # Add ZigViz runtime configuration
        cat >> "$CONTAINERD_CONFIG" << 'EOF'

# ZigViz Runtime Configuration (added by install.sh)
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz]
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz.options]
    BinaryName = "/usr/local/bin/zigviz"
    SystemdCgroup = true
EOF
        log_info "Added ZigViz runtime to containerd config"
    fi

    # Restart containerd
    if systemctl is-active containerd &> /dev/null; then
        log_info "Restarting containerd..."
        systemctl restart containerd
        sleep 2
        if systemctl is-active containerd &> /dev/null; then
            log_info "containerd restarted successfully"
        else
            log_error "containerd failed to restart"
            exit 1
        fi
    else
        log_warn "containerd is not running. Start it manually after installation."
    fi
}

configure_kubernetes() {
    log_info "Creating Kubernetes RuntimeClass..."

    if command -v kubectl &> /dev/null; then
        kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zigviz
handler: zigviz
EOF
        log_info "RuntimeClass 'zigviz' created"
    else
        log_warn "kubectl not found - skip RuntimeClass creation"
        log_info "Apply RuntimeClass manually: kubectl apply -f deploy/kubernetes/runtime-class.yaml"
    fi
}

uninstall() {
    log_info "Uninstalling ZigViz..."

    # Remove binary
    if [[ -f "$ZIGVIZ_BIN" ]]; then
        rm -f "$ZIGVIZ_BIN"
        log_info "Removed $ZIGVIZ_BIN"
    fi

    # Remove RuntimeClass
    if command -v kubectl &> /dev/null; then
        kubectl delete runtimeclass zigviz 2>/dev/null || true
        log_info "Removed RuntimeClass"
    fi

    log_warn "containerd configuration not removed - edit $CONTAINERD_CONFIG manually"
    log_info "Uninstall complete"
}

# Main
case "${1:-}" in
    --uninstall)
        uninstall
        ;;
    --node-only)
        check_requirements
        install_binary
        ;;
    *)
        check_requirements
        install_binary
        if command -v containerd &> /dev/null; then
            configure_containerd
        fi
        if command -v kubectl &> /dev/null; then
            configure_kubernetes
        fi

        echo ""
        log_info "Installation complete!"
        echo ""
        echo "To use ZigViz with Kubernetes:"
        echo "  1. Apply the RuntimeClass: kubectl apply -f deploy/kubernetes/runtime-class.yaml"
        echo "  2. Add 'runtimeClassName: zigviz' to your pod spec"
        echo ""
        echo "To test the installation:"
        echo "  zigviz version"
        echo "  zigviz spec > /tmp/config.json"
        echo ""
        ;;
esac
