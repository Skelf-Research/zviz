# Contributing to ZViz

Thank you for your interest in contributing to ZViz! This guide will help you get started.

## Ways to Contribute

- **Report bugs** — Open an issue with a clear description
- **Suggest features** — Discuss ideas in GitHub discussions
- **Submit patches** — Fix bugs or implement features
- **Improve documentation** — Help others understand ZViz
- **Review PRs** — Help review pending changes

## Getting Started

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.0+
- Git
- Linux kernel 5.15+ (for testing)

### Development Setup

```bash
# Clone the repository
git clone https://github.com/zviz/zviz.git
cd zviz

# Build
zig build

# Run tests
zig build test

# Run specific test
zig build test -- --test-filter "broker"
```

### Project Structure

```
zviz/
├── src/
│   ├── main.zig           # Entry point
│   ├── broker/            # Syscall broker
│   ├── containment/       # Namespace setup
│   ├── seccomp/           # Seccomp filter
│   ├── lsm/               # LSM integration
│   ├── cgroup/            # cgroups interface
│   ├── network/           # Network policy
│   ├── compiler/          # Profile compiler
│   ├── schema/            # Profile schema
│   ├── runtime.zig        # OCI runtime
│   └── testing/           # Test framework
├── tests/
│   ├── integration/       # Integration tests
│   ├── syscall_tester.zig # Syscall test binary
│   └── compare_runtimes.sh
├── docs/                  # Developer docs
├── documentation/         # User docs (MkDocs)
└── build.zig
```

## Development Workflow

### 1. Create a Branch

```bash
git checkout -b feature/my-feature
```

### 2. Make Changes

Follow the [code style guide](code-style.md).

### 3. Test

```bash
# Unit tests
zig build test

# Integration tests
zig build test-integration

# All tests
zig build test-all

# Escape tests (security)
sudo ./zig-out/bin/zviz escape-test
```

### 4. Submit PR

```bash
git push origin feature/my-feature
```

Open a pull request with:

- Clear description of changes
- Link to related issue
- Test results

## Code Review

All changes require code review. Reviewers look for:

- **Correctness** — Does it work as intended?
- **Security** — No new vulnerabilities introduced
- **Performance** — No unnecessary overhead
- **Style** — Follows project conventions
- **Tests** — Adequate test coverage

## Commit Messages

Follow conventional commits:

```
type(scope): description

[optional body]

[optional footer]
```

Types:
- `feat` — New feature
- `fix` — Bug fix
- `docs` — Documentation
- `test` — Tests
- `refactor` — Code refactoring
- `perf` — Performance improvement
- `chore` — Maintenance

Example:
```
feat(broker): add openat2 support

Implement openat2 syscall mediation with RESOLVE_* flag validation.

Closes #123
```

## Security Considerations

When contributing:

1. **No secrets** — Never commit secrets or credentials
2. **Input validation** — Validate all external input
3. **Error handling** — Handle errors gracefully
4. **Audit logging** — Log security-relevant events
5. **Fuzz testing** — Add fuzz tests for parsers

Report security issues to security@zviz.io (see [Security Policy](../security/index.md)).

## Documentation

### Code Documentation

Use Zig doc comments:

```zig
/// Validates path against profile rules.
///
/// Returns `true` if the path is allowed, `false` otherwise.
/// Returns an error if the path is malformed.
pub fn validatePath(path: []const u8, profile: *const Profile) !bool {
    // ...
}
```

### User Documentation

Documentation is in `documentation/docs/` using MkDocs:

```bash
cd documentation
pip install mkdocs-material
mkdocs serve
```

## Getting Help

- **GitHub Discussions** — General questions
- **GitHub Issues** — Bug reports, feature requests
- **Email** — maintainers@zviz.io

## Code of Conduct

Be respectful and constructive. See [CODE_OF_CONDUCT.md](https://github.com/zviz/zviz/blob/main/CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
