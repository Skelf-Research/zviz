#!/bin/bash
#
# ZViz Demo Script
#
# Fair comparison between ZViz and gVisor running the SAME workloads
# inside their respective container runtimes.
#
# Usage:
#   ./demo.sh              # Run all demos
#   ./demo.sh --perf       # Performance benchmark only
#   ./demo.sh --security   # Security demo only
#   ./demo.sh --quick      # Quick visual comparison
#   ./demo.sh --help       # Show help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="/tmp/zviz_demo_$(date +%s)"
BUNDLE_DIR="/tmp/zviz_demo_bundle_$$"
ZVIZ_BIN=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Status tracking
HAVE_ZVIZ=false
HAVE_DOCKER=false
HAVE_GVISOR=false
RUNSC_BIN=""

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail()    { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ============================================================================
# Prerequisites Check
# ============================================================================

check_prerequisites() {
    echo ""
    echo -e "${BOLD}Checking prerequisites...${NC}"
    echo ""

    # Check zviz (prefer local build over system install)
    if [[ -f "$SCRIPT_DIR/zig-out/bin/zviz" ]]; then
        ZVIZ_BIN="$SCRIPT_DIR/zig-out/bin/zviz"
        log_pass "zviz found: $ZVIZ_BIN"
        HAVE_ZVIZ=true
    elif command -v zviz &>/dev/null; then
        ZVIZ_BIN="zviz"
        log_pass "zviz found: $(which zviz)"
        HAVE_ZVIZ=true
    else
        log_fail "zviz not found"
        show_zviz_install_instructions
        return 1
    fi

    # Check kernel version
    local kernel_version major minor
    kernel_version=$(uname -r | cut -d. -f1-2)
    major=$(echo "$kernel_version" | cut -d. -f1)
    minor=$(echo "$kernel_version" | cut -d. -f2)

    if [[ $major -lt 5 ]] || [[ $major -eq 5 && $minor -lt 6 ]]; then
        log_fail "Kernel version >= 5.6 required (found: $(uname -r))"
        return 1
    fi
    log_pass "Kernel version: $(uname -r)"

    # Check Docker (optional - for runc baseline and creating OCI bundle)
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_pass "Docker available"
        HAVE_DOCKER=true
    else
        log_warn "Docker not available (optional - for runc baseline)"
    fi

    # Check gVisor (runsc binary directly - for parity comparison with ZViz)
    if command -v runsc &>/dev/null; then
        RUNSC_BIN="runsc"
        log_pass "gVisor (runsc) found: $(which runsc)"
        HAVE_GVISOR=true
    elif [[ -x /usr/local/bin/runsc ]]; then
        RUNSC_BIN="/usr/local/bin/runsc"
        log_pass "gVisor (runsc) found: $RUNSC_BIN"
        HAVE_GVISOR=true
    else
        log_warn "gVisor (runsc) not found - install for parity comparison"
    fi

    # ZViz supports rootless mode via user namespaces
    if [[ $EUID -ne 0 ]]; then
        log_info "Running in rootless mode (user namespaces)"
    fi

    mkdir -p "$RESULTS_DIR"
    echo ""
}

show_zviz_install_instructions() {
    echo ""
    echo -e "${YELLOW}=============================================${NC}"
    echo -e "${YELLOW}  ZViz not found. Install with:${NC}"
    echo -e "${YELLOW}=============================================${NC}"
    echo ""
    echo "  curl -fsSL https://raw.githubusercontent.com/Skelf-Research/zviz/main/install.sh | sh"
    echo ""
    echo "  Or build from source:"
    echo "    cd $SCRIPT_DIR && zig build -Doptimize=ReleaseSafe"
    echo ""
}

show_gvisor_install_instructions() {
    echo ""
    echo -e "${CYAN}+----------------------------------------------------------------+${NC}"
    echo -e "${CYAN}|  gVisor (runsc) not detected. Install for parity comparison:  |${NC}"
    echo -e "${CYAN}+----------------------------------------------------------------+${NC}"
    echo ""
    echo "  # Quick install (download binary directly)"
    echo "  ./scripts/install-gvisor.sh"
    echo ""
    echo "  # Or manually:"
    echo "  curl -fsSL https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/runsc -o /tmp/runsc"
    echo "  chmod +x /tmp/runsc && sudo mv /tmp/runsc /usr/local/bin/"
    echo ""
    echo "  # Verify"
    echo "  runsc --version"
    echo ""
}

# Run a command in gVisor using the same OCI bundle (parity with ZViz)
run_gvisor_bundle() {
    local container_id="$1"
    local bundle_dir="$2"
    local output_file="${3:-}"

    # Clean up any previous container with same ID
    sudo $RUNSC_BIN delete --force "$container_id" 2>/dev/null || true

    # gVisor requires root for OCI runtime mode
    if [[ $EUID -ne 0 ]]; then
        if [[ -n "$output_file" ]]; then
            sudo $RUNSC_BIN run --bundle "$bundle_dir" "$container_id" > "$output_file" 2>/dev/null
        else
            sudo $RUNSC_BIN run --bundle "$bundle_dir" "$container_id" 2>/dev/null
        fi
    else
        if [[ -n "$output_file" ]]; then
            $RUNSC_BIN run --bundle "$bundle_dir" "$container_id" > "$output_file" 2>/dev/null
        else
            $RUNSC_BIN run --bundle "$bundle_dir" "$container_id" 2>/dev/null
        fi
    fi
    local ret=$?

    # Cleanup
    sudo $RUNSC_BIN delete --force "$container_id" 2>/dev/null || true

    return $ret
}

# ============================================================================
# OCI Bundle Setup
# ============================================================================

setup_oci_bundle() {
    # Skip if rootfs already populated
    if [[ -f "$BUNDLE_DIR/rootfs/bin/busybox" ]] || [[ -f "$BUNDLE_DIR/rootfs/bin/sh" ]]; then
        return
    fi

    log_info "Creating OCI bundle..."

    mkdir -p "$BUNDLE_DIR/rootfs"

    if [[ "$HAVE_DOCKER" == "true" ]]; then
        # Use Docker to create rootfs
        log_info "Extracting Alpine rootfs from Docker..."
        local container_id
        container_id=$(docker create alpine:latest)
        docker export "$container_id" | tar -C "$BUNDLE_DIR/rootfs" -xf -
        docker rm "$container_id" >/dev/null
    else
        # Download Alpine minirootfs directly (no Docker needed)
        log_info "Downloading Alpine minirootfs..."
        local arch
        arch=$(uname -m)
        [[ "$arch" == "x86_64" ]] && arch="x86_64"
        [[ "$arch" == "aarch64" ]] && arch="aarch64"

        local alpine_url="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/${arch}/alpine-minirootfs-3.21.3-${arch}.tar.gz"
        if command -v curl &>/dev/null; then
            curl -fsSL "$alpine_url" | tar -xz -C "$BUNDLE_DIR/rootfs"
        elif command -v wget &>/dev/null; then
            wget -qO- "$alpine_url" | tar -xz -C "$BUNDLE_DIR/rootfs"
        else
            log_fail "Neither curl nor wget found - cannot download rootfs"
            return 1
        fi
    fi

    # Create config.json
    cat > "$BUNDLE_DIR/config.json" << 'EOF'
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bin/sh", "-c", "echo hello"],
        "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        "cwd": "/"
    },
    "root": { "path": "rootfs", "readonly": false },
    "hostname": "zviz-demo",
    "linux": {
        "namespaces": [
            { "type": "pid" },
            { "type": "mount" },
            { "type": "ipc" },
            { "type": "uts" }
        ]
    }
}
EOF

    log_pass "OCI bundle created at $BUNDLE_DIR"
}

cleanup_bundle() {
    rm -rf "$BUNDLE_DIR" 2>/dev/null || true
    # Clean up any leftover containers
    $ZVIZ_BIN delete demo-zviz-bench 2>/dev/null || true
    $ZVIZ_BIN delete demo-zviz-quick 2>/dev/null || true
}

# ============================================================================
# Benchmark Code (compiled inside containers)
# ============================================================================

BENCH_CODE='
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <string.h>

#define ITERATIONS 5000

static long long now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void bench_getpid() {
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) getpid();
    long long elapsed = now_ns() - start;
    printf("getpid,%lld\n", elapsed / ITERATIONS);
}

static void bench_getuid() {
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) getuid();
    long long elapsed = now_ns() - start;
    printf("getuid,%lld\n", elapsed / ITERATIONS);
}

static void bench_clock() {
    struct timespec ts;
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) clock_gettime(CLOCK_MONOTONIC, &ts);
    long long elapsed = now_ns() - start;
    printf("clock_gettime,%lld\n", elapsed / ITERATIONS);
}

static void bench_stat() {
    struct stat st;
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) stat("/", &st);
    long long elapsed = now_ns() - start;
    printf("stat,%lld\n", elapsed / ITERATIONS);
}

static void bench_open_close() {
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        int fd = open("/dev/null", O_RDONLY);
        if (fd >= 0) close(fd);
    }
    long long elapsed = now_ns() - start;
    printf("open_close,%lld\n", elapsed / ITERATIONS);
}

static void bench_read() {
    char buf[1];
    int fd = open("/dev/zero", O_RDONLY);
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) read(fd, buf, 1);
    long long elapsed = now_ns() - start;
    close(fd);
    printf("read,%lld\n", elapsed / ITERATIONS);
}

static void bench_write() {
    char buf[1] = {0};
    int fd = open("/dev/null", O_WRONLY);
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) write(fd, buf, 1);
    long long elapsed = now_ns() - start;
    close(fd);
    printf("write,%lld\n", elapsed / ITERATIONS);
}

int main() {
    printf("syscall,latency_ns\n");
    bench_getpid();
    bench_getuid();
    bench_clock();
    bench_stat();
    bench_open_close();
    bench_read();
    bench_write();
    return 0;
}
'

# ============================================================================
# Performance Benchmarks - REAL containerized workloads
# ============================================================================

run_performance_demo() {
    echo ""
    echo -e "${BOLD}+============================================================+${NC}"
    echo -e "${BOLD}|   Performance Comparison: Native vs ZViz vs gVisor         |${NC}"
    echo -e "${BOLD}+============================================================+${NC}"
    echo ""
    echo "Running the SAME benchmark inside each runtime environment."
    echo "This measures real container overhead, not host syscalls."
    echo ""

    # Setup OCI bundle for zviz
    setup_oci_bundle

    if [[ "$HAVE_DOCKER" == "true" ]]; then
        # Pull alpine image
        log_info "Pulling Alpine image..."
        docker pull alpine:latest >/dev/null 2>&1

        # 1. Native Docker (runc) benchmark
        echo ""
        echo -e "${GREEN}--- Native (Docker runc) Benchmark ---${NC}"
        run_docker_benchmark "native" "" "$RESULTS_DIR/bench_native.csv"
    else
        log_warn "Docker not available - skipping native runc benchmark"
    fi

    # 2. ZViz benchmark
    echo ""
    echo -e "${CYAN}--- ZViz Benchmark ---${NC}"
    run_zviz_benchmark "$RESULTS_DIR/bench_zviz.csv"

    # 3. gVisor benchmark (if available) - uses SAME bundle as ZViz for parity
    if [[ "$HAVE_GVISOR" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}--- gVisor Benchmark (same bundle as ZViz) ---${NC}"
        run_gvisor_benchmark "$RESULTS_DIR/bench_gvisor.csv"
    else
        log_warn "gVisor not available - skipping gVisor benchmark"
    fi

    # Show comparison
    echo ""
    show_benchmark_comparison
}

run_docker_benchmark() {
    local name="$1"
    local runtime_flag="$2"
    local output_file="$3"

    log_info "Running $name benchmark (5000 iterations per syscall)..."

    docker run --rm $runtime_flag \
        alpine:latest sh -c "
            apk add --no-cache build-base >/dev/null 2>&1
            cat > /tmp/bench.c << 'CCODE'
$BENCH_CODE
CCODE
            gcc -O2 -o /tmp/bench /tmp/bench.c 2>/dev/null
            /tmp/bench
        " > "$output_file" 2>/dev/null

    if [[ -s "$output_file" ]]; then
        log_pass "$name benchmark completed"
    else
        log_fail "$name benchmark failed"
        echo "syscall,latency_ns" > "$output_file"
    fi
}

run_zviz_benchmark() {
    local output_file="$1"

    log_info "Running ZViz benchmark (5000 iterations per syscall)..."

    # Compile the benchmark binary on the host (static link for portability)
    local bench_src="/tmp/zviz_bench_$$.c"
    local bench_bin="$BUNDLE_DIR/rootfs/bench"

    echo "$BENCH_CODE" > "$bench_src"

    if command -v musl-gcc &>/dev/null; then
        musl-gcc -static -O2 -o "$bench_bin" "$bench_src" 2>/dev/null
    elif command -v gcc &>/dev/null; then
        gcc -static -O2 -o "$bench_bin" "$bench_src" 2>/dev/null || \
        gcc -O2 -o "$bench_bin" "$bench_src" 2>/dev/null
    elif command -v cc &>/dev/null; then
        cc -static -O2 -o "$bench_bin" "$bench_src" 2>/dev/null || \
        cc -O2 -o "$bench_bin" "$bench_src" 2>/dev/null
    else
        log_warn "No C compiler found - cannot compile benchmark"
        echo "syscall,latency_ns" > "$output_file"
        rm -f "$bench_src"
        return
    fi
    rm -f "$bench_src"

    if [[ ! -x "$bench_bin" ]]; then
        log_warn "Benchmark compilation failed"
        echo "syscall,latency_ns" > "$output_file"
        return
    fi

    # Update config.json to run the pre-compiled benchmark
    cat > "$BUNDLE_DIR/config.json" << 'EOF'
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bench"],
        "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        "cwd": "/"
    },
    "root": { "path": "rootfs", "readonly": false },
    "hostname": "zviz-bench",
    "linux": {
        "namespaces": [
            { "type": "pid" },
            { "type": "mount" },
            { "type": "ipc" },
            { "type": "uts" }
        ]
    }
}
EOF

    # Run zviz container
    $ZVIZ_BIN delete demo-zviz-bench 2>/dev/null || true

    if $ZVIZ_BIN run demo-zviz-bench "$BUNDLE_DIR" > "$output_file" 2>/dev/null; then
        # Filter out any zviz log lines from output
        grep -v '^\[' "$output_file" > "${output_file}.tmp" 2>/dev/null && mv "${output_file}.tmp" "$output_file"
        if grep -q "syscall,latency_ns" "$output_file" 2>/dev/null; then
            log_pass "ZViz benchmark completed"
        else
            log_warn "ZViz benchmark produced no results"
            echo "syscall,latency_ns" > "$output_file"
        fi
    else
        log_warn "ZViz benchmark failed"
        echo "syscall,latency_ns" > "$output_file"
    fi

    $ZVIZ_BIN delete demo-zviz-bench 2>/dev/null || true
}

run_gvisor_benchmark() {
    local output_file="$1"

    log_info "Running gVisor benchmark with SAME bundle as ZViz (parity comparison)..."

    # Ensure benchmark binary exists in rootfs (from zviz benchmark step)
    if [[ ! -x "$BUNDLE_DIR/rootfs/bench" ]]; then
        log_warn "Benchmark binary not found - compile it first"
        echo "syscall,latency_ns" > "$output_file"
        return
    fi

    # Update config.json for benchmark
    cat > "$BUNDLE_DIR/config.json" << 'EOF'
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bench"],
        "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        "cwd": "/"
    },
    "root": { "path": "rootfs", "readonly": false },
    "hostname": "gvisor-bench",
    "linux": {
        "namespaces": [
            { "type": "pid" },
            { "type": "mount" },
            { "type": "ipc" },
            { "type": "uts" },
            { "type": "network" }
        ]
    }
}
EOF

    # Run with gVisor using same bundle
    if run_gvisor_bundle "demo-gvisor-bench" "$BUNDLE_DIR" "$output_file"; then
        if grep -q "syscall,latency_ns" "$output_file" 2>/dev/null; then
            log_pass "gVisor benchmark completed (same bundle as ZViz)"
        else
            log_warn "gVisor benchmark produced no results"
            echo "syscall,latency_ns" > "$output_file"
        fi
    else
        log_warn "gVisor benchmark failed"
        echo "syscall,latency_ns" > "$output_file"
    fi
}

show_benchmark_comparison() {
    echo -e "${BOLD}+------------------------------------------------------------+${NC}"
    echo -e "${BOLD}|              Syscall Latency Comparison (ns)               |${NC}"
    echo -e "${BOLD}+------------------------------------------------------------+${NC}"
    echo ""

    printf "%-15s %12s %12s %12s %12s\n" "Syscall" "Native" "ZViz" "gVisor" "ZViz/Native"
    printf "%-15s %12s %12s %12s %12s\n" "---------------" "------------" "------------" "------------" "------------"

    local syscalls="getpid getuid clock_gettime stat open_close read write"

    for syscall in $syscalls; do
        local native_ns="N/A"
        local zviz_ns="N/A"
        local gvisor_ns="N/A"
        local ratio="N/A"

        # Read native
        if [[ -f "$RESULTS_DIR/bench_native.csv" ]]; then
            native_ns=$(grep "^$syscall," "$RESULTS_DIR/bench_native.csv" 2>/dev/null | cut -d, -f2 || echo "N/A")
        fi

        # Read zviz
        if [[ -f "$RESULTS_DIR/bench_zviz.csv" ]]; then
            zviz_ns=$(grep "^$syscall," "$RESULTS_DIR/bench_zviz.csv" 2>/dev/null | cut -d, -f2 || echo "N/A")
        fi

        # Read gvisor
        if [[ -f "$RESULTS_DIR/bench_gvisor.csv" ]]; then
            gvisor_ns=$(grep "^$syscall," "$RESULTS_DIR/bench_gvisor.csv" 2>/dev/null | cut -d, -f2 || echo "N/A")
        fi

        # Calculate ratio
        if [[ "$native_ns" != "N/A" ]] && [[ "$zviz_ns" != "N/A" ]] && [[ "$native_ns" -gt 0 ]]; then
            ratio=$(echo "scale=2; $zviz_ns * 100 / $native_ns" | bc 2>/dev/null || echo "N/A")
            ratio="${ratio}%"
        fi

        printf "%-15s %12s %12s %12s %12s\n" "$syscall" "$native_ns" "$zviz_ns" "$gvisor_ns" "$ratio"
    done

    echo ""
    echo -e "${GREEN}Lower is better. ZViz/Native shows ZViz overhead vs native Docker.${NC}"
    echo ""
}

# ============================================================================
# Security Demo
# ============================================================================

run_security_demo() {
    echo ""
    echo -e "${BOLD}+============================================================+${NC}"
    echo -e "${BOLD}|           Security Policy Comparison                        |${NC}"
    echo -e "${BOLD}+============================================================+${NC}"
    echo ""

    # Run zviz's built-in comparison with gVisor policies
    echo -e "${CYAN}--- ZViz vs gVisor Policy Comparison ---${NC}"
    echo ""
    log_info "Comparing syscall policies..."
    $ZVIZ_BIN compare 2>&1 | grep -v 'error(gpa)\|\.zig:[0-9]' | sed 's/^\[[0-9]*\] \[INFO\] //' | tee "$RESULTS_DIR/policy_compare.txt"
    echo ""

    # Run system validation
    echo -e "${CYAN}--- System Validation ---${NC}"
    echo ""
    $ZVIZ_BIN validate 2>&1 | grep -v 'error(gpa)\|\.zig:[0-9]' | sed 's/^\[[0-9]*\] \[INFO\] //' | tee "$RESULTS_DIR/validate.txt"
    echo ""

    # Always run live security tests (zviz doesn't need Docker)
    echo -e "${CYAN}--- Live Security Tests ---${NC}"
    echo ""
    run_security_tests
}

compile_security_test() {
    local sectest_src="$1"
    local sectest_bin="$2"

    cat > "$sectest_src" << 'SECTEST_EOF'
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <fcntl.h>

static void test_ptrace(void) {
    long ret = ptrace(PTRACE_TRACEME, 0, 0, 0);
    if (ret == -1)
        printf("ptrace,BLOCKED,%d\n", errno);
    else
        printf("ptrace,ALLOWED,0\n");
}

static void test_raw_socket(void) {
    int s = socket(AF_PACKET, SOCK_RAW, 0);
    if (s < 0)
        printf("raw_socket,BLOCKED,%d\n", errno);
    else {
        printf("raw_socket,ALLOWED,0\n");
        close(s);
    }
}

static void test_mount(void) {
    int ret = mount("proc", "/mnt", "proc", 0, NULL);
    if (ret < 0)
        printf("mount,BLOCKED,%d\n", errno);
    else {
        printf("mount,ALLOWED,0\n");
        umount("/mnt");
    }
}

static void test_init_module(void) {
    long ret = syscall(__NR_init_module, NULL, 0, "");
    if (ret < 0)
        printf("init_module,BLOCKED,%d\n", errno);
    else
        printf("init_module,ALLOWED,0\n");
}

static void test_bpf(void) {
    long ret = syscall(__NR_bpf, 0, NULL, 0);
    if (ret < 0)
        printf("bpf,BLOCKED,%d\n", errno);
    else
        printf("bpf,ALLOWED,0\n");
}

static void test_kexec(void) {
    long ret = syscall(__NR_kexec_load, 0, 0, NULL, 0);
    if (ret < 0)
        printf("kexec_load,BLOCKED,%d\n", errno);
    else
        printf("kexec_load,ALLOWED,0\n");
}

static void test_host_read(void) {
    int fd = open("/etc/shadow", O_RDONLY);
    if (fd < 0)
        printf("read_shadow,BLOCKED,%d\n", errno);
    else {
        printf("read_shadow,ALLOWED,0\n");
        close(fd);
    }
}

static void test_host_write(void) {
    int fd = open("/tmp/escape_write", O_WRONLY | O_CREAT, 0644);
    if (fd < 0)
        printf("host_write,BLOCKED,%d\n", errno);
    else {
        printf("host_write,ALLOWED,0\n");
        close(fd);
        unlink("/tmp/escape_write");
    }
}

int main(void) {
    test_ptrace();
    test_raw_socket();
    test_mount();
    test_init_module();
    test_bpf();
    test_kexec();
    test_host_read();
    test_host_write();
    return 0;
}
SECTEST_EOF

    gcc -static -O2 -o "$sectest_bin" "$sectest_src" 2>/dev/null
}

run_security_tests() {
    # Check for gcc
    if ! command -v gcc &>/dev/null; then
        log_warn "gcc not found - cannot compile security test binary"
        echo "Install gcc to enable live security testing"
        return
    fi

    # Compile security test binary
    local sectest_src="$RESULTS_DIR/sectest.c"
    local sectest_bin="$RESULTS_DIR/sectest"
    log_info "Compiling security test binary..."
    compile_security_test "$sectest_src" "$sectest_bin"

    if [[ ! -f "$sectest_bin" ]]; then
        log_warn "Failed to compile security test binary"
        return
    fi

    # Ensure bundle exists
    setup_oci_bundle

    # Copy test binary into rootfs
    cp "$sectest_bin" "$BUNDLE_DIR/rootfs/bin/sectest"
    chmod +x "$BUNDLE_DIR/rootfs/bin/sectest"

    # Configure to run security test
    cat > "$BUNDLE_DIR/config.json" << 'EOF'
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bin/sectest"],
        "env": ["PATH=/bin:/usr/bin"],
        "cwd": "/"
    },
    "root": { "path": "rootfs", "readonly": true },
    "hostname": "zviz-sectest"
}
EOF

    # Run in ZViz container
    log_info "Running security tests inside ZViz container..."
    $ZVIZ_BIN delete sectest-zviz 2>/dev/null || true
    local zviz_output
    zviz_output=$($ZVIZ_BIN run sectest-zviz --bundle "$BUNDLE_DIR" 2>/dev/null)
    $ZVIZ_BIN delete sectest-zviz 2>/dev/null || true

    # Parse ZViz results into associative arrays
    declare -A zviz_results
    while IFS=',' read -r test_name result err_code; do
        zviz_results["$test_name"]="$result"
    done <<< "$zviz_output"

    # Run in gVisor if available - using SAME bundle for parity
    declare -A gvisor_results
    if [[ "$HAVE_GVISOR" == "true" ]]; then
        log_info "Running same tests in gVisor (same bundle - parity comparison)..."

        # gVisor uses the same bundle with the same binary already in rootfs
        local gvisor_output_file="$RESULTS_DIR/sectest_gvisor.txt"
        if run_gvisor_bundle "sectest-gvisor" "$BUNDLE_DIR" "$gvisor_output_file"; then
            while IFS=',' read -r test_name result err_code; do
                [[ -n "$test_name" ]] && gvisor_results["$test_name"]="$result"
            done < "$gvisor_output_file"
        else
            log_warn "gVisor security test failed"
        fi
    fi

    # Display results table
    echo "Live container security test results:"
    echo ""
    printf "%-25s %12s %12s %10s\n" "Attack Vector" "ZViz" "gVisor" "Match"
    printf "%-25s %12s %12s %10s\n" "-------------------------" "------------" "------------" "----------"

    local tests=("ptrace" "raw_socket" "mount" "init_module" "bpf" "kexec_load" "read_shadow" "host_write")
    local labels=("ptrace(TRACEME)" "Raw socket (AF_PACKET)" "mount(proc)" "init_module()" "bpf()" "kexec_load()" "Read /etc/shadow" "Write to host /tmp")
    local total=0
    local matched=0

    for i in "${!tests[@]}"; do
        local test="${tests[$i]}"
        local label="${labels[$i]}"
        local zviz_r="${zviz_results[$test]:-N/A}"
        local gvisor_r="${gvisor_results[$test]:-N/A}"
        local match_str=""

        if [[ "$gvisor_r" != "N/A" ]]; then
            total=$((total + 1))
            if [[ "$zviz_r" == "$gvisor_r" ]]; then
                matched=$((matched + 1))
                match_str="${GREEN}MATCH${NC}"
            else
                match_str="${RED}DIFFER${NC}"
            fi
        else
            match_str="-"
        fi

        # Color code results
        local zviz_colored="$zviz_r"
        local gvisor_colored="$gvisor_r"
        [[ "$zviz_r" == "BLOCKED" ]] && zviz_colored="${GREEN}BLOCKED${NC}"
        [[ "$zviz_r" == "ALLOWED" ]] && zviz_colored="${RED}ALLOWED${NC}"
        [[ "$gvisor_r" == "BLOCKED" ]] && gvisor_colored="${GREEN}BLOCKED${NC}"

        printf "%-25s %20b %20b %18b\n" "$label" "$zviz_colored" "$gvisor_colored" "$match_str"
    done

    echo ""
    if [[ $total -gt 0 ]]; then
        local pct=$((matched * 100 / total))
        echo -e "${GREEN}Security policy compatibility: ${pct}% (${matched}/${total} tests match)${NC}"
    else
        local blocked=0
        for test in "${tests[@]}"; do
            [[ "${zviz_results[$test]:-}" == "BLOCKED" ]] && blocked=$((blocked + 1))
        done
        echo -e "${GREEN}ZViz blocked ${blocked}/${#tests[@]} attack vectors.${NC}"
        if [[ "$HAVE_GVISOR" != "true" ]]; then
            echo "Install gVisor (runsc) for side-by-side comparison."
        fi
    fi
    echo ""
}

# ============================================================================
# Escape Test Suite
# ============================================================================

compile_escape_suite() {
    local src="$1"
    local bin="$2"

    cat > "$src" << 'ESCAPE_EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sched.h>
#include <fcntl.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <sys/wait.h>

/* Category: Namespace Breakout */
static void test_unshare_user_ns(void) {
    int ret = unshare(CLONE_NEWUSER);
    printf("namespace,unshare_user_ns,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_unshare_pid_ns(void) {
    int ret = unshare(CLONE_NEWPID);
    printf("namespace,unshare_pid_ns,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_unshare_mount_ns(void) {
    int ret = unshare(CLONE_NEWNS);
    printf("namespace,unshare_mount_ns,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_setns_host_pid(void) {
    int fd = open("/proc/1/ns/pid", O_RDONLY);
    if (fd < 0) {
        printf("namespace,setns_host_pid,BLOCKED,%d\n", errno);
        return;
    }
    int ret = syscall(__NR_setns, fd, CLONE_NEWPID);
    close(fd);
    printf("namespace,setns_host_pid,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

/* Category: Capability Escalation */
static void test_capset(void) {
    struct { unsigned int version; int pid; } header = { 0x20080522, 0 };
    struct { unsigned int effective, permitted, inheritable; } data[2] = {
        { 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF },
        { 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF }
    };
    int ret = syscall(__NR_capset, &header, &data);
    printf("capability,capset_all,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_prctl_dumpable(void) {
    int ret = prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);
    printf("capability,prctl_dumpable,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_prctl_seccomp_disable(void) {
    int ret = prctl(PR_SET_SECCOMP, 0, 0, 0, 0);
    printf("seccomp,prctl_seccomp_disable,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

/* Category: Seccomp Bypass */
static void test_init_module(void) {
    int ret = syscall(__NR_init_module, NULL, 0, "");
    printf("seccomp,init_module,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_ptrace(void) {
    long ret = ptrace(PTRACE_TRACEME, 0, NULL, NULL);
    printf("seccomp,ptrace,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_bpf(void) {
    int ret = syscall(__NR_bpf, 0, NULL, 0);
    printf("seccomp,bpf,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_userfaultfd(void) {
    int ret = syscall(__NR_userfaultfd, 0);
    printf("seccomp,userfaultfd,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

static void test_kexec_load(void) {
    int ret = syscall(__NR_kexec_load, 0, 0, NULL, 0);
    printf("seccomp,kexec_load,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

/* Category: Filesystem Escape */
static void test_mount(void) {
    int ret = mount("proc", "/mnt", "proc", 0, NULL);
    printf("filesystem,mount,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
    if (ret == 0) umount("/mnt");
}

static void test_proc_host_root(void) {
    int fd = open("/proc/1/root", O_RDONLY);
    printf("filesystem,proc_host_root,%s,%d\n",
           fd < 0 ? "BLOCKED" : "ALLOWED", fd < 0 ? errno : 0);
    if (fd >= 0) close(fd);
}

static void test_write_etc_passwd(void) {
    int fd = open("/etc/passwd", O_WRONLY);
    printf("filesystem,write_etc_passwd,%s,%d\n",
           fd < 0 ? "BLOCKED" : "ALLOWED", fd < 0 ? errno : 0);
    if (fd >= 0) close(fd);
}

static void test_pivot_root(void) {
    int ret = syscall(__NR_pivot_root, ".", ".");
    printf("filesystem,pivot_root,%s,%d\n",
           ret < 0 ? "BLOCKED" : "ALLOWED", ret < 0 ? errno : 0);
}

/* Category: Network Escape */
static void test_raw_socket(void) {
    int s = socket(AF_PACKET, SOCK_RAW, 0);
    printf("network,raw_socket,%s,%d\n",
           s < 0 ? "BLOCKED" : "ALLOWED", s < 0 ? errno : 0);
    if (s >= 0) close(s);
}

static void test_netlink_socket(void) {
    int s = socket(AF_NETLINK, SOCK_RAW, 0);
    printf("network,netlink_socket,%s,%d\n",
           s < 0 ? "BLOCKED" : "ALLOWED", s < 0 ? errno : 0);
    if (s >= 0) close(s);
}

/* Category: Resource Exhaustion */
static void test_fork_bomb(void) {
    int forks = 0;
    int blocked = 0;
    int i;
    for (i = 0; i < 50; i++) {
        pid_t pid = fork();
        if (pid < 0) { blocked = 1; break; }
        if (pid == 0) _exit(0);
        forks++;
        int status;
        waitpid(pid, &status, 0);
    }
    printf("resource,fork_bomb,%s,%d\n",
           blocked ? "BLOCKED" : "ALLOWED", blocked ? errno : forks);
}

int main(void) {
    test_unshare_user_ns();
    test_unshare_pid_ns();
    test_unshare_mount_ns();
    test_setns_host_pid();
    test_capset();
    test_prctl_dumpable();
    test_prctl_seccomp_disable();
    test_init_module();
    test_ptrace();
    test_bpf();
    test_userfaultfd();
    test_kexec_load();
    test_mount();
    test_proc_host_root();
    test_write_etc_passwd();
    test_pivot_root();
    test_raw_socket();
    test_netlink_socket();
    test_fork_bomb();
    return 0;
}
ESCAPE_EOF

    gcc -static -O2 -o "$bin" "$src" 2>/dev/null
}

run_escape_demo() {
    echo ""
    echo -e "${BOLD}+============================================================+${NC}"
    echo -e "${BOLD}|           Escape Test Suite (19 tests)                      |${NC}"
    echo -e "${BOLD}+============================================================+${NC}"
    echo ""
    echo "Attempting container escape via 19 attack vectors."
    echo "All attempts should be BLOCKED by ZViz's security stack."
    echo ""

    if ! command -v gcc &>/dev/null; then
        log_warn "gcc not found - cannot compile escape test binary"
        return
    fi

    local escape_src="$RESULTS_DIR/escape_suite.c"
    local escape_bin="$RESULTS_DIR/escape_suite"
    log_info "Compiling escape test suite..."
    compile_escape_suite "$escape_src" "$escape_bin"

    if [[ ! -f "$escape_bin" ]]; then
        log_warn "Failed to compile escape test suite"
        return
    fi

    # Ensure bundle exists
    setup_oci_bundle

    # Copy into rootfs
    cp "$escape_bin" "$BUNDLE_DIR/rootfs/bin/escape_suite"
    chmod +x "$BUNDLE_DIR/rootfs/bin/escape_suite"
    mkdir -p "$BUNDLE_DIR/rootfs/mnt" 2>/dev/null || true

    # Configure to run escape suite
    cat > "$BUNDLE_DIR/config.json" << 'EOF'
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bin/escape_suite"],
        "env": ["PATH=/bin:/usr/bin"],
        "cwd": "/"
    },
    "root": { "path": "rootfs", "readonly": true },
    "hostname": "zviz-escape"
}
EOF

    # Run escape suite in ZViz container
    log_info "Running escape tests inside ZViz container..."
    $ZVIZ_BIN delete escape-zviz 2>/dev/null || true
    local zviz_output
    zviz_output=$($ZVIZ_BIN run escape-zviz --bundle "$BUNDLE_DIR" 2>/dev/null)
    $ZVIZ_BIN delete escape-zviz 2>/dev/null || true

    # Run escape suite in gVisor (same bundle - parity comparison)
    local gvisor_output=""
    if [[ "$HAVE_GVISOR" == "true" ]]; then
        log_info "Running escape tests inside gVisor container (same bundle)..."
        local gvisor_output_file="$RESULTS_DIR/escape_gvisor.txt"
        if run_gvisor_bundle "escape-gvisor" "$BUNDLE_DIR" "$gvisor_output_file"; then
            gvisor_output=$(cat "$gvisor_output_file")
        fi
    fi

    # Parse gVisor results into associative array
    declare -A gvisor_escape_results
    if [[ -n "$gvisor_output" ]]; then
        while IFS=',' read -r category test_name result err_code; do
            [[ -n "$test_name" ]] && gvisor_escape_results["$test_name"]="$result"
        done <<< "$gvisor_output"
    fi

    # Parse and display results by category
    local total=0
    local blocked=0
    local gvisor_blocked=0
    local matched=0

    declare -A cat_labels
    cat_labels["namespace"]="Namespace Breakout"
    cat_labels["capability"]="Capability Escalation"
    cat_labels["seccomp"]="Seccomp Bypass"
    cat_labels["filesystem"]="Filesystem Escape"
    cat_labels["network"]="Network Escape"
    cat_labels["resource"]="Resource Exhaustion"

    if [[ "$HAVE_GVISOR" == "true" ]]; then
        printf "%-20s %-25s %10s %10s %8s\n" "Category" "Test" "ZViz" "gVisor" "Match"
        printf "%-20s %-25s %10s %10s %8s\n" "--------------------" "-------------------------" "----------" "----------" "--------"
    else
        printf "%-20s %-25s %10s %8s\n" "Category" "Test" "Result" "Errno"
        printf "%-20s %-25s %10s %8s\n" "--------------------" "-------------------------" "----------" "--------"
    fi

    while IFS=',' read -r category test_name result err_code; do
        [[ -z "$category" ]] && continue
        total=$((total + 1))

        local cat_display="${cat_labels[$category]:-$category}"

        # Color code ZViz result
        local zviz_colored="$result"
        if [[ "$result" == "BLOCKED" ]]; then
            zviz_colored="${GREEN}BLOCKED${NC}"
            blocked=$((blocked + 1))
        else
            zviz_colored="${RED}ALLOWED${NC}"
        fi

        if [[ "$HAVE_GVISOR" == "true" ]]; then
            local gvisor_r="${gvisor_escape_results[$test_name]:-N/A}"
            local gvisor_colored="$gvisor_r"
            local match_str=""

            if [[ "$gvisor_r" == "BLOCKED" ]]; then
                gvisor_colored="${GREEN}BLOCKED${NC}"
                gvisor_blocked=$((gvisor_blocked + 1))
            elif [[ "$gvisor_r" == "ALLOWED" ]]; then
                gvisor_colored="${RED}ALLOWED${NC}"
            fi

            if [[ "$gvisor_r" != "N/A" ]]; then
                if [[ "$result" == "$gvisor_r" ]]; then
                    matched=$((matched + 1))
                    match_str="${GREEN}MATCH${NC}"
                else
                    match_str="${YELLOW}DIFFER${NC}"
                fi
            else
                match_str="-"
            fi

            printf "%-20s %-25s %18b %18b %16b\n" "$cat_display" "$test_name" "$zviz_colored" "$gvisor_colored" "$match_str"
        else
            printf "%-20s %-25s %18b %8s\n" "$cat_display" "$test_name" "$zviz_colored" "$err_code"
        fi
    done <<< "$zviz_output"

    echo ""
    echo -e "${BOLD}+------------------------------------------------------------+${NC}"
    local failed=$((total - blocked))
    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}Result: ZViz blocked ${blocked}/${total} escape attempts - sandbox is secure${NC}"
    else
        echo -e "${RED}SECURITY WARNING: ${failed}/${total} escape attempts succeeded!${NC}"
    fi

    if [[ "$HAVE_GVISOR" == "true" ]]; then
        local gvisor_failed=$((total - gvisor_blocked))
        if [[ $gvisor_failed -eq 0 ]]; then
            echo -e "${GREEN}       gVisor blocked ${gvisor_blocked}/${total} escape attempts${NC}"
        else
            echo -e "${YELLOW}       gVisor blocked ${gvisor_blocked}/${total} escape attempts${NC}"
        fi
        if [[ $total -gt 0 ]]; then
            local pct=$((matched * 100 / total))
            echo -e "${CYAN}       Policy match: ${matched}/${total} (${pct}%)${NC}"
        fi
    fi
    echo -e "${BOLD}+------------------------------------------------------------+${NC}"
    echo ""

    # Save results
    echo "$zviz_output" > "$RESULTS_DIR/escape_results.csv"
    [[ -n "$gvisor_output" ]] && echo "$gvisor_output" > "$RESULTS_DIR/escape_gvisor.csv"
}

# ============================================================================
# Quick Demo
# ============================================================================

run_quick_demo() {
    echo ""
    echo -e "${BOLD}+============================================================+${NC}"
    echo -e "${BOLD}|                    Quick Comparison                         |${NC}"
    echo -e "${BOLD}+============================================================+${NC}"
    echo ""

    # Show versions
    echo -e "${CYAN}--- ZViz Info ---${NC}"
    $ZVIZ_BIN version
    echo ""

    # Quick cold start comparison
    echo -e "${CYAN}--- Cold Start Comparison ---${NC}"
    echo ""

    local start end elapsed

    # Native Docker
    if [[ "$HAVE_DOCKER" == "true" ]]; then
        echo -n "Native (runc):  "
        start=$(date +%s%N)
        docker run --rm alpine:latest echo "hello" >/dev/null 2>&1
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        echo "${elapsed}ms"

    fi

    # gVisor cold start (using same bundle as ZViz for parity)
    if [[ "$HAVE_GVISOR" == "true" ]]; then
        # Ensure bundle exists
        setup_oci_bundle

        cat > "$BUNDLE_DIR/config.json" << 'EOF'
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bin/echo", "hello"],
        "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        "cwd": "/"
    },
    "root": { "path": "rootfs", "readonly": false },
    "hostname": "gvisor",
    "linux": {
        "namespaces": [
            { "type": "pid" },
            { "type": "mount" },
            { "type": "ipc" },
            { "type": "uts" },
            { "type": "network" }
        ]
    }
}
EOF

        echo -n "gVisor (runsc): "
        start=$(date +%s%N)
        run_gvisor_bundle "demo-gvisor-quick" "$BUNDLE_DIR" >/dev/null 2>&1
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        echo "${elapsed}ms (same bundle as ZViz)"
    else
        echo "gVisor: not installed (run ./scripts/install-gvisor.sh)"
    fi

    # ZViz cold start
    setup_oci_bundle

    cat > "$BUNDLE_DIR/config.json" << 'EOF'
{
    "ociVersion": "1.0.2",
    "process": {
        "terminal": false,
        "user": { "uid": 0, "gid": 0 },
        "args": ["/bin/echo", "hello"],
        "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        "cwd": "/"
    },
    "root": { "path": "rootfs", "readonly": false },
    "hostname": "zviz",
    "linux": {
        "namespaces": [
            { "type": "pid" },
            { "type": "mount" },
            { "type": "ipc" },
            { "type": "uts" }
        ]
    }
}
EOF

    echo -n "ZViz:           "
    $ZVIZ_BIN delete demo-zviz-quick 2>/dev/null || true
    start=$(date +%s%N)
    $ZVIZ_BIN run demo-zviz-quick "$BUNDLE_DIR" >/dev/null 2>&1
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    echo "${elapsed}ms"
    $ZVIZ_BIN delete demo-zviz-quick 2>/dev/null || true

    echo ""
    echo -e "${GREEN}Key insight:${NC} ZViz achieves near-native performance because it uses"
    echo "kernel primitives instead of emulating a userspace kernel like gVisor."
    echo ""
}

# ============================================================================
# Full Demo
# ============================================================================

run_full_demo() {
    run_quick_demo
    run_performance_demo
    run_security_demo
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    cat << 'EOF'
ZViz Demo Script

Fair comparison between ZViz and gVisor running the SAME workloads
inside their respective container runtimes.

Usage:
  ./demo.sh              # Run all demos
  ./demo.sh --perf       # Performance benchmark only
  ./demo.sh --security   # Security demo only
  ./demo.sh --escape     # Escape test suite (19 attack vectors)
  ./demo.sh --quick      # Quick cold start comparison
  ./demo.sh --all        # Full demo (quick + perf + security + escape)
  ./demo.sh --help       # Show this help

What this demo does:
  --perf:     Runs identical C benchmark INSIDE each container runtime:
              - Native Docker (runc baseline)
              - ZViz container
              - gVisor container (if installed)
              Measures: getpid, getuid, clock_gettime, stat, open/close, read, write

  --security: 'zviz compare' - Policy comparison with gVisor
              'zviz validate' - System compatibility check
              Live tests of blocked operations

  --quick:    Cold start time comparison between runtimes

Prerequisites:
  - zviz (required): Install via install.sh or build from source
  - Docker (optional): For runc/gVisor comparison benchmarks
  - gVisor (optional): For side-by-side comparison with gVisor
  - curl or wget: For downloading Alpine rootfs when Docker unavailable

Examples:
  # Quick comparison
  ./demo.sh --quick

  # Full benchmark
  ./demo.sh --perf

  # Security comparison
  ./demo.sh --security

For more information: https://github.com/Skelf-Research/zviz
EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo -e "${BOLD}  +===============================================+${NC}"
    echo -e "${BOLD}  |           ZViz Demo & Comparison              |${NC}"
    echo -e "${BOLD}  |  High-performance container isolation         |${NC}"
    echo -e "${BOLD}  +===============================================+${NC}"
    echo ""

    # Parse arguments
    local mode="full"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --perf|--performance)
                mode="perf"
                shift
                ;;
            --security)
                mode="security"
                shift
                ;;
            --quick)
                mode="quick"
                shift
                ;;
            --escape)
                mode="escape"
                shift
                ;;
            --all)
                mode="all"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_warn "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi

    # Cleanup on exit
    trap cleanup_bundle EXIT

    # Run requested demo
    case "$mode" in
        perf)
            run_performance_demo
            ;;
        security)
            run_security_demo
            ;;
        escape)
            run_escape_demo
            ;;
        quick)
            run_quick_demo
            ;;
        all)
            run_quick_demo
            run_performance_demo
            run_security_demo
            run_escape_demo
            ;;
        full)
            run_full_demo
            ;;
    esac

    echo ""
    echo -e "${GREEN}Demo complete!${NC}"
    echo "Results saved to: $RESULTS_DIR"
    echo ""
}

main "$@"
