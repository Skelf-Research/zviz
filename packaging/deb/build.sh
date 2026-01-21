#!/bin/bash
#
# ZViz Debian Package Build Script
#
# Usage:
#   ./build.sh                    # Build for current architecture
#   ./build.sh 0.2.0              # Build specific version
#   ./build.sh 0.2.0 arm64        # Build specific version and architecture
#
# Prerequisites:
#   - debhelper, devscripts packages installed
#   - Pre-built binary available (local or will download from GitHub)

set -euo pipefail

VERSION="${1:-0.1.0}"
ARCH="${2:-$(dpkg --print-architecture)}"
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

# Map Debian architecture to Zig architecture
map_arch() {
    case "$1" in
        amd64)   echo "x86_64" ;;
        arm64)   echo "aarch64" ;;
        *)
            log_error "Unsupported architecture: $1"
            exit 1
            ;;
    esac
}

ZIG_ARCH=$(map_arch "$ARCH")
BINARY_NAME="zviz-${ZIG_ARCH}-musl"
BUILD_DIR="$SCRIPT_DIR/build-${ARCH}"

log_info "Building ZViz $VERSION for $ARCH (Zig: $ZIG_ARCH)"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy debian directory
cp -r "$SCRIPT_DIR/debian" "$BUILD_DIR/"

# Get binary - check local build first, then download
if [[ -f "$PROJECT_ROOT/zig-out/bin/$BINARY_NAME" ]]; then
    log_info "Using local binary: $PROJECT_ROOT/zig-out/bin/$BINARY_NAME"
    cp "$PROJECT_ROOT/zig-out/bin/$BINARY_NAME" "$BUILD_DIR/zviz"
elif [[ -f "$PROJECT_ROOT/zig-out/bin/zviz" ]] && [[ "$ARCH" == "$(dpkg --print-architecture)" ]]; then
    log_info "Using local binary: $PROJECT_ROOT/zig-out/bin/zviz"
    cp "$PROJECT_ROOT/zig-out/bin/zviz" "$BUILD_DIR/zviz"
else
    log_info "Downloading binary from GitHub Releases..."
    DOWNLOAD_URL="https://github.com/Skelf-Research/zviz/releases/download/v${VERSION}/${BINARY_NAME}"

    if ! curl -fSL -o "$BUILD_DIR/zviz" "$DOWNLOAD_URL"; then
        log_error "Failed to download binary from $DOWNLOAD_URL"
        log_error "Build the binary locally first: zig build -Dtarget=${ZIG_ARCH}-linux-musl -Doptimize=ReleaseSafe"
        exit 1
    fi
fi

chmod +x "$BUILD_DIR/zviz"

# Update changelog version
sed -i "1s/zviz ([^)]*)/zviz (${VERSION}-1)/" "$BUILD_DIR/debian/changelog"
sed -i "1s/stable/${ARCH}/" "$BUILD_DIR/debian/changelog"

cd "$BUILD_DIR"

# Build the package
log_info "Building Debian package..."

# Use dpkg-buildpackage for building
if command -v dpkg-buildpackage &>/dev/null; then
    dpkg-buildpackage -us -uc -b --host-arch="$ARCH" 2>&1 || {
        log_warn "dpkg-buildpackage failed, trying fakeroot approach..."

        # Manual package creation as fallback
        PKG_DIR="$BUILD_DIR/zviz_${VERSION}-1_${ARCH}"
        mkdir -p "$PKG_DIR/DEBIAN"
        mkdir -p "$PKG_DIR/usr/bin"
        mkdir -p "$PKG_DIR/usr/share/zviz"

        # Copy files
        cp "$BUILD_DIR/zviz" "$PKG_DIR/usr/bin/"
        cp "$PROJECT_ROOT/deploy/kubernetes/runtime-class.yaml" "$PKG_DIR/usr/share/zviz/" 2>/dev/null || true

        # Create control file
        cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: zviz
Version: ${VERSION}-1
Architecture: ${ARCH}
Maintainer: Skelf Research <team@skelf.io>
Description: High-performance container isolation runtime
 ZViz is a Zig-based container runtime that delivers gVisor-grade
 security with near-native performance.
Homepage: https://github.com/Skelf-Research/zviz
Section: admin
Priority: optional
EOF

        # Copy maintainer scripts
        cp "$BUILD_DIR/debian/postinst" "$PKG_DIR/DEBIAN/" 2>/dev/null || true
        cp "$BUILD_DIR/debian/postrm" "$PKG_DIR/DEBIAN/" 2>/dev/null || true
        chmod 755 "$PKG_DIR/DEBIAN/postinst" "$PKG_DIR/DEBIAN/postrm" 2>/dev/null || true

        # Build package
        fakeroot dpkg-deb --build "$PKG_DIR"
        mv "${PKG_DIR}.deb" "$SCRIPT_DIR/"
    }
else
    log_error "dpkg-buildpackage not found. Install devscripts package."
    exit 1
fi

# Find and report the built package
DEB_FILE=$(find "$SCRIPT_DIR" -maxdepth 2 -name "zviz_${VERSION}*.deb" -type f 2>/dev/null | head -1)

if [[ -n "$DEB_FILE" ]]; then
    log_info "Package built successfully!"
    log_info "Output: $DEB_FILE"
    echo ""
    echo "To install:"
    echo "  sudo dpkg -i $DEB_FILE"
    echo ""
    echo "To verify:"
    echo "  dpkg -I $DEB_FILE"
else
    log_warn "Package may have been built in parent directory"
    ls -la "$SCRIPT_DIR"/../*.deb 2>/dev/null || true
fi
