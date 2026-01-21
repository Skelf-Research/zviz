# Installation

This guide covers installing ZViz on various platforms.

## Quick Install

The fastest way to install ZViz:

```bash
curl -fsSL https://zviz.io/install.sh | sh
```

This script:

1. Detects your architecture (x86_64 or aarch64)
2. Downloads the latest release
3. Installs to `/usr/local/bin/zviz`
4. Verifies the binary signature

## Manual Installation

### Download Binary

Download the appropriate binary for your system:

=== "x86_64"

    ```bash
    curl -LO https://github.com/zviz/zviz/releases/latest/download/zviz-x86_64-linux-musl
    chmod +x zviz-x86_64-linux-musl
    sudo mv zviz-x86_64-linux-musl /usr/local/bin/zviz
    ```

=== "aarch64"

    ```bash
    curl -LO https://github.com/zviz/zviz/releases/latest/download/zviz-aarch64-linux-musl
    chmod +x zviz-aarch64-linux-musl
    sudo mv zviz-aarch64-linux-musl /usr/local/bin/zviz
    ```

### Verify Installation

```bash
zviz version
```

Expected output:
```
zviz version 0.1.0
zig version 0.15.2
```

## Build from Source

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.0 or later
- Git

### Build Steps

```bash
# Clone the repository
git clone https://github.com/zviz/zviz.git
cd zviz

# Build release binary
zig build -Doptimize=ReleaseSafe

# Install
sudo cp zig-out/bin/zviz /usr/local/bin/
```

### Build Options

| Option | Description |
|--------|-------------|
| `-Doptimize=Debug` | Debug build with symbols |
| `-Doptimize=ReleaseSafe` | Release with safety checks |
| `-Doptimize=ReleaseFast` | Maximum performance |
| `-Doptimize=ReleaseSmall` | Minimum binary size |

### Cross-Compilation

Build for a different target:

```bash
# Build for aarch64
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

## Package Managers

### Debian/Ubuntu

```bash
# Add repository
curl -fsSL https://zviz.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/zviz.gpg
echo "deb [signed-by=/usr/share/keyrings/zviz.gpg] https://apt.zviz.io stable main" | \
  sudo tee /etc/apt/sources.list.d/zviz.list

# Install
sudo apt update
sudo apt install zviz
```

### Fedora/RHEL

```bash
# Add repository
sudo dnf config-manager --add-repo https://rpm.zviz.io/zviz.repo

# Install
sudo dnf install zviz
```

### Container Image

For containerized deployments:

```bash
docker pull ghcr.io/zviz/zviz:latest
```

## System Configuration

### Enable Required Kernel Features

Check that required features are enabled:

```bash
# Check seccomp
grep CONFIG_SECCOMP_FILTER /boot/config-$(uname -r)

# Check user namespaces
cat /proc/sys/kernel/unprivileged_userns_clone
# Should be: 1

# Check cgroups v2
mount | grep cgroup2
```

### Configure cgroups v2

If using systemd, cgroups v2 should be enabled by default. Otherwise:

```bash
# Add to kernel boot parameters
GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1"
```

### Set Up AppArmor (Optional)

For LSM-based enforcement:

```bash
# Install AppArmor
sudo apt install apparmor apparmor-utils

# Enable and start
sudo systemctl enable apparmor
sudo systemctl start apparmor
```

## Validate Installation

Run the validation suite to check your system:

```bash
zviz validate
```

Expected output:
```
[INFO] Checking host security requirements...
[PASS] Kernel version: 6.1.0 (>= 5.15 required)
[PASS] Seccomp user notification: available
[PASS] User namespaces: enabled
[PASS] cgroups v2: mounted at /sys/fs/cgroup
[PASS] AppArmor: enabled
[PASS] Landlock: available (ABI v3)

All checks passed! ZViz is ready to use.
```

## Uninstallation

### Binary Install

```bash
sudo rm /usr/local/bin/zviz
sudo rm -rf /var/lib/zviz
sudo rm -rf /etc/zviz
```

### Package Manager

=== "Debian/Ubuntu"

    ```bash
    sudo apt remove zviz
    ```

=== "Fedora/RHEL"

    ```bash
    sudo dnf remove zviz
    ```

## Next Steps

- [Quick Start Guide](quickstart.md)
- [First Container Tutorial](first-container.md)
- [containerd Integration](../operator-guide/containerd.md)
