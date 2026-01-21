#!/bin/bash
#
# ZViz Installation Script
#
# Downloads and installs ZViz from GitHub Releases.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Skelf-Research/zviz/main/deploy/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Skelf-Research/zviz/main/deploy/install.sh | sh -s -- --version 0.1.0
#   curl -fsSL https://raw.githubusercontent.com/Skelf-Research/zviz/main/deploy/install.sh | sh -s -- --help
#
# Options:
#   --version VERSION    Install specific version (default: latest)
#   --prefix PATH        Installation prefix (default: /usr/local)
#   --no-verify          Skip checksum verification
#   --configure          Also configure containerd and Kubernetes
#   --uninstall          Remove ZViz
#   --help               Show this help message
#
# Requirements:
#   - Linux kernel >= 5.6 (for seccomp user notification)
#   - curl or wget
#   - Root privileges for installation

set -euo pipefail

# Configuration
GITHUB_REPO="Skelf-Research/zviz"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
ZVIZ_VERSION=""
VERIFY_CHECKSUM=true
CONFIGURE_RUNTIME=false
STATE_DIR="/run/zviz"
CONTAINERD_CONFIG="/etc/containerd/config.toml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${BLUE}==>${NC} $1"; }

# Architecture detection
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            log_error "ZViz supports: x86_64, aarch64"
            exit 1
            ;;
    esac
}

# OS detection
detect_os() {
    local os
    os=$(uname -s)
    case "$os" in
        Linux)  echo "linux" ;;
        *)
            log_error "Unsupported OS: $os"
            log_error "ZViz only supports Linux"
            exit 1
            ;;
    esac
}

# Get latest version from GitHub API
get_latest_version() {
    local url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local version

    if command -v curl &>/dev/null; then
        version=$(curl -fsSL "$url" 2>/dev/null | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
    elif command -v wget &>/dev/null; then
        version=$(wget -qO- "$url" 2>/dev/null | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
    else
        log_error "Neither curl nor wget found. Please install one."
        exit 1
    fi

    if [[ -z "$version" ]]; then
        log_error "Failed to determine latest version from GitHub"
        log_error "You may need to specify a version with --version"
        exit 1
    fi

    echo "$version"
}

# Download file with progress
download() {
    local url="$1"
    local dest="$2"

    log_info "Downloading: $url"

    if command -v curl &>/dev/null; then
        curl -fSL --progress-bar -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url"
    fi
}

# Verify checksum
verify_checksum() {
    local file="$1"
    local checksums_file="$2"
    local filename
    filename=$(basename "$file")

    local expected
    expected=$(grep "$filename" "$checksums_file" 2>/dev/null | awk '{print $1}')

    if [[ -z "$expected" ]]; then
        log_warn "No checksum found for $filename in checksums file"
        return 1
    fi

    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')

    if [[ "$expected" != "$actual" ]]; then
        log_error "Checksum mismatch!"
        log_error "Expected: $expected"
        log_error "Actual:   $actual"
        return 1
    fi

    log_info "Checksum verified"
    return 0
}

# Check kernel requirements
check_requirements() {
    log_step "Checking system requirements..."

    # OS check
    detect_os >/dev/null

    # Kernel version check
    local kernel_version major minor
    kernel_version=$(uname -r | cut -d. -f1-2)
    major=$(echo "$kernel_version" | cut -d. -f1)
    minor=$(echo "$kernel_version" | cut -d. -f2)

    if [[ $major -lt 5 ]] || [[ $major -eq 5 && $minor -lt 6 ]]; then
        log_error "Kernel version >= 5.6 required (found: $(uname -r))"
        log_error "seccomp user notification requires kernel 5.6+"
        exit 1
    fi
    log_info "Kernel version: $(uname -r)"

    # Check for required kernel features (optional)
    if [[ -f /proc/config.gz ]]; then
        if zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_SECCOMP_FILTER=y"; then
            log_info "seccomp filter support detected"
        fi
    fi
}

# Main installation
install_zviz() {
    local arch version binary_name download_url checksums_url

    arch=$(detect_arch)

    if [[ -z "$ZVIZ_VERSION" ]]; then
        log_step "Determining latest version..."
        version=$(get_latest_version)
    else
        version="$ZVIZ_VERSION"
    fi

    log_info "Installing ZViz v${version}"
    log_info "Architecture: ${arch}-linux-musl"

    # Use musl for static binary portability
    binary_name="zviz-${arch}-musl"
    download_url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/${binary_name}"
    checksums_url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/checksums.sha256"

    # Create temp directory
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    # Download binary
    log_step "Downloading ZViz..."
    download "$download_url" "$tmpdir/$binary_name"

    # Verify checksum
    if [[ "$VERIFY_CHECKSUM" == "true" ]]; then
        log_step "Verifying checksum..."
        download "$checksums_url" "$tmpdir/checksums.sha256"
        if ! verify_checksum "$tmpdir/$binary_name" "$tmpdir/checksums.sha256"; then
            log_error "Checksum verification failed. Use --no-verify to skip."
            exit 1
        fi
    else
        log_warn "Skipping checksum verification"
    fi

    # Install
    log_step "Installing to ${INSTALL_PREFIX}/bin/zviz..."

    if [[ $EUID -ne 0 ]]; then
        log_warn "Not running as root, using sudo for installation"
        sudo mkdir -p "${INSTALL_PREFIX}/bin"
        sudo install -m 755 "$tmpdir/$binary_name" "${INSTALL_PREFIX}/bin/zviz"
        sudo mkdir -p "$STATE_DIR"
    else
        mkdir -p "${INSTALL_PREFIX}/bin"
        install -m 755 "$tmpdir/$binary_name" "${INSTALL_PREFIX}/bin/zviz"
        mkdir -p "$STATE_DIR"
    fi

    # Verify installation
    if "${INSTALL_PREFIX}/bin/zviz" version &>/dev/null; then
        log_info "ZViz v${version} installed successfully!"
    else
        log_warn "Binary installed but version check failed (may need root to run)"
    fi
}

# Configure containerd
configure_containerd() {
    log_step "Configuring containerd..."

    if ! command -v containerd &>/dev/null; then
        log_warn "containerd not found - skipping configuration"
        return
    fi

    if [[ $EUID -ne 0 ]]; then
        log_error "Root privileges required to configure containerd"
        exit 1
    fi

    if [[ ! -f "$CONTAINERD_CONFIG" ]]; then
        log_warn "containerd config not found at $CONTAINERD_CONFIG"
        log_warn "Creating new config..."
        mkdir -p "$(dirname "$CONTAINERD_CONFIG")"
        containerd config default > "$CONTAINERD_CONFIG"
    fi

    # Backup existing config
    cp "$CONTAINERD_CONFIG" "${CONTAINERD_CONFIG}.backup.$(date +%s)"
    log_info "Backed up existing config"

    # Check if zviz runtime already configured
    if grep -q "runtimes.zviz" "$CONTAINERD_CONFIG"; then
        log_warn "ZViz runtime already configured in containerd"
    else
        # Add ZViz runtime configuration
        cat >> "$CONTAINERD_CONFIG" << 'EOF'

# ZViz Runtime Configuration (added by install.sh)
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz]
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz.options]
    BinaryName = "/usr/local/bin/zviz"
    SystemdCgroup = true
EOF
        log_info "Added ZViz runtime to containerd config"
    fi

    # Restart containerd
    if systemctl is-active containerd &>/dev/null; then
        log_info "Restarting containerd..."
        systemctl restart containerd
        sleep 2
        if systemctl is-active containerd &>/dev/null; then
            log_info "containerd restarted successfully"
        else
            log_error "containerd failed to restart"
            exit 1
        fi
    else
        log_warn "containerd is not running. Start it manually after installation."
    fi
}

# Configure Kubernetes RuntimeClass
configure_kubernetes() {
    log_step "Creating Kubernetes RuntimeClass..."

    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found - skipping RuntimeClass creation"
        return
    fi

    kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zviz
handler: zviz
EOF
    log_info "RuntimeClass 'zviz' created"
}

# Uninstall
uninstall() {
    log_step "Uninstalling ZViz..."

    local zviz_bin="${INSTALL_PREFIX}/bin/zviz"

    if [[ $EUID -ne 0 ]]; then
        log_warn "Not running as root, using sudo for uninstallation"
        if [[ -f "$zviz_bin" ]]; then
            sudo rm -f "$zviz_bin"
            log_info "Removed $zviz_bin"
        fi
    else
        if [[ -f "$zviz_bin" ]]; then
            rm -f "$zviz_bin"
            log_info "Removed $zviz_bin"
        fi
    fi

    # Remove RuntimeClass if kubectl available
    if command -v kubectl &>/dev/null; then
        kubectl delete runtimeclass zviz 2>/dev/null || true
        log_info "Removed RuntimeClass"
    fi

    log_warn "containerd configuration not removed - edit $CONTAINERD_CONFIG manually"
    log_info "Uninstall complete"
}

# Usage
usage() {
    cat <<EOF
ZViz Installer

Downloads and installs ZViz from GitHub Releases.

Usage:
  curl -fsSL https://raw.githubusercontent.com/Skelf-Research/zviz/main/deploy/install.sh | sh
  curl -fsSL ... | sh -s -- [OPTIONS]

Options:
  --version VERSION    Install specific version (default: latest)
  --prefix PATH        Installation prefix (default: /usr/local)
  --no-verify          Skip checksum verification
  --configure          Also configure containerd and Kubernetes RuntimeClass
  --uninstall          Remove ZViz
  --help               Show this help message

Examples:
  # Install latest version
  curl -fsSL https://raw.githubusercontent.com/Skelf-Research/zviz/main/deploy/install.sh | sh

  # Install specific version
  curl -fsSL ... | sh -s -- --version 0.1.0

  # Install to custom location
  curl -fsSL ... | sh -s -- --prefix /opt/zviz

  # Install and configure containerd/Kubernetes (requires root)
  curl -fsSL ... | sudo sh -s -- --configure

Environment Variables:
  INSTALL_PREFIX       Installation prefix (default: /usr/local)

For more information, visit: https://github.com/Skelf-Research/zviz
EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                ZVIZ_VERSION="$2"
                shift 2
                ;;
            --prefix)
                INSTALL_PREFIX="$2"
                shift 2
                ;;
            --no-verify)
                VERIFY_CHECKSUM=false
                shift
                ;;
            --configure)
                CONFIGURE_RUNTIME=true
                shift
                ;;
            --uninstall)
                uninstall
                exit 0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Print success message
print_success() {
    echo ""
    log_info "Installation complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify installation:  zviz version"
    echo "  2. Check system:         zviz validate"
    echo ""
    echo "For Kubernetes integration:"
    echo "  curl -fsSL ... | sudo sh -s -- --configure"
    echo ""
    echo "Documentation: https://github.com/Skelf-Research/zviz"
    echo ""
}

# Entry point
main() {
    echo ""
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║       ZViz Installer                  ║"
    echo "  ║  High-performance container isolation ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo ""

    parse_args "$@"
    check_requirements
    install_zviz

    if [[ "$CONFIGURE_RUNTIME" == "true" ]]; then
        configure_containerd
        configure_kubernetes
    fi

    print_success
}

main "$@"
