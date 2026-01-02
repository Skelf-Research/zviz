#!/bin/bash
#
# gVisor vs Native Performance Benchmark Comparison
# Runs identical workloads on both runtimes and compares performance
#
# Usage:
#   ./tests/benchmark_comparison.sh              # Full benchmark suite
#   ./tests/benchmark_comparison.sh --quick      # Quick comparison
#   ./tests/benchmark_comparison.sh --workload X # Run specific workload
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="/tmp/zigviz_benchmarks_$(date +%s)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_result() { echo -e "${CYAN}[RESULT]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    HAVE_DOCKER=false
    HAVE_GVISOR=false

    if command -v docker &> /dev/null && docker info &> /dev/null; then
        log_pass "Docker available"
        HAVE_DOCKER=true

        if docker info 2>/dev/null | grep -q runsc; then
            log_pass "gVisor runtime configured"
            HAVE_GVISOR=true
        else
            log_warn "gVisor runtime not configured in Docker"
        fi
    else
        log_warn "Docker not available"
    fi

    mkdir -p "$RESULTS_DIR"
}

# ============================================================================
# Benchmark: Syscall Latency
# ============================================================================

benchmark_syscall_latency() {
    local runtime="$1"
    local output_file="$2"
    local runtime_flag=""

    [[ "$runtime" == "gvisor" ]] && runtime_flag="--runtime=runsc"

    log_info "Running syscall latency benchmark ($runtime)..."

    # Use a simple C program for accurate syscall measurement
    docker run --rm $runtime_flag \
        -v "$SCRIPT_DIR:/tests:ro" \
        alpine:latest sh -c '
            # Install build tools
            apk add --no-cache build-base > /dev/null 2>&1

            # Create and compile benchmark
            cat > /tmp/bench.c << "CCODE"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#define ITERATIONS 10000

long long now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

void bench_getpid() {
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        getpid();
    }
    long long elapsed = now_ns() - start;
    printf("getpid,%lld\n", elapsed / ITERATIONS);
}

void bench_getuid() {
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        getuid();
    }
    long long elapsed = now_ns() - start;
    printf("getuid,%lld\n", elapsed / ITERATIONS);
}

void bench_clock() {
    struct timespec ts;
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        clock_gettime(CLOCK_MONOTONIC, &ts);
    }
    long long elapsed = now_ns() - start;
    printf("clock_gettime,%lld\n", elapsed / ITERATIONS);
}

void bench_open_close() {
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        int fd = open("/dev/null", O_RDONLY);
        if (fd >= 0) close(fd);
    }
    long long elapsed = now_ns() - start;
    printf("open_close,%lld\n", elapsed / ITERATIONS);
}

void bench_stat() {
    struct stat st;
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        stat("/", &st);
    }
    long long elapsed = now_ns() - start;
    printf("stat,%lld\n", elapsed / ITERATIONS);
}

void bench_read() {
    char buf[1];
    int fd = open("/dev/zero", O_RDONLY);
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        read(fd, buf, 1);
    }
    long long elapsed = now_ns() - start;
    close(fd);
    printf("read,%lld\n", elapsed / ITERATIONS);
}

void bench_write() {
    char buf[1] = {0};
    int fd = open("/dev/null", O_WRONLY);
    long long start = now_ns();
    for (int i = 0; i < ITERATIONS; i++) {
        write(fd, buf, 1);
    }
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
CCODE
            gcc -O2 -o /tmp/bench /tmp/bench.c
            /tmp/bench
        ' > "$output_file" 2>/dev/null
}

# ============================================================================
# Benchmark: Network Throughput
# ============================================================================

benchmark_network() {
    local runtime="$1"
    local output_file="$2"
    local runtime_flag=""

    [[ "$runtime" == "gvisor" ]] && runtime_flag="--runtime=runsc"

    log_info "Running network benchmark ($runtime)..."

    docker run --rm $runtime_flag \
        alpine:latest sh -c '
            # Simple TCP throughput test using /dev/zero and nc
            apk add --no-cache netcat-openbsd > /dev/null 2>&1

            # Start server in background
            nc -l -p 9999 > /dev/null &
            SERVER_PID=$!
            sleep 0.5

            # Send 10MB of data
            START=$(date +%s%N)
            dd if=/dev/zero bs=1M count=10 2>/dev/null | nc localhost 9999
            END=$(date +%s%N)

            wait $SERVER_PID 2>/dev/null || true

            # Calculate throughput
            ELAPSED_NS=$((END - START))
            BYTES=$((10 * 1024 * 1024))
            MBPS=$(echo "scale=2; $BYTES / 1024 / 1024 / ($ELAPSED_NS / 1000000000)" | bc)

            echo "network_throughput_mbps,$MBPS"
        ' > "$output_file" 2>/dev/null || echo "network_throughput_mbps,0" > "$output_file"
}

# ============================================================================
# Benchmark: Fork/Exec
# ============================================================================

benchmark_fork_exec() {
    local runtime="$1"
    local output_file="$2"
    local runtime_flag=""

    [[ "$runtime" == "gvisor" ]] && runtime_flag="--runtime=runsc"

    log_info "Running fork/exec benchmark ($runtime)..."

    docker run --rm $runtime_flag \
        alpine:latest sh -c '
            START=$(date +%s%N)
            for i in $(seq 1 100); do
                /bin/true
            done
            END=$(date +%s%N)

            ELAPSED_NS=$((END - START))
            AVG_NS=$((ELAPSED_NS / 100))
            echo "fork_exec_ns,$AVG_NS"
        ' > "$output_file" 2>/dev/null
}

# ============================================================================
# Benchmark: File I/O
# ============================================================================

benchmark_file_io() {
    local runtime="$1"
    local output_file="$2"
    local runtime_flag=""

    [[ "$runtime" == "gvisor" ]] && runtime_flag="--runtime=runsc"

    log_info "Running file I/O benchmark ($runtime)..."

    docker run --rm $runtime_flag \
        --tmpfs /tmp:size=512M \
        alpine:latest sh -c '
            # Write test
            START=$(date +%s%N)
            dd if=/dev/zero of=/tmp/testfile bs=1M count=100 conv=fdatasync 2>/dev/null
            END=$(date +%s%N)
            WRITE_NS=$((END - START))
            WRITE_MBPS=$(echo "scale=2; 100 / ($WRITE_NS / 1000000000)" | bc)

            # Read test
            START=$(date +%s%N)
            dd if=/tmp/testfile of=/dev/null bs=1M 2>/dev/null
            END=$(date +%s%N)
            READ_NS=$((END - START))
            READ_MBPS=$(echo "scale=2; 100 / ($READ_NS / 1000000000)" | bc)

            rm -f /tmp/testfile

            echo "file_write_mbps,$WRITE_MBPS"
            echo "file_read_mbps,$READ_MBPS"
        ' > "$output_file" 2>/dev/null
}

# ============================================================================
# Benchmark: Memory
# ============================================================================

benchmark_memory() {
    local runtime="$1"
    local output_file="$2"
    local runtime_flag=""

    [[ "$runtime" == "gvisor" ]] && runtime_flag="--runtime=runsc"

    log_info "Running memory benchmark ($runtime)..."

    docker run --rm $runtime_flag \
        alpine:latest sh -c '
            # Memory allocation/deallocation test
            START=$(date +%s%N)
            for i in $(seq 1 100); do
                # Allocate ~10MB and touch pages
                dd if=/dev/zero bs=10M count=1 2>/dev/null | cat > /dev/null
            done
            END=$(date +%s%N)

            ELAPSED_NS=$((END - START))
            AVG_NS=$((ELAPSED_NS / 100))
            echo "memory_alloc_ns,$AVG_NS"
        ' > "$output_file" 2>/dev/null
}

# ============================================================================
# Compare Results
# ============================================================================

compare_results() {
    echo ""
    echo -e "${BOLD}=============================================="
    echo "   Performance Comparison: gVisor vs Native"
    echo "==============================================${NC}"
    echo ""

    printf "%-25s %15s %15s %12s\n" "Benchmark" "Native" "gVisor" "Overhead"
    printf "%-25s %15s %15s %12s\n" "---------" "------" "------" "--------"

    # Syscall latency
    if [[ -f "$RESULTS_DIR/syscall_native.csv" ]] && [[ -f "$RESULTS_DIR/syscall_gvisor.csv" ]]; then
        while IFS=, read -r syscall native_ns; do
            [[ "$syscall" == "syscall" ]] && continue
            gvisor_ns=$(grep "^$syscall," "$RESULTS_DIR/syscall_gvisor.csv" 2>/dev/null | cut -d, -f2)
            if [[ -n "$gvisor_ns" ]] && [[ -n "$native_ns" ]] && [[ "$native_ns" -gt 0 ]]; then
                overhead=$(echo "scale=1; (($gvisor_ns - $native_ns) * 100) / $native_ns" | bc 2>/dev/null || echo "N/A")
                printf "%-25s %12s ns %12s ns %10s%%\n" "$syscall" "$native_ns" "$gvisor_ns" "$overhead"
            fi
        done < "$RESULTS_DIR/syscall_native.csv"
    fi

    # Network throughput
    if [[ -f "$RESULTS_DIR/network_native.csv" ]] && [[ -f "$RESULTS_DIR/network_gvisor.csv" ]]; then
        native_val=$(grep "network_throughput" "$RESULTS_DIR/network_native.csv" 2>/dev/null | cut -d, -f2)
        gvisor_val=$(grep "network_throughput" "$RESULTS_DIR/network_gvisor.csv" 2>/dev/null | cut -d, -f2)
        if [[ -n "$native_val" ]] && [[ -n "$gvisor_val" ]]; then
            ratio=$(echo "scale=1; ($gvisor_val * 100) / $native_val" | bc 2>/dev/null || echo "N/A")
            printf "%-25s %12s MB/s %10s MB/s %10s%%\n" "network_throughput" "$native_val" "$gvisor_val" "$ratio"
        fi
    fi

    # Fork/exec
    if [[ -f "$RESULTS_DIR/forkexec_native.csv" ]] && [[ -f "$RESULTS_DIR/forkexec_gvisor.csv" ]]; then
        native_val=$(grep "fork_exec" "$RESULTS_DIR/forkexec_native.csv" 2>/dev/null | cut -d, -f2)
        gvisor_val=$(grep "fork_exec" "$RESULTS_DIR/forkexec_gvisor.csv" 2>/dev/null | cut -d, -f2)
        if [[ -n "$native_val" ]] && [[ -n "$gvisor_val" ]] && [[ "$native_val" -gt 0 ]]; then
            overhead=$(echo "scale=1; (($gvisor_val - $native_val) * 100) / $native_val" | bc 2>/dev/null || echo "N/A")
            native_ms=$(echo "scale=2; $native_val / 1000000" | bc)
            gvisor_ms=$(echo "scale=2; $gvisor_val / 1000000" | bc)
            printf "%-25s %12s ms %12s ms %10s%%\n" "fork_exec" "$native_ms" "$gvisor_ms" "$overhead"
        fi
    fi

    # File I/O
    if [[ -f "$RESULTS_DIR/fileio_native.csv" ]] && [[ -f "$RESULTS_DIR/fileio_gvisor.csv" ]]; then
        for metric in file_write_mbps file_read_mbps; do
            native_val=$(grep "$metric" "$RESULTS_DIR/fileio_native.csv" 2>/dev/null | cut -d, -f2)
            gvisor_val=$(grep "$metric" "$RESULTS_DIR/fileio_gvisor.csv" 2>/dev/null | cut -d, -f2)
            if [[ -n "$native_val" ]] && [[ -n "$gvisor_val" ]] && [[ $(echo "$native_val > 0" | bc) -eq 1 ]]; then
                ratio=$(echo "scale=1; ($gvisor_val * 100) / $native_val" | bc 2>/dev/null || echo "N/A")
                printf "%-25s %12s MB/s %10s MB/s %10s%%\n" "$metric" "$native_val" "$gvisor_val" "$ratio"
            fi
        done
    fi

    echo ""
    echo "Results saved to: $RESULTS_DIR"
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
    echo ""
    echo -e "${BOLD}=============================================="
    echo "   Summary"
    echo "==============================================${NC}"
    echo ""

    echo "Key findings:"
    echo ""

    # Calculate average syscall overhead
    if [[ -f "$RESULTS_DIR/syscall_native.csv" ]] && [[ -f "$RESULTS_DIR/syscall_gvisor.csv" ]]; then
        total_native=0
        total_gvisor=0
        count=0
        while IFS=, read -r syscall native_ns; do
            [[ "$syscall" == "syscall" ]] && continue
            gvisor_ns=$(grep "^$syscall," "$RESULTS_DIR/syscall_gvisor.csv" 2>/dev/null | cut -d, -f2)
            if [[ -n "$gvisor_ns" ]] && [[ -n "$native_ns" ]]; then
                total_native=$((total_native + native_ns))
                total_gvisor=$((total_gvisor + gvisor_ns))
                count=$((count + 1))
            fi
        done < "$RESULTS_DIR/syscall_native.csv"

        if [[ $count -gt 0 ]] && [[ $total_native -gt 0 ]]; then
            avg_overhead=$(echo "scale=1; (($total_gvisor - $total_native) * 100) / $total_native" | bc)
            echo "  - Average syscall overhead: ${avg_overhead}%"
        fi
    fi

    # Network comparison
    if [[ -f "$RESULTS_DIR/network_native.csv" ]] && [[ -f "$RESULTS_DIR/network_gvisor.csv" ]]; then
        native_net=$(grep "network_throughput" "$RESULTS_DIR/network_native.csv" 2>/dev/null | cut -d, -f2)
        gvisor_net=$(grep "network_throughput" "$RESULTS_DIR/network_gvisor.csv" 2>/dev/null | cut -d, -f2)
        if [[ -n "$native_net" ]] && [[ -n "$gvisor_net" ]] && [[ $(echo "$native_net > 0" | bc) -eq 1 ]]; then
            ratio=$(echo "scale=2; $native_net / $gvisor_net" | bc 2>/dev/null || echo "N/A")
            echo "  - Native is ${ratio}x faster for network I/O"
        fi
    fi

    echo ""
    echo "ZigViz targets native network performance while matching"
    echo "gVisor's security posture for syscall filtering."
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "=============================================="
    echo "   gVisor Performance Benchmark"
    echo "=============================================="
    echo ""

    check_prerequisites

    if [[ "$HAVE_DOCKER" != "true" ]]; then
        log_warn "Docker not available. Cannot run benchmarks."
        exit 1
    fi

    if [[ "$HAVE_GVISOR" != "true" ]]; then
        log_warn "gVisor not configured. Will only run native benchmarks."
        log_info "To enable gVisor: sudo ./scripts/setup-gvisor-testing.sh"
    fi

    echo ""
    log_info "Running benchmarks (this may take a few minutes)..."
    echo ""

    # Pull alpine image
    docker pull alpine:latest > /dev/null 2>&1

    # Run native benchmarks
    benchmark_syscall_latency "native" "$RESULTS_DIR/syscall_native.csv"
    benchmark_fork_exec "native" "$RESULTS_DIR/forkexec_native.csv"
    benchmark_file_io "native" "$RESULTS_DIR/fileio_native.csv"
    benchmark_network "native" "$RESULTS_DIR/network_native.csv"

    # Run gVisor benchmarks
    if [[ "$HAVE_GVISOR" == "true" ]]; then
        benchmark_syscall_latency "gvisor" "$RESULTS_DIR/syscall_gvisor.csv"
        benchmark_fork_exec "gvisor" "$RESULTS_DIR/forkexec_gvisor.csv"
        benchmark_file_io "gvisor" "$RESULTS_DIR/fileio_gvisor.csv"
        benchmark_network "gvisor" "$RESULTS_DIR/network_gvisor.csv"
    fi

    # Compare and display results
    if [[ "$HAVE_GVISOR" == "true" ]]; then
        compare_results
        print_summary
    else
        echo ""
        log_info "Native benchmark results:"
        echo ""
        cat "$RESULTS_DIR"/*.csv 2>/dev/null || true
    fi
}

# Quick mode
if [[ "$1" == "--quick" ]]; then
    echo "Running quick benchmark (syscall latency only)..."
    check_prerequisites

    if [[ "$HAVE_DOCKER" == "true" ]]; then
        benchmark_syscall_latency "native" "$RESULTS_DIR/syscall_native.csv"
        if [[ "$HAVE_GVISOR" == "true" ]]; then
            benchmark_syscall_latency "gvisor" "$RESULTS_DIR/syscall_gvisor.csv"
            compare_results
        else
            cat "$RESULTS_DIR/syscall_native.csv"
        fi
    fi
    exit 0
fi

# Help
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --quick    Run quick syscall benchmark only"
    echo "  --help     Show this help"
    echo ""
    echo "Prerequisites:"
    echo "  1. Docker installed and running"
    echo "  2. gVisor configured: sudo ./scripts/setup-gvisor-testing.sh"
    exit 0
fi

main "$@"
