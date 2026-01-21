Name:           zviz
Version:        0.1.0
Release:        1%{?dist}
Summary:        High-performance container isolation runtime

License:        Apache-2.0
URL:            https://github.com/Skelf-Research/zviz
Source0:        zviz

BuildArch:      x86_64 aarch64

Recommends:     containerd >= 1.6
Suggests:       selinux-policy

%description
ZViz is a Zig-based container runtime that delivers gVisor-grade
security with near-native performance. It uses layered kernel
enforcement (namespaces, seccomp, LSMs, cgroups) instead of
syscall emulation.

Features:
- gVisor-equivalent policy outcomes
- Less than 5% overhead for network workloads
- Kubernetes RuntimeClass integration
- Profile-driven security policies
- Small memory footprint (+2MB vs +50MB for gVisor)

%prep
# No prep needed, binary is pre-built

%build
# No build needed, binary is pre-built

%install
mkdir -p %{buildroot}%{_bindir}
install -m 755 %{SOURCE0} %{buildroot}%{_bindir}/zviz

mkdir -p %{buildroot}%{_datadir}/zviz
# RuntimeClass file would be copied here if available

%files
%{_bindir}/zviz

%post
# Create state directory
mkdir -p /run/zviz

echo ""
echo "========================================"
echo "  ZViz installed successfully!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Verify installation:  zviz version"
echo "  2. Check system:         zviz validate"
echo ""
echo "For Kubernetes integration, create a RuntimeClass:"
echo "  kubectl apply -f - <<EOF"
echo "  apiVersion: node.k8s.io/v1"
echo "  kind: RuntimeClass"
echo "  metadata:"
echo "    name: zviz"
echo "  handler: zviz"
echo "  EOF"
echo ""
echo "Documentation: https://github.com/Skelf-Research/zviz"
echo ""

%postun
if [ $1 -eq 0 ]; then
    # Package removal (not upgrade)
    rm -rf /run/zviz 2>/dev/null || true
fi

%changelog
* Tue Jan 21 2026 Skelf Research <team@skelf.io> - 0.1.0-1
- Initial release
- Five-layer security enforcement (namespaces, seccomp, LSM, cgroups, network)
- Kubernetes RuntimeClass support
- Built-in security profiles
- containerd integration
- Near-native performance (<5% overhead)
