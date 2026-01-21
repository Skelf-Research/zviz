const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Determine if this is a release build
    const is_release = optimize == .ReleaseFast or optimize == .ReleaseSmall or optimize == .ReleaseSafe;

    // Create root module for the main executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // Required for seccomp, namespace syscalls
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zviz",
        .root_module = root_module,
        .linkage = if (is_release) .static else null,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the ZViz runtime");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (separate binary)
    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_integration_tests.step);

    // All tests
    const all_tests_step = b.step("test-all", "Run all tests");
    all_tests_step.dependOn(&run_unit_tests.step);
    all_tests_step.dependOn(&run_integration_tests.step);

    // Cross-compilation targets
    const cross_targets = .{
        .{ .arch = .x86_64, .os = .linux, .abi = .gnu },
        .{ .arch = .x86_64, .os = .linux, .abi = .musl },
        .{ .arch = .aarch64, .os = .linux, .abi = .gnu },
        .{ .arch = .aarch64, .os = .linux, .abi = .musl },
    };

    const release_step = b.step("release", "Build release binaries for all targets");

    inline for (cross_targets) |ct| {
        const cross_target = b.resolveTargetQuery(.{
            .cpu_arch = ct.arch,
            .os_tag = ct.os,
            .abi = ct.abi,
        });

        const cross_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cross_target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });

        const cross_exe = b.addExecutable(.{
            .name = b.fmt("zviz-{s}-{s}", .{ @tagName(ct.arch), @tagName(ct.abi) }),
            .root_module = cross_module,
            .linkage = .static,
        });

        const install_cross = b.addInstallArtifact(cross_exe, .{});
        release_step.dependOn(&install_cross.step);
    }

    // Formatting check
    const fmt_step = b.step("fmt", "Format source code");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "tests", "build.zig" },
    });
    fmt_step.dependOn(&fmt.step);

    // Check step (compile without linking for faster feedback)
    const check_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const check = b.addExecutable(.{
        .name = "zviz",
        .root_module = check_module,
    });
    const check_step = b.step("check", "Check for compile errors");
    check_step.dependOn(&check.step);

    // Syscall tester - static binary for container testing
    // Build for musl to ensure portability across containers
    const syscall_tester_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const syscall_tester_module = b.createModule(.{
        .root_source_file = b.path("tests/syscall_tester.zig"),
        .target = syscall_tester_target,
        .optimize = .ReleaseSmall, // Small binary for easy container copy
        .link_libc = false, // Pure Zig, no libc dependency
    });

    const syscall_tester = b.addExecutable(.{
        .name = "syscall_tester",
        .root_module = syscall_tester_module,
        .linkage = .static,
    });

    const install_syscall_tester = b.addInstallArtifact(syscall_tester, .{});
    const syscall_tester_step = b.step("syscall-tester", "Build syscall tester for container comparison");
    syscall_tester_step.dependOn(&install_syscall_tester.step);

    // Also add aarch64 variant
    const syscall_tester_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const syscall_tester_arm_module = b.createModule(.{
        .root_source_file = b.path("tests/syscall_tester.zig"),
        .target = syscall_tester_arm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
    });

    const syscall_tester_arm = b.addExecutable(.{
        .name = "syscall_tester-aarch64",
        .root_module = syscall_tester_arm_module,
        .linkage = .static,
    });

    const install_syscall_tester_arm = b.addInstallArtifact(syscall_tester_arm, .{});
    syscall_tester_step.dependOn(&install_syscall_tester_arm.step);
}
