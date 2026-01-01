# Metrics Reference

Prometheus metrics exposed by ZigViz.

## Broker Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zigviz_broker_requests_total` | Counter | Total requests |
| `zigviz_broker_latency_seconds` | Histogram | Request latency |
| `zigviz_broker_inflight` | Gauge | In-flight requests |

## Container Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zigviz_containers_total` | Gauge | Total containers |
| `zigviz_container_uptime_seconds` | Gauge | Container uptime |

See [Monitoring Guide](../operator-guide/monitoring.md).
