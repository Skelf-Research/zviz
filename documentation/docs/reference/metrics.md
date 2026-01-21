# Metrics Reference

Prometheus metrics exposed by ZViz.

## Broker Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zviz_broker_requests_total` | Counter | Total requests |
| `zviz_broker_latency_seconds` | Histogram | Request latency |
| `zviz_broker_inflight` | Gauge | In-flight requests |

## Container Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zviz_containers_total` | Gauge | Total containers |
| `zviz_container_uptime_seconds` | Gauge | Container uptime |

See [Monitoring Guide](../operator-guide/monitoring.md).
