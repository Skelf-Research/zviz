# CLI Reference

Complete reference for the ZViz command-line interface.

## Synopsis

```
zviz [global-options] <command> [command-options] [arguments]
```

## Global Options

| Option | Description |
|--------|-------------|
| `--log-level <level>` | Set log level: `debug`, `info`, `warn`, `error` |
| `--log-format <format>` | Log format: `text`, `json` |
| `--config <path>` | Path to configuration file |
| `--state-dir <path>` | State directory (default: `/var/lib/zviz`) |
| `--help`, `-h` | Show help |
| `--version`, `-v` | Show version |

## OCI Runtime Commands

These commands implement the OCI Runtime Specification.

### create

Create a new container.

```bash
zviz create [options] <container-id> <bundle-path>
```

**Options:**

| Option | Description |
|--------|-------------|
| `--bundle`, `-b` | Path to the OCI bundle |
| `--console-socket` | Path to console socket for PTY |
| `--pid-file` | Write container PID to file |
| `--no-pivot` | Don't use pivot_root |
| `--no-new-keyring` | Don't create new keyring |

**Example:**

```bash
sudo zviz create my-container /path/to/bundle
```

### start

Start a created container.

```bash
zviz start <container-id>
```

**Example:**

```bash
sudo zviz start my-container
```

### run

Create and start a container in one step.

```bash
zviz run [options] <container-id> <bundle-path> [command] [args...]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--profile`, `-p` | Security profile to use |
| `--memory` | Memory limit (e.g., `256M`, `1G`) |
| `--cpus` | CPU limit (e.g., `0.5`, `2`) |
| `--pids-limit` | Maximum number of processes |
| `--network` | Network mode: `host`, `none`, `bridge` |
| `--network-allow` | Allow egress to CIDR |
| `--readonly` | Read-only rootfs |
| `--writable` | Writable paths (can repeat) |
| `--detach`, `-d` | Run in background |
| `--audit` | Enable audit logging |
| `--timeout` | Container timeout (e.g., `30m`, `1h`) |

**Examples:**

```bash
# Basic run
sudo zviz run test-container . /bin/sh

# With resource limits
sudo zviz run --memory 256M --cpus 0.5 limited . /bin/sh

# With security profile
sudo zviz run --profile ci-runner build . /bin/sh -c "make"

# Detached
sudo zviz run --detach web-server . /usr/bin/nginx
```

### exec

Execute a command in a running container.

```bash
zviz exec [options] <container-id> <command> [args...]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--tty`, `-t` | Allocate pseudo-TTY |
| `--env`, `-e` | Set environment variable |
| `--cwd` | Working directory |
| `--user`, `-u` | User to run as (UID:GID) |

**Example:**

```bash
sudo zviz exec my-container /bin/sh
sudo zviz exec --user 1000:1000 my-container /bin/ls
```

### kill

Send a signal to a container.

```bash
zviz kill [options] <container-id> [signal]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--all`, `-a` | Signal all processes in container |

**Example:**

```bash
sudo zviz kill my-container
sudo zviz kill my-container SIGTERM
sudo zviz kill --all my-container SIGKILL
```

### delete

Delete a container.

```bash
zviz delete [options] <container-id>
```

**Options:**

| Option | Description |
|--------|-------------|
| `--force`, `-f` | Force delete running container |

**Example:**

```bash
sudo zviz delete my-container
sudo zviz delete --force stuck-container
```

### state

Query container state.

```bash
zviz state <container-id>
```

**Output:**

```json
{
  "ociVersion": "1.0.2",
  "id": "my-container",
  "status": "running",
  "pid": 12345,
  "bundle": "/path/to/bundle",
  "created": "2024-01-15T10:30:00Z"
}
```

### list / ps

List all containers.

```bash
zviz list
zviz ps
```

**Output:**

```
ID                STATE     PID     BUNDLE
my-container      running   12345   /path/to/bundle
other-container   stopped   0       /other/bundle
```

### spec

Generate an OCI runtime specification.

```bash
zviz spec [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--bundle`, `-b` | Bundle path (default: current dir) |
| `--output`, `-o` | Output file (default: `config.json`) |
| `--rootless` | Generate rootless spec |

**Example:**

```bash
zviz spec
zviz spec --rootless
```

## Policy Commands

### compile

Compile a security profile.

```bash
zviz compile [options] <profile.yaml>
```

**Options:**

| Option | Description |
|--------|-------------|
| `--output`, `-o` | Output directory |
| `--validate` | Validate only, don't write |
| `--check-host` | Check host compatibility |
| `--list` | List built-in profiles |
| `--show` | Show profile details |

**Examples:**

```bash
# Compile a profile
zviz compile my-profile.yaml

# Validate without writing
zviz compile --validate my-profile.yaml

# List built-in profiles
zviz compile --list

# Show profile details
zviz compile --show ci-runner
```

## Validation Commands

### validate

Run system validation tests.

```bash
zviz validate
```

**Output:**

```
[PASS] Kernel version: 6.1.0 (>= 5.15 required)
[PASS] Seccomp user notification: available
[PASS] User namespaces: enabled
[PASS] cgroups v2: mounted
[PASS] AppArmor: enabled
```

### audit

Run security audit.

```bash
zviz audit [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--profile` | Profile to audit |
| `--output`, `-o` | Output format: `text`, `json` |

### escape-test

Run escape attempt tests.

```bash
zviz escape-test
```

Runs a suite of tests that attempt to escape the sandbox. All tests should fail (attacks should be blocked).

### benchmark

Run performance benchmarks.

```bash
zviz benchmark [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--iterations`, `-n` | Number of iterations |
| `--output`, `-o` | Output format |

### compare

Compare policy with gVisor.

```bash
zviz compare
```

Compares ZViz policy outcomes with expected gVisor behavior.

## Monitoring Commands

### metrics

Export or serve Prometheus metrics.

```bash
zviz metrics [subcommand] [options]
```

**Subcommands:**

| Command | Description |
|---------|-------------|
| (none) | Export metrics to stdout |
| `serve` | Start HTTP metrics server |

**Options for `serve`:**

| Option | Description |
|--------|-------------|
| `--addr`, `-a` | Listen address (default: `127.0.0.1:9090`) |
| `--port`, `-p` | Listen port |

**Examples:**

```bash
# Export to stdout
zviz metrics

# Start HTTP server
zviz metrics serve
zviz metrics serve --addr 0.0.0.0:9090
```

## Configuration Commands

### config

Show or generate configuration.

```bash
zviz config [options]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--generate` | Generate default config |

**Example:**

```bash
# Show current config
zviz config

# Generate default config
zviz config --generate > /etc/zviz/config.yaml
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `ZVIZ_LOG_LEVEL` | Log level |
| `ZVIZ_STATE_DIR` | State directory |
| `ZVIZ_CONFIG` | Config file path |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid arguments |
| 126 | Command not executable |
| 127 | Command not found |
| 128+N | Killed by signal N |

## See Also

- [Configuration Reference](../reference/configuration.md)
- [Profile Schema](../reference/profile-schema.md)
- [Metrics Reference](../reference/metrics.md)
