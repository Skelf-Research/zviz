# ZViz Packaging

This directory contains scripts and configuration for building ZViz packages for various Linux distributions.

## Supported Formats

| Format | Directory | Distributions |
|--------|-----------|---------------|
| Debian (.deb) | `deb/` | Debian, Ubuntu, Linux Mint, etc. |
| RPM (.rpm) | `rpm/` | Fedora, RHEL, CentOS, Rocky, Alma, openSUSE |

## Prerequisites

### For Debian packages

```bash
# Debian/Ubuntu
sudo apt install debhelper devscripts fakeroot
```

### For RPM packages

```bash
# Fedora/RHEL
sudo dnf install rpm-build

# Debian/Ubuntu (for cross-building)
sudo apt install rpm
```

## Building Packages

### Debian Package

```bash
cd packaging/deb

# Build for current architecture with latest version
./build.sh

# Build specific version
./build.sh 0.2.0

# Build for specific architecture
./build.sh 0.2.0 arm64
```

The script will:
1. Look for a local binary in `zig-out/bin/`
2. If not found, download from GitHub Releases
3. Build the `.deb` package

### RPM Package

```bash
cd packaging/rpm

# Build for current architecture with latest version
./build.sh

# Build specific version
./build.sh 0.2.0

# Build for specific architecture
./build.sh 0.2.0 aarch64
```

The script will:
1. Look for a local binary in `zig-out/bin/`
2. If not found, download from GitHub Releases
3. Build the `.rpm` package in `~/rpmbuild/RPMS/`

## Building from Local Source

To build packages from locally compiled binaries:

```bash
# From project root
zig build release

# Then build packages
cd packaging/deb && ./build.sh
cd packaging/rpm && ./build.sh
```

## CI/CD Integration

Packages are automatically built when a version tag is pushed:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The GitHub Actions workflow will:
1. Build binaries for all architectures
2. Create a GitHub Release
3. Build and attach .deb and .rpm packages

## Package Contents

Both package formats install:

- `/usr/bin/zviz` - The main binary
- `/usr/share/zviz/runtime-class.yaml` - Kubernetes RuntimeClass (Debian only)

Post-installation:
- Creates `/run/zviz` state directory
- Prints setup instructions

## Architecture Support

| Architecture | Debian | RPM |
|--------------|--------|-----|
| x86_64 (amd64) | Yes | Yes |
| aarch64 (arm64) | Yes | Yes |

## Verifying Packages

### Debian

```bash
# Package info
dpkg -I zviz_0.1.0-1_amd64.deb

# List contents
dpkg -c zviz_0.1.0-1_amd64.deb

# Install
sudo dpkg -i zviz_0.1.0-1_amd64.deb

# Remove
sudo dpkg -r zviz
```

### RPM

```bash
# Package info
rpm -qip zviz-0.1.0-1.x86_64.rpm

# List contents
rpm -qlp zviz-0.1.0-1.x86_64.rpm

# Install
sudo rpm -ivh zviz-0.1.0-1.x86_64.rpm
# or
sudo dnf install zviz-0.1.0-1.x86_64.rpm

# Remove
sudo rpm -e zviz
# or
sudo dnf remove zviz
```

## Future: Package Repositories

Setting up APT and YUM repositories is planned for future releases. This will enable:

```bash
# APT (Debian/Ubuntu)
curl -fsSL https://packages.zviz.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/zviz.gpg
echo "deb [signed-by=/usr/share/keyrings/zviz.gpg] https://packages.zviz.io/apt stable main" | sudo tee /etc/apt/sources.list.d/zviz.list
sudo apt update && sudo apt install zviz

# YUM/DNF (Fedora/RHEL)
sudo dnf config-manager --add-repo https://packages.zviz.io/rpm/zviz.repo
sudo dnf install zviz
```
