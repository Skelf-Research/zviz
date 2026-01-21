#!/bin/bash
#
# ZViz RPM Package Build Script
#
# Usage:
#   ./build.sh                    # Build for current architecture
#   ./build.sh 0.2.0              # Build specific version
#   ./build.sh 0.2.0 aarch64      # Build specific version and architecture
#
# Prerequisites:
#   - rpm-build package installed
#   - Pre-built binary available (local or will download from GitHub)

set -euo pipefail

VERSION="${1:-0.1.0}"
ARCH="${2:-$(uname -m)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Normalize architecture name
normalize_arch() {
    case "$1" in
        x86_64|amd64)    echo "x86_64" ;;
        aarch64|arm64)   echo "aarch64" ;;
        *)
            log_error "Unsupported architecture: $1"
            exit 1
            ;;
    esac
}

ARCH=$(normalize_arch "$ARCH")
BINARY_NAME="zviz-${ARCH}-musl"

log_info "Building ZViz $VERSION RPM for $ARCH"

# Setup rpmbuild directory structure
RPMBUILD_DIR="$HOME/rpmbuild"
mkdir -p "$RPMBUILD_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Get binary - check local build first, then download
if [[ -f "$PROJECT_ROOT/zig-out/bin/$BINARY_NAME" ]]; then
    log_info "Using local binary: $PROJECT_ROOT/zig-out/bin/$BINARY_NAME"
    cp "$PROJECT_ROOT/zig-out/bin/$BINARY_NAME" "$RPMBUILD_DIR/SOURCES/zviz"
elif [[ -f "$PROJECT_ROOT/zig-out/bin/zviz" ]] && [[ "$ARCH" == "$(uname -m)" ]]; then
    log_info "Using local binary: $PROJECT_ROOT/zig-out/bin/zviz"
    cp "$PROJECT_ROOT/zig-out/bin/zviz" "$RPMBUILD_DIR/SOURCES/zviz"
else
    log_info "Downloading binary from GitHub Releases..."
    DOWNLOAD_URL="https://github.com/Skelf-Research/zviz/releases/download/v${VERSION}/${BINARY_NAME}"

    if ! curl -fSL -o "$RPMBUILD_DIR/SOURCES/zviz" "$DOWNLOAD_URL"; then
        log_error "Failed to download binary from $DOWNLOAD_URL"
        log_error "Build the binary locally first: zig build -Dtarget=${ARCH}-linux-musl -Doptimize=ReleaseSafe"
        exit 1
    fi
fi

chmod +x "$RPMBUILD_DIR/SOURCES/zviz"

# Update spec file with version and copy to SPECS
sed "s/^Version:.*/Version:        ${VERSION}/" "$SCRIPT_DIR/zviz.spec" > "$RPMBUILD_DIR/SPECS/zviz.spec"

# Build the RPM
log_info "Building RPM package..."

if ! command -v rpmbuild &>/dev/null; then
    log_error "rpmbuild not found. Install rpm-build package:"
    log_error "  Fedora/RHEL: sudo dnf install rpm-build"
    log_error "  Debian/Ubuntu: sudo apt install rpm"
    exit 1
fi

rpmbuild -bb --target="$ARCH" "$RPMBUILD_DIR/SPECS/zviz.spec"

# Find and report the built package
RPM_FILE=$(find "$RPMBUILD_DIR/RPMS/$ARCH" -name "zviz-${VERSION}*.rpm" -type f 2>/dev/null | head -1)

if [[ -n "$RPM_FILE" ]]; then
    log_info "Package built successfully!"
    log_info "Output: $RPM_FILE"
    echo ""
    echo "To install:"
    echo "  sudo rpm -ivh $RPM_FILE"
    echo "  # or"
    echo "  sudo dnf install $RPM_FILE"
    echo ""
    echo "To verify:"
    echo "  rpm -qip $RPM_FILE"

    # Copy to script directory for convenience
    cp "$RPM_FILE" "$SCRIPT_DIR/"
    log_info "Also copied to: $SCRIPT_DIR/$(basename "$RPM_FILE")"
else
    log_error "Failed to find built RPM package"
    ls -la "$RPMBUILD_DIR/RPMS/" 2>/dev/null || true
    exit 1
fi
