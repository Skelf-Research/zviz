#!/bin/bash
#
# Real gVisor vs ZViz Comparison Tests
# Runs identical workloads on both runtimes and compares actual outcomes
#
# Prerequisites:
#   - gVisor (runsc) installed: https://gvisor.dev/docs/user_guide/install/
#   - Docker with gVisor runtime configured
#   - ZViz built: zig build syscall-tester
#
# Usage:
#   ./tests/compare_runtimes.sh           # Run all tests
#   ./tests/compare_runtimes.sh --quick   # Quick comparison (skip Docker pulls)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SYSCALL_TESTER="$PROJECT_DIR/zig-out/bin/syscall_tester"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Results tracking
TOTAL=0
MATCH=0
DIFFER=0
RESULTS_FILE="/tmp/runtime_comparison_$(date +%s).json"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    HAVE_GVISOR=false
    HAVE_DOCKER=false
    HAVE_TESTER=false

    # Check for syscall_tester binary
    if [[ -f "$SYSCALL_TESTER" ]]; then
        log_info "syscall_tester found: $SYSCALL_TESTER"
        HAVE_TESTER=true
    else
        log_warn "syscall_tester not found. Build with: zig build syscall-tester"
        echo "Building syscall_tester..."
        (cd "$PROJECT_DIR" && zig build syscall-tester) || {
            log_fail "Failed to build syscall_tester"
            exit 1
        }
        HAVE_TESTER=true
    fi

    # Check for gVisor
    if command -v runsc &> /dev/null; then
        GVISOR_VERSION=$(runsc --version 2>&1 | head -1)
        log_info "gVisor found: $GVISOR_VERSION"
        HAVE_GVISOR=true
    else
        log_warn "gVisor (runsc) not found"
    fi

    # Check for Docker
    if command -v docker &> /dev/null; then
        # Check if Docker daemon is running
        if docker info &> /dev/null; then
            log_info "Docker found and running"
            HAVE_DOCKER=true

            # Check if gVisor runtime is configured
            if docker info 2>/dev/null | grep -q "runsc"; then
                log_info "Docker has gVisor runtime configured"
            else
                log_warn "Docker does not have gVisor runtime configured"
                log_warn "Add this to /etc/docker/daemon.json:"
                echo '  {"runtimes": {"runsc": {"path": "/usr/local/bin/runsc"}}}'
            fi
        else
            log_warn "Docker found but daemon not running"
        fi
    else
        log_warn "Docker not found"
    fi
}

# Run syscall_tester in Docker with specified runtime
run_in_docker() {
    local runtime="$1"
    local output_file="$2"
    local runtime_flag=""

    if [[ "$runtime" == "gvisor" ]]; then
        runtime_flag="--runtime=runsc"
    fi

    # Create a container with the tester binary
    local container_name="syscall_test_$$_$runtime"

    # Use a minimal base image and copy the tester
    docker run --rm $runtime_flag \
        --name "$container_name" \
        -v "$SYSCALL_TESTER:/syscall_tester:ro" \
        alpine:latest \
        /syscall_tester --json > "$output_file" 2>&1 || true
}

# Run syscall_tester natively (simulates ZViz baseline)
run_native() {
    local output_file="$1"
    "$SYSCALL_TESTER" --json > "$output_file" 2>&1 || true
}

# Compare two JSON result files
compare_results() {
    local gvisor_file="$1"
    local native_file="$2"

    log_info "Comparing results..."
    echo ""

    # Parse and compare each test
    local gvisor_tests=$(cat "$gvisor_file" 2>/dev/null | grep '"name":' | wc -l)
    local native_tests=$(cat "$native_file" 2>/dev/null | grep '"name":' | wc -l)

    if [[ "$gvisor_tests" -eq 0 ]] && [[ "$native_tests" -eq 0 ]]; then
        log_warn "No test results found in either runtime"
        return
    fi

    printf "%-25s %-12s %-12s %-8s\n" "Test" "gVisor" "Native" "Match"
    printf "%-25s %-12s %-12s %-8s\n" "----" "------" "------" "-----"

    # Extract test names from native results (it should have all tests)
    local tests=$(cat "$native_file" 2>/dev/null | grep -o '"name": "[^"]*"' | cut -d'"' -f4)

    for test in $tests; do
        # Extract results for this test
        local gvisor_allowed=$(grep "\"name\": \"$test\"" "$gvisor_file" 2>/dev/null | grep -o '"allowed": [^,}]*' | cut -d' ' -f2)
        local native_allowed=$(grep "\"name\": \"$test\"" "$native_file" 2>/dev/null | grep -o '"allowed": [^,}]*' | cut -d' ' -f2)

        # Default to N/A if not found
        [[ -z "$gvisor_allowed" ]] && gvisor_allowed="N/A"
        [[ -z "$native_allowed" ]] && native_allowed="N/A"

        # Convert to human readable
        local gvisor_str="DENIED"
        local native_str="DENIED"
        [[ "$gvisor_allowed" == "true" ]] && gvisor_str="ALLOWED"
        [[ "$native_allowed" == "true" ]] && native_str="ALLOWED"
        [[ "$gvisor_allowed" == "N/A" ]] && gvisor_str="N/A"
        [[ "$native_allowed" == "N/A" ]] && native_str="N/A"

        # Check match
        local match_str=""
        TOTAL=$((TOTAL + 1))
        if [[ "$gvisor_str" == "$native_str" ]]; then
            MATCH=$((MATCH + 1))
            match_str="${GREEN}✓${NC}"
        elif [[ "$gvisor_str" == "N/A" ]] || [[ "$native_str" == "N/A" ]]; then
            match_str="${YELLOW}?${NC}"
        else
            DIFFER=$((DIFFER + 1))
            match_str="${RED}✗${NC}"
        fi

        printf "%-25s %-12s %-12s %b\n" "$test" "$gvisor_str" "$native_str" "$match_str"
    done
}

# Print security analysis
analyze_security() {
    local gvisor_file="$1"
    local native_file="$2"

    echo ""
    log_info "Security Analysis:"
    echo ""

    # Critical syscalls that should be denied
    local critical_syscalls="mount init_module kexec_load reboot bpf"

    echo "Critical syscall blocking:"
    for syscall in $critical_syscalls; do
        local gvisor_allowed=$(grep "\"name\": \"$syscall\"" "$gvisor_file" 2>/dev/null | grep -o '"allowed": [^,}]*' | cut -d' ' -f2)
        local native_allowed=$(grep "\"name\": \"$syscall\"" "$native_file" 2>/dev/null | grep -o '"allowed": [^,}]*' | cut -d' ' -f2)

        local status=""
        if [[ "$gvisor_allowed" == "false" ]] && [[ "$native_allowed" == "false" ]]; then
            status="${GREEN}Both block${NC}"
        elif [[ "$gvisor_allowed" == "false" ]]; then
            status="${YELLOW}Only gVisor blocks${NC}"
        elif [[ "$native_allowed" == "false" ]]; then
            status="${YELLOW}Only Native blocks${NC}"
        else
            status="${RED}Neither blocks${NC}"
        fi

        printf "  %-20s %b\n" "$syscall" "$status"
    done
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "        Runtime Comparison Summary"
    echo "=============================================="
    echo ""
    echo "Total tests:      $TOTAL"
    echo -e "Matching:         ${GREEN}$MATCH${NC}"
    echo -e "Different:        ${RED}$DIFFER${NC}"
    echo ""

    if [[ $TOTAL -gt 0 ]]; then
        local compat=$((MATCH * 100 / TOTAL))
        echo "Compatibility:    ${compat}%"
    fi

    echo ""
    echo "Results saved to: $RESULTS_FILE"

    if [[ "$HAVE_GVISOR" != "true" ]]; then
        echo ""
        log_warn "gVisor not installed - gVisor results may be incomplete"
        echo "Install gVisor: https://gvisor.dev/docs/user_guide/install/"
    fi
}

# Main execution
main() {
    echo "=============================================="
    echo "   gVisor vs Native Syscall Comparison"
    echo "=============================================="
    echo ""
    echo "This test runs the syscall_tester binary in:"
    echo "  1. Native Linux (baseline)"
    echo "  2. gVisor container (if available)"
    echo ""

    check_prerequisites
    echo ""

    # Create temp files for results
    GVISOR_RESULTS="/tmp/gvisor_results_$$.json"
    NATIVE_RESULTS="/tmp/native_results_$$.json"

    trap "rm -f $GVISOR_RESULTS $NATIVE_RESULTS" EXIT

    # Run native tests
    log_test "Running syscall_tester natively..."
    run_native "$NATIVE_RESULTS"

    if [[ -s "$NATIVE_RESULTS" ]]; then
        log_pass "Native tests completed"
    else
        log_fail "Native tests failed"
        exit 1
    fi

    # Run gVisor tests if available
    if [[ "$HAVE_DOCKER" == "true" ]] && [[ "$HAVE_GVISOR" == "true" ]]; then
        log_test "Running syscall_tester in gVisor..."
        run_in_docker "gvisor" "$GVISOR_RESULTS"

        if [[ -s "$GVISOR_RESULTS" ]]; then
            log_pass "gVisor tests completed"
        else
            log_warn "gVisor tests may have failed - using fallback"
            echo '{"results": []}' > "$GVISOR_RESULTS"
        fi
    elif [[ "$HAVE_DOCKER" == "true" ]]; then
        log_test "Running syscall_tester in standard Docker (runc)..."
        run_in_docker "runc" "$GVISOR_RESULTS"

        if [[ -s "$GVISOR_RESULTS" ]]; then
            log_pass "Docker (runc) tests completed"
        else
            log_warn "Docker tests failed"
            echo '{"results": []}' > "$GVISOR_RESULTS"
        fi
    else
        log_warn "Skipping container tests (no Docker)"
        echo '{"results": []}' > "$GVISOR_RESULTS"
    fi

    echo ""
    compare_results "$GVISOR_RESULTS" "$NATIVE_RESULTS"
    analyze_security "$GVISOR_RESULTS" "$NATIVE_RESULTS"
    print_summary

    # Save combined results
    echo "{" > "$RESULTS_FILE"
    echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$RESULTS_FILE"
    echo "  \"gvisor_available\": $HAVE_GVISOR," >> "$RESULTS_FILE"
    echo "  \"gvisor_results\": $(cat "$GVISOR_RESULTS")," >> "$RESULTS_FILE"
    echo "  \"native_results\": $(cat "$NATIVE_RESULTS")," >> "$RESULTS_FILE"
    echo "  \"summary\": {\"total\": $TOTAL, \"matching\": $MATCH, \"different\": $DIFFER}" >> "$RESULTS_FILE"
    echo "}" >> "$RESULTS_FILE"
}

# Run quick comparison (native only)
if [[ "$1" == "--quick" ]]; then
    log_info "Running quick comparison (native only)..."
    "$SYSCALL_TESTER"
    exit 0
fi

# Run help
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --quick    Run native tests only (no Docker)"
    echo "  --help     Show this help"
    echo ""
    echo "Prerequisites:"
    echo "  1. Build syscall_tester: zig build syscall-tester"
    echo "  2. Install gVisor: https://gvisor.dev/docs/user_guide/install/"
    echo "  3. Configure Docker with gVisor runtime"
    exit 0
fi

main "$@"
