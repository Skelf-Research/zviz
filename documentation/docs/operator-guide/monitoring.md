# Monitoring

This guide covers monitoring ZViz in production using Prometheus metrics and structured logging.

## Metrics Overview

ZViz exposes Prometheus-format metrics at `/metrics`:

```bash
# Start metrics server
zviz metrics serve --addr 0.0.0.0:9090

# Or export to stdout
zviz metrics
```

## Available Metrics

### Broker Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zviz_broker_requests_total` | Counter | Total broker requests |
| `zviz_broker_decisions_total` | Counter | Decisions by syscall and outcome |
| `zviz_broker_latency_seconds` | Histogram | Request latency |
| `zviz_broker_inflight` | Gauge | Current in-flight requests |
| `zviz_broker_errors_total` | Counter | Broker errors |

### Container Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zviz_containers_total` | Gauge | Total containers |
| `zviz_containers_by_state` | Gauge | Containers by state |
| `zviz_container_uptime_seconds` | Gauge | Container uptime |
| `zviz_container_restarts_total` | Counter | Container restarts |

### Security Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zviz_security_denials_total` | Counter | Security denials by layer |
| `zviz_seccomp_violations_total` | Counter | Seccomp violations |
| `zviz_audit_events_total` | Counter | Audit events by type |

### Resource Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zviz_memory_usage_bytes` | Gauge | Memory usage per container |
| `zviz_cpu_usage_seconds` | Counter | CPU usage per container |
| `zviz_io_read_bytes_total` | Counter | I/O read bytes |
| `zviz_io_write_bytes_total` | Counter | I/O write bytes |

## Prometheus Configuration

### Scrape Config

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'zviz'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 15s
    metrics_path: /metrics
```

### Kubernetes Service Discovery

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'zviz'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: (.+)
        replacement: $1:9090
```

## Alerting Rules

### Critical Alerts

```yaml
# zviz-alerts.yml
groups:
  - name: zviz.critical
    rules:
      - alert: ZVizBrokerDown
        expr: up{job="zviz"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ZViz broker is down"
          description: "ZViz broker on {{ $labels.instance }} is not responding"

      - alert: ZVizSecurityViolation
        expr: rate(zviz_security_denials_total[5m]) > 10
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "High rate of security denials"
          description: "{{ $value }} security denials per second"

      - alert: ZVizBrokerLatencyHigh
        expr: histogram_quantile(0.99, rate(zviz_broker_latency_seconds_bucket[5m])) > 0.01
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Broker p99 latency above 10ms"
          description: "Broker latency is {{ $value }}s"
```

### Warning Alerts

```yaml
groups:
  - name: zviz.warning
    rules:
      - alert: ZVizHighInflight
        expr: zviz_broker_inflight > 200
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High number of in-flight broker requests"

      - alert: ZVizErrorRate
        expr: rate(zviz_broker_errors_total[5m]) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Elevated broker error rate"
```

## Grafana Dashboards

### Overview Dashboard

Import the ZViz overview dashboard:

```json
{
  "dashboard": {
    "title": "ZViz Overview",
    "panels": [
      {
        "title": "Broker Requests/sec",
        "targets": [
          {
            "expr": "rate(zviz_broker_requests_total[5m])"
          }
        ]
      },
      {
        "title": "Broker Latency (p99)",
        "targets": [
          {
            "expr": "histogram_quantile(0.99, rate(zviz_broker_latency_seconds_bucket[5m]))"
          }
        ]
      },
      {
        "title": "Security Denials",
        "targets": [
          {
            "expr": "rate(zviz_security_denials_total[5m])"
          }
        ]
      },
      {
        "title": "Active Containers",
        "targets": [
          {
            "expr": "zviz_containers_by_state{state=\"running\"}"
          }
        ]
      }
    ]
  }
}
```

### Key Panels

1. **Request Rate** — `rate(zviz_broker_requests_total[5m])`
2. **Latency Percentiles** — `histogram_quantile(0.99, ...)`
3. **Decision Breakdown** — `sum by (decision) (rate(zviz_broker_decisions_total[5m]))`
4. **Error Rate** — `rate(zviz_broker_errors_total[5m])`
5. **Container Count** — `zviz_containers_total`

## Logging

### Log Configuration

```yaml
# /etc/zviz/config.yaml
logging:
  level: info          # debug, info, warn, error
  format: json         # text, json
  output: /var/log/zviz/zviz.log
  audit:
    enabled: true
    path: /var/log/zviz/audit.json
```

### Log Format

```json
{
  "timestamp": "2024-01-15T10:30:00.123Z",
  "level": "info",
  "message": "container created",
  "container_id": "abc123",
  "profile": "ci-runner",
  "pid": 12345
}
```

### Audit Log Format

```json
{
  "timestamp": "2024-01-15T10:30:00.123Z",
  "event_type": "syscall",
  "container_id": "abc123",
  "syscall": "openat",
  "args": {
    "path": "/etc/passwd",
    "flags": "O_RDONLY"
  },
  "decision": "allow",
  "latency_us": 45,
  "layer": "broker"
}
```

### Log Aggregation

#### Fluentd

```yaml
# fluentd.conf
<source>
  @type tail
  path /var/log/zviz/*.json
  pos_file /var/log/fluentd/zviz.pos
  tag zviz
  <parse>
    @type json
  </parse>
</source>

<match zviz>
  @type elasticsearch
  host elasticsearch
  port 9200
  index_name zviz
</match>
```

#### Loki

```yaml
# promtail.yaml
scrape_configs:
  - job_name: zviz
    static_configs:
      - targets:
          - localhost
        labels:
          job: zviz
          __path__: /var/log/zviz/*.json
    pipeline_stages:
      - json:
          expressions:
            level: level
            container_id: container_id
      - labels:
          level:
          container_id:
```

## Health Checks

### HTTP Health Endpoint

```bash
curl http://localhost:9090/health
```

Response:
```json
{
  "status": "healthy",
  "version": "0.1.0",
  "uptime": 86400,
  "containers": 42,
  "broker": {
    "status": "running",
    "inflight": 5
  }
}
```

### Kubernetes Probes

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 9090
  initialDelaySeconds: 10
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /health
    port: 9090
  initialDelaySeconds: 5
  periodSeconds: 5
```

## Best Practices

### 1. Set Appropriate Scrape Intervals

- **Production**: 15-30 seconds
- **Debugging**: 5 seconds

### 2. Use Recording Rules

```yaml
groups:
  - name: zviz.rules
    rules:
      - record: zviz:broker_latency:p99
        expr: histogram_quantile(0.99, rate(zviz_broker_latency_seconds_bucket[5m]))
```

### 3. Retain Audit Logs

Keep audit logs for compliance:

```yaml
logging:
  audit:
    retention_days: 90
    compress: true
```

### 4. Monitor Cardinality

Watch for high cardinality from container IDs:

```bash
# Check cardinality
curl -s localhost:9090/metrics | grep -c zviz_
```

## See Also

- [Metrics Reference](../reference/metrics.md)
- [Debugging Guide](debugging.md)
- [Performance Tuning](performance.md)
